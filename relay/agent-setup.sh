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
    # Security: 8-char alphanumeric code (32^8 ≈ 10^12) — 6-digit numeric is
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

echo "--- background daemon ---"
# Kill any previous instance first
pkill -f "relay_agent.py --relay" 2>/dev/null || true
sleep 1

nohup env HERMES_DASHBOARD_WS="$DASH_WS" \
    "$PYTHON" "$RELAY_DIR/relay_agent.py" \
    --relay "$RELAY_URL" \
    > "$RELAY_DIR/agent.log" 2>&1 &

AGENT_PID=$!
echo "Agent started (pid $AGENT_PID), log: $RELAY_DIR/agent.log"

echo ""
echo "=== [5/5] Verify ==="
sleep 3
if kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "Agent process is running. Recent log:"
    tail -5 "$RELAY_DIR/agent.log"
    echo ""
    echo "Done. The Nexus app should now connect."
    echo "Check status anytime: tail -f $RELAY_DIR/agent.log"
else
    echo "Agent process exited — check the log:"
    cat "$RELAY_DIR/agent.log"
    exit 1
fi
