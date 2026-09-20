#!/usr/bin/env bash
set -euo pipefail

BIN_DEST="$HOME/.local/bin/herdr-status-bridge"
FOCUS_DEST="$HOME/.local/bin/herdr-focus"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/arch.herdr-status"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"

echo "==> Removing binaries..."
rm -f "$BIN_DEST" "$FOCUS_DEST"

echo "==> Removing plugin..."
rm -rf "$PLUGIN_DEST"

if [ -f "$SHELL_CONFIG" ]; then
  echo "==> Removing arch.herdr-status from shell.json..."
  python3 -c "
import json
with open('$SHELL_CONFIG', 'r') as f:
    cfg = json.load(f)
for section in ['left', 'center', 'right']:
    items = cfg.get('bar', {}).get('layout', {}).get(section, [])
    cfg['bar']['layout'][section] = [w for w in items if w.get('id') != 'arch.herdr-status']
with open('$SHELL_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
"
fi

echo "==> Triggering plugin rescan in Omarchy Shell..."
omarchy-shell shell rescanPlugins 2>/dev/null || true

echo "==> Uninstallation complete."
