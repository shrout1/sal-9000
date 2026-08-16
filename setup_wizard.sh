#!/usr/bin/env bash
#
# Interactive setup wizard for SAL-9000. Run this instead of hand-editing
# agent.conf. Walks you through:
#   1. Telegram bot token -- paste an existing one, or get walked through
#      creating one with @BotFather (there's no API for this step; Telegram
#      only offers it as a chat with BotFather, so the wizard can guide you
#      but can't do it for you).
#   2. Anthropic auth -- log in with your Anthropic account (OAuth, via the
#      `ant` CLI) or paste a static API key from the console.
#   3. Auto-detects your Telegram chat ID by watching for a message you send
#      the bot, instead of making you dig it out of the logs.
#   4. Writes agent.conf and offers to run install.sh.
#
# Safe to re-run -- every step shows you the current value (if any) and lets
# you keep it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/agent.conf"
[[ -f "$CONF" ]] || cp "$SCRIPT_DIR/agent.conf.example" "$CONF"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

get_conf() { grep -oP "^${1}=\"\K[^\"]*" "$CONF" 2>/dev/null || true; }

set_conf() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONF"; then
        # escape & and \ for sed's replacement side
        local esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"
        sed -i "s|^${key}=.*|${key}=\"${esc}\"|" "$CONF"
    else
        echo "${key}=\"${val}\"" >> "$CONF"
    fi
}

echo
echo "=== SAL-9000 setup wizard ==="
echo

# ---------------------------------------------------------------------------
# 1. Telegram bot token
# ---------------------------------------------------------------------------
existing_token="$(get_conf TELEGRAM_BOT_TOKEN)"
if [[ -n "$existing_token" ]]; then
    read -rp "A Telegram bot token is already set (ending ...${existing_token: -6}). Keep it? [Y/n] " keep
    if [[ "${keep,,}" != "n" ]]; then
        telegram_token="$existing_token"
    fi
fi

if [[ -z "${telegram_token:-}" ]]; then
    read -rp "Do you already have a Telegram bot token? [y/N] " have_token
    if [[ "${have_token,,}" != "y" ]]; then
        cat <<'EOF'

No bot yet -- here's how to make one (Telegram doesn't offer any way to do
this outside chatting with their BotFather bot):

  1. Open this link on your phone or desktop: https://t.me/botfather
     (or search for "BotFather" in Telegram -- look for the blue checkmark)
  2. Send:  /newbot
  3. Pick a display name, then a username (must end in "bot", must be
     globally unique -- if it's taken, add a suffix like "_home" or a
     number).
  4. BotFather replies with a token that looks like:
       123456789:AAExampleTokenGoesHereRestOfIt

EOF
        read -rp "Press Enter once you have the token... "
    fi

    while true; do
        read -rp "Paste the bot token: " telegram_token
        [[ -n "$telegram_token" ]] || continue
        log "checking token against the Telegram API..."
        resp="$(curl -s "https://api.telegram.org/bot${telegram_token}/getMe")"
        ok="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ok', False))" "$resp" 2>/dev/null || echo False)"
        if [[ "$ok" == "True" ]]; then
            uname_="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['result'].get('username',''))" "$resp")"
            log "token OK -- bot is @${uname_}"
            break
        fi
        warn "Telegram rejected that token. Check for typos (it includes everything after the colon) and try again."
    done
fi
set_conf TELEGRAM_BOT_TOKEN "$telegram_token"

# ---------------------------------------------------------------------------
# 2. Anthropic auth
# ---------------------------------------------------------------------------
echo
existing_key="$(get_conf ANTHROPIC_API_KEY)"
ant_profile_active=false
if command -v ant >/dev/null 2>&1 && ant auth status >/dev/null 2>&1; then
    ant_profile_active=true
fi

if [[ -n "$existing_key" ]]; then
    read -rp "An Anthropic API key is already set in agent.conf. Keep it? [Y/n] " keep
    [[ "${keep,,}" != "n" ]] && anthropic_key="$existing_key"
elif $ant_profile_active; then
    read -rp "An 'ant auth login' session is already active on this machine. Use it (leaves ANTHROPIC_API_KEY blank)? [Y/n] " keep
    [[ "${keep,,}" != "n" ]] && anthropic_key=""
fi

