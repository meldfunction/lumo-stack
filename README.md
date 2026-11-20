# Lumo Stack

A private, self-hosted way into Proton Lumo: use it from Claude Code (the
terminal interface many developers prefer), from a locked-down coding
assistant, or from your browser, with no Anthropic or OpenAI account.
Everything runs on your own machine and listens on `127.0.0.1` only.

**Platforms:** v0.1 installs on macOS. Windows and Linux support is next
(v0.2, built on Docker Compose so the same stack runs everywhere).

> **Unofficial.** Lumo has no public API yet. This uses
> [lumo-tamer](https://github.com/ZeroTricks/lumo-tamer), a community bridge
> that talks to Lumo the way Proton's web app does. Proton could block it, and
> it could put your Proton account at risk. Not affiliated with Proton.

## What you get

| Command | What it is |
|---|---|
| `lumo home` | Dashboard: service status, one-click Proton sign-in, file upload/download, open Chat and Code |
| `lumo` | Coding assistant (OpenCode) in the terminal, jailed to your workspace |
| `lumo code-web` | The same coding assistant in the browser (password-protected) |
| `lumo web` | Chat in the browser (Open WebUI) |
| `lumo ask "…"` / `lumo chat` | Quick answers / plain terminal chat |
| `lumo open <project>` | Work in one project folder; `--max` uses the stronger Lumo tier |
| `lumo snapshots` / `lumo restore` | Undo: every session starts with a git snapshot |
| `lumo import` / `lumo fetch <url>` / `lumo export` | Move files into and out of the jail |
| `lumo login` | Sign in to Proton (opens a browser, saves the login, closes it) |
| `lumo doctor` | Health and security check (29 checks) |
| `lumo update` | Update pinned components, with automatic rollback |
| `claude-lumo` | Optional: Claude Code with Lumo as the model |

## The coding jail

The coding assistant runs in a container that:

- sees only `code/` (read-write), `inbox/` (read-only) and `out/` (read-write) from your workspace
- has a read-only system, no root, no sudo, no Linux capabilities, and CPU, memory and process limits
- sits on an internal network with **no internet**; one relay container is its only path, and it leads only to Lumo
- can't edit its own config, which lives outside the workspace

`lumo doctor` re-tests all of this by actually trying the writes and connections.

## Prerequisites

**Account**

- A **Proton Unlimited** account. It includes Lumo; the
  [Lumo Plus](https://proton.me/support/proton-add-ons) add-on raises usage
  limits, which helps with heavier coding sessions.
- New to Lumo? Read more: [Lumo](https://lumo.proton.me) ·
  [What's new in Lumo 2.0](https://proton.me/blog/lumo-2) ·
  [Proton plans](https://proton.me/support/upgrading-to-new-proton-plan)

**Software (macOS)**

- [OrbStack](https://orbstack.dev) (recommended) or Docker Desktop
- Node.js 20+, Python 3.10+ and git: `brew install git node python`
- Chrome, Brave or Edge, for the Proton sign-in
- Optional: [Claude Code](https://claude.com/claude-code), for `claude-lumo`

## Install

**With dialogs:** [download the zip](https://github.com/meldfunction/lumo-stack/archive/refs/heads/main.zip),
unzip it, then double-click **Install Lumo.command** (first time: right-click → Open).

**In the terminal:**

```sh
git clone https://github.com/meldfunction/lumo-stack.git ~/lumo-stack && cd ~/lumo-stack
./install                  # options: --workspace DIR  --with-claude  --dry-run
```

The first install downloads a few GB (Open WebUI, LiteLLM, OpenCode) and takes
10–20 minutes. It ends by opening a browser for the Proton sign-in and running
`lumo doctor`. Re-running `./install` is safe: keys, configs and your login are kept.

**Uninstall:** `./uninstall` (keeps your workspace) or `./uninstall --purge`.

## How it fits together

```
lumo / lumo code-web ─► OpenCode (jail) ─► lumo-relay ─┐
lumo web ─────────────► Open WebUI ────────────────────┼─► LiteLLM :4000 ─► lumo-tamer :3003 ─► Proton Lumo
claude-lumo ──────────► Claude Code ───────────────────┘
lumo home ────────────► Lumo Home :8090 (status, sign-in, files)
```

LiteLLM routes only to lumo-tamer; the launchers refuse to start if that changes.
lumo-tamer and LiteLLM run as LaunchAgents; an hourly check notifies you if the
Proton login stops working.

## Settings

Defaults live in `lib.zsh`. To change them on one machine, create `lumo.env`
next to it (not committed), for example:

```sh
LUMO_HOME=$HOME/Documents/Lumo   # workspace (macOS will ask apps for access to Documents)
```

Pinned versions are in `versions.env`; `lumo update` changes them.

## Limits

- Tool calling through lumo-tamer is experimental: simple edits work, long multi-step tasks misfire.
- Lumo's web search, image generation and memory don't come through the bridge.
- v0.1 is macOS-only (LaunchAgents, Keychain). v0.2 moves the core into Docker
  Compose for macOS, Windows and Linux, with sign-in through a browser container.
