# SAL-9000

A personal AI assistant reachable over Telegram, running on a Raspberry Pi
as a systemd service. This is a thin wrapper around Nous Research's real
[Hermes Agent](https://hermes-agent.nousresearch.com/) -- the agent loop,
tool routing, memory, and Telegram gateway are all Hermes's own; this repo
just installs it, points it at the `openai-codex` provider (so it runs on
a ChatGPT/Codex subscription rather than a metered API key), configures
the Telegram gateway non-interactively, and gives it a persona.

Named after the sister computer to HAL 9000 in Arthur C. Clarke's *2010:
Odyssey Two* -- built the same way, run through the same diagnostics, and
the one that didn't go wrong. The persona (`~/.hermes/SOUL.md` after
install, Hermes's own fixed-path convention) runs with that as its
operating principle: direct, no hidden agenda, says plainly when it can't
do something instead of stonewalling.

## Setup

```sh
git clone https://github.com/shrout1/sal-9000
cd sal-9000
./install.sh
```

One script. In order: base packages, Hermes Agent itself (official
installer, browser/computer-use extras declined -- see below for why),
Telegram gateway config (prompts for a bot token and your numeric user
ID), `config.yaml` pointed at the `openai-codex` provider, the SAL-9000
persona, `openai-codex` device-code login (the one step that can't be
scripted -- approve it from your phone), the gateway systemd service,
real web-browsing tools, a Gmail/Calendar MCP server, and a self-hosted
Honcho memory backend -- all covered below.

Safe to re-run -- every step checks before creating, and never clobbers a
file you've since hand-edited. Two things genuinely can't be automated
and the installer will tell you exactly what to do if it finds them
missing: the `openai-codex` device-code login, and the Google OAuth
client + per-account tokens (`google/authorize.py`, `google/README`-style
instructions in the script's own warning output) -- both need a human to
click through a real browser consent screen.

## Design notes

- **`openai-codex`, not a raw API key.** Runs on your ChatGPT/Codex
  subscription's device-code OAuth, the same auth Codex CLI itself uses --
  no separate per-token billing. (Deliberately different from Claude Code:
  Anthropic's own docs explicitly prohibit routing a third-party app
  through Free/Pro/Max credentials, and the Agent SDK technically enforces
  it. OpenAI's docs recommend an API key for automation but don't
  prohibit this path the same way.)
- **Web browsing via system Chromium + `agent-browser`, not Playwright's
  bundled download.** Playwright's own `npx playwright install chromium`
  reproducibly hangs on this hardware after finishing the download --
  confirmed idle (zero CPU, zero disk I/O) for minutes across three
  separate downloads, an IPC bug in its out-of-process downloader on this
  platform, not a fluke. `agent-browser` (Hermes's built-in browser
  driver) doesn't need Playwright's private Chromium at all -- it just
  needs *a* Chromium binary, and apt's is reliable. Hermes also prefers
  the Browser Use CLI whenever it's installed, but that backend's
  local-Chrome mode is documented as desktop-only (expects a visible
  display, a manual "Allow remote debugging" click); the installer never
  installs it and pins `browser.backend: off` so nothing flips this
  silently.
- **Gmail + Calendar via a small custom MCP server** (`google/server.py`).
  Two Google identities, two trust levels: your personal account gets
  `gmail.readonly` + `calendar.readonly` -- enforced by Google itself, so
  even a bug in this code can't make it send, delete, or modify anything.
  SAL-9000 has its own separate Google account with full read/write on
  its own calendar (a dedicated "SAL" calendar, not that account's
  identity-tied primary one), shared back to you with edit access -- so
  it can actually manage a calendar without ever holding write scope on
  anything of yours. `google/authorize.py` mints the OAuth tokens
  (one-time, needs a real browser -- has a headless/SSH-tunnel mode for
  running the flow against the Pi directly, see its own docstring).
- **Honcho for memory, not the built-in file-based store**, self-hosted
  (Postgres+pgvector, Redis, [plastic-labs/honcho](https://github.com/plastic-labs/honcho),
  AGPL-3.0) rather than Honcho's managed cloud. The reasoning-derived,
  semantically-searchable memory this gives you is real infrastructure
  regardless of which model answers the calls -- the reason to actually
  run it here is that Honcho's own LLM calls (deriver, dialectic,
  summary, dream) are routed through a local proxy
  (`hermes-codex-proxy.service`) onto the *same* `openai-codex`
  subscription the main agent loop uses, via a
  [fork of hermes-agent](https://github.com/shrout1/hermes-agent/tree/codex-proxy-adapter)
  adding it as a fourth proxy upstream (Nous Portal and xAI Grok are the
  only ones Hermes ships with). No local GPU model, no separate API key,
  no per-token billing beyond the subscription already paying for chat.
  Embeddings are the one thing Codex genuinely can't do (it's a coding
  assistant product, no embeddings capability on that access path at
  all) -- those run locally too, via Ollama (`nomic-embed-text`, small
  enough to run CPU-only).
- **Whitelist-gated.** `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env` is a
  numeric-user-ID allowlist; Hermes denies all DMs by default until it's
  set, so a stranger finding the bot's username can't use it.
- **`approvals.mode: manual`** in `config.yaml` -- Hermes asks before
  running anything it judges risky, rather than acting freely. Loosen
  this once you trust the setup, if you want less friction.

## Status

Text chat, Honcho memory, Telegram gateway, `openai-codex` provider, web
browsing, Gmail/Calendar tools. Not yet configured: cron/scheduled jobs,
subagent delegation, skills beyond Hermes's own defaults, webhooks.
