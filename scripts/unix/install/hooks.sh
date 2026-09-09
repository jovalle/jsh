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

confirm() {
  local answer
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  jsh_prompt "Install repository hooks? [y/N]: "
  read -r answer || answer=
  case "${answer}" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

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
    confirm || {
      jsh_note "Skipping repository hooks."
      return
    }
    jsh_info "Installing repository hooks..."
    (cd "${JSH_ROOT}" && pre-commit install --install-hooks) || \
      jsh_warn "Pre-commit hook setup failed."
  fi
}

main "$@"
