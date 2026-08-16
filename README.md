# SAL-9000

A personal AI assistant reachable over Telegram, running as a lightweight
systemd service on a Raspberry Pi. The Pi is a thin client only: it holds
the conversation, talks to Telegram, and calls the Claude API for the
actual reasoning. Nothing runs locally that needs real compute -- that's
deliberate, this was built to run alongside [home-base](https://github.com/shrout1/home-base)
on a Pi 3B with under 1GB of RAM.

Named after the sister computer to HAL 9000 in Arthur C. Clarke's *2010:
Odyssey Two* -- built the same way, run through the same diagnostics, and
the one that didn't go wrong. The system prompt (`agent/default_persona.txt`)
runs with that as its operating principle: direct, no hidden agenda, says
plainly when it can't do something instead of stonewalling. The model
actually answering is Claude, not anything running locally.

## Setup

```sh
git clone https://github.com/shrout1/sal-9000
cd sal-9000
./setup_wizard.sh
```

The wizard walks you through everything interactively:

- **Telegram bot token** -- paste one you already have, or it walks you
  through creating one with [@BotFather](https://t.me/botfather) (there's
  no API for bot creation; Telegram only offers it as a chat with
  BotFather, so this is guided, not automated) and validates it against
  the Bot API as soon as you paste it.
- **Anthropic auth** -- log in with your Anthropic account via `ant auth
  login` (OAuth; the wizard installs the `ant` CLI if it's missing), or
  paste a static API key from
  [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys)
  and it's validated with a 1-token request.
- **Model choice** -- opus/sonnet/haiku, with the per-token cost tradeoff
  spelled out.
- **Whitelisting yourself** -- it watches for a message you send the bot
  and picks your chat ID out of the API response automatically, instead
  of you digging it out of the logs.
- Finishes by offering to run `sudo ./install.sh` for you.

Re-running the wizard is safe -- it shows you each current value and lets
you keep it or change it.

### Manual setup

If you'd rather not run the wizard: `cp agent.conf.example agent.conf`,
fill in `TELEGRAM_BOT_TOKEN` and `ANTHROPIC_API_KEY` by hand, `sudo
./install.sh`, then message the bot once and check `journalctl -u
sal-9000 -f` for your chat ID to add to `ALLOWED_CHAT_IDS`.

## Design notes

- **No listening ports.** The bot long-polls Telegram's `getUpdates` --
  there's nothing bound to any network interface, so nothing to firewall.
- **Whitelist-only.** Anyone who finds the bot's username can message it;
  `ALLOWED_CHAT_IDS` is what stops a stranger from burning your API credits.
- **Runs unprivileged**, as your normal user, not root.
- Config lives in `/etc/sal-9000/agent.conf`, same `KEY="value"` format
  as home-base's `homebase.conf`, kept out of git via `.gitignore`.
- **Persistent memory**, modeled on [Nous Research's Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory):
  two small bounded files per chat (`USER.md` for facts about you, `MEMORY.md`
  for the bot's own notes), injected into the system prompt every reply. The
  bot writes to them itself via a single `update_memory` tool -- see
  `agent/memory.py` / `agent/brain.py`.

## Status

One tool so far (`update_memory`). Not yet built: any tool that reaches
outside the conversation (web, files, code execution), voice-to-text, a
web UI.
