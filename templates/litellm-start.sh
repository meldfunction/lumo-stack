#!/bin/zsh
# Starts LiteLLM for the Lumo stack. Rendered by ./install to {{LITELLM_DIR}}/start.sh.
# Lumo-only by default. If `lumo-cloudflare on` was run, CF_ACCOUNT_ID is in lumo.env and the
# token is in the macOS Keychain (item "cloudflare-workers-ai"); both are exported here so the
# key is never stored in a file or in the LaunchAgent plist.
[[ -r "{{LUMO_STACK}}/lumo.env" ]] && source "{{LUMO_STACK}}/lumo.env"
if [[ -n $CF_ACCOUNT_ID ]]; then
  export CF_ACCOUNT_ID CLOUDFLARE_ACCOUNT_ID=$CF_ACCOUNT_ID
  export CLOUDFLARE_API_KEY="$(/usr/bin/security find-generic-password -a "$USER" -s cloudflare-workers-ai -w 2>/dev/null)"
  [[ -z $CLOUDFLARE_API_KEY ]] && print -u2 "start.sh: no cloudflare-workers-ai key in Keychain; cf-* models will fail"
fi
# Tinfoil (after `lumo-tinfoil on`): key in Keychain item "tinfoil-api".
_tf=$(/usr/bin/security find-generic-password -a "$USER" -s tinfoil-api -w 2>/dev/null) && export TINFOIL_API_KEY=$_tf
unset _tf
exec "{{LITELLM_DIR}}/venv/bin/litellm" --config "{{LITELLM_DIR}}/config.yaml" --host 127.0.0.1 --port 4000
