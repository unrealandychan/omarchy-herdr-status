#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CANONICAL_SRC="$(realpath "$SCRIPT_DIR" 2>/dev/null || (cd "$SCRIPT_DIR" && pwd -P))"
BIN_DEST="$HOME/.local/bin/herdr-status-bridge"
FOCUS_DEST="$HOME/.local/bin/herdr-focus"
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

is_owned_by_this_installation() {
  local target="$1"
  local expected_src="${2:-}"

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 1
  fi

  # If target is a symlink pointing directly into this source checkout, it belongs to this installation
  if [ -L "$target" ]; then
    local link_target
    link_target="$(realpath "$target" 2>/dev/null || true)"
    if [ "$link_target" = "$SCRIPT_DIR" ] || [ "$link_target" = "$CANONICAL_SRC" ] || \
       [[ "$link_target" == "$SCRIPT_DIR/"* ]] || [[ "$link_target" == "$CANONICAL_SRC/"* ]]; then
      return 0
    fi
  fi

  # Check install receipt recorded by this installation checkout
  if [ -f "$RECEIPT_FILE" ]; then
    local matches_receipt
    matches_receipt="$(RECEIPT_FILE="$RECEIPT_FILE" CANONICAL_SRC="$CANONICAL_SRC" SCRIPT_DIR="$SCRIPT_DIR" TARGET_FILE="$target" python3 -c "
import json, os, sys, hashlib
try:
    with open(os.environ['RECEIPT_FILE'], 'r') as f:
        data = json.load(f)
    if data.get('plugin_id') != 'arch.herdr-status':
        sys.exit(1)
    src_dir = data.get('source_dir', '')
    if src_dir != os.environ['CANONICAL_SRC'] and src_dir != os.environ['SCRIPT_DIR']:
        sys.exit(1)
    target = os.environ['TARGET_FILE']
    expected_hash = data.get('installed_files', {}).get(target)
    if not expected_hash:
        sys.exit(1)
    with open(target, 'rb') as f:
        actual_hash = hashlib.sha256(f.read()).hexdigest()
    if actual_hash.lower() == expected_hash.lower():
        sys.exit(0)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null && echo "yes" || echo "no")"
    if [ "$matches_receipt" = "yes" ]; then
      return 0
    fi
  fi

  # Fallback: compare directly with source artifact in this checkout
  if [ -n "$expected_src" ] && [ -f "$expected_src" ]; then
    if cmp -s "$expected_src" "$target"; then
      return 0
    fi
  fi

  return 1
}

echo "==> Checking binaries..."
check_ownership "$BIN_DEST"
check_ownership "$FOCUS_DEST"

if [ -e "$BIN_DEST" ] || [ -L "$BIN_DEST" ]; then
  if is_owned_by_this_installation "$BIN_DEST" "$SCRIPT_DIR/target/release/herdr-status-bridge"; then
    echo "==> Removing binary at $BIN_DEST..."
    rm -f "$BIN_DEST"
  else
    echo "==> Binary at $BIN_DEST was not installed by this checkout or has been replaced; leaving intact."
  fi
fi

if [ -e "$FOCUS_DEST" ] || [ -L "$FOCUS_DEST" ]; then
  if is_owned_by_this_installation "$FOCUS_DEST" "$SCRIPT_DIR/scripts/focus-herdr.sh"; then
    echo "==> Removing helper at $FOCUS_DEST..."
    rm -f "$FOCUS_DEST"
  else
    echo "==> Helper script at $FOCUS_DEST was not installed by this checkout or has been replaced; leaving intact."
  fi
fi

# Clean up installation receipt if it belonged to this installation
if [ -f "$RECEIPT_FILE" ]; then
  check_ownership "$RECEIPT_FILE"
  receipt_src="$(RECEIPT_FILE="$RECEIPT_FILE" python3 -c "
import json, os
try:
    with open(os.environ['RECEIPT_FILE'], 'r') as f:
        data = json.load(f)
    print(data.get('source_dir', ''))
except Exception:
    pass
" 2>/dev/null || true)"
  if [ "$receipt_src" = "$SCRIPT_DIR" ] || [ "$receipt_src" = "$CANONICAL_SRC" ]; then
    echo "==> Removing installation receipt..."
    rm -f "$RECEIPT_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
  fi
fi

# Verify ownership of destination if it exists or is a symlink
check_ownership "$PLUGIN_DEST"

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
  check_ownership "$SHELL_CONFIG"
  if grep -q "arch.herdr-status" "$SHELL_CONFIG"; then
    echo "==> Removing arch.herdr-status from shell.json..."
    BACKUP="$(get_unused_backup_path "$SHELL_CONFIG")"
    echo "==> Backing up $SHELL_CONFIG to $BACKUP..."
    cp "$SHELL_CONFIG" "$BACKUP"
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
    echo "==> Updated shell.json successfully."
  else
    echo "==> arch.herdr-status not present in shell.json."
  fi
fi

echo "==> Triggering plugin rescan in Omarchy Shell..."
omarchy-shell shell rescanPlugins 2>/dev/null || true

echo "==> Uninstallation complete."
