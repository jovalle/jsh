#!/usr/bin/env bash
# Configure mpv privacy settings.

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

if ! command -v mpv > /dev/null 2>&1; then
  jsh::log_note "Skipping mpv configuration: mpv must be installed."
  exit 0
fi

if [[ ${JSH_CONFIGURE_DRY_RUN:-${JSH_INSTALL_DRY_RUN:-0}} == 1 ]]; then
  jsh::log_note "Would configure mpv privacy settings."
  exit 0
fi

config=${MPV_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}/mpv}
for file in mpv.conf scripts/privacy.lua; do
  ensure_status=0
  jsh_ensure_file "${config}/${file}" "${JSH_ROOT}/dotfiles/.config/mpv/${file}" 0644 || ensure_status=$?
  [[ ${ensure_status} -le 1 ]] || exit "${ensure_status}"
done
jsh::log_success "mpv playback history is disabled."
