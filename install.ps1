# Lumo Stack v0.2 installer for Windows (PowerShell 5.1+ or 7+). macOS/Linux: install.sh.
#   .\install.ps1                        interactive install
#   .\install.ps1 -Workspace D:\lumo     where Lumo keeps files (default ~\lumo)
#   .\install.ps1 -WithClaude            also set up claude-lumo (installs Claude Code if missing)
#   .\install.ps1 -NoLogin               skip the Proton sign-in at the end
#   .\install.ps1 -Yes                   don't ask
# If scripts are blocked: powershell -ExecutionPolicy Bypass -File .\install.ps1
# Safe to re-run: keys, settings and your login are kept.
param([string]$Workspace = (Join-Path $HOME 'lumo'), [switch]$WithClaude, [switch]$NoLogin, [switch]$Yes, [switch]$NoLink)
$ErrorActionPreference = 'Stop'
$Stack = $PSScriptRoot
function Step($m) { ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" }
function Die($m) { Write-Host "install: $m" -ForegroundColor Red; exit 1 }
function Rnd2($n) { $b = New-Object byte[] $n; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[$_ % 62] }) }
function Dc { & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') @args; if ($LASTEXITCODE) { Die "docker compose $args failed" } }
function WriteNoBom($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

Write-Host 'Lumo Stack v0.2 installer' -ForegroundColor White

Step 'Checking prerequisites'
# Docker Desktop is the only prerequisite; offer to install it if it's missing.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Note "Docker Desktop isn't installed. Lumo Stack runs everything in it."
  $canWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
  if ($canWinget -and ($Yes -or ((Read-Host '    Install Docker Desktop with winget now? [y/N]') -match '^[yY]'))) {
    & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    Note 'Docker Desktop installed. Start it once (it may ask to set up WSL 2 and restart Windows), then re-run install.ps1.'
    exit 0
  }
  Die 'install Docker Desktop (https://www.docker.com/products/docker-desktop/), start it once, then re-run'
}
& docker compose version *> $null; if ($LASTEXITCODE) { Die 'Docker Compose is needed (it ships with Docker Desktop)' }
& docker info *> $null
if ($LASTEXITCODE) {
  Note 'Starting Docker Desktop...'; Start-Process 'Docker Desktop' -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 60; $i++) { & docker info *> $null; if (-not $LASTEXITCODE) { break }; Start-Sleep 2 }
  & docker info *> $null; if ($LASTEXITCODE) { Die "Docker isn't running. Start Docker Desktop and re-run." }
}
Note "ok: $(& docker compose version --short)"

Step "The fine print (read it, it's short)"
@'
    Lumo has no public API yet, so this uses lumo-tamer: an UNOFFICIAL community
    bridge that talks to Lumo the way Proton's own web app does. It's not
    affiliated with Proton. Proton could block it, and it could put your Proton
    account at risk. Rebellious, yes. Reckless, no.

    Everything runs in Docker on this PC and listens on 127.0.0.1 only.
    Any Proton account works; Lumo Plus is worth it if you code a lot.
'@
if (-not $Yes) { if ((Read-Host "    Type 'yes' to continue") -ne 'yes') { Die 'cancelled' } }

