#!/usr/bin/env bash
# Configure macOS display density or the X11 split-display shortcut.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
jsh::activity 'Checking display environment'
if [[ ${JSH_DESKTOP} == darwin ]]; then
  jsh::packages display
  command -v displayplacer >/dev/null 2>&1 || exit 0
  xcrun --find swift >/dev/null 2>&1 || exit 0
  jsh::activity 'Inspecting display resolutions'
  profile=$(xcrun swift "${SCRIPT_DIR}/display/resolution.swift")
  arguments=()
  [[ -n ${profile} ]] || exit 0
  while IFS=$'\t' read -r argument _name _dimensions before width height _ppi after new_width new_height _new_ppi extra; do
    [[ -n ${argument} && -n ${_new_ppi} && -z ${extra} ]] || {
      jsh::notice 'Unexpected display resolution profile'
      exit 1
    }
    if [[ ${before}:${width}:${height} == "${after}:${new_width}:${new_height}" ]]; then
      jsh::current
    else
      arguments+=("${argument}")
    fi
  done <<<"${profile}"
  if ((${#arguments[@]})); then
    jsh::task 'Configuring displays' displayplacer "${arguments[@]}"
    jsh::changed 'display resolutions'
  fi
elif [[ ${XDG_SESSION_TYPE:-x11} != wayland ]] && command -v xrandr >/dev/null 2>&1; then
  jsh::activity 'Checking display layout shortcut'
  jsh::shortcut 'Jsh display layout' '<Control><Alt><Super>m' '<Primary><Alt><Super>m' \
    "bash '${SCRIPT_DIR}/display/toggle.sh' toggle"
fi
