#!/usr/bin/env bash
# Create a sample Jsh user configuration when none exists.

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

main() {
  local destination=${HOME}/.jshrc

  [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 0
  umask 077
  if cat > "${destination}" << 'EOF'
# Jsh user configuration.
# Later files override earlier files:
#   ~/.jshrc
#   ~/.local/.jshrc
#   $JSH/local/.jshrc

# JSH_PROMPT_MODE=nerdfont-v3
# JSH_PROMPT_ASYNC=1
EOF
  then
    jsh_success "Created sample configuration: ${destination}"
  else
    jsh_warn "Could not create sample configuration: ${destination}"
  fi
}

main "$@"
