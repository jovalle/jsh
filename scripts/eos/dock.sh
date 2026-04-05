#!/usr/bin/env bash
set -euo pipefail

find_desktop_file() {
  local candidate directory
  for candidate in "$@"; do
    for directory in \
      "$HOME/.local/share/applications" \
      /usr/share/applications \
      /usr/local/share/applications \
      /var/lib/flatpak/exports/share/applications \
      "$HOME/.local/share/flatpak/exports/share/applications" \
      /home/linuxbrew/.linuxbrew/share/applications; do
      if [[ -f $directory/$candidate ]]; then
        printf '%s' "$directory/$candidate"
        return 0
      fi
    done
  done
  return 1
}

dock_pins() {
  local pins='' desktop_file
  desktop_file=$(find_desktop_file com.mitchellh.ghostty.desktop xfce4-terminal.desktop xfce4-terminal-emulator.desktop) && pins+="$desktop_file;"
  desktop_file=$(find_desktop_file visual-studio-code.desktop code.desktop code-oss.desktop) && pins+="$desktop_file;"
  desktop_file=$(find_desktop_file google-chrome.desktop com.google.Chrome.desktop) && pins+="$desktop_file;"
  desktop_file=$(find_desktop_file com.spotify.Client.desktop) && pins+="$desktop_file;"
  desktop_file=$(find_desktop_file com.todoist.Todoist.desktop) && pins+="$desktop_file;"
  desktop_file=$(find_desktop_file waterfox.desktop) && pins+="$desktop_file;"
  printf '%s' "$pins"
}

write_pins() {
  local target=$1 pins=$2 temporary
  temporary=$(mktemp "$target.XXXXXX")
  awk -v pins="$pins" '
    BEGIN { section=0; found=0 }
    /^\[user\]$/ { section=1; print; next }
    /^\[/ {
      if (section && !found) {
        print "pinned=" pins
        found=1
      }
      section=0
    }
    section && /^pinned=/ { if (!found) print "pinned=" pins; found=1; next }
    { print }
    END {
      if (!found) {
        if (!section) print "\n[user]"
        print "pinned=" pins
      }
    }
  ' "$target" 2>/dev/null >"$temporary" || printf '[user]\npinned=%s\n' "$pins" >"$temporary"
  if ! install -m 0644 -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 2
  fi
  rm -f -- "$temporary"
}

if ! xfconf-query -c xfce4-panel -lv >/dev/null 2>&1; then
  printf 'XFCE panel is unavailable; skipping dock configuration.\n'
  exit 0
fi

pins=$(dock_pins)
if [[ -z $pins ]]; then
  printf 'No configured dock applications are installed; skipping dock configuration.\n'
  exit 0
fi

panel_dir="$HOME/.config/xfce4/panel"
target=$(find "$panel_dir" -maxdepth 1 -name 'docklike-*.rc' -print -quit 2>/dev/null || true)
if [[ -z $target ]]; then
  plugin_id=$(xfconf-query -c xfce4-panel -lv | sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
  plugin_id=$((${plugin_id:-0} + 1))
  panel_id=2
  xfconf-query -c xfce4-panel -p "/panels/panel-$panel_id/plugin-ids" >/dev/null 2>&1 || panel_id=1
  target="$panel_dir/docklike-$plugin_id.rc"

  mkdir -p -- "$panel_dir"
  xfconf-query -c xfce4-panel -p "/plugins/plugin-$plugin_id" -n -t string -s docklike >/dev/null

  plugin_ids=()
  while IFS= read -r id; do
    [[ $id =~ ^[0-9]+$ ]] && plugin_ids+=("$id")
  done < <(xfconf-query -c xfce4-panel -p "/panels/panel-$panel_id/plugin-ids" 2>/dev/null)
  plugin_ids+=("$plugin_id")

  array_args=()
  for id in "${plugin_ids[@]}"; do
    array_args+=(-t int -s "$id")
  done
  xfconf-query -c xfce4-panel -p "/panels/panel-$panel_id/plugin-ids" -a "${array_args[@]}" >/dev/null
fi

mkdir -p -- "$panel_dir"
write_pins "$target" "$pins"
grep -Fqx "pinned=$pins" "$target" || {
  printf 'Failed to verify EndeavourOS dock pins.\n' >&2
  exit 2
}
xfce4-panel -r >/dev/null 2>&1 || true
