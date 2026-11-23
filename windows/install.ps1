<#
Lumo Stack installer for native Windows (Docker Desktop + PowerShell 7). EXPERIMENTAL, untested.
  pwsh -File windows\install.ps1                 interactive install
  pwsh -File windows\install.ps1 -Workspace DIR  workspace folder (default ~\lumo)
  pwsh -File windows\install.ps1 -NoLogin        skip the Proton sign-in at the end
  pwsh -File windows\install.ps1 -Yes            don't ask for confirmation
  pwsh -File windows\install.ps1 -DryRun         show what would happen, change nothing
Safe to re-run: existing keys, configs and logins are kept.
WSL2 users: run linux/install inside WSL instead (needed for a sandboxed claude-lumo).
#>
#Requires -Version 7.2
param([string]$Workspace = '', [switch]$NoLogin, [switch]$Yes, [switch]$DryRun)
. (Join-Path $PSScriptRoot 'lib.ps1')
$script:DryRun = [bool]$DryRun
if ($Workspace) { $S.LUMO_HOME = [IO.Path]::GetFullPath($Workspace) }

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor White }
function Note([string]$m) { Write-Host "    $m" }
function Fail([string]$m) { Write-Host "install: $m" -ForegroundColor Red; exit 1 }
function Dry([string]$m) { Write-Host "    [dry-run] $m" -ForegroundColor DarkGray }

if (-not $IsWindows) { Fail 'this installer is for Windows (macOS: ./install, Linux/WSL2: linux/install)' }

# --- 0. Where things go ------------------------------------------------------
Step 'Lumo Stack for Windows (experimental)'
Note "Workspace:  $($S.LUMO_HOME)   (code\ inbox\ out\)"
Note "Stack:      $Stack"
Note "Config:     $Conf   (configs + secrets, locked to your user)"
Note "Login data: $Data"
Note "Services:   Docker Compose project '$($S.LUMO_PROJECT)', ports on 127.0.0.1 only"
Note "Command:    $BinDir\lumo.cmd"

# --- 1. Prerequisites --------------------------------------------------------
Step 'Checking prerequisites'
$missing = @('docker', 'git' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing) { Fail "missing: $($missing -join ', ')  (winget install Docker.DockerDesktop Git.Git)" }
& docker compose version *> $null; if ($LASTEXITCODE) { Fail 'Docker Compose v2 is missing (update Docker Desktop)' }
& docker info *> $null; if ($LASTEXITCODE) { Fail "Docker isn't running: start Docker Desktop and wait for it to say it's running" }
$os = (& docker info --format '{{.OSType}}' 2>$null)
if ($os -ne 'linux') { Fail "Docker is in Windows-containers mode: switch Docker Desktop to Linux containers" }
foreach ($p in $S.TAMER_PORT, $S.LITELLM_PORT, $S.WEBUI_PORT) {
  $busy = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
  $ours = (& docker compose -f $Compose ps -q 2>$null)
  if ($busy -and -not $ours) { Fail "port $p is in use by something else (pick other ports in $Conf\lumo.env: TAMER_PORT, LITELLM_PORT, WEBUI_PORT)" }
}
Note "ok: Windows, $(& docker compose version --short), git $((& git --version) -replace 'git version ', '')"

# --- 2. Consent --------------------------------------------------------------
Step "The fine print (read it, it's short)"
Note 'Lumo has no public API. Lumo Stack uses lumo-bridge, a community bridge that talks to Lumo'
Note "the way Proton's own web app does. Proton could block it, and it could put your Proton"
Note 'account at risk. Not affiliated with or endorsed by Proton.'
Note 'On Windows, your secrets (the vault key, API tokens) are files locked to your user. That is'
Note 'weaker than the macOS Keychain: any program running as you can read them.'
Note 'Windows support is experimental and has not been tested on a real Windows machine yet.'
if (-not $Yes -and -not $DryRun) { if ((Read-Host '    Continue? [y/N]') -notmatch '^[yY]') { Fail 'cancelled' } }

# --- 3. Folders --------------------------------------------------------------
Step 'Folders'
$dirs = @((Join-Path $S.LUMO_HOME 'code'), (Join-Path $S.LUMO_HOME 'inbox'), (Join-Path $S.LUMO_HOME 'out'),
  (Join-Path $Data 'sessions'), (Join-Path $Data 'opencode-home\.config\opencode'), (Join-Path $Data 'opencode-home\.cache'),
  (Join-Path $Data 'opencode-home\.local\share'), $BinDir, $Conf, (Join-Path $Secrets 'tamer'), (Join-Path $Secrets 'litellm'), (Join-Path $Secrets 'code-web'))
if ($DryRun) { Dry "create $($dirs -join ', ')"; Dry "lock $Conf and $Data\sessions to $env:USERNAME" }
else {
  foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $mp = Join-Path $Data 'opencode-home\.config\opencode\opencode.json'; if (-not (Test-Path $mp)) { New-Item -ItemType File -Path $mp | Out-Null }
  Protect-UserOnly $Conf; Protect-UserOnly (Join-Path $Data 'sessions')
}
Note "$($S.LUMO_HOME)\{code,inbox,out} · $Conf (your user only)"