Step 'Settings and keys'
$secrets = Join-Path $Stack 'secrets'; New-Item -ItemType Directory -Force $secrets, (Join-Path $Stack 'logs') | Out-Null
# Vault key: exactly 32 random bytes, base64 (what lumo-tamer's vault expects).
$vk = Join-Path $secrets 'lumo-vault-key'
if (-not (Test-Path $vk) -or -not (Get-Content $vk -Raw)) { $kb = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($kb); WriteNoBom $vk ([Convert]::ToBase64String($kb)); Note 'created secrets\lumo-vault-key' }
foreach ($s in @{ n = 'helper-token'; l = 40 }, @{ n = 'code-web-password'; l = 24 }) {
  $f = Join-Path $secrets $s.n
  if (-not (Test-Path $f) -or -not (Get-Content $f -Raw)) { WriteNoBom $f (Rnd2 $s.l); Note "created secrets\$($s.n)" }
}
$envFile = Join-Path $Stack '.env'
if (-not (Test-Path $envFile)) {
  New-Item -ItemType Directory -Force $Workspace | Out-Null
  $ws = (Resolve-Path $Workspace).Path
  $p = { param($k, $d) if ([Environment]::GetEnvironmentVariable($k)) { [Environment]::GetEnvironmentVariable($k) } else { $d } }
  WriteNoBom $envFile @"
# Lumo Stack settings for this machine (not committed).
LUMO_PROJECT=$(& $p 'LUMO_PROJECT' 'lumo')
LUMO_WORKSPACE=$ws
LUMO_LITELLM_PORT=$(& $p 'LUMO_LITELLM_PORT' 4000)
LUMO_WEBUI_PORT=$(& $p 'LUMO_WEBUI_PORT' 8080)
LUMO_HOME_PORT=$(& $p 'LUMO_HOME_PORT' 8090)
LUMO_CODEWEB_PORT=$(& $p 'LUMO_CODEWEB_PORT' 4096)
LUMO_LOGIN_PORT=$(& $p 'LUMO_LOGIN_PORT' 3001)
LITELLM_MASTER_KEY=sk-$(Rnd2 40)
TAMER_COMMIT=0ef587b
LITELLM_VERSION=1.110.2
OPENCODE_VERSION=1.19.5
WEBUI_IMAGE=ghcr.io/open-webui/open-webui:main

"@
  Note "created .env (workspace: $ws)"
} else { Note '.env kept' }
$Cfg = @{}; Get-Content $envFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $Cfg[$k] = $v }
$ws = $Cfg['LUMO_WORKSPACE']
foreach ($d in 'code', 'inbox', 'out') { New-Item -ItemType Directory -Force (Join-Path $ws $d) | Out-Null }
$tamerCfg = Join-Path $Stack 'config\tamer.yaml'
if (-not (Test-Path $tamerCfg)) {
  $tamerKey = "lt-$(Rnd2 40)"; WriteNoBom $tamerCfg ((Get-Content (Join-Path $Stack 'config\tamer.yaml.template') -Raw).Replace('{{TAMER_KEY}}', $tamerKey)); Note 'created config\tamer.yaml'
} else { $tamerKey = ((Select-String -Path $tamerCfg -Pattern '^\s+apiKey: "(.*)"').Matches[0].Groups[1].Value); Note 'config\tamer.yaml kept' }
$llmCfg = Join-Path $Stack 'config\litellm.yaml'
if (-not (Test-Path $llmCfg)) {
  WriteNoBom $llmCfg ((Get-Content (Join-Path $Stack 'config\litellm.yaml.template') -Raw).Replace('{{TAMER_KEY}}', $tamerKey).Replace('{{LITELLM_KEY}}', $Cfg['LITELLM_MASTER_KEY'])); Note 'created config\litellm.yaml'
}
Note "workspace: $ws\{code,inbox,out}"

Step 'Building (first time: 10-20 minutes, a few GB)'
Dc --profile code build tamer litellm home code
Dc pull -q webui
Step 'Starting'
Dc up -d tamer litellm webui home
Note "Lumo Home: http://localhost:$($Cfg['LUMO_HOME_PORT'])"

Step 'Commands'
if ($NoLink) { Note "skipped (-NoLink): run $Stack\bin\lumo.ps1 directly" } else {
  $bin = Join-Path $HOME '.local\bin'; New-Item -ItemType Directory -Force $bin | Out-Null
  WriteNoBom (Join-Path $bin 'lumo.cmd') "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$Stack\bin\lumo.ps1`" %*`r`n"
  Note "$bin\lumo.cmd"
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (($userPath -split ';') -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path', "$userPath;$bin", 'User'); Note "added $bin to your PATH (open a new terminal)" }
}

if ($WithClaude) {
  Step 'Claude Code, minus Anthropic'
  Note 'claude-lumo runs Claude Code with Lumo as the model: prompts go to LiteLLM on'
  Note '127.0.0.1, then Lumo. Never Anthropic. Telemetry, updates and MCP are off.'
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Note "Claude Code isn't installed; the official installer downloads it from Anthropic once."
    $go = $Yes -or ((Read-Host '    Install Claude Code now? [y/N]') -match '^[yY]')
    if ($go) { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression }
  }
  if (-not $NoLink) { WriteNoBom (Join-Path $bin 'claude-lumo.cmd') "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$Stack\bin\claude-lumo.ps1`" %*`r`n"; Note "$bin\claude-lumo.cmd" }
}

if (-not $NoLogin) { Step 'Sign in to Proton'; & (Join-Path $Stack 'bin\lumo.ps1') login }
Step 'Checking everything'
Write-Host -NoNewline '    waiting for everything to finish starting'
for ($i = 0; $i -lt 60; $i++) { try { if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$($Cfg['LUMO_WEBUI_PORT'])/health").Content -match 'true') { break } } catch {}; Write-Host -NoNewline '.'; Start-Sleep 3 }
''
& (Join-Path $Stack 'bin\lumo-doctor.ps1')
Step "You're in."
@"
    lumo home      the dashboard: status, sign-in, files, chat, code
    lumo           the jailed coding agent (it only sees $ws)
    lumo web       chat in your browser
    lumo help      everything else

    Coding UI password: $(Get-Content (Join-Path $secrets 'code-web-password') -Raw)   (login: lumo)
    Your prompts are nobody's training data. Have fun.
"@
