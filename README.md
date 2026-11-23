# Lumo Stack

**Your prompts are nobody's training data.**

Lumo Stack puts [Proton Lumo](https://lumo.proton.me), Proton's private AI, inside
the tools you already use: **Claude Code**, a **jailed coding agent** and **your
browser**. It all runs on your own machine. No Anthropic account, no OpenAI
account, nothing phoning home.

> **The fine print, up front.** Lumo has no public API yet. Lumo Stack uses
> [lumo-bridge](https://github.com/meldfunction/lumo-bridge) (our fork of [lumo-tamer](https://github.com/ZeroTricks/lumo-tamer)), a community bridge that
> talks to Lumo the way Proton's own web app does. Proton could block it, and it
> could put your Proton account at risk. Not affiliated with or endorsed by Proton.
> Rebellious, yes. Reckless, no.

**Platforms:** macOS (the original, most locked-down setup). **New in v0.2:** Linux and WSL2, and
native Windows, both on Docker Compose. Linux is built but not yet tested end to end; Windows is
**experimental and untested** (we have no Windows machine). See [Linux and Windows](#linux-and-windows).

## Security: what we lock down, and what we open up

Proton protects your chats once they reach Lumo. Lumo Stack can't make Lumo itself any more private
than that: every prompt still goes to Proton. What it controls is everything around Lumo on your machine.
The tables below describe macOS; [Linux and Windows](#linux-and-windows) differ in a few places.

**Locked down**

| Where | What we do |
|---|---|
| The bridge | [lumo-bridge](https://github.com/meldfunction/lumo-bridge) listens on `127.0.0.1` only. Upstream listened on every interface, so anyone on your Wi-Fi could reach it |
| Secrets | Your Proton session sits in lumo-bridge's encrypted vault; the Cloudflare token in the macOS Keychain. Your Proton passwords are never stored |
| Signing in | Your old login is kept until the new one is proven to answer. The browser sign-in waits for the whole flow (authenticator code, second password) and never reloads the page under you. Page addresses in the log are cut at `?` and `#`, so tokens in URLs don't end up in log files |
| `claude-lumo` | No Anthropic account, telemetry or error reports, update checks or MCP servers. It refuses to start if LiteLLM could route anywhere outside its allowlist (Lumo, plus Cloudflare, Tinfoil or local Ollama only if you opt in) |
| `claude-lumo`'s commands | Run in Claude Code's OS sandbox, which `claude-lumo` now switches on itself: files can only be written in the work folders, and network only reaches hosts on its allowlist. We checked: `gh` reached GitHub, `example.com` was blocked |
| `claude-lumo`'s permissions | Normal permission prompts: anything outside its allowlist asks you first |
| The jailed agent | No internet, no home folder, read-only config, undo snapshots (see [The jail](#the-jail)) |

**Opened up, on purpose**

To make `claude-lumo` useful for real work, it can now reach more than it used to. Know what you're
turning on:

| What | What it means | Off switch |
|---|---|---|
| Your folders (`LUMO_DIRS` in `lumo.env`) | Lumo can read and edit them, so what it reads goes to Proton | Leave `LUMO_DIRS` unset |
| GitHub | `claude-lumo` gives the session your existing `gh` login, so Lumo can do on GitHub whatever that login allows. The sandbox allows the GitHub hosts, plus macOS's certificate service so `gh` can check TLS | `LUMO_NO_GH=1` |
| Cloudflare (opt-in) | Claude Code's small background calls go to Cloudflare Workers AI: TLS and Cloudflare's policy, not Proton's protections | `lumo-cloudflare off` |
| Sandbox | Some tools need it off | `LUMO_NO_SANDBOX=1` (not recommended) |

Pushing, PRs and anything public still go through `claude-lumo`'s permission prompts.

### Linux and Windows

The tables above are for macOS. Linux, WSL2 and native Windows run the same pieces in Docker
Compose instead of LaunchAgents, with these differences:

| Where | Linux / WSL2 | Native Windows |
|---|---|---|
| Secrets | Files only your user can read (`~/.config/lumo-stack`, `chmod 600`), each mounted only into the container that needs it. **Weaker than the macOS Keychain**: any program running as you can read them | The same, in `%APPDATA%\lumo-stack`, locked to your user with Windows permissions. Same caveat |
| The bridge | Its port is published on `127.0.0.1` only. Containers on the stack's own network can reach it | Same |
| Containers | Run as your user, with every Linux capability dropped and no privilege escalation | Same (Docker Desktop) |
| `claude-lumo`'s commands | Claude Code's sandbox works here (bubblewrap + socat) | **No sandbox exists on native Windows**, so `claude-lumo` refuses to start unless you set `LUMO_NO_SANDBOX=1`. For the sandbox, install inside WSL2 |
| The jailed agent | Same jail as macOS | Same jail as macOS |
| Tinfoil, local Ollama, Lumo Home, hourly login check | Not yet (macOS only) | Not yet (macOS only) |

---

## "But I've got nothing to hide"

Cool. Here's what happens to chats on the big platforms anyway:

- **Deleted isn't gone.** In May 2025, a US court ordered OpenAI to keep ChatGPT
  conversations it would normally delete, including ones users had deleted, as
  evidence in a copyright lawsuit. ([Simon Willison](https://simonwillison.net/2025/Jun/5/openai-court-order), [Malwarebytes](https://www.malwarebytes.com/blog/news/2025/06/openai-forced-to-preserve-chatgpt-chats))
- **"Shared" can mean "searchable".** In July 2025, about 4,500 shared ChatGPT
  conversations showed up in Google results, some about mental health and
  relationships. OpenAI killed the feature within days. ([TechCrunch](https://techcrunch.com/2025/07/31/your-public-chatgpt-queries-are-getting-indexed-by-google-and-other-search-engines), [PC Gamer](https://www.pcgamer.com/software/ai/chatgpt-removes-the-ability-for-conversations-to-be-displayed-by-search-engines-as-nearly-4-500-conversations-indexed-by-google/))
- **Humans read some of it.** Google says human reviewers, including
  contractors, read some Gemini conversations, and reviewed chats can be kept for
  up to three years. ([Gemini Apps Privacy Notice](https://support.google.com/gemini/answer/13594961))
- **Code leaks too.** In 2023, Samsung engineers pasted internal source code into
  ChatGPT; Samsung then banned generative AI on company devices. ([TechRadar](https://www.techradar.com/news/samsung-bans-chatgpt-use-after-employee-leak))

You might have nothing to hide. Your code, your clients and your 2 a.m. health
questions might disagree.

## Why Lumo

Lumo comes from the people behind Proton Mail and Proton VPN, with the same allergy to snooping.

- **Confidential:** chats are encrypted, Proton keeps no logs of them, and they don't train anyone's model.
- **Open:** open-source models; Proton's Lumo web and mobile apps are open source (GPLv3).
- **Swiss, one account:** run by Proton in Switzerland, on the account you already use for Mail, Drive and VPN. Free tier, zero ads.

Straight talk: for heavy coding and long tool chains, Claude, GPT and Gemini
models are still stronger. Lumo wins when where your words end up matters more
than raw horsepower.

## What Lumo Stack adds (that Proton doesn't, yet)

Proton's Lumo apps are great chat apps. They don't plug into your tools, because
there's no public API. Until there is, Lumo Stack is the adapter.

| | Proton's Lumo apps | With Lumo Stack |
|---|---|---|
| API for other tools | none yet (on Proton's roadmap) | OpenAI-compatible endpoint on localhost |
| Claude Code | — | `claude-lumo`: Claude Code with Lumo as the brain, no Anthropic account |
| Coding agent | desktop app works directly on your machine | OpenCode in a jail: no internet, only your workspace visible, undo snapshots |
| Browser | lumo.proton.me | plus Open WebUI and a browser coding UI, self-hosted on localhost |
| Scripting | — | `lumo ask` and `lumo run` in any shell script |
| Files | upload in chat | inbox and out folders, URL fetch, project zips |
| Keeping it alive | — | `lumo doctor`, sign-in alerts, pinned versions with rollback |

When Proton ships an official API, Lumo Stack switches to it and retires the
unofficial bridge. We'll throw a small party.

## Claude Code, minus Anthropic

Love the Claude Code workflow but want Lumo doing the thinking? `claude-lumo` is
Claude Code with the brain swapped out. Here's exactly how it keeps Anthropic out of the loop:

| What Claude Code normally does | What `claude-lumo` does instead |
|---|---|
| Sends prompts to Anthropic's API | `ANTHROPIC_BASE_URL` points at LiteLLM on `127.0.0.1:4000`, which forwards to Lumo (and to Cloudflare, Tinfoil or local Ollama only if you opt in) |
| Signs in with your Anthropic account or API key | Uses your local LiteLLM key; `ANTHROPIC_API_KEY` is unset |
| Uses Opus, Sonnet and Haiku | Every model slot, subagents included, maps to `lumo`, `lumo-max` or `lumo-lite` |
| Sends telemetry and error reports, checks for updates | All switched off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`) |
| Loads your MCP servers (which make their own connections) | Off by default (`--strict-mcp-config`); `LUMO_KEEP_MCP=1` brings them back |
| Trusts its config | Refuses to start if LiteLLM could route outside its allowlist |
| Runs commands unsandboxed, in "auto" permission mode if that's your setting | Switches Claude Code's sandbox on, and uses normal permission prompts (auto mode's safety check runs on Anthropic's servers, which `claude-lumo` never talks to) |

We checked by watching the network: with MCP off, a `claude-lumo` session's only
connection was to `127.0.0.1:4000`. That was before GitHub access: with it on, commands
Lumo runs can also reach GitHub (see [Security](#security-what-we-lock-down-and-what-we-open-up));
`LUMO_NO_GH=1` takes you back. Your plain `claude` command stays your normal
Claude Code; only `claude-lumo` is Lumo-only.

Installing Claude Code itself is one download from Anthropic (the official
installer, `curl -fsSL https://claude.ai/install.sh | bash`). `./install --with-claude`
does it for you if it's missing. No Anthropic account is needed for `claude-lumo`.

Heads up: Claude Code was built around Claude's tool use. With Lumo it's great
for questions and small edits, and wobblier on long multi-step jobs. For anything
that edits files, the jailed `lumo` agent is the safer bet: `claude-lumo` runs on
your machine in Claude Code's sandbox with normal permission prompts, not in a jail. On native
Windows there is no sandbox, so `claude-lumo` stays off there unless you switch it on (use WSL2 instead).

## Commands

It's all just `lumo`. Every command starts whatever's asleep first, and keeps a log.

> **On Linux or Windows?** The table below is macOS. There it's one command with subcommands:
> `lumo code` (the jailed agent; `lumo code run "task"` for a one-shot), `lumo code --web`, `lumo web`,
> `lumo login`, `lumo cloudflare on|off|status`, `lumo status`, `lumo doctor`, `lumo update`,
> `lumo uninstall`. `lumo help` lists them. On Windows the options are PowerShell-style
> (`lumo code -Project app -Max`). Not there yet: `lumo ask`, snapshots, `lumo-ask`, `lumo-task`/`lumo-hq`,
> Lumo Home, Tinfoil and local Ollama.

| Command | What it does |
|---|---|
| `lumo` | Coding agent (OpenCode) in the terminal, jailed. `--max` for Lumo's strongest model |
| `lumo open <project>` | One folder per project; new ones get an `AGENTS.md` tuned for Lumo |
| `lumo run "task"` | Fire-and-forget task |
| `lumo code-web` | The coding agent in your browser, password-protected |
| `lumo web` | Chat in Open WebUI |
| `lumo ask "…"` / `lumo chat` | Quick answer / plain terminal chat |
| `claude-lumo` | Claude Code on Lumo (optional add-on). Lean by default; `LUMO_FULL=1` for the full setup |
| `lumo-ask "…" files…` | One request, no agent loop: files pasted with line numbers, temperature 0. `--write f --check "cmd"` fixes a file and retries once if the check fails. Fastest and most accurate in benchmarks |
| `lumo-task "…"` · `lumo-hq` | A small task log where every task carries a model (auto-picked, or pinned). Private tasks only ever run on Lumo. `lumo-hq` opens a local dashboard: tasks, model status, token HP bars. See [docs/hq.md](docs/hq.md) |
| `lumo-cloudflare on\|off\|status\|usage\|models` | Opt-in: add Cloudflare Workers AI models (US/EU-origin only). Token in the Keychain, account ID in `lumo.env` |
| `lumo-local on\|off\|status` | Opt-in, emergency: tool-capable Ollama models (optionally on an external drive, `LUMO_LOCAL_DRIVE`) as the private last-resort fallback. Nothing leaves the Mac |
| `lumo-tinfoil on\|off\|status` | Opt-in: add Tinfoil confidential inference (hardware enclaves, attestation checked by the local tinfoil-proxy). Falls back to Lumo, never to Cloudflare |
| `lumo import` / `lumo fetch <url>` / `lumo export` | Move files into and out of the jail |
| `lumo snapshots` / `lumo restore` | List undo points, then rewind (the rewind is undoable too) |
| `lumo home` | Dashboard: status, one-click Proton sign-in, files, chat, code |
| `lumo login` | Sign in to Proton: a browser opens, you sign in, it tidies up after itself |
| `lumo doctor` | 29 health and security checks |
| `lumo update` | Update pinned parts, with automatic rollback if anything breaks |

## The jail

AI agents run commands. Ours runs them in a box with no windows.

- **No internet.** It sits on an internal Docker network; one relay container is its only road, and it leads to Lumo.
- **No power.** Read-only system, no root, no sudo, no Linux capabilities, CPU/memory/process limits.
- **No snooping.** It can't see your home folder, your keys or the rest of your machine.
- **No rewriting its own rules.** Its config lives outside the jail, mounted read-only.
- **Your workspace only:** `code/` read-write, `inbox/` read-only, `out/` for results.
- **Undo built in:** a git snapshot before every session.

No trust-me-bro settings readout: `lumo doctor` spins up a jailed container and
actually tries every write and connection.

## Install

### First, a Proton account

Any Proton account works, free included. Coding a lot? Get Lumo Plus: coding
agents are chatty, and Plus removes the chat cap.

| Lumo tier | Account | What you get | Price |
|---|---|---|---|
| Guest | none | Limited chats, nothing saved. Lumo Stack needs a signed-in account, so this one's out | free |
| Free | free Proton account | Limited messages and Max-model use, chats kept 7 days, a few images, 1 Project, web search, small file uploads | $0 |
| **Plus** (our pick) | Proton account | Unlimited chats, more Max-model use (`lumo --max`), longer history, more images, unlimited Projects and Custom Lumos, big file uploads | $9.99/mo billed yearly ($119.88), or $12.99 monthly |
| Business | Lumo Professional or Proton Workspace | Much higher limits, admin controls | [see pricing](https://proton.me/business/lumo/pricing) |

Proton Unlimited, Duo and Family come with free-tier Lumo; Plus is an
[add-on](https://proton.me/support/proton-add-ons). Visionary and Workspace
Premium include Plus. Prices as Proton listed them in November 2026;
[check the latest](https://proton.me/lumo/pricing).

New to Lumo? [Try it](https://lumo.proton.me) ·
[Getting started](https://proton.me/support/lumo-getting-started) ·
[What's new in Lumo 2.0](https://proton.me/blog/lumo-2)

Then pick your system: [macOS](#macos-what-you-need) · [Linux / WSL2](#linux-and-wsl2) · [Windows](#windows-experimental-untested).

### macOS: what you need

- [OrbStack](https://orbstack.dev) (recommended) or Docker Desktop
- Node.js 20+, Python 3.10+ and git
- Chrome, Brave or Edge, for the Proton sign-in
- Optional: Claude Code (the installer can fetch it for you)

```sh
brew install git node python
brew install --cask orbstack
```

### macOS: click your way through

1. [Download the zip](https://github.com/meldfunction/lumo-stack/archive/refs/heads/main.zip) and unzip it.
2. Double-click **Install Lumo.command**. First time, macOS gets suspicious: right-click it and choose Open.
3. Pick a home for Lumo's files (or keep `~/lumo`), and say yes or no to Claude Code.
4. Sign in to Proton in the browser window that pops up. It closes itself when you're done.
5. Lumo Home opens. You're in.

### macOS: the terminal way

```sh
git clone https://github.com/meldfunction/lumo-stack.git ~/lumo-stack
cd ~/lumo-stack && ./install
```

Commitment issues? `./install --dry-run` shows every step and changes nothing.
Options: `--workspace DIR`, `--with-claude`, `--no-login`, `--yes`.

The first install pulls a few GB (Open WebUI, LiteLLM, OpenCode) and takes 10–20
minutes. Make a coffee. It finishes with the Proton sign-in and a `lumo doctor`
run. Re-running is safe: your keys, settings and login stay put.

**Changed your mind?** `./uninstall` removes it all and keeps your files;
`./uninstall --purge` takes those too.

### Linux (and WSL2)

Needs Docker Engine with the Compose plugin (or Docker Desktop), zsh, git, curl, openssl and
python3. For `claude-lumo`: Claude Code, plus `bubblewrap` and `socat` for its sandbox.

```sh
sudo apt install zsh git curl openssl python3 docker.io docker-compose-v2   # Debian/Ubuntu
git clone https://github.com/meldfunction/lumo-stack.git ~/lumo-stack
cd ~/lumo-stack && ./linux/install            # --dry-run, --with-claude, --no-login, --yes
```

One command does everything: `lumo up`, `lumo login`, `lumo code`, `lumo web`, `lumo doctor`,
`lumo update`, `lumo uninstall [--purge]` (`lumo help` lists them all). Configs and secrets live in
`~/.config/lumo-stack`, the Proton login in `~/.local/share/lumo-stack`.

### Windows (experimental, untested)

Needs Docker Desktop (Linux containers), Git and PowerShell 7: `winget install Docker.DockerDesktop Git.Git Microsoft.PowerShell`.

```powershell
git clone https://github.com/meldfunction/lumo-stack.git $HOME\lumo-stack
pwsh -File $HOME\lumo-stack\windows\install.ps1      # -DryRun, -NoLogin, -Yes
```

Open a new terminal afterwards so `lumo` is on your PATH. The same `lumo` commands, as PowerShell
(`lumo code -Project app`, `lumo login -Browser`). Configs and secrets live in `%APPDATA%\lumo-stack`,
the Proton login in `%LOCALAPPDATA%\lumo-stack`. **Changed your mind?** `lumo uninstall` (add
`-Purge` to delete configs and the login too; your workspace stays).
Want `claude-lumo` with its sandbox? Use WSL2 and the Linux steps above. If you try Windows,
please open an issue either way.

## Under the hood

```
lumo / lumo code-web ─► OpenCode (jail) ─► lumo-relay ─┐
lumo web ─────────────► Open WebUI ────────────────────┼─► LiteLLM :4000 ─► lumo-tamer :3003 ─► Proton Lumo
claude-lumo ──────────► Claude Code ───────────────────┘
lumo home ────────────► Lumo Home :8090 (status, sign-in, files)
```

LiteLLM routes only to lumo-tamer, and every launcher checks that before it
starts. On macOS, lumo-tamer and LiteLLM run as LaunchAgents (on Linux and Windows,
as Compose services: see `compose/compose.yaml`); an hourly check pings you if
the Proton login stops working. Everything listens on `127.0.0.1`.

### Settings

Defaults live in `lib.zsh`. To change them on one machine, drop a `lumo.env` next
to it (it's git-ignored):

```sh
LUMO_HOME=$HOME/Documents/Lumo   # workspace (macOS will ask apps for access to Documents)
```

On Linux the settings file is `~/.config/lumo-stack/lumo.env`; on Windows,
`%APPDATA%\lumo-stack\lumo.env`. Ports can be changed there too (`TAMER_PORT`, `LITELLM_PORT`, `WEBUI_PORT`).

Pinned versions live in `versions.env`; `lumo update` changes them.

## What to expect

- **Tool calling is experimental.** Quick edits and file writes work; long multi-step sessions trip over themselves more than with Claude or GPT.
- **Some Lumo perks stay home.** Lumo's web search, image generation and memory don't make it through the bridge.
- **Your login babysits itself.** It lasts 24 hours and renews on its own; if Proton signs you out, Lumo Home and a notification tell you.
- **macOS is the most tested.** Linux and Windows are new in v0.2: Linux is built but not yet tested end to end, Windows is experimental and untested, and some extras (Lumo Home, sign-in alerts, Tinfoil, local Ollama) are macOS only for now.

---

Built on [lumo-bridge](https://github.com/meldfunction/lumo-bridge), a fork of [lumo-tamer](https://github.com/ZeroTricks/lumo-tamer), LiteLLM, OpenCode
and Open WebUI. Not affiliated with Proton AG. Made by people who read privacy
policies for fun.
