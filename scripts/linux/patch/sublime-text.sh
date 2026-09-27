#!/usr/bin/env bash
# Reconcile and patch Sublime Text Build 4200 on Linux.

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

if [[ -z ${SUBLIME_BINARY:-} && -z ${SUBLIME_APP_PATH:-} ]]; then
  "${JSH_ROOT}/scripts/linux/install/sublime-text.sh"
fi

exec "${JSH_ROOT}/bin/sublime" apply "$@"
