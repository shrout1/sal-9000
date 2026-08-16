"""Per-chat conversation history, persisted as one JSON file per chat so a
service restart doesn't lose recent context. This is a personal bot with a
handful of chats at most -- a JSON file per chat is simpler than a database
at this scale and there's nothing to migrate if that stops being true.
"""
import json
from pathlib import Path

HISTORY_DIR = Path("/var/lib/sal-9000/history")


def _path_for(chat_id: str) -> Path:
    return HISTORY_DIR / f"{chat_id}.json"


def load(chat_id: str) -> list[dict]:
    path = _path_for(chat_id)
    if not path.exists():
        return []
    return json.loads(path.read_text())


def save(chat_id: str, messages: list[dict], max_turns: int) -> None:
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    # A turn is one user message + one assistant reply -> 2 entries.
    trimmed = messages[-(max_turns * 2):]
    _path_for(chat_id).write_text(json.dumps(trimmed))
