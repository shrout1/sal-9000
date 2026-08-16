"""Loads /etc/sal-9000/agent.conf -- same KEY="value" shell-style format
as home-base's homebase.conf, parsed the same way (no shell involved, just
a line-oriented regex) so the two sibling services stay consistent.
"""
import re
from pathlib import Path

CONF_PATH = Path("/etc/sal-9000/agent.conf")

_KV_RE = re.compile(r'^([A-Z_][A-Z0-9_]*)=["\']?(.*?)["\']?\s*(?:#.*)?$')


class ConfigError(Exception):
    pass


def _parse_kv_file(path: Path) -> dict:
    values = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = _KV_RE.match(line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


class Config:
    def __init__(self, path: Path = CONF_PATH):
        if not path.exists():
            raise ConfigError(
                f"{path} not found -- copy agent.conf.example to {path} and fill it in"
            )
        raw = _parse_kv_file(path)

        self.telegram_bot_token = self._require(raw, "TELEGRAM_BOT_TOKEN")
        # Blank is valid here -- it means "use whatever ambient Anthropic
        # credential is available" (an `ant auth login` profile, or
        # ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN in the service's own
        # environment), which is what setup_wizard.sh sets up when you pick
        # the OAuth login path instead of pasting a static key.
        self.anthropic_api_key = raw.get("ANTHROPIC_API_KEY", "").strip()
        self.model = raw.get("MODEL") or "claude-opus-5"
        self.allowed_chat_ids = {
            cid.strip() for cid in raw.get("ALLOWED_CHAT_IDS", "").split(",") if cid.strip()
        }
        self.max_history_turns = int(raw.get("MAX_HISTORY_TURNS") or 20)
        self.poll_timeout_seconds = int(raw.get("POLL_TIMEOUT_SECONDS") or 30)

        prompt_file = raw.get("SYSTEM_PROMPT_FILE", "").strip()
        default_persona = Path(__file__).resolve().parent / "default_persona.txt"
        self.system_prompt = Path(prompt_file or default_persona).read_text().strip()

    @staticmethod
    def _require(raw: dict, key: str) -> str:
        value = raw.get(key, "").strip()
        if not value:
            raise ConfigError(f"{key} is not set in {CONF_PATH}")
        return value
