#!/usr/bin/env bash
# Nexus Relay Agent — server-side setup, pairing, and daemon start
#
# One-shot script for the Hermes server: fetches the agent client, installs
# deps, pairs with the Nexus app, then runs in the background.
#
# Usage:
#   bash agent-setup.sh <relay-url> [dashboard-ws-url]
#
#   <relay-url>        your relay endpoint, e.g. wss://relay.example.com/relay
#   [dashboard-ws-url] Hermes Dashboard WebSocket with token, e.g.
#                      ws://127.0.0.1:9119/api/ws?token=YOUR_TOKEN
#                      (also read from $HERMES_DASHBOARD_WS if not passed)
#
# Examples:
#   bash agent-setup.sh wss://relay.example.com/relay
#   HERMES_DASHBOARD_WS='ws://127.0.0.1:9119/api/ws?token=abc' \
#     bash agent-setup.sh wss://relay.example.com/relay
#
# After pairing completes, the agent runs as a background process writing
# to ~/nexus-relay/agent.log. Stop it with:  pkill -f relay_agent.py

set -euo pipefail

RELAY_URL="${1:-}"
DASH_WS="${2:-${HERMES_DASHBOARD_WS:-}}"

if [ -z "$RELAY_URL" ]; then
    echo "ERROR: relay URL required."
    echo "Usage: bash agent-setup.sh <relay-url> [dashboard-ws-url]"
    echo "  or set HERMES_DASHBOARD_WS for the dashboard token."
    exit 1
fi
if [ -z "$DASH_WS" ]; then
    echo "ERROR: dashboard WebSocket URL required (2nd arg or HERMES_DASHBOARD_WS)."
    exit 1
fi

RELAY_DIR="$HOME/nexus-relay"
PYTHON="${PYTHON:-python3}"
STATE_DIR="$HOME/.hermes/mobile"

echo "=== [1/5] Fetch relay agent code ==="
mkdir -p "$RELAY_DIR"
if [ -f "$RELAY_DIR/relay_agent.py" ] && [ -f "$RELAY_DIR/crypto.py" ]; then
    echo "agent files already present in $RELAY_DIR — keeping them."
    echo "To upgrade, delete them first or git pull the repo."
else
    echo "Fetching from https://github.com/rayjun/nexus (relay/ branch main)..."
    TMP_CLONE="$(mktemp -d)"
    if git clone --depth 1 https://github.com/rayjun/nexus.git "$TMP_CLONE" 2>/dev/null; then
        cp "$TMP_CLONE/relay/relay_agent.py" "$TMP_CLONE/relay/crypto.py" "$RELAY_DIR/"
        rm -rf "$TMP_CLONE"
        echo "fetched relay_agent.py + crypto.py"
    else
        echo "git clone failed — place relay_agent.py and crypto.py in $RELAY_DIR manually, then re-run."
        exit 1
    fi
fi
chmod 644 "$RELAY_DIR"/*.py

echo "=== [2/5] Install Python deps ==="
"$PYTHON" -m pip install --user --quiet websockets pynacl cryptography 2>/dev/null || \
"$PYTHON" -m pip install --quiet websockets pynacl cryptography || {
    echo "pip install failed — install manually: pip3 install websockets pynacl cryptography"
    exit 1
}

echo "=== [3/5] Check pairing state ==="
if [ -f "$STATE_DIR/enc_key" ] && [ -f "$STATE_DIR/paired_pubkey" ]; then
    echo "Already paired (channel: $(cat "$STATE_DIR/channel_id" 2>/dev/null || echo '?'))."
    echo "Skipping pairing — starting agent in run mode."
    PAIR_MODE=0
else
    PAIR_MODE=1
    # Security: 16-char alphanumeric code (32^16 ≈ 10^24) — 6-digit or 8-char is
    # brute-forceable (channel ids are precomputable; attacker races the app).
    PAIR_CODE="$(tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' < /dev/urandom | head -c 8)"
    echo "NOT paired yet. Pairing code: $PAIR_CODE"
    echo ""
    echo ">>> In the Nexus app: enter $PAIR_CODE"
    echo ">>> This script will block until pairing completes."
fi

echo ""
echo "=== [4/5] Start agent ==="
if [ "$PAIR_MODE" = "1" ]; then
    echo "--- pairing (foreground) ---"
    HERMES_DASHBOARD_WS="$DASH_WS" \
        "$PYTHON" "$RELAY_DIR/relay_agent.py" \
        --relay "$RELAY_URL" --pair --code "$PAIR_CODE"
    # After pairing, Ctrl-C exits; state is saved. Then re-run for daemon mode.
    echo ""
    echo "Pairing finished. Restarting as background daemon..."
    sleep 1
fi

echo "--- background daemon (systemd) ---"
# Stop any previous instance first
pkill -f "relay_agent.py --relay" 2>/dev/null || true
systemctl --user stop nexus-relay-agent.service 2>/dev/null || true
sleep 1

# Token goes in a 0600 environment file, never in the unit/argv/ps.
umask 077
cat > "$RELAY_DIR/agent.env" <<EOF
HERMES_DASHBOARD_WS=$DASH_WS
EOF
chmod 600 "$RELAY_DIR/agent.env"

cat > "$HOME/.config/systemd/user/nexus-relay-agent.service" <<EOF
[Unit]
Description=Nexus Relay Agent (Hermes mobile bridge)
After=network-online.target

[Service]
Type=simple
EnvironmentFile=$RELAY_DIR/agent.env
ExecStart=$PYTHON $RELAY_DIR/relay_agent.py --relay $RELAY_URL
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now nexus-relay-agent.service
sleep 3

echo ""
echo "=== [5/5] Verify ==="
if systemctl --user is-active --quiet nexus-relay-agent.service; then
    echo "Agent service is running (Restart=always, autostart on boot)."
    journalctl --user -u nexus-relay-agent.service -n 8 --no-pager | tail -8
    echo ""
    echo "Done. The Nexus app should now connect."
    echo "Check status: systemctl --user status nexus-relay-agent"
    echo "View logs: journalctl --user -u nexus-relay-agent -f"
else
    echo "Agent service failed to start — check logs:"
    journalctl --user -u nexus-relay-agent.service -n 20 --no-pager
    exit 1
fi
