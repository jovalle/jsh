#!/usr/bin/env bash
# Configure Fabric AI on first install.

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

readonly FABRIC_CONFIG_DIR=${XDG_CONFIG_HOME:-${HOME}/.config}/fabric

if ! command -v fabric-ai > /dev/null 2>&1; then
  jsh_note "Skipping Fabric AI setup: fabric-ai is unavailable."
elif [[ -f ${FABRIC_CONFIG_DIR}/.env && -d ${FABRIC_CONFIG_DIR}/patterns ]]; then
  jsh_success "Fabric AI is already configured."
elif [[ ! -t 0 ]]; then
  jsh_note "Skipping Fabric AI setup: an interactive terminal is required."
  jsh_detail "Run later: fabric-ai --setup"
else
  jsh_info "Starting Fabric AI setup with its defaults..."
  fabric-ai --setup
fi
