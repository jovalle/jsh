#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    KEYBINDINGS CHEATSHEET                                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

CONFIG="$HOME/.jsh/.config/hypr/hyprland.conf"

# Extract keybindings with their comments and format nicely
grep -E '^bind' "$CONFIG" | \
  grep '#' | \
  sed 's/bind[lme]* = //' | \
  sed 's/\$mainMod/SUPER/' | \
  sed 's/, exec,.*#/  →  /' | \
  sed 's/, / + /' | \
  sed 's/,.*#/  →  /' | \
  column -t -s '→' | \
  wofi --dmenu \
       --prompt "Keybindings (SUPER+/ to close)" \
       --width 600 \
       --height 500 \
       --cache-file /dev/null
