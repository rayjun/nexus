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

# Validate INSTALL_DIR: no whitespace (breaks the shim shebang)
case "$INSTALL_DIR" in
    *[[:space:]]*)
        echo "ERROR: NEXUS_INSTALL_DIR must not contain whitespace: '$INSTALL_DIR'" >&2
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

echo ""
echo "==> Installed. Next steps:"
echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "    nexus-agent setup      # relay URL + pairing code"
echo "    nexus-agent pair       # wait for the app"
echo "    nexus-agent start      # run in the background"
echo ""
