#!/usr/bin/env bash
# Enable and start Syncthing as a user service.

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

DRY_RUN=${JSH_INSTALL_DRY_RUN:-${JSH_CONFIGURE_DRY_RUN:-0}}

enable_linux_syncthing() {
  command -v systemctl > /dev/null 2>&1 || {
    jsh::log_error "systemctl is required to enable Syncthing."
    return 1
  }
  systemctl --user daemon-reload
  systemctl --user cat syncthing.service > /dev/null 2>&1 || {
    jsh::log_error "Syncthing user service is unavailable."
    return 1
  }
  if systemctl --user is-enabled --quiet syncthing.service &&
    systemctl --user is-active --quiet syncthing.service; then
    jsh::log_note "Syncthing user service is already running."
    return 0
  fi
  if [[ ${DRY_RUN} == 1 ]]; then
    jsh::log_detail "Would enable and start syncthing.service."
  else
    systemctl --user enable --now syncthing.service
  fi
  jsh::log_success "Syncthing user service is enabled and running."
}

enable_macos_syncthing() {
  local brew_command
  if command -v brew > /dev/null 2>&1; then
    brew_command=$(command -v brew)
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    brew_command=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    brew_command=/usr/local/bin/brew
  else
    jsh::log_error "Homebrew is required to enable Syncthing."
    return 1
  fi
  if "${brew_command}" services info syncthing 2> /dev/null | grep -Eiq '^(Running:[[:space:]]*true|status:[[:space:]]*"?started"?)$'; then
    jsh::log_note "Syncthing user service is already running."
    return 0
  fi
  if [[ ${DRY_RUN} == 1 ]]; then
    jsh::log_detail "Would start Syncthing with Homebrew services."
  else
    "${brew_command}" services start syncthing
  fi
  jsh::log_success "Syncthing user service is enabled and running."
}

main() {
  case "$(uname -s)" in
    Linux) enable_linux_syncthing ;;
    Darwin) enable_macos_syncthing ;;
    *) return 0 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
