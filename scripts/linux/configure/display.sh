#!/usr/bin/env bash
# Configure EndeavourOS ultrawide display splitting and its keyboard shortcut.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

readonly BINDING='Control+Mod1+Mod4 + m'
readonly LEFT_NAME=jsh-left
readonly RIGHT_NAME=jsh-right
readonly BLOCK_START='# jsh display layout: start'
readonly BLOCK_END='# jsh display layout: end'

is_endeavouros() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1
  local ID=
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ "${ID:-}" == endeavouros ]]
}

notify_layout() {
  if command -v notify-send > /dev/null 2>&1; then
    notify-send --replace-id=73942 'Display Layout' "$1"
  else
    printf '%s\n' "$1"
  fi
}

refresh_layout() {
  local record width height max_width max_height
  record=$(xrandr --query | awk '
    /^Screen [0-9]+:/ { gsub(/,/, ""); print $8 "|" $10 "|" $12 "|" $14; exit }
  ')
  [[ "${record}" =~ ^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]] || return 1
  IFS='|' read -r width height max_width max_height <<< "${record}"
  if ((width < max_width)); then
    xrandr --fb "$((width + 1))x${height}"
  elif ((height < max_height)); then
    xrandr --fb "${width}x$((height + 1))"
  else
    return 1
  fi
  xrandr --fb "${width}x${height}"
}

toggle_layout() {
  local record output width height x y half mm_width mm_height half_mm monitors
  command -v xrandr > /dev/null 2>&1 || {
    jsh_error "xrandr is required to toggle the display layout."
    return 1
  }
  monitors=$(xrandr --listmonitors)
  if grep -Eq "[+*]?${LEFT_NAME}([[:space:]]|$)" <<< "${monitors}"; then
    xrandr --delmonitor "${LEFT_NAME}" 2> /dev/null || true
    xrandr --delmonitor "${RIGHT_NAME}" 2> /dev/null || true
    refresh_layout || true
    notify_layout "Restored the physical ultrawide display."
    return
  fi
  record=$(xrandr --query | awk '
    $2 == "connected" {
      for (i=3; i<=NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$/) {
          split($i, geometry, /x|\+|-/)
          if (geometry[1] >= geometry[2] * 3) {
            print $1 "|" geometry[1] "|" geometry[2] "|0|0"; exit
          }
        }
      }
    }')
  [[ -n "${record}" ]] || {
    jsh_error "No active display with an aspect ratio of at least 3:1 was found."
    return 1
  }
  IFS='|' read -r output width height x y <<< "${record}"
  half=$((width / 2))
  mm_width=$(xrandr --query | awk -v output="${output}" '
    $1 == output && $2 == "connected" {
      for (i=1; i<=NF-2; i++) if ($i ~ /^[0-9]+mm$/ && $(i+1) == "x") {
        sub(/mm$/, "", $i); print $i; exit
      }
    }')
  mm_height=$(xrandr --query | awk -v output="${output}" '
    $1 == output && $2 == "connected" {
      for (i=1; i<=NF-2; i++) if ($i ~ /^[0-9]+mm$/ && $(i+1) == "x") {
        sub(/mm$/, "", $(i+2)); print $(i+2); exit
      }
    }')
  [[ "${mm_width:-}" =~ ^[0-9]+$ ]] || mm_width=${width}
  [[ "${mm_height:-}" =~ ^[0-9]+$ ]] || mm_height=${height}
  half_mm=$((mm_width / 2))
  xrandr --setmonitor "*${LEFT_NAME}" "${half}/${half_mm}x${height}/${mm_height}+${x}+${y}" "${output}"
  xrandr --setmonitor "${RIGHT_NAME}" "${half}/${half_mm}x${height}/${mm_height}+$((x + half))+${y}" "${output}"
  refresh_layout || true
  notify_layout "Split the ultrawide display into two logical monitors."
}

configure_shortcut() {
  local command_path="${SCRIPT_DIR}/display.sh toggle"
  local xfce_binding='/commands/custom/<Primary><Alt><Super>m'
  local bindings="${HOME}/.xbindkeysrc" autostart="${HOME}/.config/autostart/jsh-keybindings.desktop"
  local existing='' cleaned content temporary
  jsh_info "This will bind Ctrl+Alt+Super+M to toggle an ultrawide display split."
  jsh_prompt "Configure the EndeavourOS display shortcut? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_warn "Skipping EndeavourOS display shortcut."
    return
  }

  if command -v xfconf-query > /dev/null 2>&1 &&
    [[ "${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}" == *[Xx][Ff][Cc][Ee]* ]]; then
    if xfconf-query -c xfce4-keyboard-shortcuts -p "${xfce_binding}" > /dev/null 2>&1; then
      xfconf-query -c xfce4-keyboard-shortcuts -p "${xfce_binding}" -s "${command_path}"
    else
      xfconf-query -c xfce4-keyboard-shortcuts -p "${xfce_binding}" -n -t string -s "${command_path}"
    fi
  else
    [[ ! -r "${bindings}" ]] || existing=$(< "${bindings}")
    cleaned=$(awk -v start="${BLOCK_START}" -v end="${BLOCK_END}" '
      $0 == start { drop=1; next }
      $0 == end { drop=0; next }
      !drop { print }
    ' <<< "${existing}")
    content="${cleaned%$'\n'}
${BLOCK_START}
\"${command_path}\"
  ${BINDING}
${BLOCK_END}"
    temporary=$(mktemp "${bindings}.XXXXXX")
    printf '%s\n' "${content}" > "${temporary}"
    install -m 0644 "${temporary}" "${bindings}"
    rm -f "${temporary}"
  fi

  mkdir -p "$(dirname -- "${autostart}")"
  printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=jsh global keybindings' \
    'Exec=xbindkeys' 'OnlyShowIn=XFCE;' 'X-GNOME-Autostart-enabled=true' > "${autostart}"
  pkill -HUP -u "$(id -u)" -x xbindkeys 2> /dev/null || xbindkeys
  jsh_success "EndeavourOS display shortcut configured."
}

case ${1:-configure} in
  configure)
    [[ "$(uname -s)" == Linux ]] || exit 0
    is_endeavouros || {
      jsh_info "Skipping display shortcut: EndeavourOS not detected."
      exit 0
    }
    configure_shortcut
    ;;
  toggle) toggle_layout ;;
  *)
    jsh_error "Usage: $0 [configure|toggle]"
    exit 2
    ;;
esac
