#!/usr/bin/env bash
# Install repository hooks.

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
  local platform
  platform=$(uname -s)
  case "${platform}" in
    Darwin | Linux) ;;
    *)
      jsh_error "Unsupported platform: ${platform}"
      exit 1
      ;;
  esac

  if command -v pre-commit >/dev/null 2>&1; then
    jsh_info "Installing repository hooks..."
    (cd "${JSH_ROOT}" && pre-commit install --install-hooks) || \
      jsh_warn "Pre-commit hook setup failed."
  fi
}

main "$@"