if [[ -z "${anthropic_key+x}" ]]; then
    echo "Two ways to authenticate the bot against the Claude API:"
    echo "  1) Log in with your Anthropic account (opens a URL you approve from any device -- recommended)"
    echo "  2) Paste a static API key from console.anthropic.com/settings/keys"
    read -rp "Which? [1/2] " auth_choice

    if [[ "$auth_choice" == "1" ]]; then
        if ! command -v ant >/dev/null 2>&1; then
            read -rp "The 'ant' CLI isn't installed. Install it now (needs sudo)? [Y/n] " do_install
            if [[ "${do_install,,}" != "n" ]]; then
                ver="$(curl -s https://api.github.com/repos/anthropics/anthropic-cli/releases/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")"
                arch="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
                log "installing ant v${ver} (${arch})"
                curl -fsSL "https://github.com/anthropics/anthropic-cli/releases/download/v${ver}/ant_${ver}_linux_${arch}.tar.gz" \
                    | sudo tar -xz -C /usr/local/bin ant
            else
                warn "skipping OAuth login -- falling back to a pasted API key"
                auth_choice=2
            fi
        fi
    fi

    if [[ "$auth_choice" == "1" ]]; then
        echo
        log "running 'ant auth login --no-browser' -- open the printed URL on your phone or laptop, approve it, then paste the code back here"
        ant auth login --no-browser
        anthropic_key=""
        log "logged in. The bot will use this ambient credential (ANTHROPIC_API_KEY stays blank)."
    else
        while true; do
            read -rp "Paste your Anthropic API key: " anthropic_key
            [[ -n "$anthropic_key" ]] || continue
            log "validating key with a 1-token request..."
            resp="$(curl -s https://api.anthropic.com/v1/messages \
                -H "content-type: application/json" -H "x-api-key: ${anthropic_key}" \
                -H "anthropic-version: 2023-06-01" \
                -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')"
            err_type="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('error',{}).get('type',''))" "$resp" 2>/dev/null || echo parse_error)"
            if [[ -z "$err_type" ]]; then
                log "key OK"
                break
            fi
            warn "Anthropic rejected that key (${err_type}). Check console.anthropic.com/settings/keys and try again."
        done
    fi
fi
set_conf ANTHROPIC_API_KEY "$anthropic_key"

# ---------------------------------------------------------------------------
# 3. Model choice
# ---------------------------------------------------------------------------
echo
current_model="$(get_conf MODEL)"
echo "Which Claude model should answer? (per-token pricing, most to least expensive)"
echo "  1) claude-opus-5    -- most capable [default]"
echo "  2) claude-sonnet-5  -- cheaper, still strong"
echo "  3) claude-haiku-4-5 -- cheapest, fastest"
read -rp "Choice [1/2/3, Enter to keep '${current_model:-claude-opus-5}']: " model_choice
case "$model_choice" in
    2) model="claude-sonnet-5" ;;
    3) model="claude-haiku-4-5" ;;
    1) model="claude-opus-5" ;;
    *) model="${current_model:-claude-opus-5}" ;;
esac
set_conf MODEL "$model"

# ---------------------------------------------------------------------------
# 4. Whitelist your chat ID
# ---------------------------------------------------------------------------
echo
existing_ids="$(get_conf ALLOWED_CHAT_IDS)"
if [[ -n "$existing_ids" ]]; then
    read -rp "ALLOWED_CHAT_IDS is already set (${existing_ids}). Add another chat now? [y/N] " add_more
else
    add_more=y
fi

if [[ "${add_more,,}" == "y" ]]; then
    echo "Open Telegram, message your bot (any text), then come back here."
    read -rp "Press Enter once you've sent it... "
    log "checking for your message (up to 30s)..."
    chat_id=""
    for _ in $(seq 1 6); do
        resp="$(curl -s "https://api.telegram.org/bot${telegram_token}/getUpdates?limit=5")"
        chat_id="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for u in reversed(data.get('result', [])):
    m = u.get('message')
    if m and 'chat' in m:
        print(m['chat']['id']); break
" "$resp" 2>/dev/null)"
        [[ -n "$chat_id" ]] && break
        sleep 5
    done
    if [[ -n "$chat_id" ]]; then
        log "found chat ID: ${chat_id}"
        combined="${existing_ids:+${existing_ids},}${chat_id}"
        set_conf ALLOWED_CHAT_IDS "$combined"
    else
        warn "didn't see a message come through. Leaving ALLOWED_CHAT_IDS as-is -- re-run this wizard, or add your chat ID by hand once you find it in the logs."
    fi
fi

chmod 600 "$CONF"

# ---------------------------------------------------------------------------
# 5. Install
# ---------------------------------------------------------------------------
echo
read -rp "Run 'sudo ./install.sh' now to deploy the service? [Y/n] " do_install
if [[ "${do_install,,}" != "n" ]]; then
    sudo "$SCRIPT_DIR/install.sh"
else
    echo "When ready: sudo ./install.sh"
fi
