#!/usr/bin/env bash
# Install the selected checksum-pinned native Debian desktop applications.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file
[[ $(jsh_linux_family) == debian ]] || exit 0
action=apply
if [[ ${JSH_INSTALL_DRY_RUN:-0} == 1 || ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]]; then action=plan; fi
python3 "${JSH_ROOT}/lib/apps.py" "${action}" "$@"
