#!/usr/bin/env bash
# Nexus Relay — server install & upgrade script
#
# Installs or upgrades the Nexus relay stack on a public server:
#   - relay_server.py (public WebSocket relay, loopback :9120)
#   - crypto.py (X25519 + ChaCha20-Poly1305)
#   - relay_agent.py (agent-side client bridging to Hermes Dashboard)
#   - Caddy /relay route (TLS termination)
#   - systemd services (nexus-relay, nexus-relay-agent)
#
# Usage:
#   bash deploy-relay.sh install  <relay.example.com>   # first install
#   bash deploy-relay.sh upgrade  <relay.example.com>   # upgrade from git repo
#   bash deploy-relay.sh upgrade  <relay.example.com> /path/to/nexus  # upgrade from local checkout
#
# Requirements:
#   - a domain pointing at this server (A record)
#   - Caddy installed (or adapt the reverse-proxy block to your proxy)
#   - python3 with pip access
#
# No domain names are hardcoded — pass yours explicitly.

set -euo pipefail

ACTION="${1:-install}"
DOMAIN="${2:-}"
NEXUS_REPO="${3:-}"

if [ -z "$DOMAIN" ]; then
    echo "ERROR: relay domain required."
    echo "Usage: bash deploy-relay.sh <install|upgrade> <relay.example.com> [/path/to/nexus]"
    exit 1
fi

RELAY_DIR="$HOME/nexus-relay"
PYTHON="${PYTHON:-python3}"

echo "=== [$ACTION] domain=$DOMAIN relay_dir=$RELAY_DIR ==="

