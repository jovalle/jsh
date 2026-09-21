#!/usr/bin/env bash
# Disable macOS notification controls through System Settings and verify them.

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
  local arg mode=apply plan plan_count platform
  for arg in "$@"; do
    case ${arg} in
    -y | --yes) export JSH_ASSUME_YES=1 ;;
    --check) mode=check ;;
    --dry-run) mode=dry-run ;;
    -h | --help)
      jsh::log_info "Usage: ${0##*/} [--yes | --dry-run | --check]"
      jsh::log_detail "Disables global and all listed application notifications (retains iPhone notifications)."
      jsh::log_detail "Requires English System Settings and terminal Accessibility permission."
      jsh::log_detail "--check verifies the live controls; --dry-run previews changes."
      return
      ;;
    *)
      jsh::log_error "Unknown option: ${arg}"
      return 2
      ;;
    esac
  done
  platform=$(uname -s)
  [[ ${platform} == Darwin ]] || {
    jsh::log_note "Skipping notifications: macOS not detected."
    return
  }
  [[ ${EUID} -ne 0 ]] || {
    jsh::log_error "Run as your normal user, without sudo."
    return 1
  }
  xcrun --find swift >/dev/null 2>&1 || {
    jsh::log_error "The Swift command-line tools are required."
    return 1
  }
  jsh::log_detail "Inspecting notification controls; retain iPhone notifications."
  if ! plan=$(xcrun swift "${JSH_ROOT}/lib/darwin/notifications.swift" --dry-run 2>&1); then
    while IFS= read -r line; do jsh::log_detail "${line}"; done <<<"${plan}"
    jsh::log_error "Could not inspect notification controls."
    return 1
  fi
  if [[ -z ${plan} ]]; then
    jsh::log_success "macOS notifications already match the desired state."
    return
  fi
  plan_count=$(printf '%s\n' "${plan}" | wc -l | tr -d ' ')
  jsh::log_info "Notification changes (${plan_count}):"
  while IFS= read -r line; do jsh::log_detail "  ${line}"; done <<<"${plan}"
  if [[ ${mode} == check ]]; then
    jsh::log_error "Notification controls differ from the desired state."
    return 1
  fi
  [[ ${mode} == dry-run ]] && return
  jsh::confirm "Apply these notification changes?" --default no || {
    jsh::log_note "Skipping notifications."
    return
  }
  if xcrun swift "${JSH_ROOT}/lib/darwin/notifications.swift" 2>&1 |
    while IFS= read -r line; do jsh::log_detail "${line}"; done; then
    jsh::log_success "macOS notifications disabled and verified."
  else
    jsh::log_error "Notification configuration did not complete. See the error above; rerun to finish."
    return 1
  fi
}

main "$@"
