#!/usr/bin/env bash
# Toggle an X11 ultrawide display between physical and split layouts.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

readonly LEFT_NAME=jsh-left RIGHT_NAME=jsh-right

linux_desktop() {
  local session
  session=${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}
  case ${session,,} in
    *xfce*) printf '%s\n' xfce ;;
    *gnome*) printf '%s\n' gnome ;;
  esac
}

notify_layout() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --replace-id=73942 'Display Layout' "$1"
  else
    jsh::log_info "$1"
  fi
}

refresh_layout() {
  local record width height max_width max_height
  record=$(xrandr --query | awk '
    /^Screen [0-9]+:/ { gsub(/,/, ""); print $8 "|" $10 "|" $12 "|" $14; exit }')
  [[ ${record} =~ ^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]] || return 1
  IFS='|' read -r width height max_width max_height <<<"${record}"
  if ((width < max_width)); then xrandr --fb "$((width + 1))x${height}"
  elif ((height < max_height)); then xrandr --fb "${width}x$((height + 1))"
  else return 1; fi
  xrandr --fb "${width}x${height}"
}

settle_xfce_layout() {
  local expected actual attempt stable=0
  expected=$(xrandr --listmonitors | awk 'NR>1 { gsub(/\/[0-9]+/, "", $3); print $3 }' | sort)
  [[ -n ${expected} ]] || return 1
  for ((attempt = 0; attempt < 50; attempt++)); do
    actual=$(xwininfo -root -tree | awk '
      /\("xfdesktop" "Xfdesktop"\)/ {
        for (index=1; index<=NF; index++) {
          if ($index ~ /^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$/) {
            split($index, size, /x|\+|-/)
            if (size[1] > 10 && size[2] > 10) print size[1] "x" size[2] $NF
            break
          }
        }
      }' | sort)
    if [[ ${actual} == "${expected}" ]]; then
      stable=$((stable + 1))
      ((stable < 3)) || return 0
    else
      stable=0
    fi
    sleep 0.1
  done
  jsh::log_error 'XFCE did not finish updating the desktop monitor geometry.'
  return 1
}

finish_layout() {
  local desktop
  desktop=$(linux_desktop)
  [[ ${desktop} != xfce ]] || settle_xfce_layout || return
  "${JSH_ROOT}/j.sh" configure wallpaper >/dev/null 2>&1 || true
  if [[ ${desktop} == xfce ]]; then
    sleep 0.2
    xfdesktop --reload
  fi
}

[[ ${1:-toggle} == toggle ]] || { jsh::log_error "Usage: $0 [toggle]"; exit 2; }
command -v xrandr >/dev/null 2>&1 || { jsh::log_error 'xrandr is required to toggle the display layout.'; exit 1; }
command -v flock >/dev/null 2>&1 || { jsh::log_error 'flock is required to serialize display changes.'; exit 1; }
desktop=$(linux_desktop)
if [[ ${desktop} == xfce ]] &&
  { ! command -v xwininfo >/dev/null 2>&1 || ! command -v xfdesktop >/dev/null 2>&1; }; then
  jsh::log_error 'xwininfo and xfdesktop are required to refresh the XFCE display layout.'
  exit 1
fi
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::log_note '  › would toggle the ultrawide display split'
  exit 0
fi

lock_directory=${XDG_RUNTIME_DIR:-${JSH_ROOT}/tmp}
display_name=${DISPLAY:-default}
mkdir -p -- "${lock_directory}"
exec {layout_lock}>>"${lock_directory}/jsh-display-${display_name//[^[:alnum:]]/_}.lock"
flock -n "${layout_lock}" || { jsh::log_note '  › display layout change already in progress'; exit 0; }
monitors=$(xrandr --listmonitors)
if grep -Eq "[+*]?${LEFT_NAME}([[:space:]]|$)" <<<"${monitors}"; then
  xrandr --delmonitor "${LEFT_NAME}" 2>/dev/null || true
  xrandr --delmonitor "${RIGHT_NAME}" 2>/dev/null || true
  refresh_layout || true
  finish_layout
  notify_layout 'Restored the physical ultrawide display.'
  exit 0
fi
record=$(xrandr --query | awk '
  $2 == "connected" {
    for (index=3; index<=NF; index++) {
      if ($index ~ /^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$/) {
        split($index, geometry, /x|\+|-/)
        if (geometry[1] >= geometry[2] * 3) {
          print $1 "|" geometry[1] "|" geometry[2] "|0|0"; exit
        }
      }
    }
  }')
[[ -n ${record} ]] || { jsh::log_error 'No active display with an aspect ratio of at least 3:1 was found.'; exit 1; }
IFS='|' read -r output width height x y <<<"${record}"
half=$((width / 2))
mm_width=$(xrandr --query | awk -v output="${output}" '
  $1 == output && $2 == "connected" {
    for (index=1; index<=NF-2; index++) if ($index ~ /^[0-9]+mm$/ && $(index+1) == "x") {
      sub(/mm$/, "", $index); print $index; exit
    }
  }')
mm_height=$(xrandr --query | awk -v output="${output}" '
  $1 == output && $2 == "connected" {
    for (index=1; index<=NF-2; index++) if ($index ~ /^[0-9]+mm$/ && $(index+1) == "x") {
      sub(/mm$/, "", $(index+2)); print $(index+2); exit
    }
  }')
[[ ${mm_width:-} =~ ^[0-9]+$ ]] || mm_width=${width}
[[ ${mm_height:-} =~ ^[0-9]+$ ]] || mm_height=${height}
half_mm=$((mm_width / 2))
xrandr --setmonitor "*${LEFT_NAME}" \
  "${half}/${half_mm}x${height}/${mm_height}+${x}+${y}" "${output}"
xrandr --setmonitor "${RIGHT_NAME}" \
  "${half}/${half_mm}x${height}/${mm_height}+$((x + half))+${y}" "${output}"
refresh_layout || true
finish_layout
notify_layout 'Split the ultrawide display into two logical monitors.'
