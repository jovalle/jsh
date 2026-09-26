#!/usr/bin/env bash
# Install repository hooks.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

main() {
  local platform arg
  platform=$(uname -s)
  case "${platform}" in
    Darwin | Linux) ;;
    *)
      jsh::log_error "Unsupported platform: ${platform}"
      exit 1
      ;;
  esac

  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
    esac
  done

  if ! command -v pre-commit >/dev/null 2>&1; then
    jsh::log_note "pre-commit is not installed; skipping repository hooks."
    return 0
  fi

  if [[ ! -d "${JSH_ROOT}/.git" ]]; then
    jsh::log_note "Not a git repository; skipping repository hooks."
    return 0
  fi

  if [[ -f "${JSH_ROOT}/.git/hooks/pre-commit" ]] && grep -Fq "pre-commit" "${JSH_ROOT}/.git/hooks/pre-commit" 2> /dev/null; then
    if [[ ${JSH_UPDATE:-0} != 1 ]]; then
      jsh::log_note "Repository hooks are already installed."
      return 0
    fi
  fi

  jsh::confirm "Install repository hooks?" --default no || {
    jsh::log_note "Skipping repository hooks."
    return
  }
  jsh::log_info "Installing repository hooks..."
  if (cd "${JSH_ROOT}" && pre-commit install --install-hooks); then
    jsh::log_success "Repository hooks installed."
  else
    jsh::log_warn "Pre-commit hook setup failed."
  fi
}

main "$@"
