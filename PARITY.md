# Platform parity

macOS, Linux/WSL2 and native Windows are **kept separately on purpose**: macOS keeps its
LaunchAgents and Keychain, and Linux and Windows run Docker Compose with their own scripts.
They share only data and images: `versions.env`, `templates/`, `compose/`, `Dockerfile.opencode`,
`opencode.json`.

That means a fix in one column may be needed in the others. **When you change a row, check the
other columns and say in the PR whether they need the same change.**

| What | macOS (repo root) | Linux / WSL2 (`linux/`) | Windows (`windows/`) |
|---|---|---|---|
| Install | `install`, `Install Lumo.command` | `install` | `install.ps1` |
| Uninstall | `uninstall` | `lumo uninstall` | `lumo uninstall` |
| Shared settings | `lib.zsh` + `lumo.env` | `lib.zsh` + `~/.config/lumo-stack/lumo.env` | `lib.ps1` + `%APPDATA%\lumo-stack\lumo.env` |
| Start services | `lumo-up` (launchctl) | `lumo up` (compose) | `lumo up` (compose) |
| Sign-in (password) | `lumo-signin` | `lumo login` | `lumo login` |
| Sign-in (browser / CAPTCHA) | `lumo-login` (host Chrome/Brave/Edge) | `lumo login --browser` (`browser` profile, noVNC) | `lumo login -Browser` |
| Jailed agent | `lumo-code` | `lumo code` | `lumo code` |
| Open WebUI | `lumo-web`, `webui-create` | `lumo web` | `lumo web` |
| Claude Code on Lumo | `claude-lumo` (Seatbelt sandbox) | *paused: not written yet* | `claude-lumo.ps1` (refuses: no sandbox) |
| Cloudflare opt-in | `lumo-cloudflare` | `lumo cloudflare` + `cfgtool.py` | `lumo cloudflare` + `Edit-CloudflareBlock` |
| Lumo router (Q&A-only Lumo, weekly budget) | `lumo-router` + `templates/lumo_router.py` | `lumo router` + `cfgtool.py router` | `lumo router` + `Edit-RouterCallback` |
| Health check | `lumo-doctor` | `lumo doctor` | `lumo doctor` |
| Update | `lumo-update` | `lumo update` | `lumo update` |
| Secrets | Keychain | 0600 files | user-only ACL files |
| Tinfoil, local Ollama | `lumo-tinfoil`, `lumo-local` | — | — |
| Lumo Home, hourly check | `lumo-home.py`, `lumo-watch` | — | — |

**Tests:** `tests/parity.sh` checks that all PowerShell parses, and that the Python (Linux) and
PowerShell (Windows) config editing produce identical files. It runs on any machine with Docker.
