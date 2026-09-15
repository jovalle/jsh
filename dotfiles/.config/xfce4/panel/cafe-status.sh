#!/usr/bin/env bash
set -euo pipefail

pid_file="${XDG_RUNTIME_DIR:-/tmp}/cafe.${USER:-$(id -un)}.pid"
is_active=0

if [[ -r "${pid_file}" ]]; then
  pid=$(< "${pid_file}")
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    is_active=1
  fi
fi

if (( is_active )); then
  icon=cafe-on.svg
  tip="Cafe: Active (Sleep disabled - Click to allow sleep)"
else
  icon=cafe-off.svg
  tip="Cafe: Inactive (Normal sleep - Click to disable sleep)"
fi
root=${JSH_ROOT:-${HOME}/.jsh}
printf '<img>%s/assets/icons/%s</img><tool>%s</tool><click>%s/.config/xfce4/panel/cafe-toggle.sh</click>\n' \
  "${root}" "${icon}" "${tip}" "${HOME}"
