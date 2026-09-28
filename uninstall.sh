#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CANONICAL_SRC="$(realpath "$SCRIPT_DIR" 2>/dev/null || true)"
BIN_DEST="$HOME/.local/bin/herdr-status-bridge"
FOCUS_DEST="$HOME/.local/bin/herdr-focus"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/arch.herdr-status"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
CURRENT_UID="$(id -u)"

echo "==> Removing binaries..."
rm -f "$BIN_DEST" "$FOCUS_DEST"

# Verify ownership of destination if it exists or is a symlink
if [ -e "$PLUGIN_DEST" ] || [ -L "$PLUGIN_DEST" ]; then
  DEST_UID="$(stat -c %u "$PLUGIN_DEST" 2>/dev/null || true)"
  if [ -n "$DEST_UID" ] && [ "$DEST_UID" -ne "$CURRENT_UID" ]; then
    echo "Error: $PLUGIN_DEST is owned by UID $DEST_UID, not current user UID $CURRENT_UID. Refusing to modify." >&2
    exit 1
  fi
fi

echo "==> Removing plugin..."
if [ -L "$PLUGIN_DEST" ]; then
  CANONICAL_DEST="$(realpath "$PLUGIN_DEST" 2>/dev/null || true)"
  DEST_TARGET="$(readlink "$PLUGIN_DEST" 2>/dev/null || true)"
  DEST_TARGET_CANONICAL="$(realpath -m "$PLUGIN_DEST" 2>/dev/null || true)"
  if [ "$CANONICAL_DEST" = "$SCRIPT_DIR" ] || [ "$CANONICAL_DEST" = "$CANONICAL_SRC" ] || \
     [ "$DEST_TARGET" = "$SCRIPT_DIR" ] || [ "$DEST_TARGET" = "$CANONICAL_SRC" ] || \
     [ "$DEST_TARGET_CANONICAL" = "$SCRIPT_DIR" ] || [ "$DEST_TARGET_CANONICAL" = "$CANONICAL_SRC" ]; then
    echo "==> Removing plugin symlink at $PLUGIN_DEST..."
    rm -f "$PLUGIN_DEST"
  else
    echo "==> Plugin symlink at $PLUGIN_DEST points to $DEST_TARGET (not this checkout $SCRIPT_DIR); leaving intact."
  fi
elif [ -d "$PLUGIN_DEST" ]; then
  DEST_REAL="$(cd "$PLUGIN_DEST" && pwd -P)"
  if [ "$SCRIPT_DIR" = "$DEST_REAL" ] || [ "$CANONICAL_SRC" = "$DEST_REAL" ]; then
    echo "==> Running uninstaller from destination directory; leaving source files intact."
  else
    echo "==> Destination $PLUGIN_DEST is a directory (not a symlink created by this installer); leaving intact."
  fi
elif [ -e "$PLUGIN_DEST" ]; then
  echo "==> Destination $PLUGIN_DEST is not a symlink created by this installer; leaving intact."
fi

if [ -f "$SHELL_CONFIG" ]; then
  echo "==> Removing arch.herdr-status from shell.json..."
  cp "$SHELL_CONFIG" "$SHELL_CONFIG.bak.$(date +%s)"
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
