#!/usr/bin/env bash
# Configure opt-in EndeavourOS SSH, GPG, and Podman user services.

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

is_endeavouros() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1
  local ID=
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ "${ID:-}" == endeavouros ]]
}

install_user_text() {
  local destination=$1 content=$2 temporary
  if [[ -r "${destination}" && "$(< "${destination}")" == "${content}" ]]; then
    return
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would write ${destination}"
    return
  fi
  mkdir -p "$(dirname -- "${destination}")"
  temporary=$(mktemp "${destination}.XXXXXX")
  printf '%s\n' "${content}" > "${temporary}"
  install -m 0644 "${temporary}" "${destination}"
  rm -f "${temporary}"
}

enable_user_unit() {
  local unit=$1
  if ! systemctl --user cat "${unit}" > /dev/null 2>&1; then
    jsh_warn "Skipping unavailable user unit: ${unit}"
    return
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would enable and start ${unit}"
  else
    systemctl --user enable --now "${unit}"
  fi
}

main() {
  [[ "$(uname -s)" == Linux ]] || return
  is_endeavouros || {
    jsh_info "Skipping user services: EndeavourOS not detected."
    return
  }
  command -v systemctl > /dev/null 2>&1 || {
    jsh_error "systemctl is required to configure user services."
    return 1
  }

  jsh_info "This will configure SSH, GPG, and Podman user services."
  jsh_prompt "Configure EndeavourOS user services? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_warn "Skipping EndeavourOS user services."
    return
  }

  install_user_text "${HOME}/.config/systemd/user/ssh-agent.service" \
    "[Unit]
Description=SSH Agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a \$SSH_AUTH_SOCK

[Install]
WantedBy=default.target"
  install_user_text "${HOME}/.config/environment.d/ssh-agent.conf" \
    'SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"'
  install_user_text "${HOME}/.config/environment.d/podman.conf" \
    'DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/podman/podman.sock"'

  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would reload the user systemd manager."
  else
    systemctl --user daemon-reload
  fi
  enable_user_unit ssh-agent.service
  enable_user_unit gpg-agent.socket
  enable_user_unit podman.socket
  jsh_success "EndeavourOS user services configured."
  jsh_detail "Log out and back in to load the environment files."
}

main "$@"
