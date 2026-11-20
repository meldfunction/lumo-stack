#!/usr/bin/env bash
# Lumo Stack v0.2 installer for macOS and Linux. Windows: install.ps1.
#   ./install.sh                      interactive install
#   ./install.sh --workspace DIR      where Lumo keeps files (default ~/lumo)
#   ./install.sh --with-claude        also set up claude-lumo (installs Claude Code if missing)
#   ./install.sh --no-login           skip the Proton sign-in at the end
#   ./install.sh --yes                don't ask
# Advanced: LUMO_PROJECT and LUMO_*_PORT environment variables change the
# Docker project name and the localhost ports (to run next to another install).
# Safe to re-run: keys, settings and your login are kept.
set -euo pipefail
STACK="$(cd "$(dirname "$0")" && pwd)"
workspace="$HOME/lumo"; with_claude=""; no_login=""; yes=""; no_link=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) workspace="$2"; shift 2 ;;
    --with-claude) with_claude=1; shift ;;
    --no-login) no_login=1; shift ;;
    --yes) yes=1; shift ;;
    --no-link) no_link=1; shift ;;      # don't put lumo / claude-lumo on PATH
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install: unknown option $1" >&2; exit 1 ;;
  esac
done
B=$'\e[1m'; D=$'\e[2m'; R=$'\e[31m'; G=$'\e[32m'; N=$'\e[0m'
step() { echo; echo "${B}==> $*${N}"; }
note() { echo "    $*"; }
die()  { echo "${R}install: $*${N}" >&2; exit 1; }
rnd()  { ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1" ); }
render() { sed -e "s|{{TAMER_KEY}}|$TAMER_KEY|g" -e "s|{{LITELLM_KEY}}|$LITELLM_KEY|g" "$1" > "$2"; }

echo "${B}Lumo Stack v0.2 installer${N}"

# --- 1. Prerequisites ----------------------------------------------------------
step "Checking prerequisites"
# Docker is the only prerequisite; offer to install it if it's missing.
ask() { [ -n "$yes" ] && return 0; read -r -p "    $1 [y/N] " a; case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac; }
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  case "$(uname)" in
    Darwin)
      note "Docker isn't installed. Lumo Stack runs on OrbStack (light, recommended) or Docker Desktop."
      if command -v brew >/dev/null && ask "Install OrbStack with Homebrew now?"; then
        brew install --cask orbstack && open -ga OrbStack
      else
        die "install OrbStack (https://orbstack.dev) or Docker Desktop, then re-run"
      fi ;;
    Linux)
      note "Docker isn't installed. The official script (get.docker.com) installs Docker Engine + Compose."
      note "It needs sudo, and adds you to the docker group (log out and back in afterwards)."
      if ask "Install Docker now?"; then
        curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker "$USER"
        note "Docker installed. Log out and back in (or run: newgrp docker), then re-run ./install.sh"; exit 0
      else
        die "install Docker Engine and the compose plugin (https://docs.docker.com/engine/install/), then re-run"
      fi ;;
    *) die "unsupported system: $(uname). On Windows, use install.ps1" ;;
  esac
fi
docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is needed (docker compose version)"
if ! docker info >/dev/null 2>&1; then
  [ "$(uname)" = Darwin ] && { open -ga OrbStack 2>/dev/null || open -ga Docker 2>/dev/null || true; }
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || die "Docker isn't running. Start it and re-run."
fi
command -v curl >/dev/null || die "curl needed"
note "${G}ok${N}: $(docker compose version --short 2>/dev/null | sed 's/^/Docker Compose /'), $(uname -s)"

# --- 2. The fine print -----------------------------------------------------------
step "The fine print (read it, it's short)"
cat <<'EOF'
    Lumo has no public API yet, so this uses lumo-tamer: an UNOFFICIAL community
    bridge that talks to Lumo the way Proton's own web app does. It's not
    affiliated with Proton. Proton could block it, and it could put your Proton
    account at risk. Rebellious, yes. Reckless, no.

    Everything runs in Docker on this machine and listens on 127.0.0.1 only.
    Any Proton account works; Lumo Plus is worth it if you code a lot.
EOF
if [ -z "$yes" ]; then read -r -p "    Type 'yes' to continue: " ans; [ "$ans" = yes ] || die "cancelled"; fi

