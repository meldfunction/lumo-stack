# Shared settings and helpers for the native Windows scripts (PowerShell 7). Dot-source it.
# macOS uses the repo-root scripts, Linux/WSL2 uses linux/. This file touches neither.
#Requires -Version 7.2
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

$script:Stack   = Split-Path -Parent $PSScriptRoot
$script:WinDir  = $PSScriptRoot
$script:Conf    = if ($env:LUMO_CONF) { $env:LUMO_CONF } else { Join-Path $env:APPDATA 'lumo-stack' }       # configs + secrets (user-only)
$script:Data    = if ($env:LUMO_DATA) { $env:LUMO_DATA } else { Join-Path $env:LOCALAPPDATA 'lumo-stack' }  # login, sources, logs
$script:Secrets = Join-Path $Conf 'secrets'
$script:LiteCfg = Join-Path $Conf 'litellm-config.yaml'
$script:TamerCfg = Join-Path $Conf 'tamer-config.yaml'
$script:TamerSrc = Join-Path $Data 'src\lumo-bridge'
$script:BinDir  = Join-Path $Data 'bin'
$script:LogDir  = Join-Path $Data 'logs'
$script:Compose = Join-Path $Stack 'compose\compose.yaml'
$script:DryRun  = $false

function Read-EnvFile([string]$Path) {
  # KEY=value lines; ignores comments and blank lines, strips trailing "# ..." comments.
  $h = [ordered]@{}
  if (Test-Path -LiteralPath $Path) {
    foreach ($l in Get-Content -LiteralPath $Path) {
      if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*(#.*)?$') { $h[$Matches[1]] = $Matches[2].Trim().Trim('"') }
    }
  }
  $h
}

# Settings: defaults < versions.env < this machine's lumo.env (ports, Cloudflare account).
$script:S = [ordered]@{
  LUMO_HOME = Join-Path $HOME 'lumo'; LUMO_PROJECT = 'lumo'; LUMO_JAIL_NET = 'lumo-jail'
  TAMER_PORT = '3003'; LITELLM_PORT = '4000'; WEBUI_PORT = '8080'; CODE_WEB_PORT = '4096'; BROWSER_PORT = '3001'
  CF_ACCOUNT_ID = ''
}
foreach ($src in @((Join-Path $Stack 'versions.env'), (Join-Path $Conf 'lumo.env'))) {
  $e = Read-EnvFile $src; foreach ($k in $e.Keys) { $S[$k] = $e[$k] }
}

function ConvertTo-DockerPath([string]$p) { $p -replace '\\', '/' }   # C:\x\y -> C:/x/y (Compose and docker -v accept it)

function Set-ComposeEnv {
  # Compose reads these from the environment (see compose/compose.yaml). Docker Desktop's file
  # sharing ignores Unix owners, so containers run as 1000:1000 here.
  $env:LUMO_CONF = ConvertTo-DockerPath $Conf
  $env:LUMO_DATA = ConvertTo-DockerPath $Data
  $env:TAMER_SRC = ConvertTo-DockerPath $TamerSrc
  $env:LUMO_UID = '1000'; $env:LUMO_GID = '1000'
  foreach ($k in 'LUMO_PROJECT','LUMO_JAIL_NET','TAMER_PORT','LITELLM_PORT','WEBUI_PORT','BROWSER_PORT',
                 'TAMER_COMMIT','LITELLM_VERSION','WEBUI_IMAGE','SOCAT_IMAGE','CF_ACCOUNT_ID') {
    Set-Item -Path "env:$k" -Value ([string]$S[$k])
  }
}
Set-ComposeEnv

function Write-Log([string]$msg) {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  Add-Content -LiteralPath (Join-Path $LogDir 'lumo.log') -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] $msg"
}
function Stop-Lumo([string]$msg) { Write-Log "ABORT: $msg"; Write-Host "lumo: $msg" -ForegroundColor Red; exit 1 }

