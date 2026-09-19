#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DEST="$HOME/.local/bin/herdr-status-bridge"
PLUGIN_SRC="$SCRIPT_DIR/plugin"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/arch.herdr-status"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"

echo "==> Building Rust release binary..."
cd "$SCRIPT_DIR"
cargo build --release

echo "==> Installing binary to $BIN_DEST..."
mkdir -p "$HOME/.local/bin"
install -m 755 "$SCRIPT_DIR/target/release/herdr-status-bridge" "$BIN_DEST"

echo "==> Installing herdr-focus helper to $HOME/.local/bin/herdr-focus..."
install -m 755 "$SCRIPT_DIR/scripts/focus-herdr.sh" "$HOME/.local/bin/herdr-focus"

echo "==> Linking Quickshell plugin to $PLUGIN_DEST..."
mkdir -p "$(dirname "$PLUGIN_DEST")"
rm -rf "$PLUGIN_DEST"
ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"

if [ -f "$SHELL_CONFIG" ]; then
  if grep -q "arch.herdr-status" "$SHELL_CONFIG"; then
    echo "==> Plugin already in shell.json"
  else
    echo "==> Adding arch.herdr-status to $SHELL_CONFIG (right section)..."
    cp "$SHELL_CONFIG" "$SHELL_CONFIG.bak.$(date +%s)"
    python3 -c "
import json
with open('$SHELL_CONFIG', 'r') as f:
    cfg = json.load(f)
right = cfg.get('bar', {}).get('layout', {}).get('right', [])
# Insert before sysmon or at start of right section
exists = any(w.get('id') == 'arch.herdr-status' for w in right)
if not exists:
    right.insert(0, {'id': 'arch.herdr-status'})
with open('$SHELL_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
"
    echo "==> Updated shell.json successfully."
  fi
fi

echo "==> Triggering plugin rescan in Omarchy Shell..."
omarchy-shell shell rescanPlugins 2>/dev/null || true

echo "==> Installation complete! Check your top navigation bar."
