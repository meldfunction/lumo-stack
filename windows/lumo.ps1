<#
Lumo Stack for native Windows: one command, services under Docker Compose (Docker Desktop).
macOS uses the repo-root scripts and Linux/WSL2 uses linux/lumo; this file touches neither.

  lumo up | down | restart | status | logs [service]
  lumo login [-Browser]            sign in to Proton (password login; browser if Proton wants a CAPTCHA)
  lumo code [-Project name] [-Max] [opencode args]  the jailed coding agent (sees only ~\lumo)
  lumo code -Web | code-web stop   the same agent in your browser (:4096)
  lumo web [stop]                  chat in your browser (Open WebUI, :8080)
  lumo claude [args]               Claude Code on Lumo: UNSANDBOXED on Windows, so off unless LUMO_NO_SANDBOX=1
  lumo cloudflare on|off|status    opt in to Cloudflare Workers AI models
  lumo doctor                      check everything
  lumo update                      rebuild for the versions in versions.env, roll back if it fails
  lumo uninstall [-Purge]          remove containers + command (-Purge: configs, login, chats too)
  add -DryRun to see what a command would do; put -- before agent options (lumo code -- --continue)
#>
#Requires -Version 7.2
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [string]$Project = '',
  [switch]$Max, [switch]$Web, [switch]$Browser, [switch]$Purge, [switch]$Forget, [switch]$NewToken, [switch]$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]$Rest = @()
)
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:DryRun = [bool]$DryRun
$CodeImage = "lumo-opencode:$($S.OPENCODE_VERSION)"
$Base = @('bridge', 'tamer', 'litellm', 'relay')

function Assert-Installed { if (-not ((Test-Path $LiteCfg) -and (Test-Path $TamerCfg))) { Stop-Lumo "not installed yet: run $(Join-Path $WinDir 'install.ps1')" } }
function Get-AuthStatus { (& docker compose -f $Compose exec -T tamer tamer auth status 2>&1 | Out-String) -replace "`e\[[0-9;]*m", '' }

function Invoke-Up {
  Assert-Installed
  if (-not (Test-RoutesAllowed)) { Stop-Lumo 'LiteLLM config routes somewhere other than lumo-bridge or your Cloudflare account' }
  if ((Test-Healthy) -and -not $DryRun) { return }
  Write-Log 'up'
  if (-not (Invoke-Dc up -d @Base)) { Stop-Lumo 'docker compose up failed (lumo logs)' }
  if (-not (Wait-Up)) { Stop-Lumo "the stack didn't come up (lumo logs)" }
}

function Invoke-Login([switch]$UseBrowser) {
  Assert-Installed; Invoke-Up
  $cliLog = Join-Path $Data 'sessions\lumo-tamer-cli.log'
  if ($UseBrowser) {
    Write-Log 'login: browser'
    if (-not (Invoke-Dc --profile browser up -d browser)) { Stop-Lumo "couldn't start the sign-in browser" }
    Write-Host "Open http://127.0.0.1:$($S.BROWSER_PORT), sign in to Proton there, then come back here."
    if (-not $DryRun) { Start-Process "http://127.0.0.1:$($S.BROWSER_PORT)" }
    if ($DryRun) { Write-Host '[dry-run] docker compose run --rm tamer auth browser' } else { & docker compose -f $Compose run --rm tamer auth browser }
    $rc = $LASTEXITCODE
    $null = Invoke-Dc --profile browser stop browser
    if ($rc) { Stop-Lumo "browser sign-in didn't finish" }
  } else {
    Write-Log 'login: password'
    # The bridge logs to sessions\lumo-tamer-cli.log; new lines there tell us if Proton wanted a CAPTCHA.
    $before = if (Test-Path $cliLog) { (Get-Item $cliLog).Length } else { 0 }
    if ($DryRun) { Write-Host '[dry-run] docker compose run --rm tamer auth login'; return }
    & docker compose -f $Compose run --rm tamer auth login
    if (Test-Path $cliLog) {
      $fs = [IO.File]::Open($cliLog, 'Open', 'Read', 'ReadWrite'); $null = $fs.Seek($before, 'Begin')
      $new = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
      if ($new -match 'Code=9001|CAPTCHA') { Write-Host 'Proton asked for a CAPTCHA. Switching to the browser sign-in...'; Invoke-Login -UseBrowser; return }
    }
  }
  if ($DryRun) { return }
  $null = Invoke-Dc restart tamer; Start-Sleep 4
  if ((Get-AuthStatus) -match 'configured and valid') { Write-Host 'Signed in. Lumo is answering.' }
  else { Stop-Lumo "sign-in didn't finish: check your password, second password and authenticator code, then retry" }
}