# Run a native command (output to the console, not the pipeline), or only print it with -DryRun.
# Returns $true on exit code 0. Interactive commands (sign-in, the agent) are called directly instead.
function Invoke-Step {
  param([Parameter(Mandatory)][string]$Exe, [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
  if ($DryRun) { Write-Host "[dry-run] $Exe $($Rest -join ' ')" -ForegroundColor DarkGray; return $true }
  & $Exe @Rest | Out-Host
  return ($LASTEXITCODE -eq 0)
}
function Invoke-Dc { param([Parameter(ValueFromRemainingArguments)][string[]]$Rest) Invoke-Step docker compose -f $Compose @Rest }

function Test-Url([string]$Url, [int]$Timeout = 3) {
  try { $null = Invoke-WebRequest -Uri $Url -TimeoutSec $Timeout -SkipHttpErrorCheck -UseBasicParsing; return $true } catch { return $false }
}
function Test-Healthy {
  (Test-Url "http://127.0.0.1:$($S.TAMER_PORT)/health") -and (Test-Url "http://127.0.0.1:$($S.LITELLM_PORT)/health/liveliness")
}
function Wait-Up {
  if ($DryRun) { return $true }
  Write-Host -NoNewline 'Waiting for lumo-bridge and LiteLLM'
  for ($i = 0; $i -lt 60; $i++) { if (Test-Healthy) { Write-Host ''; return $true }; Write-Host -NoNewline '.'; Start-Sleep 2 }
  Write-Host ''; return $false
}

function New-RandomHex([int]$Bytes = 24) { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes)).ToLower() }
function Get-YamlValue([string]$Path, [string]$Key) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $m = Select-String -LiteralPath $Path -Pattern "^  ${Key}: `"(.*)`"" | Select-Object -First 1
  if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
}
function Get-LitellmKey { Get-YamlValue $LiteCfg 'master_key' }
function Get-TamerKey   { Get-YamlValue $TamerCfg 'apiKey' }

# Secrets and configs: files under %APPDATA%\lumo-stack, which is locked to your user only
# (inheritance off, no Administrators/SYSTEM entries). Weaker than the macOS Keychain: any
# program running as you can read them.
function Protect-UserOnly([string]$Path) {
  $who = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
  $grant = if ((Get-Item -LiteralPath $Path).PSIsContainer) { "${who}:(OI)(CI)F" } else { "${who}:F" }
  & icacls $Path /inheritance:r /grant:r $grant /q | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-Lumo "couldn't restrict access to $Path" }
}
function Test-UserOnly([string]$Path) {
  # True when every ACL entry belongs to the current user.
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $Path
  if (-not $acl.AreAccessRulesProtected) { return $false }
  foreach ($r in $acl.Access) {
    $sid = try { $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) } catch { $null }
    if ($sid -ne $me) { return $false }
  }
  return $true
}
function Write-PrivateFile([string]$Path, [string]$Content) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [IO.File]::WriteAllText($Path, $Content)   # UTF-8, no BOM
}
function Set-Secret([string]$Container, [string]$Name, [string]$Value) { Write-PrivateFile (Join-Path $Secrets "$Container\$Name") $Value }
function Get-Secret([string]$Container, [string]$Name) {
  $p = Join-Path $Secrets "$Container\$Name"; if (Test-Path -LiteralPath $p) { (Get-Content -Raw -LiteralPath $p).Trim() } else { '' }
}
function Remove-Secret([string]$Container, [string]$Name) { Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $Secrets "$Container\$Name") }

function Expand-Template([string]$Template, [hashtable]$Vars) {
  (Get-Content -Raw -LiteralPath $Template) -replace '\{\{([A-Z_]+)\}\}', { $Vars[$_.Groups[1].Value] }
}

function Set-LumoEnv([string]$Name, [string]$Value) {
  # Edit this machine's lumo.env: replace NAME=..., or remove it when Value is empty.
  $f = Join-Path $Conf 'lumo.env'
  $lines = @(if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | Where-Object { $_ -notmatch "^$Name=" } })
  if ($Value) { $lines += "$Name=$Value" }
  Write-PrivateFile $f (($lines -join "`n") + "`n")
}

# Keep the lumo-bridge checkout at TAMER_COMMIT (Docker can't build a short commit over git).
function Update-TamerSrc {
  if ($DryRun) { Write-Host "[dry-run] lumo-bridge checkout at $($S.TAMER_COMMIT) in $TamerSrc" -ForegroundColor DarkGray; return $true }
  if (-not (Test-Path -LiteralPath (Join-Path $TamerSrc '.git'))) {
    & git -c core.autocrlf=false clone -q https://github.com/meldfunction/lumo-bridge.git $TamerSrc; if ($LASTEXITCODE) { return $false }
  }
  & git -C $TamerSrc cat-file -e "$($S.TAMER_COMMIT)^{commit}" 2>$null
  if ($LASTEXITCODE) { & git -C $TamerSrc fetch -q origin; if ($LASTEXITCODE) { return $false } }
  # Line endings must stay LF inside the image (shell scripts), whatever git's Windows default is.
  & git -C $TamerSrc config core.autocrlf false
  & git -C $TamerSrc -c advice.detachedHead=false checkout -q -f $S.TAMER_COMMIT
  return ($LASTEXITCODE -eq 0)
}

# Cloudflare block in the LiteLLM config (same markers as macOS and Linux).
function Edit-CloudflareBlock([ValidateSet('add','remove')][string]$Mode) {
  $txt = Get-Content -Raw -LiteralPath $LiteCfg
  $txt = $txt -replace '\n[ \t]*# >>> cloudflare[^\n]*\n[\s\S]*?# <<< cloudflare <<<[^\n]*', ''
  $txt = $txt -replace '\n[ \t]*# >>> cloudflare-settings[^\n]*\n[\s\S]*?# <<< cloudflare-settings <<<[^\n]*', ''
  $txt = $txt -replace '\n*# >>> cloudflare-router[^\n]*\n[\s\S]*?# <<< cloudflare-router <<<[^\n]*\n?', "`n"
  if ($Mode -eq 'add') {
    $models = (Get-Content -Raw -LiteralPath (Join-Path $Stack 'templates\litellm-cloudflare.yaml')).Replace('{{CF_ACCOUNT_ID}}', $S.CF_ACCOUNT_ID).TrimEnd("`n", "`r")
    $models = $models.Replace('Key from the Keychain via start.sh.', 'Key from the secrets folder.')
    $settings = "  # >>> cloudflare-settings (managed by lumo cloudflare) >>>`n" +
                "  # Translate /v1/messages to chat/completions; Workers AI rejects the Responses API.`n" +
                "  use_chat_completions_url_for_anthropic_messages: true`n" +
                "  # <<< cloudflare-settings <<<"
    if (-not $txt.Contains("`nlitellm_settings:")) { Stop-Lumo 'config has no litellm_settings: section' }
    if ($txt.Contains("`nrouter_settings:")) { Stop-Lumo 'config already has router_settings:; merge the cloudflare fallbacks by hand' }
    $i = $txt.IndexOf("`nlitellm_settings:")
    $txt = $txt.Substring(0, $i) + "`n" + $models + "`n`nlitellm_settings:`n" + $settings + $txt.Substring($i + "`nlitellm_settings:".Length)
    $txt = $txt.TrimEnd("`n") + "`n`n# >>> cloudflare-router (managed by lumo cloudflare) >>>`n" +
      "router_settings:`n  num_retries: 1`n  timeout: 120`n  fallbacks:`n" +
      "    - cf-llama4: [cf-gptoss, cf-mistral, lumo]`n    - cf-gptoss: [cf-mistral, cf-gemma4, lumo]`n" +
      "    - cf-mistral: [cf-gptoss, cf-gemma4, lumo]`n    - cf-gemma4: [cf-gptoss, cf-mistral, lumo]`n" +
      "    - cf-smart: [cf-mistral, lumo]`n    - cf-fast: [cf-mistral, lumo]`n" +
      "# <<< cloudflare-router <<<`n"
    $txt = $txt -replace '\n{3,}', "`n`n"
  }
  [IO.File]::WriteAllText($LiteCfg, $txt)
}

