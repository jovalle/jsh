#!/usr/bin/env bash
# Configure opt-in macOS display resolutions near desktop-class pixel density.

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
  local selector="${JSH_ROOT}/lib/darwin/resolution.swift"
  local profile display_arg label physical_size
  local current_logical current_backing current_scaling current_ppi
  local proposed_logical proposed_backing proposed_scaling proposed_ppi
  local -a display_args=()
  local arg

  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
    esac
  done

  [[ "$(uname -s)" == Darwin ]] || {
    jsh::log_note "Skipping macOS display resolution: macOS not detected."
    return
  }
  command -v displayplacer > /dev/null 2>&1 || {
    jsh::log_note "Skipping display resolution: displayplacer is unavailable."
    return
  }
  if ! command -v xcrun > /dev/null 2>&1 || ! xcrun --find swift > /dev/null 2>&1; then
    jsh::log_note "Skipping display resolution: the Swift toolchain is unavailable."
    return
  fi
  if ! profile=$(xcrun swift "${selector}"); then
    jsh::log_note "Skipping display resolution: unable to calculate display modes."
    return
  fi
  [[ -n "${profile}" ]] || {
    jsh::log_note "Skipping display resolution: no configurable displays found."
    return
  }

  while IFS=$'\t' read -r display_arg label physical_size \
    current_logical current_backing current_scaling current_ppi \
    proposed_logical proposed_backing proposed_scaling proposed_ppi; do
    [[ -n "${display_arg}" ]] || continue
    if [[ "${current_logical}" == "${proposed_logical}" &&
          "${current_backing}" == "${proposed_backing}" &&
          "${current_scaling}" == "${proposed_scaling}" ]]; then
      continue
    fi
    if ((${#display_args[@]} == 0)); then
      jsh::log_info "Planned display resolution changes:"
    fi
    display_args+=("${display_arg}")
    jsh::log_detail "${label} (${physical_size})"
    jsh::log_detail "  Current: ${current_logical} logical, ${current_backing} backing, scaling:${current_scaling}, ${current_ppi} effective PPI"
    jsh::log_detail "  Proposed: ${proposed_logical} logical, ${proposed_backing} backing, scaling:${proposed_scaling}, ${proposed_ppi} effective PPI"
  done <<< "${profile}"

  if ((${#display_args[@]} == 0)); then
    jsh::log_note "macOS display resolutions are already current."
    return 0
  fi

  jsh::confirm "Configure macOS display resolutions?" --default no || {
    jsh::log_note "Skipping macOS display resolution."
    return
  }

  jsh::log_info "Configuring display resolutions..."
  displayplacer "${display_args[@]}"
  jsh::log_success "macOS display resolutions configured."
}

main "$@"
