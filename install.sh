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
# 2. Hermes Agent itself -- official installer, browser/computer-use skipped.
#    Browser support is installed separately below (step 3b) -- Playwright's
#    own bundled-Chromium download hangs reproducibly on this hardware, so
#    we skip it here and wire up system Chromium + agent-browser instead.
#    Computer-use pulls a separate third-party installer we don't need.
#    Setup wizard skipped (we drive config ourselves below).
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
# 3b. Browser support -- gives Hermes real web-browsing tools. Two hard-won
#    findings baked in here, both discovered by actually running the
#    obvious path and watching it fail:
#
#    1. Playwright's own bundled-Chromium download (`npx playwright install
#       --with-deps chromium`) reproducibly hangs on this hardware after
#       reaching 100% -- confirmed idle (zero CPU, zero disk I/O, no new
#       network bytes) for minutes at a time across three separate
#       downloads (chromium, ffmpeg, chromium-headless-shell), not a fluke.
#       It's a bug in Playwright's out-of-process download IPC handshake on
#       this platform, not a resource/network problem. So: skip it. Hermes's
#       actual browser driver (agent-browser, below) doesn't need
#       Playwright's private Chromium at all -- it just needs *a* Chromium
#       binary, and apt's is reliable.
#
#    2. Hermes prefers the Browser Use CLI (browser-use) as its browser
#       backend whenever it's installed -- but Browser Use's own docs say
#       local-Chrome mode is for desktops with a visible display ("click
#       Allow" on a permission popup); their documented answer for headless
#       servers is their paid cloud browser product, not something to
#       silently opt into. So: don't install browser-use here, and pin
#       browser.backend to "off" so Hermes always uses its built-in
#       agent-browser-driven tools instead, regardless of whether something
#       else installs browser-use on this box later.
# ---------------------------------------------------------------------------
log "setting up browser support (system Chromium + agent-browser, not Playwright's bundled download)"
export PATH="$HOME/.hermes/node/bin:$HOME/.local/bin:$PATH"

if command -v chromium >/dev/null 2>&1; then
    log "  system chromium already installed"
else
    sudo apt-get install -y -qq chromium
fi

if command -v agent-browser >/dev/null 2>&1; then
    log "  agent-browser already installed"
else
    npm install -g --allow-scripts=agent-browser agent-browser
fi

CHROMIUM_PATH="$(command -v chromium)"
if grep -q '^AGENT_BROWSER_EXECUTABLE_PATH=' "$ENV_FILE" 2>/dev/null; then
    log "  AGENT_BROWSER_EXECUTABLE_PATH already set in $ENV_FILE -- leaving it as-is"
else
    set_env AGENT_BROWSER_EXECUTABLE_PATH "$CHROMIUM_PATH"
fi

hermes config set browser.backend off >/dev/null

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
# 7b. Google MCP server -- read-only Gmail + Calendar on the personal
#    account, read/write on SAL-9000's own "SAL" calendar. The MCP server
#    code lives in this repo (google/server.py); the OAuth credentials it
#    needs do NOT, on purpose (gitignored -- see google/.gitignore) and
#    can't be minted headlessly, since Google's consent flow needs a real
#    browser. If they're not already sitting in google/ next to this
#    script, this step warns with exact instructions and skips itself --
#    everything else in this installer still runs.
# ---------------------------------------------------------------------------
GOOGLE_SRC="$SCRIPT_DIR/google"
GOOGLE_MCP_HOME="$HERMES_HOME/google-mcp"
GOOGLE_CREDS_READY=1
for f in client_secret.json token_personal.json token_sal9000.json; do
    [[ -f "$GOOGLE_SRC/$f" ]] || GOOGLE_CREDS_READY=0
done

if [[ "$GOOGLE_CREDS_READY" -eq 0 ]]; then
    warn "google/client_secret.json and/or google/token_*.json not found next to this script --"
    warn "  skipping the Google MCP server (Gmail/Calendar tools). To set it up:"
    warn "  1. Create a Google Cloud OAuth client (Desktop app type) and save it as"
    warn "     $GOOGLE_SRC/client_secret.json"
    warn "  2. Run google/authorize.py once per account (personal, sal9000) -- see its"
    warn "     own docstring for the SSH-tunnel flow if running this on a headless box"
    warn "  3. Re-run this installer"
