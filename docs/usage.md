# How you'll use Lumo Stack

Two ways in, on every system: **the browser** (click around, no commands to remember) and **the
terminal** (faster, scriptable). Both talk to the same Lumo behind the scenes. Pick your system:

- [macOS](#macos): browser dashboard (Lumo Home) + terminal
- [Linux and WSL2](#linux-and-wsl2): browser chat and coding UI + terminal *(new in v0.2, not yet tested end to end)*
- [Windows](#windows): browser chat and coding UI + PowerShell *(experimental, untested)*

**Where your files go (every system).** Your workspace is `~/lumo` (on Windows, `%USERPROFILE%\lumo`):

| Folder | What it's for | Lumo can |
|---|---|---|
| `code/<project>` | One folder per project. The coding agent works here | read and write |
| `inbox/` | Drop files here for Lumo to read | read only |
| `out/` | Results Lumo makes for you | write |

The coding agent sees **only** these three folders: no internet, no home folder. Before each session
it saves a git snapshot of the project, so you can always undo.

---

## macOS

### In the browser: Lumo Home

```sh
lumo home          # opens http://localhost:8090
```

**First time**
1. **Services → Start everything.** Wait until the services show as running.
2. **Proton login → Log in to Proton.** A browser window opens on Lumo. Sign in (authenticator code,
   second password if you use one). It closes by itself when you're done.

**Chat**
1. **Chat → Open Chat.** Open WebUI opens at http://localhost:8080.
2. First visit only: Open WebUI asks you to create an account. It's local to your Mac; pick any name and password.
3. Choose a model at the top: `lumo` (Proton picks), `lumo-max` (strongest) or `lumo-lite` (fastest).

**Code on a project**
1. **Code → Open Code.** The coding agent opens in your browser at http://localhost:4096.
2. Log in as `lumo`. The password is in your Keychain:
   `security find-generic-password -s lumo-stack -a code-web -w`
3. Ask for what you want ("make a script that renames my photos by date"). It works in `~/lumo/code`.
4. **Code → Stop** when you're done.

**Files**
- In **Files**, upload puts files in `inbox/` for Lumo to read, and **Fetch** downloads a web page or PDF into `inbox/`.
- Results show up under `out/`; click one to download it.

### In the terminal

```sh
lumo                                  # coding agent in ~/lumo/code (jailed)
lumo open photo-tools                 # ...in its own project folder (created with an AGENTS.md)
lumo open photo-tools --max           # ...on Lumo's strongest model
lumo run -p photo-tools "add a --dry-run flag to rename.py"    # one-shot, no chat

lumo ask "what's the difference between a mutex and a semaphore?"   # quick answer, no tools
lumo chat                             # plain chat in the terminal

lumo import ~/Desktop/report.pdf      # copy into inbox/ (read-only for Lumo)
lumo fetch https://example.com/spec.pdf
lumo export                           # copy out/ to ~/Downloads

lumo snapshots photo-tools            # undo points
lumo restore photo-tools <id>         # roll back (the rollback can be undone too)

lumo login                            # sign in again (browser window)
lumo status · lumo doctor · lumo logs · lumo update
claude-lumo                           # Claude Code on Lumo (if installed with --with-claude)
```

A typical session: `lumo import notes.txt` → `lumo open blog` → "turn inbox/notes.txt into a post in
out/post.md" → `lumo export` → the post is in `~/Downloads`.

---

## Linux and WSL2

There's no dashboard on Linux yet: Lumo Home is macOS only. The browser covers chat and coding, and
the terminal does everything else.

### In the browser

```sh
lumo web               # chat: opens http://localhost:8080 (Open WebUI)
lumo code --web        # coding agent: http://localhost:4096
lumo code -p photo-tools --web    # ...in one project folder
```

- **Chat:** first visit, Open WebUI asks you to create an account (local to your machine). Pick
  `lumo`, `lumo-max` or `lumo-lite` at the top.
- **Coding agent:** log in as `lumo`; the password is `cat ~/.config/lumo-stack/secrets/code-web/password`.
  Stop it with `lumo code-web stop`.
- **Sign-in, when Proton wants a CAPTCHA:** `lumo login` switches to a browser sign-in by itself. Open
  http://127.0.0.1:3001 (a browser running in a container, shown in your own browser), sign in to Proton
  there, then go back to the terminal. Or start it yourself: `lumo login --browser`.
- **WSL2:** the URLs open in your Windows browser (WSL2 shares `localhost` with Windows).

### In the terminal

```sh
lumo login                                     # email, password, authenticator code (passwords not stored)
lumo code                                      # coding agent in ~/lumo/code (jailed)
lumo code -p photo-tools                       # ...in its own project folder
lumo code -p photo-tools --max                 # ...on Lumo's strongest model
lumo code -p photo-tools run "add a --dry-run flag to rename.py"   # one-shot

cp ~/Desktop/report.pdf ~/lumo/inbox/          # give Lumo a file to read
ls ~/lumo/out/                                 # results

git -C ~/lumo/code/photo-tools log --oneline   # undo points (one snapshot per session)
git -C ~/lumo/code/photo-tools reset --hard <id>   # roll back

lumo status · lumo doctor · lumo logs tamer · lumo update
lumo cloudflare on                             # optional: add Cloudflare models
lumo claude                                    # Claude Code on Lumo: not written for Linux yet
```

Not on Linux yet: `lumo ask`, `lumo chat`, `lumo import`/`fetch`/`export`, `lumo snapshots`/`restore`
(use the `cp` and `git` lines above), Lumo Home, sign-in alerts.

---

## Windows

Run these in **PowerShell 7** (`pwsh`), in a new terminal after installing. Options use PowerShell's
style: `-Project`, `-Max`, `-Web`.

### In the browser

```powershell
lumo web                          # chat: opens http://localhost:8080 (Open WebUI)
lumo code -Web                    # coding agent: http://localhost:4096
lumo code -Project photo-tools -Web
```

- **Chat:** first visit, Open WebUI asks you to create an account (local to your PC).
- **Coding agent:** log in as `lumo`; the password is
  `Get-Content $env:APPDATA\lumo-stack\secrets\code-web\password`. Stop it with `lumo code-web stop`.
- **Sign-in, when Proton wants a CAPTCHA:** `lumo login` switches to the browser sign-in and opens
  http://127.0.0.1:3001. Sign in there, then go back to PowerShell. Or: `lumo login -Browser`.

### In the terminal

```powershell
lumo login                                        # email, password, authenticator code
lumo code                                         # coding agent in ~\lumo\code (jailed)
lumo code -Project photo-tools                    # ...in its own project folder
lumo code -Project photo-tools -Max               # ...on Lumo's strongest model
lumo code -Project photo-tools run "add a --dry-run flag to rename.py"   # one-shot
lumo code -- --continue                           # pass options to the agent after --

Copy-Item $HOME\Desktop\report.pdf $HOME\lumo\inbox\   # give Lumo a file to read
Get-ChildItem $HOME\lumo\out                           # results

git -C $HOME\lumo\code\photo-tools log --oneline       # undo points
git -C $HOME\lumo\code\photo-tools reset --hard <id>   # roll back

lumo status ; lumo doctor ; lumo logs tamer ; lumo update
lumo cloudflare on                                # optional: add Cloudflare models
```

`claude-lumo` stays off on native Windows: Claude Code can't sandbox commands there. For it, install
inside WSL2 and use the Linux steps.

---

## When something's off (every system)

| You see | Do this |
|---|---|
| "sign-in needed", or chat answers with an auth error | `lumo login` |
| Proton asks for a CAPTCHA | Let `lumo login` switch to the browser sign-in (macOS opens a window; Linux/Windows use http://127.0.0.1:3001) |
| A page at localhost won't load | `lumo status`, then `lumo doctor`: it says what failed and the command that fixes it |
| "port … is in use" | Something else uses that port. Linux/Windows: change it in `lumo.env` (`WEBUI_PORT=8081` etc.) |
| The agent broke your project | Roll back: `lumo restore` on macOS, `git reset --hard <id>` in the project on Linux/Windows |
| Still stuck | `lumo logs` (Linux/Windows: `lumo logs tamer`, `lumo logs litellm`) and open an issue |
