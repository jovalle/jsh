#!/usr/bin/env bash
# Install the global Graphify agent skill that matches the installed CLI.

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

if ! command -v graphify > /dev/null 2>&1; then
  jsh::log_note "Skipping Graphify skill: graphify is not installed."
  exit 0
fi
graphify install --platform agents > /dev/null
jsh::log_success "Graphify skill is installed."