else
    log "setting up the Google MCP server (Gmail read-only, Calendar via google/server.py)"
    mkdir -p "$GOOGLE_MCP_HOME"
    if [[ ! -x "$GOOGLE_MCP_HOME/venv/bin/python" ]]; then
        python3 -m venv "$GOOGLE_MCP_HOME/venv"
    fi
    "$GOOGLE_MCP_HOME/venv/bin/pip" install --quiet --upgrade pip mcp google-auth \
        google-auth-oauthlib google-api-python-client

    install -m 0644 "$GOOGLE_SRC/server.py" "$GOOGLE_MCP_HOME/server.py"
    install -m 0644 "$GOOGLE_SRC/authorize.py" "$GOOGLE_MCP_HOME/authorize.py"
    # Credentials: only copy in if not already deployed. server.py rewrites its
    # OWN copy of the token files in place on refresh -- a later re-run of this
    # installer must not clobber a since-refreshed token with this repo's
    # (potentially stale) copy.
    for f in client_secret.json token_personal.json token_sal9000.json; do
        if [[ -f "$GOOGLE_MCP_HOME/$f" ]]; then
            log "  $f already deployed -- leaving it as-is"
        else
            install -m 0600 "$GOOGLE_SRC/$f" "$GOOGLE_MCP_HOME/$f"
        fi
    done

    if hermes mcp list 2>/dev/null | grep -q 'google-suite'; then
        log "  google-suite MCP server already registered -- leaving it as-is"
    else
        log "  registering the google-suite MCP server with Hermes"
        echo Y | hermes mcp add google-suite \
            --command "$GOOGLE_MCP_HOME/venv/bin/python" \
            --args "$GOOGLE_MCP_HOME/server.py" >/dev/null
    fi
fi

# ---------------------------------------------------------------------------
# 7c. Honcho memory backend -- self-hosted (github.com/plastic-labs/honcho,
#    AGPL-3.0), replacing Hermes's built-in file-based memory with
#    reasoning-derived, semantically-searchable long-term memory. Everything
#    it needs runs locally: Postgres+pgvector for storage, Redis for
#    caching, Ollama for embeddings, and Honcho's own reasoning/derivation
#    calls routed through the openai-codex proxy (7d, hermes-codex-proxy) --
#    no external API keys, no per-token billing, same subscription the main
#    agent loop already uses. See google/../README or the project history
#    for why: real infrastructure either way, but nothing beyond what's
#    already running on this box.
# ---------------------------------------------------------------------------
log "setting up Honcho (self-hosted memory backend)"

log "  installing Postgres + pgvector, Redis, Ollama"
sudo apt-get install -y -qq postgresql redis-server >/dev/null
PG_MAJOR="$(psql --version | grep -oP '\d+' | head -1)"
sudo apt-get install -y -qq "postgresql-${PG_MAJOR}-pgvector" >/dev/null

if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
ollama pull nomic-embed-text >/dev/null

HONCHO_DB_PASS_FILE="$HOME/.honcho_db_pass"
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='honcho'" | grep -q 1; then
    log "  honcho Postgres role already exists -- leaving it as-is"
    # shellcheck disable=SC1090
    [[ -f "$HONCHO_DB_PASS_FILE" ]] && source "$HONCHO_DB_PASS_FILE"
else
    HONCHO_DB_PASS="$(openssl rand -hex 24)"
    sudo -u postgres psql -c "CREATE ROLE honcho WITH LOGIN PASSWORD '$HONCHO_DB_PASS';" >/dev/null
    sudo -u postgres psql -c "CREATE DATABASE honcho OWNER honcho;" >/dev/null
    sudo -u postgres psql -d honcho -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null
    echo "HONCHO_DB_PASS=$HONCHO_DB_PASS" > "$HONCHO_DB_PASS_FILE"
    chmod 600 "$HONCHO_DB_PASS_FILE"
fi
[[ -n "${HONCHO_DB_PASS:-}" ]] || die "honcho Postgres role exists but $HONCHO_DB_PASS_FILE is missing -- can't recover the password. Drop the role and re-run, or restore the password file from backup."