# ---------- source files ----------
if [ "$ACTION" = "upgrade" ] && [ -n "$NEXUS_REPO" ]; then
    echo "=== [0/6] Copying relay files from repo: $NEXUS_REPO ==="
    mkdir -p "$RELAY_DIR"
    cp "$NEXUS_REPO/relay/relay_server.py" "$NEXUS_REPO/relay/crypto.py" "$NEXUS_REPO/relay/relay_agent.py" "$RELAY_DIR/"
    chmod 644 "$RELAY_DIR"/*.py
elif [ "$ACTION" = "upgrade" ]; then
    echo "=== [0/6] Pulling latest relay files from git (assumes repo at $RELAY_DIR/repo) ==="
    if [ -d "$RELAY_DIR/repo/.git" ]; then
        (cd "$RELAY_DIR/repo" && git pull --ff-only)
    else
        echo "ERROR: no repo at $RELAY_DIR/repo. Clone it first:"
        echo "  git clone <your-nexus-repo> $RELAY_DIR/repo"
        echo "or pass the repo path as the 3rd argument."
        exit 1
    fi
    cp "$RELAY_DIR/repo/relay/relay_server.py" "$RELAY_DIR/repo/relay/crypto.py" "$RELAY_DIR/repo/relay/relay_agent.py" "$RELAY_DIR/"
    chmod 644 "$RELAY_DIR"/*.py
else
    # install: expect relay_server.py, crypto.py, relay_agent.py next to this script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "=== [0/6] Copying relay files from $SCRIPT_DIR ==="
    mkdir -p "$RELAY_DIR"
    cp "$SCRIPT_DIR/relay_server.py" "$SCRIPT_DIR/crypto.py" "$SCRIPT_DIR/relay_agent.py" "$RELAY_DIR/"
    chmod 644 "$RELAY_DIR"/*.py
fi

echo "=== [1/6] Install Python deps ==="
"$PYTHON" -m pip install --user --quiet websockets pynacl cryptography 2>/dev/null || \
"$PYTHON" -m pip install --quiet websockets pynacl cryptography

echo "=== [2/6] Configure Caddy (/relay route) ==="
CADDYFILE="/etc/caddy/Caddyfile"
if [ -f "$CADDYFILE" ]; then
    if grep -q "/relay" "$CADDYFILE"; then
        echo "Caddyfile already has a /relay route — verify it proxies to 127.0.0.1:9120:"
        grep -A2 "/relay" "$CADDYFILE" || true
    else
        echo "Appending /relay site block for $DOMAIN..."
        # Append a standalone site block. For a shared domain you may need to
        # merge this into an existing block instead (see docs/RELAY-DEPLOYMENT.md).
        sudo tee -a "$CADDYFILE" <<CADDY

# Nexus relay (added by deploy-relay.sh)
$DOMAIN {
    handle /relay {
        reverse_proxy 127.0.0.1:9120
    }
}
CADDY
        sudo systemctl reload caddy || sudo systemctl restart caddy
        echo "Caddy reloaded."
    fi
else
    echo "No Caddyfile at $CADDYFILE — set up your reverse proxy manually:"
    echo "  reverse_proxy $DOMAIN/relay -> 127.0.0.1:9120"
fi

echo "=== [3/6] Install systemd services ==="

cat > /tmp/nexus-relay.service <<UNIT
[Unit]
Description=Nexus Relay Server
After=network.target

[Service]
ExecStart=$PYTHON $RELAY_DIR/relay_server.py
Restart=always
RestartSec=3
User=$(whoami)

[Install]
WantedBy=multi-user.target
UNIT

# NOTE: HERMES_DASHBOARD_WS must point at your loopback Dashboard WS with its
# session token, e.g. ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN
# The token lives in a 0600 EnvironmentFile — never in the unit file (which
# is world-readable) or on the command line.
cat > /tmp/nexus-relay-agent.service <<UNIT
[Unit]
Description=Nexus Relay Agent
After=network.target nexus-relay.service

[Service]
ExecStart=$PYTHON $RELAY_DIR/relay_agent.py --relay wss://$DOMAIN/relay
EnvironmentFile=$RELAY_DIR/agent.env
Restart=always
RestartSec=5
User=$(whoami)

[Install]
WantedBy=multi-user.target
UNIT

sudo cp /tmp/nexus-relay.service /etc/systemd/system/
sudo cp /tmp/nexus-relay-agent.service /etc/systemd/system/
sudo systemctl daemon-reload

# Agent environment file (0600): fail loudly if the token is still the
# placeholder so a production deploy can't silently ship with a fake token.
if [ ! -f "$RELAY_DIR/agent.env" ] || grep -q "REPLACE_WITH_DASHBOARD_TOKEN" "$RELAY_DIR/agent.env" 2>/dev/null; then
    echo ""
    echo "!!! Set the real Dashboard token, then re-run this script:"
    echo "    sudo tee $RELAY_DIR/agent.env >/dev/null <<EOF"
    echo "    HERMES_DASHBOARD_WS=ws://127.0.0.1:9119/api/ws?token=YOUR_REAL_TOKEN"
    echo "    EOF"
    echo "    sudo chmod 600 $RELAY_DIR/agent.env"
    exit 1
fi
sudo chmod 600 "$RELAY_DIR/agent.env"

echo "=== [4/6] Restart services ==="
sudo systemctl enable --now nexus-relay.service || true
sudo systemctl restart nexus-relay.service
sudo systemctl restart nexus-relay-agent.service
sleep 2
sudo systemctl status nexus-relay.service --no-pager | head -5 || true

echo ""
echo "======================================================"
echo " NEXT STEPS"
echo "======================================================"
echo "1. Set the real Dashboard token (once, before re-running):"
echo "     sudo tee $RELAY_DIR/agent.env >/dev/null <<EOF"
echo "     HERMES_DASHBOARD_WS=ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN"
echo "     EOF"
echo "     sudo chmod 600 $RELAY_DIR/agent.env"
echo ""
echo "2. First-time pairing (run ONCE, foreground):"
echo "     cd $RELAY_DIR"
echo "     HERMES_DASHBOARD_WS='ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN' \\\\"
echo "       $PYTHON relay_agent.py --relay wss://$DOMAIN/relay --pair --code K7M2P9QX3F5B8TZ2"
echo "   Enter code K7M2P9QX3F5B8TZ2 in the Nexus app, wait for 'pairing complete'."
echo "   Then Ctrl-C (the pairing state is saved)."
echo ""
echo "3. Start the agent daemon (after pairing):"
echo "     sudo systemctl enable --now nexus-relay-agent.service"
echo ""
echo "4. Verify the relay endpoint is reachable:"
echo "     curl -s https://$DOMAIN/relay | head -c 200"
echo "   (a WebSocket error / 4xx from the relay itself means the port is open)"
echo "======================================================"
