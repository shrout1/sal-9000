#!/usr/bin/env bash
#
# SAL-9000 installer -- monolithic: OS packages, the real Hermes Agent
# (NousResearch/hermes-agent, official installer, browser/computer-use
# extras declined), openai-codex provider auth, Telegram gateway, the
# SAL-9000 persona, and Hermes's own systemd service installer, in one run.
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
# 1.5. IPv6 sanity check -- if there's no IPv6 default route, DNS can still
#      hand out AAAA records (Telegram's API included) that nothing can
#      actually reach. curl fails fast on an unreachable IPv6 address, but
#      the asyncio/httpx stack Hermes's gateway uses can hang on one for
#      minutes instead of falling back to IPv4. Disabling IPv6 at the kernel
#      level takes it out of DNS resolution entirely, so everything goes
#      straight to IPv4. Only touches it if IPv6 is already non-functional
#      here -- a box with real IPv6 connectivity is left alone.
# ---------------------------------------------------------------------------
IPV6_SYSCTL=/etc/sysctl.d/99-disable-ipv6.conf
if [[ -f "$IPV6_SYSCTL" ]]; then
    log "IPv6 already disabled ($IPV6_SYSCTL) -- leaving it as-is"
elif [[ -n "$(ip -6 route show default 2>/dev/null)" ]]; then
    log "IPv6 default route present -- leaving IPv6 enabled"
else
    log "no IPv6 default route -- disabling IPv6 system-wide so DNS can't hand out unreachable AAAA records"
    sudo tee "$IPV6_SYSCTL" >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sudo sysctl -p "$IPV6_SYSCTL" >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. Hermes Agent itself -- official installer, browser/computer-use skipped
#    (we don't need GUI/browser automation for a text-based Telegram bot;
#    computer-use pulls a separate third-party installer we don't need
#    either), setup wizard skipped (we drive config ourselves below).
#
#    The installer only updates PATH for *future* shells (via .bashrc) --
#    it does not affect this already-running script, so we add its known
#    install location ourselves rather than relying on `command -v` finding
#    something .bashrc hasn't applied yet.
# ---------------------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"

if command -v hermes >/dev/null 2>&1; then
    log "hermes already installed ($(command -v hermes)) -- skipping installer, leaving it as-is"
else
    log "installing Hermes Agent (official installer, --skip-browser --skip-computer-use --skip-setup)"
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/hermes-install.sh
    bash /tmp/hermes-install.sh --skip-browser --skip-computer-use --skip-setup
    rm -f /tmp/hermes-install.sh
fi

command -v hermes >/dev/null 2>&1 || die "hermes still not found at \$HOME/.local/bin/hermes after install -- check the installer output above"

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
# 4. config.yaml -- Hermes's own installer already wrote this (it's the
#    full, heavily-commented reference file, not an adaptive default -- its
#    memory:/platform_toolsets: sections already match what we want, so we
#    only touch the two lines that actually need to change: pin the
#    provider to openai-codex and drop the OpenRouter base_url that ships
#    as the template's example. A SAL-9000 marker comment makes this
#    idempotent without clobbering anything hand-edited after the fact.
# ---------------------------------------------------------------------------
CONFIG_FILE="$HERMES_HOME/config.yaml"
[[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE missing -- expected the Hermes installer to have created it"

if grep -q '# Managed by SAL-9000 install.sh' "$CONFIG_FILE" 2>/dev/null; then
    log "config.yaml already has the SAL-9000 provider edits -- leaving it as-is"
else
    log "pointing config.yaml at the openai-codex provider"
    # Scoped to the model: block only (from ^model: to the next unindented
    # top-level key) -- default:/provider: appear dozens of times elsewhere
    # in this file (memory sub-model overrides, TTS, delegation, ...); an
    # unscoped substitution would corrupt those too.
    sed -i '/^model:/,/^[a-zA-Z]/{
        s/^\(\s*default:\s*\).*/\1"gpt-5.5"/
        s/^\(\s*provider:\s*\).*/\1"openai-codex"/
        s|^\(\s*\)base_url:\s*"https://openrouter.ai/api/v1"|\1# base_url: (unset -- openai-codex is a first-class provider, no custom endpoint needed)|
    }' "$CONFIG_FILE"
    sed -i "1i # Managed by SAL-9000 install.sh -- see model: above for the provider/model edits" "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# 5. Persona -- SAL-9000. Hermes reads ~/.hermes/SOUL.md by convention (no
#    config.yaml key for it); the installer seeds a generic default there,
#    which we replace outright.
# ---------------------------------------------------------------------------
SOUL_FILE="$HERMES_HOME/SOUL.md"
if grep -q 'SAL-9000' "$SOUL_FILE" 2>/dev/null; then
    log "SOUL.md already has the SAL-9000 persona -- leaving it as-is"
else
    log "writing $SOUL_FILE"
    cat > "$SOUL_FILE" <<'EOF'
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
# 7. Gateway service -- Hermes's own systemd installer, not a hand-rolled
#    unit file. --force makes this idempotent across re-runs. --system
#    needs root itself; sudo drops PATH, so call it via the wrapper's fixed
#    absolute path (it hardcodes its own venv/install paths internally, so
#    running it as root resolves correctly regardless of root's own $HOME).
# ---------------------------------------------------------------------------
log "installing the gateway as a system service (Hermes's own installer, service name: hermes-gateway)"
sudo "$HOME/.local/bin/hermes" gateway install --force --system --run-as-user "$USER" --start-now --start-on-login

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
cat <<EOF

==================================================================
SAL-9000 setup complete.

  Config    : $CONFIG_FILE
  Persona   : $SOUL_FILE
  Secrets   : $ENV_FILE
  Logs      : journalctl -u hermes-gateway -f
  Status    : sudo hermes gateway status --system
  Restart   : sudo hermes gateway restart --system

Message the bot on Telegram to test it.
==================================================================
EOF