HONCHO_SRC="$HOME/honcho-src"
if [[ -d "$HONCHO_SRC/.git" ]]; then
    log "  honcho-src already cloned -- leaving it as-is (not auto-updating; git pull by hand if you want upstream changes)"
else
    git clone --depth 1 https://github.com/plastic-labs/honcho.git "$HONCHO_SRC"
fi

log "  syncing Honcho's Python dependencies (uv)"
export PATH="$HERMES_HOME/bin:$PATH"
( cd "$HONCHO_SRC" && uv sync --quiet )

HONCHO_CONFIG="$HONCHO_SRC/config.toml"
if [[ -f "$HONCHO_CONFIG" ]]; then
    log "  $HONCHO_CONFIG already exists -- leaving it as-is"
else
    log "  writing $HONCHO_CONFIG"
    cat > "$HONCHO_CONFIG" <<EOF
# SAL-9000 Honcho config -- Codex proxy for reasoning/generation, local
# Ollama for embeddings. Localhost-only, no auth (matches the rest of the
# SAL-9000/Hermes setup on this box).

[app]
LOG_LEVEL = "INFO"
EMBED_MESSAGES = true
NAMESPACE = "honcho"

[db]
CONNECTION_URI = "postgresql+psycopg://honcho:${HONCHO_DB_PASS}@localhost:5432/honcho"

[auth]
USE_AUTH = false

[sentry]
ENABLED = false

[llm]
# Per-module overrides below point everything at the local Codex proxy;
# this is just a harmless fallback so nothing chokes on a missing key.
OPENAI_API_KEY = "unused-local-proxy"

[embedding]
VECTOR_DIMENSIONS = 768  # nomic-embed-text's real output size, not OpenAI's 1536

[embedding.model_config]
transport = "openai"
model = "nomic-embed-text"
[embedding.model_config.overrides]
base_url = "http://127.0.0.1:11434/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[deriver]
ENABLED = true
FLUSH_ENABLED = true