# --- 4. Keys and configs -----------------------------------------------------
Step 'Keys and configs'
if (Get-Secret 'tamer' 'lumo-vault-key') { Note 'vault key kept' }
else {
  if ($DryRun) { Dry 'new vault key' } else { Set-Secret 'tamer' 'lumo-vault-key' ([Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))) }
  Note 'vault key created (encrypts your Proton session)'
}
$vars = @{}
if (Test-Path $TamerCfg) { $vars.TAMER_KEY = Get-TamerKey; Note 'lumo-bridge config kept' }
else {
  $vars.TAMER_KEY = "lt-$(New-RandomHex)"
  if ($DryRun) { Dry "write $TamerCfg" } else { Write-PrivateFile $TamerCfg (Expand-Template (Join-Path $Stack 'compose\tamer-config.yaml') $vars) }
  Note 'lumo-bridge config written (random API key)'
}
if (Test-Path $LiteCfg) { $vars.LITELLM_KEY = Get-LitellmKey; Note 'LiteLLM config kept' }
else {
  $vars.LITELLM_KEY = "sk-$(New-RandomHex)"
  if ($DryRun) { Dry "write $LiteCfg" } else { Write-PrivateFile $LiteCfg (Expand-Template (Join-Path $Stack 'compose\litellm-config.yaml') $vars) }
  Note 'LiteLLM config written (routes only to lumo-bridge)'
}
if ($DryRun) { Dry "write $Conf\webui.env" } else { Write-PrivateFile (Join-Path $Conf 'webui.env') "OPENAI_API_KEY=$($vars.LITELLM_KEY)`n" }
$envFile = Join-Path $Conf 'lumo.env'
if (-not (Test-Path $envFile) -and -not $DryRun) { Write-PrivateFile $envFile "# This machine's settings for Lumo Stack (ports, Cloudflare account). Not shared.`nLUMO_HOME=$($S.LUMO_HOME)`n" }

# --- 5. Images and services --------------------------------------------------
Step 'Building and starting (first time: several minutes)'
Note "lumo-bridge $($S.TAMER_COMMIT), LiteLLM $($S.LITELLM_VERSION), OpenCode $($S.OPENCODE_VERSION)"
if (-not (Update-TamerSrc)) { Fail "couldn't fetch lumo-bridge $($S.TAMER_COMMIT)" }
if (-not (Invoke-Dc build tamer litellm)) { Fail 'image build failed' }
if (-not (Invoke-Dc pull -q bridge relay)) { Fail 'image pull failed' }
& docker image inspect "lumo-opencode:$($S.OPENCODE_VERSION)" *> $null
if ($LASTEXITCODE -and -not (Invoke-Step docker build -q -t "lumo-opencode:$($S.OPENCODE_VERSION)" -f (Join-Path $Stack 'Dockerfile.opencode') $Stack)) { Fail 'OpenCode image build failed' }
if (-not (Invoke-Dc up -d bridge tamer litellm relay)) { Fail "couldn't start the services (lumo logs)" }
Note "Open WebUI downloads the first time you run 'lumo web'"

# --- 6. Commands -------------------------------------------------------------
Step 'Commands'
$shims = @{
  'lumo.cmd'        = "@pwsh -NoProfile -File `"$(Join-Path $WinDir 'lumo.ps1')`" %*"
  'claude-lumo.cmd' = "@pwsh -NoProfile -File `"$(Join-Path $WinDir 'claude-lumo.ps1')`" %*"
}
foreach ($k in $shims.Keys) { if ($DryRun) { Dry "write $BinDir\$k" } else { [IO.File]::WriteAllText((Join-Path $BinDir $k), $shims[$k] + "`r`n") } }
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $BinDir)) {
  $add = $Yes -or $DryRun -or ((Read-Host "    Add $BinDir to your PATH? [Y/n]") -notmatch '^[nN]')
  if ($add) {
    if ($DryRun) { Dry "add $BinDir to your user PATH" }
    else { [Environment]::SetEnvironmentVariable('Path', ((@($userPath -split ';') + $BinDir) | Where-Object { $_ }) -join ';', 'User'); Note 'added to PATH (open a new terminal)' }
  } else { Note "not on PATH: run $BinDir\lumo.cmd" }
}
Note "$BinDir\lumo.cmd, claude-lumo.cmd (claude-lumo stays off on Windows unless LUMO_NO_SANDBOX=1)"

# --- 7. Sign-in + check ------------------------------------------------------
if ($DryRun) { Step 'Done (dry run): nothing was changed'; exit 0 }
$lumo = Join-Path $WinDir 'lumo.ps1'
if (-not $NoLogin) {
  Step 'Sign in to Proton'
  Note "Email, password, second password (if any) and authenticator code. Passwords aren't stored."
  & $lumo login; if ($LASTEXITCODE) { Note "sign-in didn't finish: run 'lumo login' later" }
}
Step 'Checking everything'
& $lumo doctor
Step "You're in."
Note "lumo code      the jailed coding agent (it only sees $($S.LUMO_HOME))"
Note 'lumo web       chat in your browser'
Note 'lumo status    what is running · lumo doctor  check everything · lumo help  all commands'
