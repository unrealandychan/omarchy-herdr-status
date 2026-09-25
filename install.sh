#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DEST="$HOME/.local/bin/herdr-status-bridge"
PLUGIN_SRC="$SCRIPT_DIR"
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

echo "==> Setting up Quickshell plugin at $PLUGIN_DEST..."
mkdir -p "$(dirname "$PLUGIN_DEST")"

CANONICAL_SRC="$(cd "$PLUGIN_SRC" && pwd -P)"
CURRENT_UID="$(id -u)"

# Verify ownership of destination if it exists or is a symlink
if [ -e "$PLUGIN_DEST" ] || [ -L "$PLUGIN_DEST" ]; then
  DEST_UID="$(stat -c %u "$PLUGIN_DEST" 2>/dev/null || true)"
  if [ -n "$DEST_UID" ] && [ "$DEST_UID" -ne "$CURRENT_UID" ]; then
    echo "Error: $PLUGIN_DEST is owned by UID $DEST_UID, not current user UID $CURRENT_UID. Refusing to modify." >&2
    exit 1
  fi
fi

if [ -L "$PLUGIN_DEST" ]; then
  CANONICAL_DEST="$(realpath "$PLUGIN_DEST" 2>/dev/null || true)"
  if [ "$CANONICAL_DEST" = "$CANONICAL_SRC" ]; then
    echo "==> Plugin symlink at $PLUGIN_DEST already points to $PLUGIN_SRC."
  else
    echo "==> Updating Quickshell plugin symlink at $PLUGIN_DEST..."
    ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
  fi
elif [ -d "$PLUGIN_DEST" ]; then
  CANONICAL_DEST="$(cd "$PLUGIN_DEST" && pwd -P)"
  if [ "$CANONICAL_DEST" = "$CANONICAL_SRC" ]; then
    echo "==> Running from destination directory ($PLUGIN_DEST); preserving source."
  else
    BACKUP_BASE="${PLUGIN_DEST}.bak.$(date +%s)"
    BACKUP="$BACKUP_BASE"
    n=1
    while [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; do
      BACKUP="${BACKUP_BASE}-${n}"
      n=$((n + 1))
    done
    echo "==> Preserving existing plugin checkout: moving $PLUGIN_DEST to $BACKUP..."
    mv "$PLUGIN_DEST" "$BACKUP"
    ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
  fi
elif [ -e "$PLUGIN_DEST" ]; then
  BACKUP_BASE="${PLUGIN_DEST}.bak.$(date +%s)"
  BACKUP="$BACKUP_BASE"
  n=1
  while [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; do
    BACKUP="${BACKUP_BASE}-${n}"
    n=$((n + 1))
  done
  echo "==> Preserving existing file at $PLUGIN_DEST: moving to $BACKUP..."
  mv "$PLUGIN_DEST" "$BACKUP"
  ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
else
  echo "==> Linking Quickshell plugin to $PLUGIN_DEST..."
  ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
fi

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
