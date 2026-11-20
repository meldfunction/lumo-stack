#!/bin/zsh
# Double-click installer: asks with macOS dialogs, runs ./install, then signs
# you in to Proton and opens Lumo Home. The Terminal window shows progress.
cd "${0:A:h}"
HERE=$PWD
LOG=$(mktemp -t lumo-install).log

dialog() {  # dialog <text> <buttons...>  -> prints the button pressed ("" if cancelled)
  local text=$1; shift
  local btns=$(printf '"%s",' "$@"); btns=${btns%,}
  osascript -e "button returned of (display dialog \"$text\" buttons {$btns} default button \"${@[-1]}\" with title \"Lumo Stack\" with icon note)" 2>/dev/null
}
fail() {
  osascript -e "display alert \"Lumo Stack couldn't be installed\" message \"$1\n\nFull log: $LOG\" as critical" >/dev/null 2>&1
  exit 1
}

# 1. Consent
ans=$(dialog "This installs Lumo Stack: Proton Lumo as a chat app, a locked-down coding assistant and a dashboard, all on this Mac.

It uses lumo-tamer, an UNOFFICIAL community bridge not affiliated with Proton. Proton could block it, and it could put your Proton account at risk.

You need: OrbStack or Docker Desktop, Node.js 20+, Python 3.10+, git, and Chrome, Brave or Edge." "Cancel" "Install")
[[ $ans == Install ]] || exit 0

# 2. Workspace
args=(--yes --no-login)
ans=$(dialog "Where should Lumo keep its files? It can only see this folder (code, inbox and out)." "Choose a folder…" "Use ~/lumo")
if [[ $ans == "Choose a folder…" ]]; then
  dir=$(osascript -e 'POSIX path of (choose folder with prompt "Choose or create a folder for Lumo")' 2>/dev/null) || exit 0
  args+=(--workspace "${dir%/}")
fi

# 3. Optional Claude Code launcher
if command -v claude >/dev/null; then
  [[ $(dialog "Claude Code is installed. Also add 'claude-lumo' (Claude Code running on Lumo, no Anthropic account)?" "No" "Add it") == "Add it" ]] \
    && args+=(--with-claude)
fi

# 4. Install
print "Installing Lumo Stack. This can take 10–20 minutes the first time (large downloads).\n"
./install $args 2>&1 | tee $LOG
(( ${pipestatus[1]} == 0 )) || fail "$(grep 'install:' $LOG | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"

# 5. Sign in, then open the dashboard
if [[ $(dialog "Installed. Next, sign in to Proton: a browser window will open on Lumo. Sign in there; it closes by itself when done." "Later" "Sign in") == "Sign in" ]]; then
  ./lumo-login || osascript -e 'display alert "Sign-in didn'"'"'t finish" message "You can sign in any time from Lumo Home."' >/dev/null
fi
./lumo home >/dev/null
print "\nDone. Lumo Home is open in your browser. You can close this window."
