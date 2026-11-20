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
ans=$(dialog "Lumo Stack: Proton's private AI in your terminal, a jailed coding agent and your browser. All on this Mac. Your prompts are nobody's training data.

The fine print: it uses lumo-tamer, an UNOFFICIAL community bridge not affiliated with Proton. Proton could block it, and it could put your Proton account at risk.

You'll need: a Proton account, OrbStack or Docker Desktop, Node.js 20+, Python 3.10+, git, and Chrome, Brave or Edge." "Not today" "Let's go")
[[ $ans == "Let's go" ]] || exit 0

# 2. Workspace
args=(--yes --no-login)
ans=$(dialog "Where should Lumo live? The coding agent can only see this one folder (code, inbox and out). Nothing else on your Mac." "Choose a folder…" "Use ~/lumo")
if [[ $ans == "Choose a folder…" ]]; then
  dir=$(osascript -e 'POSIX path of (choose folder with prompt "Choose or create a folder for Lumo")' 2>/dev/null) || exit 0
  args+=(--workspace "${dir%/}")
fi

# 3. Optional: Claude Code on Lumo
if command -v claude >/dev/null; then
  q="Claude Code is already here. Add claude-lumo too? Same Claude Code, but Lumo is the brain: prompts go to Lumo through this Mac, never to Anthropic. Plain 'claude' keeps working as before."
else
  q="Want Claude Code too? We'll install it (one download from Anthropic) and add claude-lumo: Claude Code with Lumo as the brain. No Anthropic account needed, and your prompts never go to Anthropic."
fi
[[ $(dialog "$q" "Skip" "Yes, add it") == "Yes, add it" ]] && args+=(--with-claude)

# 4. Install
print "Installing Lumo Stack. First time takes 10–20 minutes (a few GB of downloads). Coffee?\n"
./install $args 2>&1 | tee $LOG
(( ${pipestatus[1]} == 0 )) || fail "$(grep 'install:' $LOG | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"

# 5. Sign in, then open the dashboard
if [[ $(dialog "Installed. Last step: sign in to Proton. A browser window opens on Lumo; sign in and it closes itself." "Later" "Sign in") == "Sign in" ]]; then
  ./lumo-login || osascript -e 'display alert "Sign-in didn'"'"'t finish" message "You can sign in any time from Lumo Home."' >/dev/null
fi
./lumo home >/dev/null
print "\nYou're in. Lumo Home is open in your browser. You can close this window."