[deriver.model_config]
transport = "openai"
model = "gpt-5.5"
[deriver.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[peer_card]
ENABLED = true

[dialectic.levels.minimal.model_config]
transport = "openai"
model = "gpt-5.5"
[dialectic.levels.minimal.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[dialectic.levels.low.model_config]
transport = "openai"
model = "gpt-5.5"
[dialectic.levels.low.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[dialectic.levels.medium.model_config]
transport = "openai"
model = "gpt-5.5"
[dialectic.levels.medium.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[dialectic.levels.high.model_config]
transport = "openai"
model = "gpt-5.5"
[dialectic.levels.high.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[dialectic.levels.max.model_config]
transport = "openai"
model = "gpt-5.5"
[dialectic.levels.max.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[summary]
ENABLED = true

[summary.model_config]
transport = "openai"
model = "gpt-5.5"
[summary.model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[dream]
ENABLED = true

[dream.deduction_model_config]
transport = "openai"
model = "gpt-5.5"
[dream.deduction_model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[dream.induction_model_config]
transport = "openai"
model = "gpt-5.5"
[dream.induction_model_config.overrides]
base_url = "http://127.0.0.1:8646/v1"
api_key_env = "LOCAL_PROXY_API_KEY"

[webhook]

[metrics]
ENABLED = false

[telemetry]
ENABLED = false

[cache]
ENABLED = false
URL = "redis://localhost:6379/0"

[vector_store]
TYPE = "pgvector"
NAMESPACE = "honcho"
EOF
fi

log "  running Honcho's DB migrations (safe to re-run)"
( cd "$HONCHO_SRC" && LOCAL_PROXY_API_KEY=unused uv run alembic upgrade head )
( cd "$HONCHO_SRC" && LOCAL_PROXY_API_KEY=unused uv run python scripts/configure_embeddings.py --yes )

# ---------------------------------------------------------------------------
# 7d. Systemd services for the Codex proxy + Honcho's API and deriver.
#    hermes-codex-proxy is what lets Honcho (and nothing else, currently)
#    route its LLM calls through the openai-codex subscription instead of a
#    metered API key -- see hermes_cli/proxy/adapters/codex.py in the
#    shrout1/hermes-agent fork (branch codex-proxy-adapter) for how.
# ---------------------------------------------------------------------------
log "  installing systemd services (hermes-codex-proxy, honcho-api, honcho-deriver)"

sudo tee /etc/systemd/system/hermes-codex-proxy.service >/dev/null <<EOF
[Unit]
Description=Hermes local OpenAI-compatible proxy for OpenAI Codex (ChatGPT OAuth) -- used by Honcho
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$HERMES_HOME/hermes-agent/venv/bin/python -m hermes_cli.main proxy start --provider codex --host 127.0.0.1 --port 8646
WorkingDirectory=$HERMES_HOME
Environment="HOME=$HOME"
Environment="HERMES_HOME=$HERMES_HOME"
Environment="PATH=$HERMES_HOME/node:$HERMES_HOME/hermes-agent/venv/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/honcho-api.service >/dev/null <<EOF
[Unit]
Description=Honcho memory service -- API server
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
Requires=postgresql.service redis-server.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$HONCHO_SRC/.venv/bin/fastapi run --host 127.0.0.1 src/main.py
WorkingDirectory=$HONCHO_SRC
Environment="HOME=$HOME"
Environment="LOCAL_PROXY_API_KEY=unused-local-proxy"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/honcho-deriver.service >/dev/null <<EOF
[Unit]
Description=Honcho memory service -- background deriver
After=network-online.target postgresql.service redis-server.service honcho-api.service
Wants=network-online.target
Requires=postgresql.service redis-server.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$HONCHO_SRC/.venv/bin/python -m src.deriver
WorkingDirectory=$HONCHO_SRC
Environment="HOME=$HOME"
Environment="LOCAL_PROXY_API_KEY=unused-local-proxy"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hermes-codex-proxy honcho-api honcho-deriver >/dev/null

# ---------------------------------------------------------------------------
# 7e. Wire Honcho into Hermes as the active memory provider. This is what
#    `hermes memory setup honcho` writes interactively; written directly
#    here so a re-run doesn't depend on piping answers through a wizard
#    that might change shape. Matches the values chosen when this was set
#    up by hand: single-user (pinUserPeer), async writes, hybrid recall.
# ---------------------------------------------------------------------------
HONCHO_JSON="$HERMES_HOME/honcho.json"
if [[ -f "$HONCHO_JSON" ]]; then
    log "  $HONCHO_JSON already exists -- leaving it as-is"
else
    log "  writing $HONCHO_JSON"
    cat > "$HONCHO_JSON" <<'EOF'
{
  "hosts": {
    "hermes": {
      "peerName": "shrout",
      "aiPeer": "sal-9000",
      "workspace": "sal-9000",
      "pinUserPeer": true,
      "observationMode": "directional",
      "writeFrequency": "async",
      "recallMode": "hybrid",
      "dialecticCadence": 2,
      "dialecticReasoningLevel": "low",
      "sessionStrategy": "per-session",
      "enabled": true,
      "saveMessages": true
    }
  },
  "baseUrl": "http://localhost:8000"
}
EOF
fi

# ---------------------------------------------------------------------------
# 8. Restart the gateway so it picks up the Google MCP server and Honcho
#    memory provider from this run, then summarize.
# ---------------------------------------------------------------------------
sudo hermes gateway restart --system >/dev/null 2>&1 || true

cat <<EOF

==================================================================
SAL-9000 setup complete.

  Config       : $CONFIG_FILE
  Persona      : $SOUL_FILE
  Secrets      : $ENV_FILE
  Google MCP   : $([[ "$GOOGLE_CREDS_READY" -eq 1 ]] && echo "installed (google-suite)" || echo "SKIPPED -- see warnings above")
  Honcho       : $HONCHO_SRC (memory provider: $(hermes memory status 2>/dev/null | grep -oP 'Provider:\s*\K\S+' || echo "unknown"))
  DB password  : $HONCHO_DB_PASS_FILE
  Logs         : journalctl -u hermes-gateway -f
                 journalctl -u honcho-api -f
                 journalctl -u honcho-deriver -f
                 journalctl -u hermes-codex-proxy -f
  Status       : sudo hermes gateway status --system
  Restart      : sudo hermes gateway restart --system

Message the bot on Telegram to test it.
==================================================================
EOF
