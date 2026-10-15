#!/usr/bin/env bash
# omarchy-plugin-id: arch.herdr-status
# Usage: herdr-focus [PANE_ID] [SESSION]
# Focuses PANE_ID inside Herdr, then raises the terminal window running that session's client.
set -euo pipefail

TARGET_PANE="${1:-}"
SESSION="${2:-}"
[ "$SESSION" = "default" ] && SESSION=""
# Window classes tried when the Herdr client's own window cannot be found.
read -r -a FALLBACK_CLASSES <<< "${HERDR_FOCUS_CLASSES:-com.mitchellh.ghostty ghostty Alacritty foot kitty org.wezfurlong.wezterm}"

notify() {
  omarchy-notification-send --app-name Herdr -g "󰚩" "$1" "${2:-}" >/dev/null 2>&1 ||
    notify-send -a Herdr "$1" "${2:-}" >/dev/null 2>&1 || true
}

herdr_cmd() {
  if [ -n "$SESSION" ]; then
    herdr --session "$SESSION" "$@"
  else
    herdr "$@"
  fi
}

# `hyprctl repl` exits 0 even when nothing matches, so callers check for a match first.
focus_window() {
  hyprctl repl "hl.dispatch(hl.dsp.focus({ window = \"$1\" }))" >/dev/null 2>&1 ||
    hyprctl dispatch focuswindow "$1" >/dev/null 2>&1
}

# Session a Herdr client process is attached to ("" = default); fails for servers.
client_session() {
  local args=()
  mapfile -d '' -t args < "/proc/$1/cmdline" 2>/dev/null || return 1
  local i session=""
  for ((i = 1; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      server) return 1 ;;
      --session) session="${args[i + 1]:-}" ;;
      attach) [ "${args[i - 1]}" = "session" ] && session="${args[i + 1]:-}" ;;
    esac
  done
  [ "$session" = "default" ] && session=""
  echo "$session"
}

parent_pid() {
  # /proc/PID/stat is "pid (comm) state ppid ..."; comm may contain spaces.
  sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f2
}

# PID of the Hyprland window whose process tree contains this session's Herdr client.
herdr_window_pid() {
  local window_pids client pid session
  window_pids=$(hyprctl clients -j 2>/dev/null | jq -r '.[].pid') || return 1
  for client in $(pgrep -x herdr); do
    session=$(client_session "$client") || continue
    [ "$session" = "$SESSION" ] || continue
    pid=$client
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
      if grep -qx "$pid" <<< "$window_pids"; then
        echo "$pid"
        return 0
      fi
      pid=$(parent_pid "$pid")
    done
  done
  return 1
}

has_window_class() {
  hyprctl clients -j 2>/dev/null | jq -e --arg c "$1" 'any(.[]; .class == $c)' >/dev/null
}

# 1. Focus the pane inside Herdr.
if [ -n "$TARGET_PANE" ]; then
  if ! err=$(herdr_cmd agent focus "$TARGET_PANE" 2>&1 >/dev/null); then
    notify "Could not focus Herdr pane $TARGET_PANE" "$err"
  fi
fi

# 2. Raise the terminal window that runs Herdr.
if window_pid=$(herdr_window_pid); then
  focus_window "pid:$window_pid"
  exit 0
fi

for class in "${FALLBACK_CLASSES[@]}"; do
  if has_window_class "$class"; then
    focus_window "class:$class"
    exit 0
  fi
done

omarchy-launch-terminal >/dev/null 2>&1 || true
