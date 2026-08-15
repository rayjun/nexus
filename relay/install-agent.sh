#!/usr/bin/env bash
# Nexus Agent installer — one command:  curl -fsSL <url>/install-agent.sh | bash
#
# Installs the nexus-agent CLI + relay agent into ~/.nexus:
#   - ~/.nexus/relay/          (relay_agent.py, nexus_agent_cli.py, crypto.py)
#   - ~/.nexus/venv/           (isolated Python 3 with websockets/pynacl/pyyaml)
#   - ~/.local/bin/nexus-agent (executable shim)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rayjun/nexus/main/relay/install-agent.sh | bash
#   nexus-agent setup
#   nexus-agent pair            # show code, wait for the app
#   nexus-agent start           # run in the background

set -euo pipefail

REPO_URL="${NEXUS_REPO_URL:-https://github.com/rayjun/nexus.git}"
BRANCH="${NEXUS_BRANCH:-main}"
INSTALL_DIR="${NEXUS_INSTALL_DIR:-$HOME/.nexus}"
BIN_DIR="${NEXUS_BIN_DIR:-$HOME/.local/bin}"

echo "==> Nexus Agent installer"
echo "    install dir: $INSTALL_DIR"

# --- Python 3 required -----------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (>= 3.10)" >&2
    exit 1
fi
# Version gate: the CLI uses PEP 604 unions (int | None), needs 3.10+
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    echo "ERROR: python3 >= 3.10 is required (found $(python3 --version 2>&1))" >&2
    exit 1
fi

# Validate INSTALL_DIR: no whitespace (breaks the shim shebang) and no
# XML/systemd metacharacters (would corrupt the plist/unit files).
case "$INSTALL_DIR" in
    *[[:space:]]*)
        echo "ERROR: NEXUS_INSTALL_DIR must not contain whitespace: '$INSTALL_DIR'" >&2
        exit 1
        ;;
    *[\&\<\%]*)
        echo "ERROR: NEXUS_INSTALL_DIR must not contain '&', '<' or '%': '$INSTALL_DIR'" >&2
        exit 1
        ;;
esac

# --- Fetch the relay agent code ---------------------------------------------
if [ -d "$INSTALL_DIR/relay/.git" ]; then
    echo "==> Updating existing checkout…"
    git -C "$INSTALL_DIR/relay" fetch --depth 1 origin "$BRANCH"
    git -C "$INSTALL_DIR/relay" checkout -q FETCH_HEAD
else
    echo "==> Cloning $REPO_URL (shallow)…"
    mkdir -p "$INSTALL_DIR"
    git clone --depth 1 --branch "$BRANCH" --filter=blob:none "$REPO_URL" "$INSTALL_DIR/relay" \
        || git clone --depth 1 --filter=blob:none "$REPO_URL" "$INSTALL_DIR/relay"
    # Sparse: only the relay/ directory is needed
    git -C "$INSTALL_DIR/relay" sparse-checkout init --cone
    git -C "$INSTALL_DIR/relay" sparse-checkout set relay
fi

# --- Virtualenv with dependencies --------------------------------------------
if [ ! -x "$INSTALL_DIR/venv/bin/python" ]; then
    echo "==> Creating virtualenv…"
    python3 -m venv "$INSTALL_DIR/venv"
fi
echo "==> Installing dependencies…"
env -u PYTHONPATH "$INSTALL_DIR/venv/bin/pip" install -q --disable-pip-version-check \
    -r "$INSTALL_DIR/relay/relay/requirements.txt"

# --- CLI shim ---------------------------------------------------------------
# The shim derives its paths at RUNTIME (no install-time interpolation), so
# a hostile NEXUS_INSTALL_DIR can't inject code into the generated file.
mkdir -p "$BIN_DIR"
# Shebang uses the venv python (absolute; INSTALL_DIR is whitespace-free by
# the guard above). sys.path is derived at runtime — no interpolation of
# $INSTALL_DIR into the file body, so no injection vector.
cat > "$INSTALL_DIR/venv/bin/nexus-agent" <<SHIM
#!$INSTALL_DIR/venv/bin/python
import os, sys
# This file lives at <install>/venv/bin/nexus-agent:
#   dirname x2 -> <install>/venv ; parent of that -> <install>
_bin = os.path.dirname(os.path.abspath(__file__))
_install = os.path.dirname(os.path.dirname(_bin))
sys.path.insert(0, os.path.join(_install, "relay", "relay"))
from nexus_agent_cli import main
sys.exit(main())
SHIM
chmod +x "$INSTALL_DIR/venv/bin/nexus-agent"
ln -sf "$INSTALL_DIR/venv/bin/nexus-agent" "$BIN_DIR/nexus-agent"

# --- Supervisor (crash-restart) ---------------------------------------------
# Register a system-level supervisor so the agent survives crashes. The CLI
# prefers this over its built-in daemon when present.
if [ -d "$HOME/Library/LaunchAgents" ] && [ ! -f "$HOME/Library/LaunchAgents/com.rayjun.nexus-agent.plist" ]; then
    echo "==> Registering launchd agent (macOS)…"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.rayjun.nexus-agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.rayjun.nexus-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/venv/bin/nexus-agent</string>
        <string>run-supervised</string>
    </array>
    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>$INSTALL_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key><string>$INSTALL_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST
    launchctl unload "$HOME/Library/LaunchAgents/com.rayjun.nexus-agent.plist" 2>/dev/null || true
    if ! launchctl load "$HOME/Library/LaunchAgents/com.rayjun.nexus-agent.plist" 2>/dev/null; then
        # Headless SSH sessions have no GUI domain — degrade gracefully
        # instead of aborting the whole install.
        echo "WARN: launchd load failed (no GUI session?) — crash supervision inactive"
    fi
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files >/dev/null 2>&1 \
   && [ ! -f "$HOME/.config/systemd/user/nexus-agent.service" ]; then
    echo "==> Registering systemd user unit (Linux)…"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/nexus-agent.service" <<UNIT
[Unit]
Description=Nexus mobile agent (E2E relay bridge)

[Service]
ExecStart=$INSTALL_DIR/venv/bin/nexus-agent run-supervised
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable nexus-agent.service
    # Linger keeps the user manager alive after logout/reboot on servers.
    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$USER" 2>/dev/null \
            || echo "WARN: could not enable linger — run 'loginctl enable-linger $USER' on headless servers"
    fi
fi

echo ""
echo "==> Installed. Next steps:"
echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "    nexus-agent setup      # relay URL + pairing code"
echo "    nexus-agent pair       # wait for the app"
echo "    nexus-agent start      # start (supervised — survives crashes)"
echo ""
