#!/usr/bin/env bash
# Configure Linux SSH, GPG, and Podman user services.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

conf=${SCRIPT_DIR}
user_units_changed=0
ssh_agent_changed=0
ssh_agent_unit=ssh-agent.service

install_user_text() {
  local destination=$1 content=$2 temporary
  if [[ -r ${destination} && $(<"${destination}") == "${content}" ]]; then
    jsh::current
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::changed "${destination}"
    return
  fi
  mkdir -p -- "${destination%/*}"
  temporary=$(mktemp "${destination}.XXXXXX")
  printf '%s\n' "${content}" >"${temporary}"
  install -m 0644 "${temporary}" "${destination}"
  rm -f -- "${temporary}"
  user_units_changed=1
  jsh::changed "${destination}"
}

remove_managed_text() {
  local destination=$1 content=$2 unit=${3:-}
  [[ -e ${destination} || -L ${destination} ]] || return 0
  if [[ ! -r ${destination} || $(<"${destination}") != "${content}" ]]; then
    jsh::log_error "Refusing to remove modified managed file: ${destination}"
    return 1
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::removed "${destination}"
    return
  fi
  [[ -z ${unit} ]] || systemctl --user disable --now "${unit}"
  rm -f -- "${destination}"
  user_units_changed=1
  ssh_agent_changed=1
  jsh::removed "${destination}"
}

ssh_agent_socket_path() {
  local listen
  listen=$(systemctl --user show ssh-agent.socket --property=Listen --value 2>/dev/null || true)
  printf '%s\n' "${listen%% *}"
}

ssh_agent_service_socket_path() {
  local assignment environment
  local -a assignments=()
  environment=$(systemctl --user show ssh-agent.service --property=Environment --value \
    2>/dev/null || true)
  read -r -a assignments <<<"${environment}"
  for assignment in "${assignments[@]}"; do
    case ${assignment} in
      SSH_AUTH_SOCK=*) printf '%s\n' "${assignment#SSH_AUTH_SOCK=}"; return ;;
    esac
  done
}

configure_ssh_agent() {
  local legacy_environment legacy_service service_path socket_path
  legacy_service=$(<"${conf}/agent.service")
  legacy_environment=$(<"${conf}/ssh.conf")
  if ! systemctl --user cat ssh-agent.socket >/dev/null 2>&1; then
    install_user_text "${HOME}/.config/systemd/user/ssh-agent.service" "${legacy_service}"
    install_user_text "${HOME}/.config/environment.d/ssh-agent.conf" "${legacy_environment}"
    return
  fi

  socket_path=$(ssh_agent_socket_path)
  service_path=$(ssh_agent_service_socket_path)
  if [[ -n ${socket_path} && -n ${service_path} && ${socket_path} != "${service_path}" ]]; then
    jsh::log_note "  › repairing SSH agent socket mismatch: ${service_path} != ${socket_path}"
  fi
  remove_managed_text "${HOME}/.config/systemd/user/ssh-agent.service" \
    "${legacy_service}" ssh-agent.service
  remove_managed_text "${HOME}/.config/environment.d/ssh-agent.conf" "${legacy_environment}"
  ssh_agent_unit=ssh-agent.socket
}

enable_user_unit() {
  local unit=$1 state
  if ! systemctl --user cat "${unit}" >/dev/null 2>&1; then
    jsh::current
    return
  fi
  state=$(systemctl --user is-enabled "${unit}" 2>/dev/null || true)
  if [[ ${state} == enabled || ${state} == static ]] && \
    systemctl --user is-active --quiet "${unit}"; then
    jsh::current
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    :
  elif [[ ${state} == static ]]; then
    systemctl --user start "${unit}"
  else
    systemctl --user enable --now "${unit}"
  fi
  jsh::changed "${unit}"
}

activate_ssh_agent() {
  if [[ ${JSH_DRY_RUN:-0} == 1 || ${ssh_agent_changed} == 0 ]]; then
    enable_user_unit "${ssh_agent_unit}"
  else
    systemctl --user enable "${ssh_agent_unit}"
    systemctl --user restart "${ssh_agent_unit}"
    jsh::changed "${ssh_agent_unit}"
  fi
}

command -v systemctl >/dev/null 2>&1 || exit 0
configure_ssh_agent
install_user_text "${HOME}/.config/environment.d/podman.conf" "$(<"${conf}/podman.conf")"
if [[ ${JSH_DRY_RUN:-0} != 1 ]] && ((user_units_changed)); then
  systemctl --user daemon-reload
fi
activate_ssh_agent
enable_user_unit gpg-agent.socket
enable_user_unit podman.socket
((user_units_changed == 0)) || jsh::notice 'log out and back in to load the new environment files'
