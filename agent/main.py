#!/usr/bin/env python3
"""SAL-9000: a Telegram bot backed by Claude.

Long-polls Telegram's getUpdates -- no listening socket, nothing bound to
any interface, same "no attack surface on the network" posture as
home-base's dashboard being loopback/LAN-only, just taken one step further
since this service doesn't need to accept inbound connections at all.
"""
import json
import logging
import time
from pathlib import Path

import anthropic
import requests

import brain
import history
from config import Config, ConfigError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sal-9000")

STATE_DIR = Path("/var/lib/sal-9000")
OFFSET_PATH = STATE_DIR / "offset.txt"


def load_offset() -> int:
    if OFFSET_PATH.exists():
        return int(OFFSET_PATH.read_text().strip() or 0)
    return 0


def save_offset(offset: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    OFFSET_PATH.write_text(str(offset))


def get_updates(token: str, offset: int, timeout: int) -> list[dict]:
    resp = requests.get(
        f"https://api.telegram.org/bot{token}/getUpdates",
        params={"offset": offset, "timeout": timeout},
        timeout=timeout + 10,
    )
    resp.raise_for_status()
    return resp.json()["result"]


def send_message(token: str, chat_id: int, text: str) -> None:
    # Telegram caps a single message at 4096 chars -- split rather than truncate.
    for i in range(0, len(text), 4096) or [0]:
        chunk = text[i : i + 4096] if text else "(empty response)"
        resp = requests.post(
            f"https://api.telegram.org/bot{token}/sendMessage",
            json={"chat_id": chat_id, "text": chunk},
            timeout=15,
        )
        if not resp.ok:
            log.error("sendMessage failed: %s %s", resp.status_code, resp.text)


def handle_message(cfg: Config, client: anthropic.Anthropic, chat_id: int, text: str) -> None:
    chat_key = str(chat_id)
    if not cfg.allowed_chat_ids:
        log.warning(
            "ALLOWED_CHAT_IDS is empty -- ignoring message from chat %s. "
            "Add it to /etc/sal-9000/agent.conf and restart to let it through.",
            chat_key,
        )
        return
    if chat_key not in cfg.allowed_chat_ids:
        log.warning("ignoring message from non-whitelisted chat %s", chat_key)
        return

    messages = history.load(chat_key)
    messages.append({"role": "user", "content": text})
    try:
        reply_text = brain.reply(client, cfg.model, cfg.system_prompt, chat_key, messages)
    except anthropic.APIError as e:
        log.exception("Claude API call failed")
        send_message(cfg.telegram_bot_token, chat_id, f"(SAL-9000 hit an API error: {e})")
        return

    messages.append({"role": "assistant", "content": reply_text})
    history.save(chat_key, messages, cfg.max_history_turns)
    send_message(cfg.telegram_bot_token, chat_id, reply_text)


def run() -> None:
    cfg = Config()
    # Blank ANTHROPIC_API_KEY means "use ambient credentials" -- an
    # `ant auth login` profile, or ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN in
    # the service's own environment. The zero-arg constructor resolves
    # those itself.
    client = anthropic.Anthropic(api_key=cfg.anthropic_api_key) if cfg.anthropic_api_key else anthropic.Anthropic()
    offset = load_offset()
    log.info("SAL-9000 starting, model=%s, %d chat(s) whitelisted", cfg.model, len(cfg.allowed_chat_ids))

    while True:
        try:
            updates = get_updates(cfg.telegram_bot_token, offset, cfg.poll_timeout_seconds)
        except requests.RequestException:
            log.exception("getUpdates failed, retrying in 10s")
            time.sleep(10)
            continue

        for update in updates:
            offset = update["update_id"] + 1
            message = update.get("message") or {}
            text = message.get("text")
            chat = message.get("chat") or {}
            chat_id = chat.get("id")
            if text and chat_id is not None:
                try:
                    handle_message(cfg, client, chat_id, text)
                except Exception:
                    log.exception("error handling message from chat %s", chat_id)
            save_offset(offset)


if __name__ == "__main__":
    try:
        run()
    except ConfigError as e:
        log.error("%s", e)
        raise SystemExit(1)
