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
the one that didn't go wrong. The persona (`~/.hermes/persona.md` after
install) runs with that as its operating principle: direct, no hidden
agenda, says plainly when it can't do something instead of stonewalling.

## Setup

```sh
git clone https://github.com/shrout1/sal-9000
cd sal-9000
./install.sh
```

One script, in order:

1. Installs base packages (`git`, `curl`; `node`/`npm` as a fallback --
   Hermes installs its own managed Node if the system one's too old)
2. Installs Hermes Agent itself, via the
   [official installer](https://github.com/NousResearch/hermes-agent),
   with `--skip-browser` (no Playwright/Chromium -- not needed for a
   text-based bot) and `--skip-computer-use` (declines a separate
   third-party GUI-automation installer it otherwise offers)
3. Prompts for your Telegram bot token (from
   [@BotFather](https://t.me/botfather)) and your numeric Telegram user
   ID (from `@userinfobot`), writes them to `~/.hermes/.env`
4. Writes `~/.hermes/config.yaml` -- `openai-codex` as the model provider,
   built-in memory only (no Honcho/Docker/Postgres -- see below), sane
   defaults for an always-on personal assistant
5. Writes the SAL-9000 persona to `~/.hermes/persona.md`
6. Runs `hermes auth add openai-codex` -- the one step that can't be
   scripted away: a ChatGPT device-code login, approve it from your phone
7. Installs and starts the `sal-9000` systemd service

Safe to re-run -- every step checks before creating, and never clobbers a
file you've since hand-edited.

## Design notes

- **`openai-codex`, not a raw API key.** Runs on your ChatGPT/Codex
  subscription's device-code OAuth, the same auth Codex CLI itself uses --
  no separate per-token billing. (Deliberately different from Claude Code:
  Anthropic's own docs explicitly prohibit routing a third-party app
  through Free/Pro/Max credentials, and the Agent SDK technically enforces
  it. OpenAI's docs recommend an API key for automation but don't
  prohibit this path the same way.)
- **Built-in memory only, no Honcho.** Hermes supports a much deeper
  memory backend (Honcho: Postgres+pgvector+Redis, semantic search,
  background synthesis), but that's real infrastructure regardless of
  which model answers its calls -- not something worth running on a Pi
  for a single-user assistant. Built-in memory (bounded `MEMORY.md`/
  `USER.md`-style files, updated by the agent's own tool calls) covers
  the same goal -- durable notes across sessions -- with nothing extra
  running.
- **Whitelist-gated.** `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env` is a
  numeric-user-ID allowlist; Hermes denies all DMs by default until it's
  set, so a stranger finding the bot's username can't use it.
- **`approvals.mode: manual`** in `config.yaml` -- Hermes asks before
  running anything it judges risky, rather than acting freely. Loosen
  this once you trust the setup, if you want less friction.

## Status

Base install: text chat, built-in memory, Telegram gateway, `openai-codex`
provider. Not yet configured: cron/scheduled jobs, subagent delegation,
skills beyond Hermes's own defaults, webhooks.
