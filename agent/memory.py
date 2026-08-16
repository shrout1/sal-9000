"""Persistent, per-chat memory -- modeled on Nous Research's Hermes Agent:
https://hermes-agent.nousresearch.com/docs/user-guide/features/memory

Two small bounded files per chat, USER.md (facts/preferences about the
person) and MEMORY.md (the bot's own operating notes), each holding a list
of one-line entries. Entries are appended; the oldest drops once a file
hits its character budget, so this stays cheap to inject into every system
prompt without needing a database or embeddings.
"""
from pathlib import Path

MEMORY_DIR = Path("/var/lib/sal-9000/memory")
CHAR_BUDGET = {"USER": 1400, "MEMORY": 2200}
LABELS = {"USER": "What I know about this user", "MEMORY": "My own notes"}


def _path(chat_id: str, file: str) -> Path:
    return MEMORY_DIR / chat_id / f"{file}.md"


def _entries(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [
        line[2:].strip() if line.startswith("§ ") else line.strip()
        for line in path.read_text().splitlines()
        if line.strip()
    ]


def load(chat_id: str, file: str) -> str:
    return "\n".join(f"§ {e}" for e in _entries(_path(chat_id, file)))


def load_for_prompt(chat_id: str) -> str:
    parts = []
    for file in ("USER", "MEMORY"):
        content = load(chat_id, file)
        if content:
            parts.append(f"## {LABELS[file]}\n{content}")
    return "\n\n".join(parts)


def append_entry(chat_id: str, file: str, note: str) -> None:
    if file not in CHAR_BUDGET:
        raise ValueError(f"unknown memory file {file!r}")
    note = " ".join(note.split())  # collapse whitespace/newlines to one line
    if not note:
        return

    path = _path(chat_id, file)
    entries = _entries(path)
    entries.append(note)

    budget = CHAR_BUDGET[file]
    while len(entries) > 1 and sum(len(e) + 2 for e in entries) > budget:
        entries.pop(0)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"§ {e}" for e in entries) + "\n")