function Invoke-Code([string]$Proj, [switch]$UseMax, [switch]$UseWeb, [string[]]$AgentArgs) {
  if ($Proj -and $Proj -notmatch '^[A-Za-z0-9._-]+$') { Stop-Lumo 'project names: letters, digits, . _ - only' }
  Write-Log "code: project=$(if ($Proj) { $Proj } else { '<root>' }) max=$([int][bool]$UseMax) web=$([int][bool]$UseWeb)"
  $oc = Join-Path $Stack 'opencode.json'
  if (-not (Select-String -LiteralPath $oc -SimpleMatch '"baseURL": "http://lumo-relay:4000/v1"' -Quiet)) { Stop-Lumo 'opencode.json points somewhere other than lumo-relay' }
  Assert-Installed
  if (-not (Test-LumoOnly)) { Stop-Lumo 'LiteLLM routes beyond Lumo (lumo cloudflare off first): the jail is Lumo-only' }
  Invoke-Up
  & docker image inspect $CodeImage *> $null
  if ($LASTEXITCODE -and -not (Invoke-Step docker build -q -t $CodeImage -f (Join-Path $Stack 'Dockerfile.opencode') $Stack)) { Stop-Lumo "couldn't build $CodeImage" }
  if (-not $DryRun -and ((& docker network inspect -f '{{.Internal}}' $S.LUMO_JAIL_NET 2>$null) -ne 'true')) { Stop-Lumo "network $($S.LUMO_JAIL_NET) missing or not internal" }

  # Project folder, AGENTS.md for new projects, and a git snapshot so work can be undone.
  $codeRoot = Join-Path $S.LUMO_HOME 'code'
  $dir = if ($Proj) { Join-Path $codeRoot $Proj } else { $codeRoot }
  $wdir = if ($Proj) { "/lumo/code/$Proj" } else { '/lumo/code' }
  $ocHome = Join-Path $Data 'opencode-home'
  if (-not $DryRun) {
    foreach ($d in $dir, (Join-Path $S.LUMO_HOME 'inbox'), (Join-Path $S.LUMO_HOME 'out'), (Join-Path $ocHome '.config\opencode'), (Join-Path $ocHome '.cache'), (Join-Path $ocHome '.local\share')) {
      New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    $mp = Join-Path $ocHome '.config\opencode\opencode.json'; if (-not (Test-Path $mp)) { New-Item -ItemType File -Path $mp | Out-Null }
    $agents = Join-Path $dir 'AGENTS.md'
    if ($Proj -and -not (Test-Path $agents)) {
      [IO.File]::WriteAllText($agents, (Get-Content -Raw (Join-Path $Stack 'templates\AGENTS.md')).Replace('{{PROJECT}}', $Proj))
    }
    $g = @('-C', $dir, '-c', 'user.name=lumo', '-c', 'user.email=lumo@localhost')
    if (-not (Test-Path (Join-Path $dir '.git'))) { & git @g init -q }
    $dirty = & git @g status --porcelain 2>$null
    & git @g rev-parse -q HEAD *> $null; $noHead = [bool]$LASTEXITCODE
    if ($dirty -or $noHead) { & git @g add -A; & git @g commit -qm "lumo snapshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" --allow-empty }
  }

  $env:LITELLM_KEY = Get-LitellmKey
  $dp = { param($p) ConvertTo-DockerPath $p }
  $jail = @(
    '--read-only', '--tmpfs', '/tmp:rw,exec,nosuid,size=512m',
    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
    '--pids-limit', '512', '--memory', '4g', '--cpus', '4',
    '--user', '1000:1000', '-e', 'HOME=/home/node',
    '--network', $S.LUMO_JAIL_NET,
    '-e', 'LITELLM_KEY',
    '-e', 'OPENCODE_DISABLE_MODELS_FETCH=1', '-e', 'OPENCODE_DISABLE_DEFAULT_PLUGINS=1',
    '-e', 'OPENCODE_DISABLE_LSP_DOWNLOAD=1', '-e', 'OPENCODE_DISABLE_AUTOUPDATE=1', '-e', 'OPENCODE_DISABLE_EXTERNAL_SKILLS=1',
    '-v', "$(& $dp $ocHome):/home/node",
    '-v', "$(& $dp $oc):/home/node/.config/opencode/opencode.json:ro",
    '-v', "$(& $dp $codeRoot):/lumo/code",
    '-v', "$(& $dp (Join-Path $S.LUMO_HOME 'inbox')):/lumo/inbox:ro",
    '-v', "$(& $dp (Join-Path $S.LUMO_HOME 'out')):/lumo/out",
    '-w', $wdir
  )
  $model = if ($UseMax) { @('-m', 'lumo/lumo-max') } else { @() }

  if ($UseWeb) {
    # Browser UI: the jail network can't publish ports, so also attach a bridge without
    # masquerading (no route to the internet) and publish 127.0.0.1:4096 only.
    $webnet = "$($S.LUMO_PROJECT)-web-only"; $name = "$($S.LUMO_PROJECT)-code-web"; $port = $S.CODE_WEB_PORT
    & docker network inspect $webnet *> $null
    if ($LASTEXITCODE) { $null = Invoke-Step docker network create -o com.docker.network.bridge.enable_ip_masquerade=false $webnet }
    $env:OPENCODE_SERVER_USERNAME = 'lumo'
    $env:OPENCODE_SERVER_PASSWORD = Get-Secret 'code-web' 'password'
    if (-not $env:OPENCODE_SERVER_PASSWORD) {
      $env:OPENCODE_SERVER_PASSWORD = (New-RandomHex 12)
      if (-not $DryRun) { Set-Secret 'code-web' 'password' $env:OPENCODE_SERVER_PASSWORD }
    }
    & docker rm -f $name *> $null
    $ok = (Invoke-Step docker create --name $name @jail -p "127.0.0.1:${port}:${port}" -e OPENCODE_SERVER_USERNAME -e OPENCODE_SERVER_PASSWORD $CodeImage web --hostname 0.0.0.0 --port $port) -and
          (Invoke-Step docker network disconnect $S.LUMO_JAIL_NET $name) -and
          (Invoke-Step docker network connect $webnet $name) -and
          (Invoke-Step docker network connect $S.LUMO_JAIL_NET $name) -and
          (Invoke-Step docker start $name)
    if (-not $ok) { Stop-Lumo "couldn't start the browser agent ($name)" }
    Write-Host "Lumo Code (browser): http://localhost:$port  (stop: lumo code-web stop)"
    Write-Host "  login: lumo / password: Get-Content `"$(Join-Path $Secrets 'code-web\password')`""
    return
  }

  $tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { @('-i') } else { @('-it') }
  $a = @($AgentArgs)
  if ($model) { if ($a.Count -and $a[0] -eq 'run') { $a = @('run') + $model + @($a | Select-Object -Skip 1) } else { $a = $model + $a } }
  if ($DryRun) { Write-Host "[dry-run] docker run --rm $($tty -join ' ') $($jail -join ' ') $CodeImage $($a -join ' ')"; return }
  & docker run --rm @tty @jail $CodeImage @a
  exit $LASTEXITCODE
}

function Invoke-WebUi([string]$Sub) {
  Assert-Installed
  switch ($Sub) {
    'stop'   { $null = Invoke-Dc --profile web stop webui; return }
    'status' { $null = Invoke-Dc --profile web ps webui; return }
  }
  Invoke-Up
  if (-not (Invoke-Dc --profile web up -d webui)) { Stop-Lumo "couldn't start Open WebUI" }
  $url = "http://127.0.0.1:$($S.WEBUI_PORT)/health"
  if (-not $DryRun) {
    Write-Host -NoNewline 'Waiting for Open WebUI'
    for ($i = 0; $i -lt 90; $i++) {
      $ok = try { (Invoke-RestMethod -Uri $url -TimeoutSec 2).status -eq $true } catch { $false }
      if ($ok) { break }; Write-Host -NoNewline '.'; Start-Sleep 2
    }
    Write-Host ''
    if (-not $ok) { Stop-Lumo "Open WebUI didn't come up (lumo logs webui)" }
  }
  Write-Host "Open WebUI ready: http://localhost:$($S.WEBUI_PORT)"
  if (-not $env:LUMO_WEB_NO_OPEN -and -not $DryRun) { Start-Process "http://localhost:$($S.WEBUI_PORT)" }
}

function Test-CfToken {
  $k = Get-Secret 'litellm' 'cloudflare-api-key'; if (-not $k -or -not $S.CF_ACCOUNT_ID) { return $false }
  $h = @{ Authorization = "Bearer $k" }
  foreach ($u in "https://api.cloudflare.com/client/v4/accounts/$($S.CF_ACCOUNT_ID)/tokens/verify", 'https://api.cloudflare.com/client/v4/user/tokens/verify') {
    try { if ((Invoke-RestMethod -Uri $u -Headers $h -TimeoutSec 20).success) { return $true } } catch { }
  }
  return $false
}

function Invoke-Cloudflare([string]$Sub) {
  Assert-Installed
  switch ($Sub) {
    'on' {
      if (-not $S.CF_ACCOUNT_ID) { $S.CF_ACCOUNT_ID = Read-Host 'Cloudflare account ID' }
      if ($S.CF_ACCOUNT_ID -notmatch '^[0-9a-f]{32}$') { Stop-Lumo "that doesn't look like an account ID (32 hex characters)" }
      if ($NewToken -or -not (Get-Secret 'litellm' 'cloudflare-api-key')) {
        Write-Host 'API token (Cloudflare dashboard > My Profile > API Tokens > "Workers AI" template).'
        $t = Read-Host 'Token (hidden)' -MaskInput
        if (-not $t) { Stop-Lumo 'no token given' }
        if (-not $DryRun) { Set-Secret 'litellm' 'cloudflare-api-key' $t }
      }
      if ($DryRun) { Write-Host '[dry-run] add cf-* models, restart litellm'; return }
      if (-not (Test-CfToken)) { Stop-Lumo "Cloudflare rejected that token for account $($S.CF_ACCOUNT_ID)" }
      Set-LumoEnv 'CF_ACCOUNT_ID' $S.CF_ACCOUNT_ID; $env:CF_ACCOUNT_ID = $S.CF_ACCOUNT_ID
      Edit-CloudflareBlock add
      if ((Invoke-Dc up -d --force-recreate litellm) -and (Wait-Up)) { Write-Host 'Cloudflare models on.' }
    }
    'off' {
      if ($DryRun) { Write-Host "[dry-run] remove cf-* models$(if ($Forget) { ', delete token' }), restart litellm"; return }
      Edit-CloudflareBlock remove
      if ($Forget) { Remove-Secret 'litellm' 'cloudflare-api-key'; Set-LumoEnv 'CF_ACCOUNT_ID' ''; Write-Host 'Token and account ID deleted.' }
      if ((Invoke-Dc up -d --force-recreate litellm) -and (Wait-Up)) { Write-Host 'Cloudflare models off. Lumo only.' }
    }
    { $_ -in 'status', '' } {
      Write-Host "models     : $(@(Select-String -LiteralPath $LiteCfg -Pattern 'model_name: cf-').Count) cf-* in LiteLLM"
      Write-Host "account    : $(if ($S.CF_ACCOUNT_ID) { $S.CF_ACCOUNT_ID } else { 'none' })"
      if (Get-Secret 'litellm' 'cloudflare-api-key') { Write-Host "token      : in $Secrets\litellm, $(if (Test-CfToken) { 'valid' } else { 'REJECTED' })" }
      else { Write-Host 'token      : none' }
    }
    default { Stop-Lumo 'usage: lumo cloudflare on [-NewToken] | off [-Forget] | status' }
  }
}

function Invoke-Doctor {
  $script:bad = $false
  function Check([string]$Name, [scriptblock]$Test, [string]$Fix = '') {
    $ok = try { [bool](& $Test) } catch { $false }
    if ($ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name$(if ($Fix) { "  ->  $Fix" })" -ForegroundColor Red; $script:bad = $true }
  }
  Write-Host 'Lumo Stack doctor (Windows)'
  Check 'docker running'            { & docker info *> $null; $LASTEXITCODE -eq 0 } 'start Docker Desktop'
  Check 'docker compose v2'         { & docker compose version *> $null; $LASTEXITCODE -eq 0 } 'update Docker Desktop'
  Check "installed ($Conf)"         { (Test-Path $LiteCfg) -and (Test-Path $TamerCfg) } (Join-Path $WinDir 'install.ps1')
  Check 'config folder: only you can read it' { Test-UserOnly $Conf } 're-run install.ps1'
  Check 'vault key present'         { [bool](Get-Secret 'tamer' 'lumo-vault-key') } 're-run install.ps1'
  Check "routes: Lumo$(if ($S.CF_ACCOUNT_ID) { ' + Cloudflare' }) only" { Test-RoutesAllowed } "check $LiteCfg"
  Check "lumo-bridge on 127.0.0.1:$($S.TAMER_PORT)" { Test-Url "http://127.0.0.1:$($S.TAMER_PORT)/health" } 'lumo up'
  Check "LiteLLM on 127.0.0.1:$($S.LITELLM_PORT)"   { Test-Url "http://127.0.0.1:$($S.LITELLM_PORT)/health/liveliness" } 'lumo up'
  Check 'ports bound to 127.0.0.1 only' { -not ((& docker compose -f $Compose ps --format '{{.Ports}}' | Out-String) -match '0\.0\.0\.0:|:::') } 'check compose.yaml'
  Check 'jail network is internal'  { (& docker network inspect -f '{{.Internal}}' $S.LUMO_JAIL_NET 2>$null) -eq 'true' } 'lumo up'
  Check 'Proton sign-in valid'      { (Get-AuthStatus) -match 'configured and valid' } 'lumo login'
  Check 'Lumo answers' {
    $body = @{ model = 'lumo-lite'; max_tokens = 5; messages = @(@{ role = 'user'; content = 'Reply with: ok' }) } | ConvertTo-Json -Depth 4
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$($S.LITELLM_PORT)/v1/chat/completions" -Method Post -TimeoutSec 60 `
      -Headers @{ Authorization = "Bearer $(Get-LitellmKey)" } -ContentType 'application/json' -Body $body
    [bool]$r.choices
  } 'lumo login'
  if ($S.CF_ACCOUNT_ID) { Check 'Cloudflare token valid' { Test-CfToken } 'lumo cloudflare on -NewToken' }
  Check 'claude-lumo: off on Windows (no sandbox)' { -not ($env:LUMO_NO_SANDBOX -eq '1') } 'unset LUMO_NO_SANDBOX, or use WSL2 for a sandboxed claude-lumo'
  if ($script:bad) { exit 1 }
}

function Invoke-Update {
  Assert-Installed
  $old = [ordered]@{}; foreach ($k in $S.Keys) { $old[$k] = $S[$k] }
  if (Test-Path (Join-Path $Stack '.git')) {
    if (-not (Invoke-Step git -C $Stack pull --ff-only)) { Stop-Lumo "couldn't update the stack (local changes?)" }
    $v = Read-EnvFile (Join-Path $Stack 'versions.env'); foreach ($k in $v.Keys) { $S[$k] = $v[$k] }; Set-ComposeEnv
  }
  Write-Log "update: tamer=$($S.TAMER_COMMIT) litellm=$($S.LITELLM_VERSION)"
  $ok = (Update-TamerSrc) -and (Invoke-Dc build tamer litellm) -and (Invoke-Dc pull bridge relay) -and (Invoke-Dc --profile web pull webui) -and
        (Invoke-Step docker build -q -t "lumo-opencode:$($S.OPENCODE_VERSION)" -f (Join-Path $Stack 'Dockerfile.opencode') $Stack)
  if (-not $ok) { Stop-Lumo 'build failed; nothing changed' }
  $null = Invoke-Dc up -d @Base
  if (Wait-Up) { Write-Host "Updated: lumo-bridge $($S.TAMER_COMMIT), LiteLLM $($S.LITELLM_VERSION)."; return }
  # Roll back: the previous images are still tagged by version, so start those again.
  Write-Log 'update: failed, rolling back'
  foreach ($k in $old.Keys) { $S[$k] = $old[$k] }; Set-ComposeEnv
  $null = Invoke-Dc up -d @Base; $null = Wait-Up
  Stop-Lumo "the new versions didn't start; rolled back to lumo-bridge $($S.TAMER_COMMIT), LiteLLM $($S.LITELLM_VERSION)"
}

function Invoke-Uninstall {
  Write-Host "Removing Lumo Stack containers$(if ($Purge) { ', configs, sign-in and chats' })."
  $down = @('--profile', 'web', '--profile', 'browser', 'down') + $(if ($Purge) { @('--volumes') } else { @() })
  $null = Invoke-Dc @down
  & docker rm -f "$($S.LUMO_PROJECT)-code-web" *> $null
  & docker network rm "$($S.LUMO_PROJECT)-web-only" *> $null
  foreach ($f in 'lumo.cmd', 'claude-lumo.cmd') { $p = Join-Path $BinDir $f; if (Test-Path $p) { if ($DryRun) { Write-Host "[dry-run] remove $p" } else { Remove-Item -Force $p } } }
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -and ($userPath -split ';') -contains $BinDir -and -not $DryRun) {
    [Environment]::SetEnvironmentVariable('Path', (($userPath -split ';') | Where-Object { $_ -and $_ -ne $BinDir }) -join ';', 'User')
  }
  if ($Purge) {
    if ($DryRun) { Write-Host "[dry-run] remove $Conf and $Data" } else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Conf, $Data }
    Write-Host "Configs, secrets and the Proton login are deleted. Your workspace ($($S.LUMO_HOME)) is kept."
  } else {
    Write-Host "Kept: $Conf (configs, secrets), $Data (login), $($S.LUMO_HOME) (workspace). -Purge removes the first two."
  }
}

