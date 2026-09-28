#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CANONICAL_SRC="$(realpath "$SCRIPT_DIR" 2>/dev/null || (cd "$SCRIPT_DIR" && pwd -P))"
BIN_DEST="$HOME/.local/bin/herdr-status-bridge"
FOCUS_DEST="$HOME/.local/bin/herdr-focus"
PLUGIN_SRC="$SCRIPT_DIR"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/arch.herdr-status"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/arch.herdr-status"
RECEIPT_FILE="$STATE_DIR/install-receipt.json"
CURRENT_UID="$(id -u)"

check_ownership() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    local target_uid
    target_uid="$(stat -c %u "$target" 2>/dev/null || true)"
    if [ -n "$target_uid" ] && [ "$target_uid" -ne "$CURRENT_UID" ]; then
      echo "Error: $target is owned by UID $target_uid, not current user UID $CURRENT_UID. Refusing to modify." >&2
      exit 1
    fi
  fi
}

get_unused_backup_path() {
  local target="$1"
  local base="${target}.bak.$(date +%s)"
  local backup="$base"
  local n=1
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    backup="${base}-${n}"
    n=$((n + 1))
  done
  echo "$backup"
}

echo "==> Building Rust release binary..."
cd "$SCRIPT_DIR"
cargo build --locked --release

mkdir -p "$HOME/.local/bin"

echo "==> Installing binary to $BIN_DEST..."
check_ownership "$BIN_DEST"
SOURCE_BIN="$SCRIPT_DIR/target/release/herdr-status-bridge"

if [ -e "$BIN_DEST" ] || [ -L "$BIN_DEST" ]; then
  if cmp -s "$SOURCE_BIN" "$BIN_DEST"; then
    echo "==> Binary at $BIN_DEST is already up-to-date."
    chmod 755 "$BIN_DEST" 2>/dev/null || true
  else
    BACKUP="$(get_unused_backup_path "$BIN_DEST")"
    echo "==> Preserving existing binary at $BIN_DEST: moving to $BACKUP..."
    mv "$BIN_DEST" "$BACKUP"
    install -m 755 "$SOURCE_BIN" "$BIN_DEST"
  fi
else
  install -m 755 "$SOURCE_BIN" "$BIN_DEST"
fi

echo "==> Installing herdr-focus helper to $FOCUS_DEST..."
check_ownership "$FOCUS_DEST"
SOURCE_FOCUS="$SCRIPT_DIR/scripts/focus-herdr.sh"

if [ -e "$FOCUS_DEST" ] || [ -L "$FOCUS_DEST" ]; then
  if cmp -s "$SOURCE_FOCUS" "$FOCUS_DEST"; then
    echo "==> Helper at $FOCUS_DEST is already up-to-date."
    chmod 755 "$FOCUS_DEST" 2>/dev/null || true
  else
    BACKUP="$(get_unused_backup_path "$FOCUS_DEST")"
    echo "==> Preserving existing file at $FOCUS_DEST: moving to $BACKUP..."
    mv "$FOCUS_DEST" "$BACKUP"
    install -m 755 "$SOURCE_FOCUS" "$FOCUS_DEST"
  fi
else
  install -m 755 "$SOURCE_FOCUS" "$FOCUS_DEST"
fi

echo "==> Recording installation receipt..."
mkdir -p "$STATE_DIR"
check_ownership "$RECEIPT_FILE"
BIN_HASH="$(sha256sum "$BIN_DEST" | awk '{print $1}')"
FOCUS_HASH="$(sha256sum "$FOCUS_DEST" | awk '{print $1}')"

RECEIPT_FILE="$RECEIPT_FILE" CANONICAL_SRC="$CANONICAL_SRC" BIN_DEST="$BIN_DEST" BIN_HASH="$BIN_HASH" FOCUS_DEST="$FOCUS_DEST" FOCUS_HASH="$FOCUS_HASH" python3 -c "
import json, os
receipt = {
    'plugin_id': 'arch.herdr-status',
    'source_dir': os.environ['CANONICAL_SRC'],
    'installed_files': {
        os.environ['BIN_DEST']: os.environ['BIN_HASH'],
        os.environ['FOCUS_DEST']: os.environ['FOCUS_HASH']
    }
}
with open(os.environ['RECEIPT_FILE'], 'w') as f:
    json.dump(receipt, f, indent=2)
"

echo "==> Setting up Quickshell plugin at $PLUGIN_DEST..."
mkdir -p "$(dirname "$PLUGIN_DEST")"
check_ownership "$PLUGIN_DEST"

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
    BACKUP="$(get_unused_backup_path "$PLUGIN_DEST")"
    echo "==> Preserving existing plugin checkout: moving $PLUGIN_DEST to $BACKUP..."
    mv "$PLUGIN_DEST" "$BACKUP"
    ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
  fi
elif [ -e "$PLUGIN_DEST" ]; then
  BACKUP="$(get_unused_backup_path "$PLUGIN_DEST")"
  echo "==> Preserving existing file at $PLUGIN_DEST: moving to $BACKUP..."
  mv "$PLUGIN_DEST" "$BACKUP"
  ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
else
  echo "==> Linking Quickshell plugin to $PLUGIN_DEST..."
  ln -sfn "$PLUGIN_SRC" "$PLUGIN_DEST"
fi

if [ -f "$SHELL_CONFIG" ]; then
  check_ownership "$SHELL_CONFIG"
  if grep -q "arch.herdr-status" "$SHELL_CONFIG"; then
    echo "==> Plugin already in shell.json"
  else
    echo "==> Adding arch.herdr-status to $SHELL_CONFIG (right section)..."
    BACKUP="$(get_unused_backup_path "$SHELL_CONFIG")"
    echo "==> Backing up $SHELL_CONFIG to $BACKUP..."
    cp "$SHELL_CONFIG" "$BACKUP"
    python3 -c "
import json
with open('$SHELL_CONFIG', 'r') as f:
    cfg = json.load(f)
right = cfg.get('bar', {}).get('layout', {}).get('right', [])
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
