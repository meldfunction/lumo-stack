# Lumo Stack v0.2 command for Windows (PowerShell 5.1+ or 7+). macOS/Linux: bin/lumo.
#   lumo [--max]                    coding agent in the terminal (jailed)
#   lumo open <project> [--max]     coding agent in code\<project>
#   lumo run [-p project] "task"    one-shot coding task
#   lumo code-web [project|stop]    coding agent in the browser
#   lumo web | lumo home            chat / dashboard in the browser
#   lumo ask "question" | lumo chat quick answer / terminal chat
#   lumo login [--browser]          sign in to Proton (email+password, or a browser)
#   lumo import <path>... | fetch <url> | export [dir]
#   lumo projects | snapshots <p> | restore <p> <id>
#   lumo up | down | status | logs [service] | doctor | update
$ErrorActionPreference = 'Stop'
$Stack = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Stack '.env'
function Die($m) { Write-Host "lumo: $m" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $EnvFile)) { Die "not installed yet: run $Stack\install.ps1" }
$Cfg = @{}
Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $Cfg[$k] = $v }
function Port($k, $d) { if ($Cfg[$k]) { $Cfg[$k] } else { $d } }
$Workspace = $Cfg['LUMO_WORKSPACE']
$PWebui = Port 'LUMO_WEBUI_PORT' 8080; $PHome = Port 'LUMO_HOME_PORT' 8090
$PCode = Port 'LUMO_CODEWEB_PORT' 4096; $PLogin = Port 'LUMO_LOGIN_PORT' 3001
$LogDir = Join-Path $Stack 'logs'; New-Item -ItemType Directory -Force $LogDir | Out-Null
function Log($m) { Add-Content (Join-Path $LogDir 'lumo.log') "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" }
function Dc { & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') @args; if ($LASTEXITCODE) { throw "docker compose $args failed" } }
function DcQuiet { & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') @args 2>$null | Out-Null }
function OpenUrl($u) { if (-not $env:LUMO_NO_OPEN) { Start-Process $u } }
function ValidName($n) { if ($n -notmatch '^[A-Za-z0-9._-]+$') { Die "project names: letters, digits, . _ - only" } }

function EnsureUp {
  & docker info *> $null; if ($LASTEXITCODE) { Die "Docker isn't running (start Docker Desktop)" }
  Dc up -d tamer litellm webui home | Out-Null
}
function Snapshot($dir) {
  $script = 'cd "/lumo/code/' + $dir + '" || exit 1; g="git -c user.name=lumo -c user.email=lumo@localhost"; [ -d .git ] || $g init -q; if [ -n "$($g status --porcelain)" ] || ! $g rev-parse -q HEAD >/dev/null 2>&1; then $g add -A && $g commit -qm "lumo snapshot $(date "+%Y-%m-%d %H:%M:%S")" --allow-empty && $g rev-parse --short HEAD; fi'
  & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') --profile code run --rm --no-deps -T --entrypoint sh code -c $script 2>$null
}
function CodeSession($project, $max, [string[]]$rest) {
  if ($project) { ValidName $project }
  EnsureUp
  $dir = Join-Path (Join-Path $Workspace 'code') $project
  New-Item -ItemType Directory -Force $dir | Out-Null
  $agents = Join-Path $dir 'AGENTS.md'
  if ($project -and -not (Test-Path $agents)) {
    (Get-Content (Join-Path $Stack 'config\AGENTS.md') -Raw).Replace('{{PROJECT}}', $project) | Set-Content -NoNewline $agents
  }
  $snap = Snapshot $project; if ($snap) { Log "snapshot $project $snap" }
  if ($max) { if ($rest.Count -and $rest[0] -eq 'run') { $rest = @('run', '-m', 'lumo/lumo-max') + @($rest | Select-Object -Skip 1) } else { $rest = @('-m', 'lumo/lumo-max') + $rest } }
  Log "code project=$project max=$max args=$rest"
  & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') --profile code run --rm -w "/lumo/code/$project" code @rest
}

$Argv = @($args)   # captured here: inside switch blocks $args is the block's own
$cmd = if ($Argv.Count) { $Argv[0] } else { '' }
$rest = if ($Argv.Count -gt 1) { [string[]]$Argv[1..($Argv.Count - 1)] } else { @() }
# Take(list, flag): removes --max (returns $true) or -p <name> (returns name) from list.
function Take([ref]$list, $flag) {
  $l = @($list.Value); $i = [array]::IndexOf($l, $flag)
  if ($i -lt 0) { return $null }
  if ($flag -eq '-p') { $v = $l[$i + 1]; $keep = 0..($l.Count - 1) | Where-Object { $_ -ne $i -and $_ -ne ($i + 1) } }
  else { $v = $true; $keep = 0..($l.Count - 1) | Where-Object { $_ -ne $i } }
  $list.Value = @($keep | ForEach-Object { $l[$_] }); return $v
}

switch ($cmd) {
  { $_ -in '', 'code', '--max', '-p' } {
    $all = @($Argv); $p = Take ([ref]$all) '-p'; $m = Take ([ref]$all) '--max'; $all = @($all | Where-Object { $_ -ne 'code' })
    CodeSession $p $m $all; break }
  'open' { if (-not $rest.Count) { Die 'usage: lumo open <project> [--max]' }; $r = @($rest | Select-Object -Skip 1); $m = Take ([ref]$r) '--max'; CodeSession $rest[0] $m $r; break }
  'run' { $r = @($rest); $p = Take ([ref]$r) '-p'; $m = Take ([ref]$r) '--max'; CodeSession $p $m (@('run') + $r); break }
  'code-web' {
    if ($rest.Count -and $rest[0] -eq 'stop') { DcQuiet --profile codeweb rm -sf code-web; 'Coding UI stopped'; break }
    if ($rest.Count) { ValidName $rest[0]; New-Item -ItemType Directory -Force (Join-Path (Join-Path $Workspace 'code') $rest[0]) | Out-Null; $env:LUMO_CODEWEB_PROJECT = $rest[0] }
    EnsureUp; Dc --profile codeweb up -d --force-recreate code-web | Out-Null
    Write-Host -NoNewline 'Starting the coding UI'; for ($i = 0; $i -lt 40; $i++) { try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$PCode/" | Out-Null; break } catch { if ($_.Exception.Response.StatusCode.value__ -eq 401) { break } }; Write-Host -NoNewline '.'; Start-Sleep 2 }; ''
    "Coding UI: http://localhost:$PCode  (login: lumo / password in $Stack\secrets\code-web-password)"; OpenUrl "http://localhost:$PCode"; break }
  'web' { EnsureUp; "Chat: http://localhost:$PWebui"; OpenUrl "http://localhost:$PWebui"; break }
  'home' { EnsureUp; "Lumo Home: http://localhost:$PHome"; OpenUrl "http://localhost:$PHome"; break }
  'ask' { EnsureUp; Dc exec -T tamer tamer ($rest -join ' '); break }
  'chat' { EnsureUp; & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec tamer tamer; break }
  'login' {
    EnsureUp
    if (-not ($rest -contains '--browser')) {
      'Sign in with your Proton account (Proton''s own secure login; the password isn''t stored).'
      'CAPTCHA or a hardware security key? Use: lumo login --browser'
      & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec tamer sh -c 'cp -p sessions/vault.enc sessions/vault.enc.bak 2>/dev/null; tamer auth login'
      $st = & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec -T tamer tamer auth status 2>$null | Out-String
      if ($st -match 'configured and valid') {
        Dc restart tamer | Out-Null; Start-Sleep 3
        $r = & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec -T tamer tamer 'Reply with exactly: ok' 2>$null | Out-String
        if ($r -match 'ok') { DcQuiet exec -T tamer rm -f sessions/vault.enc.bak; 'Signed in. Lumo is answering.'; Log 'login ok (password)'; break }
      }
      DcQuiet exec -T tamer sh -c 'mv sessions/vault.enc.bak sessions/vault.enc 2>/dev/null'; Dc restart tamer | Out-Null
      Die "sign-in didn't work; your previous login (if any) was kept. Try again, or: lumo login --browser"
    }
    'Starting the sign-in browser (first time downloads ~3 GB)...'
    Dc --profile login up -d browser | Out-Null
    ''
    "  1. Open https://localhost:$PLogin  (your browser may warn about its self-signed certificate; that's expected)"
    '  2. Sign in to Proton in the browser you see there (keep that window open).'
    '  3. Come back here and press Enter. (Or press "I''ve signed in" in Lumo Home.)'
    OpenUrl "https://localhost:$PLogin"
    Read-Host | Out-Null
    # The sign-in helper opens Lumo in the sign-in browser, refuses guest mode,
    # saves the login and restarts lumo-tamer (same as Lumo Home's button).
    $js = 'const t=require("fs").readFileSync("/run/secrets/helper-token","utf8").trim();fetch("http://127.0.0.1:3010/login",{method:"POST",headers:{"X-Lumo-Token":t}}).then(r=>r.json()).then(j=>{console.log(j.ok?"OK":(j.error||"failed"));process.exit(j.ok?0:1)}).catch(e=>{console.log(String(e));process.exit(1)})'
    $res = (& docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec -T tamer node -e $js 2>&1 | Out-String).Trim()
    if ($res -eq 'OK') {
      Start-Sleep 4
      $r = & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec -T tamer tamer 'Reply with exactly: ok' 2>$null | Out-String
      if ($r -match 'ok') { 'Signed in. Lumo is answering.'; Log 'login ok (browser)' } else { Write-Host "Login saved, but Lumo didn't answer yet. Check: lumo status" -ForegroundColor Yellow }
    } else { Write-Host $res -ForegroundColor Yellow; Write-Host 'Run lumo login --browser again once you''ve signed in.' -ForegroundColor Yellow }
    'Stopping the sign-in browser and wiping its profile...'
    DcQuiet --profile login rm -sf browser
    $proj = if ($Cfg['LUMO_PROJECT']) { $Cfg['LUMO_PROJECT'] } else { 'lumo' }
    & docker volume rm "${proj}_browser-profile" *> $null; break }
  'import' {
    if (-not $rest.Count) { Die 'usage: lumo import <file|folder>...' }
    foreach ($f in $rest) { if (-not (Test-Path $f)) { Die "not found: $f" }; Copy-Item -Recurse -Force $f (Join-Path $Workspace 'inbox'); "imported $(Split-Path -Leaf $f) -> inbox (Lumo sees /lumo/inbox)" }; break }
  'fetch' {
    if (-not $rest.Count) { Die 'usage: lumo fetch <url>' }; EnsureUp
    Dc exec -T home python3 -c 'import sys; sys.path.insert(0,"/app"); import app
try:
    n,b=app.fetch_url(sys.argv[1]); print(f"saved {n} ({b} bytes) -> inbox (Lumo sees /lumo/inbox)")
except Exception as e:
    sys.exit(f"lumo: could not fetch: {e}")' $rest[0]; break }
  'export' {
    $dest = if ($rest.Count) { $rest[0] } else { Join-Path $HOME "Downloads\lumo-out-$(Get-Date -Format yyyyMMdd-HHmmss)" }
    $out = Join-Path $Workspace 'out'
    if (-not (Get-ChildItem $out -Force)) { Die 'out\ is empty' }
    New-Item -ItemType Directory -Force $dest | Out-Null; Copy-Item -Recurse -Force (Join-Path $out '*') $dest; "exported out\ -> $dest"; break }
  'projects' { Get-ChildItem -Directory (Join-Path $Workspace 'code') | ForEach-Object Name; break }
  'snapshots' {
    if (-not $rest.Count) { Die 'usage: lumo snapshots <project>' }; ValidName $rest[0]
    & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') --profile code run --rm --no-deps -T --entrypoint git code -C "/lumo/code/$($rest[0])" log --format='%h  %cd  %s' --date=format:'%Y-%m-%d %H:%M' -20; break }
  'restore' {
    if ($rest.Count -lt 2) { Die 'usage: lumo restore <project> <id>' }; ValidName $rest[0]
    if ($rest[1] -notmatch '^[0-9a-fA-F]+$') { Die "snapshot ids are hex (lumo snapshots $($rest[0]))" }
    $p = $rest[0]; $id = $rest[1]
    $script = 'cd "/lumo/code/' + $p + '" || exit 1; g="git -c user.name=lumo -c user.email=lumo@localhost"; $g rev-parse -q --verify "' + $id + '^{commit}" >/dev/null || { echo "no snapshot ' + $id + '" >&2; exit 1; }; $g add -A && $g commit -qm "lumo pre-restore" --allow-empty; pre=$($g rev-parse --short HEAD); $g restore --source="' + $id + '" --staged --worktree -- . && $g clean -fdq && $g commit -qm "lumo restored to ' + $id + '" --allow-empty && echo "restored to ' + $id + ' (undo: lumo restore ' + $p + ' $pre)"'
    & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') --profile code run --rm --no-deps -T --entrypoint sh code -c $script; break }
  'up' { EnsureUp; "Lumo Stack is up. Lumo Home: http://localhost:$PHome"; break }
  'down' { Dc --profile code --profile codeweb --profile login down; 'Lumo Stack stopped'; break }
  'status' {
    Dc ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
    ((& docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') exec -T tamer tamer auth status 2>$null | Out-String) -replace '\x1b\[[0-9;]*m', '') -split "`n" | Where-Object { $_ -match 'expiresIn|valid|attention' } | ForEach-Object { '  Proton login: ' + $_.Trim() }; break }
  'logs' { Dc logs --tail 50 @rest; break }
  'doctor' { & (Join-Path $PSScriptRoot 'lumo-doctor.ps1'); exit $LASTEXITCODE }
  'update' { "Rebuilding with the versions in $EnvFile..."; Dc build --pull; Dc up -d; & (Join-Path $PSScriptRoot 'lumo-doctor.ps1'); break }
  { $_ -in '-h', '--help', 'help' } { Get-Content $PSCommandPath | Select-Object -Skip 1 -First 10 | ForEach-Object { $_ -replace '^# ?', '' }; break }
  default { Die "unknown command '$cmd' (lumo help)" }
}
