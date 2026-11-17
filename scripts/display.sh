#!/usr/bin/env bash
# Configure macOS display density or the X11 split-display shortcut.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
if [[ ${JSH_DESKTOP} == darwin ]]; then
  jsh::packages display
  command -v displayplacer >/dev/null 2>&1 || jsh::skip "display: displayplacer is not installed"
  xcrun --find swift >/dev/null 2>&1 || jsh::skip "display: Swift is not available"
  jsh::step check "display resolutions"
  profile=$(xcrun swift "${SCRIPT_DIR}/display/resolution.swift")
  arguments=()
  names=()
  resolutions=()
  [[ -n ${profile} ]] || jsh::skip "display: no configurable displays"
  while IFS=$'\t' read -r argument _name _dimensions before width height _ppi after new_width new_height _new_ppi extra; do
    [[ -n ${argument} && -n ${_new_ppi} && -z ${extra} ]] || {
      jsh::notice 'Unexpected display resolution profile'
      exit 1
    }
    jsh::status "${_name}"
    if [[ ${before}:${width}:${height} == "${after}:${new_width}:${new_height}" ]]; then
      jsh::ok "${_name} resolution is ${after} (${new_width}, scaling ${new_height})"
    else
      arguments+=("${argument}")
      names+=("${_name}")
      resolutions+=("${after} (${new_width}, scaling ${new_height})")
    fi
  done <<<"${profile}"
  if ((${#arguments[@]})); then
    jsh::task 'configuring displays' displayplacer "${arguments[@]}"
    for ((index = 0; index < ${#names[@]}; index++)); do
      jsh::changed "${names[index]} resolution set ${resolutions[index]}" \
        "${names[index]} resolution is not ${resolutions[index]}"
    done
  fi
else
  [[ ${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce ]] ||
    jsh::skip "display shortcut: no desktop session"
  [[ ${XDG_SESSION_TYPE:-x11} != wayland ]] || jsh::skip "display shortcut: Wayland session"
  command -v xrandr >/dev/null 2>&1 || jsh::skip "display shortcut: xrandr is not installed"
  jsh::step check "display layout shortcut"
  jsh::shortcut 'Jsh display layout' '<Control><Alt><Super>m' '<Primary><Alt><Super>m' \
    "bash '${SCRIPT_DIR}/display/toggle.sh' toggle"
fi
