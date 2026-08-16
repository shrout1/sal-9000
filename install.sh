#!/usr/bin/env bash
#
# SAL-9000 installer.
#
# Deploys the bot to /opt/sal-9000 (in a venv, since the anthropic SDK
# isn't in Debian's apt repos), config to /etc/sal-9000/agent.conf, and
# installs it as a systemd service running as the invoking non-root user
# (not root -- this service doesn't touch the network stack or firewall
# the way home-base does, so it doesn't need root at runtime).
#
# Safe to re-run: every step either checks before creating, or overwrites a
# file this script owns outright.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must be run as root (sudo ./install.sh)"
[[ -n "${SUDO_USER:-}" ]] || die "run with sudo (not as root directly) so the service can be owned by your normal user"

# ---------------------------------------------------------------------------
# 1. Config
# ---------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/agent.conf" ]]; then
    log "loading agent.conf"
else
    log "agent.conf not found -- copying agent.conf.example, edit it and re-run to actually start the bot"
    cp "$SCRIPT_DIR/agent.conf.example" "$SCRIPT_DIR/agent.conf"
fi

if ! grep -q '^TELEGRAM_BOT_TOKEN="[^"]\+"' "$SCRIPT_DIR/agent.conf" 2>/dev/null; then
    warn "TELEGRAM_BOT_TOKEN isn't set in agent.conf yet -- the service will fail to start until it is"
fi
if ! grep -q '^ANTHROPIC_API_KEY="[^"]\+"' "$SCRIPT_DIR/agent.conf" 2>/dev/null \
    && ! sudo -u "$SUDO_USER" -H ant auth status >/dev/null 2>&1; then
    warn "ANTHROPIC_API_KEY isn't set in agent.conf and no 'ant auth login' session was found for $SUDO_USER -- the service will fail to start until one of those is in place. Run ./setup_wizard.sh to fix this interactively."
fi

# ---------------------------------------------------------------------------
# 2. Deploy code
# ---------------------------------------------------------------------------
log "installing agent to /opt/sal-9000"
mkdir -p /opt/sal-9000
rm -rf /opt/sal-9000/agent
cp -a "$SCRIPT_DIR/agent" /opt/sal-9000/agent
cp "$SCRIPT_DIR/requirements.txt" /opt/sal-9000/requirements.txt
chown -R "$SUDO_USER:$SUDO_USER" /opt/sal-9000

log "creating/updating venv at /opt/sal-9000/venv"
if [[ ! -d /opt/sal-9000/venv ]]; then
    sudo -u "$SUDO_USER" python3 -m venv /opt/sal-9000/venv
fi
sudo -u "$SUDO_USER" /opt/sal-9000/venv/bin/pip install --quiet --upgrade pip
sudo -u "$SUDO_USER" /opt/sal-9000/venv/bin/pip install --quiet -r /opt/sal-9000/requirements.txt

# ---------------------------------------------------------------------------
# 3. Config + state dirs
# ---------------------------------------------------------------------------
mkdir -p /etc/sal-9000
if [[ -f /etc/sal-9000/agent.conf ]]; then
    log "config already deployed at /etc/sal-9000/agent.conf -- leaving it as-is"
    log "  (edit /etc/sal-9000/agent.conf directly, not this repo's copy, then restart the service)"
else
    log "installing config to /etc/sal-9000/agent.conf"
    install -m 0600 -o "$SUDO_USER" -g "$SUDO_USER" "$SCRIPT_DIR/agent.conf" /etc/sal-9000/agent.conf
fi

mkdir -p /var/lib/sal-9000
chown -R "$SUDO_USER:$SUDO_USER" /var/lib/sal-9000

# ---------------------------------------------------------------------------
# 4. systemd
# ---------------------------------------------------------------------------
log "installing systemd service (running as $SUDO_USER)"
sed "s/^User=.*/User=$SUDO_USER/; s/^Group=.*/Group=$SUDO_USER/" \
    "$SCRIPT_DIR/templates/sal-9000.service.tmpl" > /etc/systemd/system/sal-9000.service
systemctl daemon-reload
systemctl enable sal-9000 >/dev/null
systemctl restart sal-9000

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
cat <<EOF

==================================================================
SAL-9000 setup complete.

  Config   : /etc/sal-9000/agent.conf
  Logs     : journalctl -u sal-9000 -f
  Restart  : sudo systemctl restart sal-9000

If ALLOWED_CHAT_IDS is still blank, message the bot on Telegram, then check
the logs for your chat ID, add it to agent.conf, and restart.
==================================================================
EOF
