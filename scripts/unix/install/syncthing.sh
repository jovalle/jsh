#!/usr/bin/env bash
# Configure Syncthing connectivity and project exclusions.

set -euo pipefail

SYNCTHING_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SYNCTHING_JSH_ROOT=$(cd -- "${SYNCTHING_SCRIPT_DIR}/../../.." && pwd -P)
readonly SYNCTHING_SCRIPT_DIR SYNCTHING_JSH_ROOT
for library_file in "${SYNCTHING_JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

DRY_RUN=${JSH_INSTALL_DRY_RUN:-${JSH_CONFIGURE_DRY_RUN:-0}}
readonly -a PROJECT_IGNORE_PATTERNS=(
  '(?d).git'
  '(?d)node_modules'
  '(?d).venv'
  '(?d)venv'
  '(?d)target'
  '(?d).next'
  '(?d)__pycache__'
  '(?d).cache'
)

configure_projects_ignores() {
  local projects_dir=${JSH_PROJECTS_DIR:-${HOME}/Projects}
  local target=${projects_dir}/.stignore candidate pattern result separator=0

  if [[ -L ${target} || (-e ${target} && ! -f ${target}) ]]; then
    jsh::log_error "Refusing to replace non-regular Syncthing ignore file: ${target}"
    return 1
  fi
  if [[ ${DRY_RUN} == 1 ]]; then
    for pattern in "${PROJECT_IGNORE_PATTERNS[@]}"; do
      if [[ ! -r ${target} ]] || ! grep -Fxq -- "${pattern}" "${target}"; then
        jsh::log_detail "Would add Syncthing ignore pattern '${pattern}' to ${target}"
      fi
    done
    return 0
  fi

  mkdir -p -- "${projects_dir}"
  candidate=$(mktemp "${projects_dir}/.stignore.XXXXXX")
  jsh_interrupt_cleanup_path "${candidate}"
  [[ ! -r ${target} ]] || cat -- "${target}" > "${candidate}"
  for pattern in "${PROJECT_IGNORE_PATTERNS[@]}"; do
    grep -Fxq -- "${pattern}" "${candidate}" 2> /dev/null && continue
    if [[ ${separator} == 0 && -s ${candidate} ]]; then
      printf '\n' >> "${candidate}"
      separator=1
    fi
    printf '%s\n' "${pattern}" >> "${candidate}"
  done

  result=0
  jsh_ensure_file "${target}" "${candidate}" 0600 || result=$?
  rm -f -- "${candidate}"
  [[ ${result} == 0 || ${result} == 1 ]] || return "${result}"
}

configure_syncthing_nat() {
  local attempt current syncthing_command
  if [[ ${DRY_RUN} == 1 ]]; then
    jsh::log_detail "Would disable Syncthing NAT traversal."
    return 0
  fi
  syncthing_command=$(command -v syncthing) || {
    jsh::log_error "Syncthing is required to configure NAT traversal."
    return 1
  }
  for attempt in {1..10}; do
    if current=$("${syncthing_command}" cli config options natenabled get 2> /dev/null); then
      break
    fi
    if [[ ${attempt} == 10 ]]; then
      jsh::log_error "Syncthing did not become ready for configuration."
      return 1
    fi
    sleep 1
  done
  [[ ${current} != false ]] || return 0
  [[ ${current} == true ]] || {
    jsh::log_error "Unexpected Syncthing NAT setting: ${current}"
    return 1
  }
  "${syncthing_command}" cli config options natenabled set false
  current=$("${syncthing_command}" cli config options natenabled get)
  [[ ${current} == false ]] || {
    jsh::log_error "Syncthing NAT traversal remained enabled."
    return 1
  }
  jsh::log_success "Syncthing NAT traversal disabled."
}

main() {
  configure_projects_ignores
  configure_syncthing_nat
  jsh::log_success "Syncthing configured."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