# Lumo router hook in litellm_settings.callbacks (same result as linux/cfgtool.py router).
function Edit-RouterCallback([ValidateSet('on','off')][string]$Mode) {
  $txt = Get-Content -Raw -LiteralPath $LiteCfg
  $m = [regex]::Match($txt, '(?m)^  callbacks:[ \t]*(.*)$')
  $items = @()
  if ($m.Success) {
    $v = ($m.Groups[1].Value -split '#')[0].Trim().Trim('[', ']')
    if ($v) { $items = @($v -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ }) }
  }
  $items = @($items | Where-Object { $_ -ne 'lumo_router.router' })
  if ($Mode -eq 'on') { $items = @('lumo_router.router') + $items }
  $line = if ($items.Count) { '  callbacks: [' + (($items | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']' } else { '' }
  if ($m.Success) {
    if ($line) { $txt = $txt.Substring(0, $m.Index) + $line + $txt.Substring($m.Index + $m.Length) }
    else { $txt = [regex]::new('(?m)^  callbacks:.*\n?').Replace($txt, '', 1) }
  } elseif ($line) {
    if (-not $txt.Contains("`nlitellm_settings:")) { Stop-Lumo 'config has no litellm_settings: section' }
    $i = $txt.IndexOf("`nlitellm_settings:") + "`nlitellm_settings:".Length
    $txt = $txt.Substring(0, $i) + "`n" + $line + $txt.Substring($i)
  }
  [IO.File]::WriteAllText($LiteCfg, $txt)
}
function Test-RouterOn { [bool](Select-String -LiteralPath $LiteCfg -SimpleMatch 'lumo_router.router' -Quiet) }
function Show-RouterStatus {
  Write-Host "router     : $(if (Test-RouterOn) { 'on' } else { 'off (lumo router on)' })"
  $p = Join-Path $Data 'router\lumo-router.json'
  if (-not (Test-Path $p)) { Write-Host 'lumo       : no data yet'; return }
  $s = Get-Content -Raw $p | ConvertFrom-Json
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $used = @($s.sent | Where-Object { $now - $_ -lt 7 * 86400 }).Count
  $budget = if ($s.budget) { $s.budget } else { 60 }; $est = if ($s.weekly_est) { $s.weekly_est } else { 100 }
  Write-Host "lumo       : $used/$budget messages in the last 7 days (Proton's cap: unpublished, est. ~$est/week)"
  if ($s.exhausted_until -gt $now) { Write-Host "quota      : OUT, next try $([DateTimeOffset]::FromUnixTimeSeconds([long]$s.exhausted_until).LocalDateTime.ToString('ddd HH:mm'))" }
  else { Write-Host 'quota      : ok' }
  $r = $s.rerouted.PSObject.Properties | ForEach-Object { "$($_.Name) $($_.Value)" }
  Write-Host "rerouted   : $(if ($r) { $r -join ', ' } else { 'none yet' })"
}

function Get-ApiBases {
  @(Get-Content -LiteralPath $LiteCfg | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '^\s*api_base:' } |
    ForEach-Object { $_.Trim() } | Sort-Object -Unique)
}
function Get-CfBase { "https://api.cloudflare.com/client/v4/accounts/$(if ($S.CF_ACCOUNT_ID) { $S.CF_ACCOUNT_ID } else { 'none' })/ai/v1" }
function Test-RoutesAllowed {
  # LiteLLM may only route to lumo-bridge, or to Cloudflare on your own account.
  $ok = @('api_base: http://bridge:3004/v1', "api_base: $(Get-CfBase)")
  -not @(Get-ApiBases | Where-Object { $_ -notin $ok })
}
function Test-LumoOnly { $b = @(Get-ApiBases); ($b.Count -eq 1) -and ($b[0] -eq 'api_base: http://bridge:3004/v1') }
