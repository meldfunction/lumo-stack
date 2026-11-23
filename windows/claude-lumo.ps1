<#
claude-lumo for native Windows: Claude Code with Lumo as the only model, no Anthropic account.
  Claude Code -> LiteLLM (127.0.0.1) -> lumo-bridge -> Lumo

Claude Code has no OS sandbox on native Windows: Lumo's shell commands would run with your full
user rights. So this refuses to start unless you set LUMO_NO_SANDBOX=1 on purpose.
For the sandboxed version, install Lumo Stack inside WSL2 (linux/install --with-claude).
#>
#Requires -Version 7.2
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Stop-Lumo "Claude Code isn't installed (https://claude.com/claude-code)" }
if ($env:LUMO_NO_SANDBOX -ne '1') {
  Write-Host @"
claude-lumo: refusing to start. Claude Code can't sandbox commands on native Windows, so Lumo's
commands would run with your full user rights.
  Sandboxed:    use WSL2 and install there (linux/install --with-claude).
  Unsandboxed:  `$env:LUMO_NO_SANDBOX = '1'; lumo claude   (every command still asks you first)
"@ -ForegroundColor Yellow
  exit 2
}
Write-Log "claude-lumo: launch cwd=$PWD (UNSANDBOXED, LUMO_NO_SANDBOX=1)"

# 1. LiteLLM may only route to lumo-bridge, or to Cloudflare on your account with an allowlisted model.
if (-not (Test-Path $LiteCfg)) { Stop-Lumo "missing $LiteCfg (run install.ps1)" }
if (-not (Test-RoutesAllowed)) { Stop-Lumo 'LiteLLM config routes somewhere other than lumo-bridge or Cloudflare Workers AI' }
$allowed = '^\s*model: openai/(lumo(-max|-lite)?|@cf/meta/llama-4-scout-17b-16e-instruct|@cf/mistralai/mistral-small-3\.1-24b-instruct|@cf/meta/llama-3\.3-70b-instruct-fp8-fast|@cf/meta/llama-3\.1-8b-instruct-fast|@cf/openai/gpt-oss-120b|@cf/google/gemma-4-26b-a4b-it)$'
$cfg = Get-Content $LiteCfg | Where-Object { $_ -notmatch '^\s*#' }
if ($cfg | Where-Object { $_ -match '^\s*model:' -and $_ -notmatch $allowed }) { Stop-Lumo 'LiteLLM config has a model outside the Lumo + Cloudflare allowlist' }
if ($cfg | Where-Object { $_ -notmatch '^\s*use_chat_completions_url_for_anthropic_messages: true$' -and $_ -match 'anthropic|claude' }) { Stop-Lumo 'LiteLLM config mentions anthropic/claude' }

# 2. Servers up.
& (Join-Path $PSScriptRoot 'lumo.ps1') up; if ($LASTEXITCODE) { exit 1 }

# 3. Every model slot is Lumo (Cloudflare does tool-heavy work if on); no Anthropic key, telemetry or updates.
foreach ($v in 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
$env:ANTHROPIC_BASE_URL = "http://localhost:$($S.LITELLM_PORT)"
$env:ANTHROPIC_AUTH_TOKEN = Get-LitellmKey
if (-not $env:ANTHROPIC_AUTH_TOKEN) { Stop-Lumo "no master_key in $LiteCfg" }
$env:ANTHROPIC_MODEL = 'lumo'; $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'lumo-max'; $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'lumo'
$tool = if ($env:LUMO_TOOL_MODEL) { $env:LUMO_TOOL_MODEL } elseif ($S.CF_ACCOUNT_ID) { 'cf-gptoss' } else { 'lumo' }
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $tool; $env:ANTHROPIC_SMALL_FAST_MODEL = $tool; $env:CLAUDE_CODE_SUBAGENT_MODEL = $tool
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = if ($env:LUMO_CONTEXT_TOKENS) { $env:LUMO_CONTEXT_TOKENS } else { '100000' }
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'; $env:DISABLE_AUTOUPDATER = '1'; $env:DISABLE_TELEMETRY = '1'; $env:DISABLE_ERROR_REPORTING = '1'

# 4. No MCP servers; lean tool set; normal permission prompts; sandbox explicitly off (it can't run here).
$mcp = if ($env:LUMO_KEEP_MCP -eq '1') { @() } else { @('--strict-mcp-config') }
$nudge = 'Your tools are real and run on this machine: use them to do the work instead of describing commands or asking the user to run them. When editing, prefer writing the whole file if an exact-match edit fails.'
$lean = if ($env:LUMO_FULL -eq '1') { @() } else { @('--bare', '--tools', 'Read,Write,Edit,Grep,Glob,Bash', '--append-system-prompt', $nudge) }
$perm = if ($args -match '^--(permission-mode|dangerously-skip-permissions)') { @() } else { @('--permission-mode', 'default') }
$perm += @('--settings', '{"sandbox":{"enabled":false}}')

# 5. GitHub: hand gh's login over unless LUMO_NO_GH=1.
if ($env:LUMO_NO_GH -eq '1') { foreach ($v in 'GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_PERSONAL_ACCESS_TOKEN') { Remove-Item "env:$v" -ErrorAction SilentlyContinue } }
elseif (-not $env:GITHUB_TOKEN -and (Get-Command gh -ErrorAction SilentlyContinue)) {
  $t = & gh auth token 2>$null; if ($t) { $env:GITHUB_TOKEN = $t; $env:GH_TOKEN = $t }
}

Write-Log "claude-lumo: start model=lumo tool=$tool sandbox=off"
& claude @mcp @lean @perm @args
exit $LASTEXITCODE
