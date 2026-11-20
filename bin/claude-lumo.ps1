# Claude Code with Lumo as the ONLY model (Windows). macOS/Linux: bin/claude-lumo.
#   Claude Code -> LiteLLM (127.0.0.1) -> lumo-tamer -> Lumo. No Anthropic account.
# Refuses to start if LiteLLM could route anywhere but Lumo. Not jailed.
$ErrorActionPreference = 'Stop'
$Stack = Split-Path -Parent $PSScriptRoot
function Die($m) { Write-Host "claude-lumo: $m" -ForegroundColor Red; exit 1 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Die "Claude Code isn't installed (irm https://claude.ai/install.ps1 | iex)" }
$Cfg = @{}; Get-Content (Join-Path $Stack '.env') | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $Cfg[$k] = $v }
$lines = Get-Content (Join-Path $Stack 'config\litellm.yaml') | Where-Object { $_ -notmatch '^\s*#' }
$bases = @($lines | Where-Object { $_ -match '^\s*api_base:' } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
if ($bases.Count -ne 1 -or $bases[0] -ne 'api_base: http://tamer:3003/v1') { Die 'LiteLLM routes somewhere other than lumo-tamer' }
if ($lines | Where-Object { $_ -match '^\s*model:' -and $_ -notmatch 'model: openai/lumo(-max|-lite)?$' }) { Die 'LiteLLM config has a non-Lumo model' }
if ($lines -match '(?i)anthropic|claude') { Die 'LiteLLM config mentions anthropic/claude' }
& (Join-Path $PSScriptRoot 'lumo.ps1') up | Out-Null

Remove-Item Env:ANTHROPIC_API_KEY, Env:CLAUDE_CODE_USE_BEDROCK, Env:CLAUDE_CODE_USE_VERTEX -ErrorAction SilentlyContinue
$port = if ($Cfg['LUMO_LITELLM_PORT']) { $Cfg['LUMO_LITELLM_PORT'] } else { 4000 }
$env:ANTHROPIC_BASE_URL = "http://localhost:$port"
$env:ANTHROPIC_AUTH_TOKEN = $Cfg['LITELLM_MASTER_KEY']; if (-not $env:ANTHROPIC_AUTH_TOKEN) { Die 'no LITELLM_MASTER_KEY in .env' }
$env:ANTHROPIC_MODEL = 'lumo'; $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'lumo-max'; $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'lumo'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'lumo-lite'; $env:ANTHROPIC_SMALL_FAST_MODEL = 'lumo-lite'; $env:CLAUDE_CODE_SUBAGENT_MODEL = 'lumo'
if ($env:LUMO_CONTEXT_TOKENS) { $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $env:LUMO_CONTEXT_TOKENS }
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'; $env:DISABLE_AUTOUPDATER = '1'; $env:DISABLE_TELEMETRY = '1'; $env:DISABLE_ERROR_REPORTING = '1'
$mcp = if ($env:LUMO_KEEP_MCP -eq '1') { @() } else { @('--strict-mcp-config') }
& claude @mcp @args
exit $LASTEXITCODE
