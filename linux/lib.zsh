# Shared settings for the Linux / WSL2 scripts. Source it; don't run it.
# macOS uses the root scripts and ../lib.zsh instead; this file never touches them.
LUMO_STACK=${LUMO_STACK:-${${(%):-%x}:A:h:h}}
LUMO_LINUX=$LUMO_STACK/linux
: ${LUMO_CONF:=${XDG_CONFIG_HOME:-$HOME/.config}/lumo-stack}     # configs + secrets (user-only)
: ${LUMO_DATA:=${XDG_DATA_HOME:-$HOME/.local/share}/lumo-stack}  # bridge sessions (encrypted vault)
[[ -r $LUMO_CONF/lumo.env ]] && source $LUMO_CONF/lumo.env       # this machine's settings (ports, CF account)
source $LUMO_STACK/versions.env
: ${LUMO_HOME:=$HOME/lumo}                                         # workspace: code/ inbox/ out/
: ${LUMO_PROJECT:=lumo}                                            # Compose project name
: ${LUMO_JAIL_NET:=lumo-jail}
: ${LOG_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/lumo-stack/logs}
: ${BIN_DIR:=$HOME/.local/bin}
: ${TAMER_PORT:=3003} ${LITELLM_PORT:=4000} ${WEBUI_PORT:=8080} ${CODE_WEB_PORT:=4096} ${BROWSER_PORT:=3001}
LITELLM_CFG=$LUMO_CONF/litellm-config.yaml
TAMER_CFG=$LUMO_CONF/tamer-config.yaml
SECRETS=$LUMO_CONF/secrets
TAMER_SRC=$LUMO_DATA/src/lumo-bridge   # build context for the bridge image
export TAMER_SRC LUMO_CONF LUMO_DATA LUMO_PROJECT LUMO_JAIL_NET TAMER_PORT LITELLM_PORT WEBUI_PORT BROWSER_PORT
export LUMO_UID=$(id -u) LUMO_GID=$(id -g)
export TAMER_COMMIT LITELLM_VERSION WEBUI_IMAGE SOCAT_IMAGE CF_ACCOUNT_ID
mkdir -p $LOG_DIR 2>/dev/null

dc()          { docker compose -f $LUMO_STACK/compose/compose.yaml "$@"; }
litellm_key() { sed -n 's/^  master_key: "\(.*\)"/\1/p' $LITELLM_CFG; }
tamer_key()   { sed -n 's/^  apiKey: "\(.*\)"/\1/p' $TAMER_CFG; }
is_wsl()      { [[ -n $WSL_DISTRO_NAME ]] || grep -qi microsoft /proc/version 2>/dev/null; }
open_url()    { if is_wsl && command -v wslview >/dev/null; then wslview $1
                elif command -v xdg-open >/dev/null; then xdg-open $1 >/dev/null 2>&1 &!
                else print "Open: $1"; fi; }
notify()      { command -v notify-send >/dev/null && notify-send -a Lumo "$1" "$2" 2>/dev/null; }

# Secrets: one file each, readable only by you (0600 in a 0700 folder), mounted into the one
# container that needs it. Weaker than the macOS Keychain: any process running as you can read them.
#   secret_set <container> <name> (value on stdin) · secret_get <container> <name> · secret_rm <container> <name>
secret_set() { ( umask 077; mkdir -p $SECRETS/$1 && cat > $SECRETS/$1/$2 ); chmod 600 $SECRETS/$1/$2; }
secret_get() { cat $SECRETS/$1/$2 2>/dev/null; }
secret_rm()  { rm -f $SECRETS/$1/$2; }

# tamer_src: make sure the lumo-bridge checkout is at TAMER_COMMIT (Docker can't build a short commit over git).
tamer_src() {
  [[ -d $TAMER_SRC/.git ]] || git clone -q https://github.com/meldfunction/lumo-bridge.git $TAMER_SRC || return 1
  git -C $TAMER_SRC cat-file -e "$TAMER_COMMIT^{commit}" 2>/dev/null || git -C $TAMER_SRC fetch -q origin || return 1
  git -C $TAMER_SRC -c advice.detachedHead=false checkout -q $TAMER_COMMIT
}