switch ($Command) {
  'up'         { Invoke-Up }
  'down'       { Assert-Installed; $null = Invoke-Dc --profile web --profile browser stop }
  'restart'    { Assert-Installed; $null = Invoke-Dc restart; $null = Wait-Up }
  'status'     { Assert-Installed; $null = Invoke-Dc --profile web ps; Write-Host ''; ((Get-AuthStatus) -split "`n" | Select-String -Pattern 'valid|expire|not' | Select-Object -First 3) | Out-Host }
  'logs'       { $n = if ($env:LUMO_LOG_LINES) { $env:LUMO_LOG_LINES } else { '100' }; & docker compose -f $Compose logs --tail $n @Rest }
  'login'      { Invoke-Login -UseBrowser:$Browser }
  'code'       { Invoke-Code -Proj $Project -UseMax:$Max -UseWeb:$Web -AgentArgs $Rest }
  'code-web'   { if ($Rest -contains 'stop') { & docker rm -f "$($S.LUMO_PROJECT)-code-web" *> $null; Write-Host 'stopped' } else { Invoke-Code -Proj $Project -UseWeb } }
  'web'        { Invoke-WebUi ($Rest | Select-Object -First 1) }
  'claude'     { & (Join-Path $WinDir 'claude-lumo.ps1') @Rest; exit $LASTEXITCODE }
  'cloudflare' { Invoke-Cloudflare ([string]($Rest | Select-Object -First 1)) }
  'doctor'     { Invoke-Doctor }
  'update'     { Invoke-Update }
  'uninstall'  { Invoke-Uninstall }
  { $_ -in 'help', '-h', '--help' } { Get-Content $PSCommandPath | Select-Object -Skip 1 -First 17 | Out-Host }
  default      { Stop-Lumo "unknown command '$Command' (lumo help)" }
}
