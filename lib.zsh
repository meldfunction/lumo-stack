# Shared settings for every lumo-stack script. Source it; don't run it.
# Defaults suit a fresh install. A machine-specific lumo.env (not committed)
# next to this file can override any of them.
LUMO_STACK=${LUMO_STACK:-${${(%):-%x}:A:h}}
[[ -r $LUMO_STACK/lumo.env ]] && source $LUMO_STACK/lumo.env
source $LUMO_STACK/versions.env

: ${LUMO_HOME:=$HOME/lumo}                       # workspace: code/ inbox/ out/
: ${LUMO_LABEL:=org.lumo-stack}                  # LaunchAgent label prefix
: ${TAMER_DIR:=$LUMO_STACK/vendor/lumo-tamer}    # lumo-tamer checkout
: ${LITELLM_DIR:=$LUMO_STACK/litellm}            # LiteLLM venv + config
: ${LOG_DIR:=$HOME/Library/Logs/lumo-stack}
: ${BIN_DIR:=$HOME/.local/bin}
LITELLM_CFG=$LITELLM_DIR/config.yaml
TAMER_PORT=3003 LITELLM_PORT=4000 WEBUI_PORT=8080 CODE_WEB_PORT=4096 HOME_PORT=8090
mkdir -p $LOG_DIR 2>/dev/null

litellm_key() { sed -n 's/^  master_key: "\(.*\)"/\1/p' $LITELLM_CFG; }
tamer_key()   { sed -n 's/^  apiKey: "\(.*\)"/\1/p' $TAMER_DIR/config.yaml; }
agent()       { print -r -- "$LUMO_LABEL.$1"; }   # agent tamer -> org.lumo-stack.tamer
