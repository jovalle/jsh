#!/usr/bin/env bash
# Configure Linux SSH, GPG, and Podman user services.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"

[[ $(uname -s) == Linux ]] || jsh::skip "services: Linux only"
command -v systemctl >/dev/null 2>&1 || jsh::skip "services: systemctl is unavailable"
jsh::step check "user service files"

conf=${SCRIPT_DIR}/services
user_units_changed=0
ssh_agent_changed=0
ssh_agent_unit=ssh-agent.service

install_user_text() {
  local destination=$1 content=$2 temporary
  jsh::status "${destination}"
  if [[ -r ${destination} && $(<"${destination}") == "${content}" ]]; then
    jsh::ok "${destination} is current"
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::changed "${destination} updated" "${destination} differs"
    return
  fi
  mkdir -p -- "${destination%/*}"
  temporary=$(mktemp "${destination}.XXXXXX")
  printf '%s\n' "${content}" >"${temporary}"
  install -m 0644 "${temporary}" "${destination}"
  rm -f -- "${temporary}"
  user_units_changed=1
  jsh::changed "${destination} updated" "${destination} differs"
}

remove_managed_text() {
  local destination=$1 content=$2 unit=${3:-}
  jsh::status "${destination}"
  if [[ ! -e ${destination} && ! -L ${destination} ]]; then
    jsh::ok "${destination} is absent"
    return 0
  fi
  if [[ ! -r ${destination} || $(<"${destination}") != "${content}" ]]; then
    jsh::fail "Refusing to remove modified managed file: ${destination}"
    return 1
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::removed "${destination} removed" "${destination} is managed"
    return
  fi
  [[ -z ${unit} ]] || systemctl --user disable --now "${unit}"
  rm -f -- "${destination}"
  user_units_changed=1
  ssh_agent_changed=1
  jsh::removed "${destination} removed" "${destination} is managed"
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
      SSH_AUTH_SOCK=*)
        printf '%s\n' "${assignment#SSH_AUTH_SOCK=}"
        return
        ;;
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
    jsh::info "repairing SSH agent socket mismatch: ${service_path} != ${socket_path}"
  fi
  remove_managed_text "${HOME}/.config/systemd/user/ssh-agent.service" \
    "${legacy_service}" ssh-agent.service
  remove_managed_text "${HOME}/.config/environment.d/ssh-agent.conf" "${legacy_environment}"
  ssh_agent_unit=ssh-agent.socket
}

enable_user_unit() {
  local unit=$1 state
  jsh::status "${unit}"
  if ! systemctl --user cat "${unit}" >/dev/null 2>&1; then
    jsh::skipped "${unit}: unit is unavailable"
    return
  fi
  state=$(systemctl --user is-enabled "${unit}" 2>/dev/null || true)
  if [[ ${state} == enabled || ${state} == static ]] &&
    systemctl --user is-active --quiet "${unit}"; then
    jsh::ok "${unit} is active"
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    :
  elif [[ ${state} == static ]]; then
    systemctl --user start "${unit}"
  else
    systemctl --user enable --now "${unit}"
  fi
  jsh::changed "${unit} activated" "${unit} is not active"
}

activate_ssh_agent() {
  if [[ ${JSH_DRY_RUN:-0} == 1 || ${ssh_agent_changed} == 0 ]]; then
    enable_user_unit "${ssh_agent_unit}"
  else
    systemctl --user enable "${ssh_agent_unit}"
    systemctl --user restart "${ssh_agent_unit}"
    jsh::changed "${ssh_agent_unit} restarted" "${ssh_agent_unit} configuration changed"
  fi
}

jsh::status "SSH agent files"
configure_ssh_agent
jsh::status "Podman environment"
install_user_text "${HOME}/.config/environment.d/podman.conf" "$(<"${conf}/podman.conf")"
if [[ ${JSH_DRY_RUN:-0} != 1 ]] && ((user_units_changed)); then
  jsh::status "systemd user manager"
  systemctl --user daemon-reload
fi
jsh::step check "user service activation"
activate_ssh_agent
enable_user_unit gpg-agent.socket
enable_user_unit podman.socket
((user_units_changed == 0)) || jsh::notice 'log out and back in to load the new environment files'
