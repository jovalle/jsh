#!/usr/bin/env bash
# Configure Graphify for VS Code Copilot Chat.

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
  jsh_note "Skipping Graphify setup: graphify is unavailable."
  exit 0
fi

jsh_info "Registering Graphify with VS Code Copilot Chat..."
(
  cd -- "${JSH_ROOT}"
  graphify vscode install
)
jsh_success "Graphify is registered with VS Code Copilot Chat."
