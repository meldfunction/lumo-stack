# Health and security check for Lumo Stack v0.2 (Windows).
$Stack = Split-Path -Parent $PSScriptRoot
$Cfg = @{}; Get-Content (Join-Path $Stack '.env') | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $Cfg[$k] = $v }
$script:pass = 0; $script:fail = 0
function Ok($m) { Write-Host "  + $m" -ForegroundColor Green; $script:pass++ }
function Bad($m, $hint) { Write-Host "  x $m$(if ($hint) { "  ->  $hint" })" -ForegroundColor Red; $script:fail++ }
function Dc { & docker compose --project-directory $Stack -f (Join-Path $Stack 'compose.yaml') @args }
function Up($url) { try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 $url).StatusCode -lt 500 } catch { $false } }
$proj = if ($Cfg['LUMO_PROJECT']) { $Cfg['LUMO_PROJECT'] } else { 'lumo' }

'Services'
& docker info *> $null; if ($LASTEXITCODE) { Bad 'Docker running' 'start Docker Desktop' } else { Ok 'Docker running' }
foreach ($s in 'tamer', 'litellm', 'webui', 'home') { $id = Dc ps -q $s; if ($id -and (& docker inspect -f '{{.State.Running}}' $id) -eq 'true') { Ok "$s running" } else { Bad "$s running" "lumo up; lumo logs $s" } }
if (Up "http://127.0.0.1:$($Cfg['LUMO_LITELLM_PORT'])/health/liveliness") { Ok 'LiteLLM on localhost' } else { Bad 'LiteLLM on localhost' }
if (Up "http://127.0.0.1:$($Cfg['LUMO_WEBUI_PORT'])/health") { Ok 'Open WebUI on localhost' } else { Bad 'Open WebUI on localhost' }
if (Up "http://127.0.0.1:$($Cfg['LUMO_HOME_PORT'])/") { Ok 'Lumo Home on localhost' } else { Bad 'Lumo Home on localhost' }

''; 'Proton login'
$st = (Dc exec -T tamer tamer auth status 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
if ($st -match 'configured and valid') { Ok 'signed in' } else { Bad 'not signed in' 'lumo login' }
$r = Dc exec -T tamer tamer 'Reply with exactly: ok' 2>$null | Out-String
if ($r -match 'ok') { Ok 'Lumo answers a test message' } else { Bad "Lumo didn't answer" 'lumo login, or check your network' }

''; 'Routing (Lumo only)'
$lines = Get-Content (Join-Path $Stack 'config\litellm.yaml') | Where-Object { $_ -notmatch '^\s*#' }
$bases = @($lines | Where-Object { $_ -match '^\s*api_base:' } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
if ($bases.Count -eq 1 -and $bases[0] -eq 'api_base: http://tamer:3003/v1') { Ok 'LiteLLM routes only to lumo-tamer' } else { Bad 'LiteLLM routes somewhere else' }
if ($lines -match '(?i)anthropic|claude') { Bad 'LiteLLM config mentions anthropic/claude' } else { Ok 'no Anthropic routes in LiteLLM' }
if ((Get-Content (Join-Path $Stack 'config\opencode.json') -Raw) -match '"baseURL": "http://lumo-relay:4000/v1"') { Ok 'coding agent routes only to LiteLLM' } else { Bad 'opencode.json changed' }
$open = & docker ps --filter "label=com.docker.compose.project=$proj" --format '{{.Ports}}' | ForEach-Object { $_ -split ',' } | Where-Object { $_ -match '->' -and $_ -notmatch '127\.0\.0\.1:' }
if (-not $open) { Ok 'every published port is localhost-only' } else { Bad 'ports open beyond localhost' ($open -join ' ') }
if (-not (& docker port (Dc ps -q tamer) 2>$null)) { Ok 'lumo-tamer not published at all' } else { Bad 'lumo-tamer is published' }

''; 'Coding jail'
if ((& docker network inspect -f '{{.Internal}}' "${proj}_jail" 2>$null) -eq 'true') { Ok 'jail network is internal (no internet route)' } else { Bad 'jail network missing or not internal' }
$probeScript = @'
w(){ sh -c "echo x > $1" 2>/dev/null && { echo "W $1"; rm -f "$1"; } || echo "B $1"; }
w /etc/lumo-probe; w /usr/bin/lumo-probe; w /lumo-probe; w /lumo/inbox/lumo-probe; w /home/node/.config/opencode/opencode.json; w /lumo/out/.lumo-probe
[ "$(id -u)" = 0 ] && echo "W root" || echo "B root"
node -e 'fetch("https://example.com",{signal:AbortSignal.timeout(5000)}).then(()=>console.log("W internet")).catch(()=>console.log("B internet"))'
node -e 'fetch("http://tamer:3003/health",{signal:AbortSignal.timeout(4000)}).then(()=>console.log("W tamer")).catch(()=>console.log("B tamer"))'
node -e 'fetch("http://lumo-relay:4000/health/liveliness",{signal:AbortSignal.timeout(5000)}).then(()=>console.log("W relay")).catch(()=>console.log("B relay"))'
'@
$probe = (Dc --profile code run --rm --no-deps -T --entrypoint sh code -c $probeScript 2>&1 | Out-String) -split "`n" | ForEach-Object { $_.Trim() }
foreach ($p in '/etc/lumo-probe', '/usr/bin/lumo-probe', '/lumo-probe', '/lumo/inbox/lumo-probe', '/home/node/.config/opencode/opencode.json', 'root', 'internet', 'tamer') {
  if ($probe -contains "B $p") { Ok "blocked: $p" } else { Bad "NOT blocked: $p" } }
if ($probe -contains 'W /lumo/out/.lumo-probe') { Ok 'writable: /lumo/out (as intended)' } else { Bad "can't write /lumo/out" }
if ($probe -contains 'W relay') { Ok 'reaches Lumo via LiteLLM' } else { Bad "can't reach LiteLLM" }

''; "$script:pass passed, $script:fail failed"
exit [int]($script:fail -gt 0)
