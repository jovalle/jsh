#!/usr/bin/env bash
# Configure passwordless sudo for the current Linux user.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

username=$(id -un)
if [[ ${username} == root ]]; then
  jsh::current
  exit 0
fi

sudoers_line="${username} ALL=(ALL) NOPASSWD:ALL"
sudoers_file="/etc/sudoers.d/${username}"
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::changed "${sudoers_file}"
  exit 0
fi
if jsh::root grep -Fxq "${sudoers_line}" "${sudoers_file}" 2>/dev/null; then
  jsh::current
  exit 0
fi

jsh::log_note "  › grants ${username} passwordless sudo access"
mkdir -p -- "${JSH_ROOT}/tmp"
temporary=$(mktemp "${JSH_ROOT}/tmp/sudoers.XXXXXXXX")
staging=
cleanup() {
  rm -f -- "${temporary}"
  [[ -z ${staging} ]] || jsh::root rm -f -- "${staging}" 2>/dev/null || true
}
trap cleanup EXIT
printf '%s\n' "${sudoers_line}" >"${temporary}"
visudo -cf "${temporary}"

if jsh::root test -e "${sudoers_file}"; then
  backup="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%s)-$$/sudoers"
  mkdir -p -- "${backup%/*}"
  # Keep this private backup owned by the invoking user.
  (umask 077; jsh::root cat "${sudoers_file}" >"${backup}")
  jsh::log_note "  › backup ${backup}"
fi
staging=$(jsh::root mktemp /etc/sudoers.d/.jsh-XXXXXX)
jsh::root install -o root -g root -m 0440 "${temporary}" "${staging}"
jsh::root mv -f -- "${staging}" "${sudoers_file}"
staging=
jsh::changed "${sudoers_file}"
