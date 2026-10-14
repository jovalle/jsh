#!/usr/bin/env bash
# Register REA with Codex and install its matching agent skill.

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

if ! command -v rea > /dev/null 2>&1 || ! command -v codex > /dev/null 2>&1; then
  jsh::log_note "Skipping REA configuration: REA and Codex must be installed."
  exit 0
fi
rea setup --client codex --yes
jsh::log_success "REA is configured for Codex. Restart Codex to load its tools and skill."
