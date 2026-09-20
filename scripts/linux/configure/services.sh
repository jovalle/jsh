#!/usr/bin/env bash
# Configure opt-in Linux SSH, GPG, and Podman user services.

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

DRY_RUN=${JSH_CONFIGURE_DRY_RUN:-0}
USER_UNITS_CHANGED=0
SSH_AGENT_CHANGED=0
SSH_AGENT_UNIT=ssh-agent.service

install_user_text() {
  local destination=$1 content=$2 temporary
  if [[ -r "${destination}" && "$(< "${destination}")" == "${content}" ]]; then
    return
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh::log_detail "Would write ${destination}"
    return
  fi
  USER_UNITS_CHANGED=1
  mkdir -p "$(dirname -- "${destination}")"
  temporary=$(mktemp "${destination}.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  printf '%s\n' "${content}" > "${temporary}"
  install -m 0644 "${temporary}" "${destination}"
  rm -f "${temporary}"
}

remove_managed_text() {
  local destination=$1 content=$2 unit=${3:-}
  [[ -e "${destination}" || -L "${destination}" ]] || return 0
  if [[ ! -r "${destination}" || "$(< "${destination}")" != "${content}" ]]; then
    jsh::log_error "Refusing to remove modified managed file: ${destination}"
    return 1
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh::log_detail "Would remove ${destination}"
    return
  fi
  if [[ -n "${unit}" ]]; then
    systemctl --user disable --now "${unit}"
  fi
  rm -f "${destination}"
  USER_UNITS_CHANGED=1
  SSH_AGENT_CHANGED=1
}

ssh_agent_socket_path() {
  local listen
  listen=$(systemctl --user show ssh-agent.socket --property=Listen --value 2> /dev/null || true)
  printf '%s\n' "${listen%% *}"
}

ssh_agent_service_socket_path() {
  local assignment environment
  local -a assignments=()
  environment=$(systemctl --user show ssh-agent.service --property=Environment --value 2> /dev/null || true)
  read -r -a assignments <<< "${environment}"
  for assignment in "${assignments[@]}"; do
    case "${assignment}" in
      SSH_AUTH_SOCK=*) printf '%s\n' "${assignment#SSH_AUTH_SOCK=}"; return ;;
    esac
  done
}

configure_ssh_agent() {
  local legacy_environment legacy_service service_path socket_path
  legacy_service='[Unit]
Description=SSH Agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target'
  legacy_environment='SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"'

  if ! systemctl --user cat ssh-agent.socket > /dev/null 2>&1; then
    install_user_text "${HOME}/.config/systemd/user/ssh-agent.service" "${legacy_service}"
    install_user_text "${HOME}/.config/environment.d/ssh-agent.conf" "${legacy_environment}"
    return
  fi

  socket_path=$(ssh_agent_socket_path)
  service_path=$(ssh_agent_service_socket_path)
  if [[ -n "${socket_path}" && -n "${service_path}" && "${socket_path}" != "${service_path}" ]]; then
    jsh::log_note "Repairing SSH agent socket mismatch: ${service_path} != ${socket_path}"
  fi

  remove_managed_text "${HOME}/.config/systemd/user/ssh-agent.service" \
    "${legacy_service}" ssh-agent.service
  remove_managed_text "${HOME}/.config/environment.d/ssh-agent.conf" \
    "${legacy_environment}"
  SSH_AGENT_UNIT=ssh-agent.socket
}

enable_user_unit() {
  local unit=$1 state
  if ! systemctl --user cat "${unit}" > /dev/null 2>&1; then
    jsh::log_note "Skipping unavailable user unit: ${unit}"
    return
  fi
  state=$(systemctl --user is-enabled "${unit}" 2> /dev/null || true)
  if [[ ${state} == enabled || ${state} == static ]] && systemctl --user is-active --quiet "${unit}"; then
    return 0
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    if [[ "${state}" == static ]]; then
      jsh::log_detail "Would start static user unit ${unit}"
    else
      jsh::log_detail "Would enable and start ${unit}"
    fi
  elif [[ "${state}" == static ]]; then
    systemctl --user start "${unit}"
  else
    systemctl --user enable --now "${unit}"
  fi
}

activate_ssh_agent() {
  if [[ "${DRY_RUN}" == 1 || "${SSH_AGENT_CHANGED}" == 0 ]]; then
    enable_user_unit "${SSH_AGENT_UNIT}"
    return
  fi
  systemctl --user enable "${SSH_AGENT_UNIT}"
  systemctl --user restart "${SSH_AGENT_UNIT}"
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
    esac
  done

  [[ "$(uname -s)" == Linux ]] || return
  command -v systemctl > /dev/null 2>&1 || {
    jsh::log_error "systemctl is required to configure user services."
    return 1
  }

  jsh::log_detail "This will configure SSH, GPG, and Podman user services."
  if ! jsh::confirm "Configure Linux user services?" --default no; then
    jsh::log_note "Skipping Linux user services."
    return
  fi

  configure_ssh_agent
  install_user_text "${HOME}/.config/environment.d/podman.conf" \
    'DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/podman/podman.sock"'

  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh::log_detail "Would reload the user systemd manager."
  elif ((USER_UNITS_CHANGED)); then
    systemctl --user daemon-reload
  fi
  activate_ssh_agent
  enable_user_unit gpg-agent.socket
  enable_user_unit podman.socket
  jsh::log_success "Linux user services configured."
  jsh::log_detail "Log out and back in to load the environment files."
}

main "$@"
