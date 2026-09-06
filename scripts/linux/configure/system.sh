#!/usr/bin/env bash
# Configure opt-in EndeavourOS memory, coredump, timezone, and system services.

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
BACKUP_ROOT=

is_endeavouros() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1
  local ID=
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ "${ID:-}" == endeavouros ]]
}

run_root() {
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would run as root: $*"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo > /dev/null 2>&1; then
    sudo -- "$@"
  else
    jsh_error "sudo is required to configure the system."
    return 1
  fi
}

backup_root_file() {
  local source=$1 backup
  [[ -e "${source}" ]] || return 0
  if [[ -z "${BACKUP_ROOT}" ]]; then
    BACKUP_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d%H%M%S)"
  fi
  backup="${BACKUP_ROOT}${source}"
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would back up ${source} to ${backup}"
    return
  fi
  mkdir -p "$(dirname -- "${backup}")"
  if [[ "$(id -u)" -eq 0 ]]; then
    cat -- "${source}" > "${backup}"
  else
    sudo cat -- "${source}" | command cat > "${backup}"
  fi
  chmod 0600 "${backup}"
}

install_root_text() {
  local destination=$1 content=$2 temporary
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/system-config.XXXXXX")
  printf '%s\n' "${content}" > "${temporary}"
  if [[ "${DRY_RUN}" != 1 && -e "${destination}" ]] &&
    run_root cmp -s "${temporary}" "${destination}"; then
    rm -f "${temporary}"
    return
  fi
  backup_root_file "${destination}"
  run_root install -D -o root -g root -m 0644 "${temporary}" "${destination}"
  rm -f "${temporary}"
}

main() {
  [[ "$(uname -s)" == Linux ]] || return
  is_endeavouros || {
    jsh_info "Skipping system configuration: EndeavourOS not detected."
    return
  }

  jsh_warn "This will change memory policy, disable coredump storage, and enable earlyoom and zram."
  jsh_prompt "Configure EndeavourOS system policy? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_warn "Skipping EndeavourOS system policy."
    return
  }

  install_root_text /etc/default/earlyoom \
    "# Managed by jsh
EARLYOOM_ARGS=\"-m 4 -s 15 -r 60 --avoid '(^|/)(init|systemd|Xorg|Xwayland|xfce4-session|sshd)$' --prefer '(^|/)(code|waterfox|electron|zoom)$'\""
  install_root_text /etc/sysctl.d/99-jsh-memory.conf \
    "# Managed by jsh
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0"
  install_root_text /etc/systemd/coredump.conf.d/99-jsh-storage.conf \
    "# Managed by jsh
[Coredump]
Storage=none
ProcessSizeMax=0"
  install_root_text /etc/systemd/zram-generator.conf \
    "# Managed by jsh
[zram0]
zram-size = ram
compression-algorithm = zstd"

  run_root timedatectl set-timezone America/New_York
  run_root sysctl --system
  run_root systemctl daemon-reload
  run_root systemctl enable --now earlyoom.service
  run_root systemctl start systemd-zram-setup@zram0.service
  [[ -z "${BACKUP_ROOT}" ]] || jsh_detail "Backups: ${BACKUP_ROOT}"
  jsh_success "EndeavourOS system policy configured."
}

main "$@"
