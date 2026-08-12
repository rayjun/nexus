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
    echo "ERROR: python3 is required (>= 3.9)" >&2
    exit 1
fi

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
"$INSTALL_DIR/venv/bin/pip" install -q --disable-pip-version-check \
    websockets pynacl pyyaml

# --- CLI shim ---------------------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$INSTALL_DIR/venv/bin/nexus-agent" <<SHIM
#!/usr/bin/env python3
import os, sys
sys.path.insert(0, "$INSTALL_DIR/relay/relay")
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
