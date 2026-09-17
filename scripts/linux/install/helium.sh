#!/usr/bin/env bash
# Install and update native Helium before profile configuration.

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
# shellcheck source=../../unix/configure/helium.sh
. "${JSH_ROOT}/scripts/unix/configure/helium.sh"

if [[ $(jsh_linux_family) == debian && $(uname -m) == x86_64 ]]; then
  upgrade_app
fi
