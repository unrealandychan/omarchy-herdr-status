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
  if [ -f "$RECEIPT_FILE" ] && [ ! -L "$RECEIPT_FILE" ]; then
    local matches_receipt
    matches_receipt="$(RECEIPT_FILE="$RECEIPT_FILE" CANONICAL_SRC="$CANONICAL_SRC" SCRIPT_DIR="$SCRIPT_DIR" TARGET_FILE="$target" python3 -c "
import json, os, sys, hashlib
try:
    fd = os.open(os.environ['RECEIPT_FILE'], os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'r') as f:
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
if [ -L "$RECEIPT_FILE" ]; then
  check_ownership "$RECEIPT_FILE"
  echo "==> Removing receipt symlink..."
  rm -f "$RECEIPT_FILE"
elif [ -f "$RECEIPT_FILE" ]; then
  check_ownership "$RECEIPT_FILE"
  receipt_src="$(RECEIPT_FILE="$RECEIPT_FILE" python3 -c "
import json, os
try:
    fd = os.open(os.environ['RECEIPT_FILE'], os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'r') as f:
        data = json.load(f)
    print(data.get('source_dir', ''))
except Exception:
    pass
" 2>/dev/null || true)"
  if [ "$receipt_src" = "$SCRIPT_DIR" ] || [ "$receipt_src" = "$CANONICAL_SRC" ]; then
    echo "==> Removing installation receipt..."
    rm -f "$RECEIPT_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
    RECEIPT_OWNED=1
  fi
fi

# Verify ownership of destination if it exists or is a symlink
check_ownership "$PLUGIN_DEST"

THIS_INSTALLATION_OWNS_PLUGIN=0

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
    THIS_INSTALLATION_OWNS_PLUGIN=1
  else
    echo "==> Plugin symlink at $PLUGIN_DEST points to $DEST_TARGET (not this checkout $SCRIPT_DIR); leaving intact."
  fi
elif [ -d "$PLUGIN_DEST" ]; then
  DEST_REAL="$(cd "$PLUGIN_DEST" && pwd -P)"
  if [ "$SCRIPT_DIR" = "$DEST_REAL" ] || [ "$CANONICAL_SRC" = "$DEST_REAL" ]; then
    echo "==> Running uninstaller from destination directory; leaving source files intact."
    THIS_INSTALLATION_OWNS_PLUGIN=1
  else
    echo "==> Destination $PLUGIN_DEST is a directory (not a symlink created by this installer); leaving intact."
  fi
elif [ -e "$PLUGIN_DEST" ]; then
  echo "==> Destination $PLUGIN_DEST is not a symlink created by this installer; leaving intact."
else
  # Destination does not exist: if this checkout owned the receipt, allow cleaning shell.json
  if [ "${RECEIPT_OWNED:-0}" = "1" ]; then
    THIS_INSTALLATION_OWNS_PLUGIN=1
  fi
fi

if [ "$THIS_INSTALLATION_OWNS_PLUGIN" -eq 1 ]; then
  if [ -L "$SHELL_CONFIG" ]; then
    echo "Error: $SHELL_CONFIG is a symlink. Refusing to modify." >&2
    exit 1
  fi

  if [ -f "$SHELL_CONFIG" ]; then
    check_ownership "$SHELL_CONFIG"
    if grep -q "arch.herdr-status" "$SHELL_CONFIG"; then
      echo "==> Removing arch.herdr-status from shell.json..."
      BACKUP="$(get_unused_backup_path "$SHELL_CONFIG")"
      echo "==> Backing up $SHELL_CONFIG to $BACKUP..."
      cp "$SHELL_CONFIG" "$BACKUP"
      SHELL_CONFIG="$SHELL_CONFIG" python3 -c "
import json, os, tempfile, sys

config_path = os.environ['SHELL_CONFIG']
dirname = os.path.dirname(config_path)
basename = os.path.basename(config_path)
current_uid = os.getuid()

dir_fd = os.open(dirname, os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_NOFOLLOW', 0))
try:
    dir_stat = os.fstat(dir_fd)
    if dir_stat.st_uid != current_uid:
        raise PermissionError(f'Directory {dirname} is owned by UID {dir_stat.st_uid}, not {current_uid}')

    fd = os.open(basename, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=dir_fd)
    try:
        st = os.fstat(fd)
        if st.st_uid != current_uid:
            raise PermissionError(f'File {basename} is owned by UID {st.st_uid}, not {current_uid}')
        orig_mode = st.st_mode & 0o777
        with os.fdopen(fd, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        raise

    for section in ['left', 'center', 'right']:
        items = cfg.get('bar', {}).get('layout', {}).get(section, [])
        cfg['bar']['layout'][section] = [w for w in items if w.get('id') != 'arch.herdr-status']

    tmp_fd, tmp_path = tempfile.mkstemp(prefix=f'.{basename}-', suffix='.tmp', dir=dirname)
    tmp_base = os.path.basename(tmp_path)
    try:
        with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_path, orig_mode)
        os.replace(tmp_base, basename, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        tmp_path = None
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
finally:
    os.close(dir_fd)
"
      echo "==> Updated shell.json successfully."
    else
      echo "==> arch.herdr-status not present in shell.json."
    fi
  fi

  echo "==> Triggering plugin rescan in Omarchy Shell..."
  omarchy-shell shell rescanPlugins 2>/dev/null || true
else
  echo "==> Active plugin at $PLUGIN_DEST is not owned by this checkout; leaving shell.json intact."
fi

echo "==> Uninstallation complete."
