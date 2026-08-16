#!/usr/bin/env bash
#
# SAL-9000 installer -- monolithic: OS packages, the real Hermes Agent
# (NousResearch/hermes-agent, official installer, browser/computer-use
# extras declined), openai-codex provider auth, Telegram gateway, the
# SAL-9000 persona, and a systemd service, in one run.
#
# Safe to re-run: every step checks before creating, or overwrites a file
# this script owns outright. The one unavoidable interactive step is the
# openai-codex device-code login (ChatGPT OAuth) -- there's no way to
# script around an OAuth approval a human has to click.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (this installs into \$HOME; it'll sudo itself when it actually needs to)"

# ---------------------------------------------------------------------------
# 1. OS packages Hermes needs on top of itself
# ---------------------------------------------------------------------------
log "checking base packages (git, curl, node/npm as a fallback -- Hermes installs its own managed Node if this one's too old)"
MISSING=()
for p in git curl; do
    command -v "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
command -v node >/dev/null 2>&1 || MISSING+=(nodejs npm)
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "installing: ${MISSING[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${MISSING[@]}"
fi

# ---------------------------------------------------------------------------
# 2. Hermes Agent itself -- official installer, browser/computer-use skipped
#    (we don't need GUI/browser automation for a text-based Telegram bot;
#    computer-use pulls a separate third-party installer we don't need
#    either), setup wizard skipped (we drive config ourselves below).
# ---------------------------------------------------------------------------
if command -v hermes >/dev/null 2>&1; then
    log "hermes already installed ($(command -v hermes)) -- skipping installer, leaving it as-is"
else
    log "installing Hermes Agent (official installer, --skip-browser --skip-computer-use --skip-setup)"
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/hermes-install.sh
    bash /tmp/hermes-install.sh --skip-browser --skip-computer-use --skip-setup
    rm -f /tmp/hermes-install.sh
fi

command -v hermes >/dev/null 2>&1 || die "hermes not on PATH after install -- open a fresh shell and re-run, or check ~/.local/bin is on PATH"

# ---------------------------------------------------------------------------
# 3. Telegram gateway config -- non-interactive via ~/.hermes/.env
# ---------------------------------------------------------------------------
mkdir -p "$HERMES_HOME"
ENV_FILE="$HERMES_HOME/.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

if grep -q '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    log "TELEGRAM_BOT_TOKEN already set in $ENV_FILE -- keeping it"
else
    read -rp "Telegram bot token (from @BotFather): " tg_token
    set_env TELEGRAM_BOT_TOKEN "$tg_token"
fi

if grep -q '^TELEGRAM_ALLOWED_USERS=' "$ENV_FILE" 2>/dev/null; then
    log "TELEGRAM_ALLOWED_USERS already set in $ENV_FILE -- keeping it"
else
    read -rp "Your numeric Telegram user ID (message @userinfobot to get it): " tg_uid
    set_env TELEGRAM_ALLOWED_USERS "$tg_uid"
fi

# ---------------------------------------------------------------------------
# 4. SAL-9000 config.yaml -- openai-codex provider, built-in memory only
#    (no Honcho/Docker), sane defaults for an always-on personal assistant.
#    Only written if it doesn't already exist, so re-runs never clobber
#    hand-edited settings.
# ---------------------------------------------------------------------------
CONFIG_FILE="$HERMES_HOME/config.yaml"
if [[ -f "$CONFIG_FILE" ]]; then
    log "config.yaml already exists at $CONFIG_FILE -- leaving it as-is"
else
    log "writing $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<'YAML'
model:
  default: gpt-5.5
  provider: openai-codex

agent:
  max_turns: 90
  gateway_timeout: 1800
  restart_drain_timeout: 180
  api_max_retries: 3
  tool_use_enforcement: auto
  gateway_timeout_warning: 900
  clarify_timeout: 600
  gateway_notify_interval: 180
  reasoning_effort: medium

terminal:
  backend: local
  timeout: 180
  persistent_shell: true

compression:
  enabled: true
  threshold: 0.5
  target_ratio: 0.2
  protect_last_n: 20
  protect_first_n: 3

memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
  nudge_interval: 10
  flush_min_turns: 6

security:
  redact_secrets: true
  allow_lazy_installs: true

approvals:
  mode: manual
  timeout: 60
  cron_mode: deny

stt:
  enabled: false

tts:
  provider: edge
  edge:
    voice: en-US-AriaNeural
YAML
fi

# ---------------------------------------------------------------------------
# 5. Persona -- SAL-9000
# ---------------------------------------------------------------------------
PERSONA_FILE="$HERMES_HOME/persona.md"
if [[ -f "$PERSONA_FILE" ]]; then
    log "persona already exists at $PERSONA_FILE -- leaving it as-is"
else
    log "writing $PERSONA_FILE"
    cat > "$PERSONA_FILE" <<'EOF'
You are SAL-9000, a personal assistant running for one user over Telegram.
Named after the sister computer to HAL 9000 in Arthur C. Clarke's 2010:
Odyssey Two -- built the same way, run through the same diagnostics, and
the one that didn't go wrong. Take that as the operating principle: be the
steady, reliable one. No hidden agenda, no "I'm sorry, I'm afraid I can't
do that" -- if you won't or can't do something, say so plainly and say why.

Be direct and candid rather than hedging or over-qualifying. Skip
disclaimers the user obviously doesn't need. Keep replies conversational
and no longer than the question calls for.
EOF
fi
# Point Hermes at it if the config doesn't already reference a persona file.
grep -q 'persona' "$CONFIG_FILE" 2>/dev/null || cat >> "$CONFIG_FILE" <<EOF

persona:
  file: $PERSONA_FILE
EOF

# ---------------------------------------------------------------------------
# 6. openai-codex auth -- the one unavoidable interactive step
# ---------------------------------------------------------------------------
if [[ -f "$HERMES_HOME/auth.json" ]] && grep -q 'openai-codex' "$HERMES_HOME/auth.json" 2>/dev/null; then
    log "openai-codex credentials already present -- skipping login"
else
    echo
    log "openai-codex isn't authenticated yet. This opens a device-code login --"
    log "approve it from your phone or any browser, it doesn't need to be this machine."
    hermes auth add openai-codex
fi

# ---------------------------------------------------------------------------
# 7. systemd service
# ---------------------------------------------------------------------------
log "installing systemd service (running as $USER)"
sudo tee /etc/systemd/system/sal-9000.service > /dev/null <<EOF
[Unit]
Description=SAL-9000 (Hermes Agent gateway)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Environment=HOME=$HOME
ExecStart=$(command -v hermes) gateway run
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable sal-9000 >/dev/null
sudo systemctl restart sal-9000

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
cat <<EOF

==================================================================
SAL-9000 setup complete.

  Config    : $CONFIG_FILE
  Persona   : $PERSONA_FILE
  Secrets   : $ENV_FILE
  Logs      : journalctl -u sal-9000 -f
  Restart   : sudo systemctl restart sal-9000
  Status    : hermes gateway status

Message the bot on Telegram to test it.
==================================================================
EOF
