#!/usr/bin/env bash
set -euo pipefail

TARGET_PANE="${1:-}"
SESSION="${2:-}"

# 1. If a pane or agent target is given, tell Herdr to focus it
if [ -n "$TARGET_PANE" ]; then
  if [ -n "$SESSION" ] && [ "$SESSION" != "default" ]; then
    herdr --session "$SESSION" agent focus "$TARGET_PANE" >/dev/null 2>&1 || true
  else
    herdr agent focus "$TARGET_PANE" >/dev/null 2>&1 || true
  fi
fi

# 2. Switch Hyprland focus to the terminal window
focused=false
for class in "com.mitchellh.ghostty" "ghostty" "Alacritty" "foot" "kitty"; do
  if hyprctl repl "hl.dispatch(hl.dsp.focus({ window = \"class:$class\" }))" >/dev/null 2>&1; then
    focused=true
    break
  fi
done

if [ "$focused" = false ]; then
  omarchy-launch-terminal >/dev/null 2>&1 || true
fi