# --- 3. Settings, keys, configs (kept on re-runs) --------------------------------
step "Settings and keys"
mkdir -p "$STACK/secrets" "$STACK/logs"; chmod 700 "$STACK/secrets"
# Vault key: exactly 32 random bytes, base64 (what lumo-tamer's vault expects).
f="$STACK/secrets/lumo-vault-key"; [ -s "$f" ] || { (umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n' > "$f"); note "created secrets/lumo-vault-key"; }
for s in helper-token:40 code-web-password:24; do
  f="$STACK/secrets/${s%%:*}"; [ -s "$f" ] || { (umask 077; rnd "${s##*:}" > "$f"); note "created secrets/${s%%:*}"; }
done
if [ ! -f "$STACK/.env" ]; then
  workspace="$(mkdir -p "$workspace" && cd "$workspace" && pwd)"
  (umask 077; cat > "$STACK/.env" <<EOF
# Lumo Stack settings for this machine (not committed).
LUMO_PROJECT=${LUMO_PROJECT:-lumo}
LUMO_WORKSPACE=$workspace
LUMO_LITELLM_PORT=${LUMO_LITELLM_PORT:-4000}
LUMO_WEBUI_PORT=${LUMO_WEBUI_PORT:-8080}
LUMO_HOME_PORT=${LUMO_HOME_PORT:-8090}
LUMO_CODEWEB_PORT=${LUMO_CODEWEB_PORT:-4096}
LUMO_LOGIN_PORT=${LUMO_LOGIN_PORT:-3001}
LITELLM_MASTER_KEY=sk-$(rnd 40)
TAMER_COMMIT=0ef587b
LITELLM_VERSION=1.110.2
OPENCODE_VERSION=1.19.5
WEBUI_IMAGE=ghcr.io/open-webui/open-webui:main
EOF
  )
  note "created .env (workspace: $workspace)"
else
  note ".env kept"
fi
getenv() { sed -n "s/^$1=//p" "$STACK/.env" | tail -1; }
WORKSPACE="$(getenv LUMO_WORKSPACE)"; LITELLM_KEY="$(getenv LITELLM_MASTER_KEY)"
mkdir -p "$WORKSPACE/code" "$WORKSPACE/inbox" "$WORKSPACE/out"
if [ ! -f "$STACK/config/tamer.yaml" ]; then
  TAMER_KEY="lt-$(rnd 40)"; (umask 077; render "$STACK/config/tamer.yaml.template" "$STACK/config/tamer.yaml"); note "created config/tamer.yaml"
else
  TAMER_KEY="$(sed -n 's/^  apiKey: "\(.*\)"/\1/p' "$STACK/config/tamer.yaml")"; note "config/tamer.yaml kept"
fi
[ -f "$STACK/config/litellm.yaml" ] || { (umask 077; render "$STACK/config/litellm.yaml.template" "$STACK/config/litellm.yaml"); note "created config/litellm.yaml"; }
note "workspace: $WORKSPACE/{code,inbox,out}"

# --- 4. Build and start ---------------------------------------------------------
dc() { docker compose --project-directory "$STACK" -f "$STACK/compose.yaml" "$@"; }
step "Building (first time: 10-20 minutes, a few GB)"
dc --profile code build tamer litellm home code
dc pull -q webui
step "Starting"
dc up -d tamer litellm webui home
note "Lumo Home: http://localhost:$(getenv LUMO_HOME_PORT)"

# --- 5. Commands ----------------------------------------------------------------
step "Commands"
if [ -n "$no_link" ]; then note "skipped (--no-link): run $STACK/bin/lumo directly"; else
mkdir -p "$HOME/.local/bin"
ln -sf "$STACK/bin/lumo" "$HOME/.local/bin/lumo"
note "$HOME/.local/bin/lumo"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) note "${R}add ~/.local/bin to your PATH${N}: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.profile" ;; esac

# --- 6. Claude Code (optional) ----------------------------------------------------
if [ -n "$with_claude" ]; then
  step "Claude Code, minus Anthropic"
  note "claude-lumo runs Claude Code with Lumo as the model: prompts go to LiteLLM on"
  note "127.0.0.1, then Lumo. Never Anthropic. Telemetry, updates and MCP are off."
  if ! command -v claude >/dev/null; then
    note "Claude Code isn't installed; the official installer downloads it from Anthropic once."
    go=1; [ -z "$yes" ] && { read -r -p "    Install Claude Code now? [y/N] " a; case "$a" in [yY]*) ;; *) go="" ;; esac; }
    [ -n "$go" ] && curl -fsSL https://claude.ai/install.sh | bash
  fi
  [ -n "$no_link" ] || { ln -sf "$STACK/bin/claude-lumo" "$HOME/.local/bin/claude-lumo"; note "$HOME/.local/bin/claude-lumo"; }
fi

# --- 7. Sign in, check ------------------------------------------------------------
if [ -z "$no_login" ]; then step "Sign in to Proton"; "$STACK/bin/lumo" login || true; fi
step "Checking everything"
printf "    waiting for everything to finish starting"
for _ in $(seq 1 60); do curl -s -m 2 "http://127.0.0.1:$(getenv LUMO_WEBUI_PORT)/health" | grep -q true && break; printf "."; sleep 3; done; echo
"$STACK/bin/lumo-doctor" || true
step "You're in."
cat <<EOF
    lumo home      the dashboard: status, sign-in, files, chat, code
    lumo           the jailed coding agent (it only sees $WORKSPACE)
    lumo web       chat in your browser
    lumo help      everything else

    Coding UI password: $(cat "$STACK/secrets/code-web-password")   (login: lumo)
    Your prompts are nobody's training data. Have fun.
EOF
