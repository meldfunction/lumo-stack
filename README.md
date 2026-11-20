# Lumo Stack

**Your prompts are nobody's training data.**

Lumo Stack puts [Proton Lumo](https://lumo.proton.me), Proton's private AI, inside
the tools you already use: **Claude Code**, a **jailed coding agent** and **your
browser**. It all runs on your own machine. No Anthropic account, no OpenAI
account, nothing phoning home.

> **The fine print, up front.** Lumo has no public API yet. Lumo Stack uses
> [lumo-tamer](https://github.com/ZeroTricks/lumo-tamer), a community bridge that
> talks to Lumo the way Proton's own web app does. Proton could block it, and it
> could put your Proton account at risk. Not affiliated with or endorsed by Proton.
> Rebellious, yes. Reckless, no.

**Platforms:** macOS today. Windows and Linux land in v0.2 (Docker Compose, same stack everywhere).

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
| Sends prompts to Anthropic's API | `ANTHROPIC_BASE_URL` points at LiteLLM on `127.0.0.1:4000`, which forwards only to Lumo |
| Signs in with your Anthropic account or API key | Uses your local LiteLLM key; `ANTHROPIC_API_KEY` is unset |
| Uses Opus, Sonnet and Haiku | Every model slot, subagents included, maps to `lumo`, `lumo-max` or `lumo-lite` |
| Sends telemetry and error reports, checks for updates | All switched off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`) |
| Loads your MCP servers (which make their own connections) | Off by default (`--strict-mcp-config`); `LUMO_KEEP_MCP=1` brings them back |
| Trusts its config | Refuses to start if LiteLLM routes anywhere but lumo-tamer |

We checked by watching the network: with MCP off, a `claude-lumo` session's only
connection was to `127.0.0.1:4000`. Your plain `claude` command stays your normal
Claude Code; only `claude-lumo` is Lumo-only.

Installing Claude Code itself is one download from Anthropic (the official
installer, `curl -fsSL https://claude.ai/install.sh | bash`). `./install --with-claude`
does it for you if it's missing. No Anthropic account is needed for `claude-lumo`.

Heads up: Claude Code was built around Claude's tool use. With Lumo it's great
for questions and small edits, and wobblier on long multi-step jobs. For anything
that edits files, the jailed `lumo` agent is the safer bet: `claude-lumo` runs on
your Mac with Claude Code's normal permission prompts, not in a jail.

## Commands

It's all just `lumo`. Every command starts whatever's asleep first, and keeps a log.

| Command | What it does |
|---|---|
| `lumo` | Coding agent (OpenCode) in the terminal, jailed. `--max` for Lumo's strongest model |
| `lumo open <project>` | One folder per project; new ones get an `AGENTS.md` tuned for Lumo |
| `lumo run "task"` | Fire-and-forget task |
| `lumo code-web` | The coding agent in your browser, password-protected |
| `lumo web` | Chat in Open WebUI |
| `lumo ask "…"` / `lumo chat` | Quick answer / plain terminal chat |
| `claude-lumo` | Claude Code on Lumo (optional add-on) |
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

### Then, your Mac

- [OrbStack](https://orbstack.dev) (recommended) or Docker Desktop
- Node.js 20+, Python 3.10+ and git
- Chrome, Brave or Edge, for the Proton sign-in
- Optional: Claude Code (the installer can fetch it for you)

```sh
brew install git node python
brew install --cask orbstack
```

### Click your way through

1. [Download the zip](https://github.com/meldfunction/lumo-stack/archive/refs/heads/main.zip) and unzip it.
2. Double-click **Install Lumo.command**. First time, macOS gets suspicious: right-click it and choose Open.
3. Pick a home for Lumo's files (or keep `~/lumo`), and say yes or no to Claude Code.
4. Sign in to Proton in the browser window that pops up. It closes itself when you're done.
5. Lumo Home opens. You're in.

### Or the terminal way

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

## Under the hood

```
lumo / lumo code-web ─► OpenCode (jail) ─► lumo-relay ─┐
lumo web ─────────────► Open WebUI ────────────────────┼─► LiteLLM :4000 ─► lumo-tamer :3003 ─► Proton Lumo
claude-lumo ──────────► Claude Code ───────────────────┘
lumo home ────────────► Lumo Home :8090 (status, sign-in, files)
```

LiteLLM routes only to lumo-tamer, and every launcher checks that before it
starts. lumo-tamer and LiteLLM run as LaunchAgents; an hourly check pings you if
the Proton login stops working. Everything listens on `127.0.0.1`.

### Settings

Defaults live in `lib.zsh`. To change them on one machine, drop a `lumo.env` next
to it (it's git-ignored):

```sh
LUMO_HOME=$HOME/Documents/Lumo   # workspace (macOS will ask apps for access to Documents)
```

Pinned versions live in `versions.env`; `lumo update` changes them.

## What to expect

- **Tool calling is experimental.** Quick edits and file writes work; long multi-step sessions trip over themselves more than with Claude or GPT.
- **Some Lumo perks stay home.** Lumo's web search, image generation and memory don't make it through the bridge.
- **Your login babysits itself.** It lasts 24 hours and renews on its own; if Proton signs you out, Lumo Home and a notification tell you.
- **macOS only in v0.1.** Windows and Linux are next.

---

Built on [lumo-tamer](https://github.com/ZeroTricks/lumo-tamer), LiteLLM, OpenCode
and Open WebUI. Not affiliated with Proton AG. Made by people who read privacy
policies for fun.
