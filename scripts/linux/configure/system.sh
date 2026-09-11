#!/usr/bin/env bash
# Configure opt-in Linux memory, coredump, timezone, and system services.

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
  jsh_run_root cat -- "${source}" > "${backup}"
  chmod 0600 "${backup}"
}

install_root_text() {
  local destination=$1 content=$2 temporary
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/system-config.XXXXXX")
  printf '%s\n' "${content}" > "${temporary}"
  if [[ "${DRY_RUN}" != 1 && -e "${destination}" ]] &&
    jsh_run_root cmp -s "${temporary}" "${destination}"; then
    rm -f "${temporary}"
    return
  fi
  backup_root_file "${destination}"
  jsh_run_root install -D -o root -g root -m 0644 "${temporary}" "${destination}"
  rm -f "${temporary}"
}

enable_system_unit() {
  local unit=$1 action=$2
  if ! jsh_run_root systemctl cat "${unit}" > /dev/null 2>&1; then
    jsh_note "Skipping unavailable system unit: ${unit}"
    return
  fi
  case "${action}" in
    enable) jsh_run_root systemctl enable --now "${unit}" ;;
    start) jsh_run_root systemctl start "${unit}" ;;
  esac
}

main() {
  local command
  [[ "$(uname -s)" == Linux ]] || return
  for command in systemctl sysctl timedatectl; do
    command -v "${command}" > /dev/null 2>&1 || {
      jsh_error "${command} is required to configure Linux system policy."
      return 1
    }
  done

  jsh_detail "This will change memory policy, disable coredump storage, and enable earlyoom and zram."
  jsh_prompt "Configure Linux system policy? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_note "Skipping Linux system policy."
    return
  }

  install_root_text /etc/default/earlyoom \
    "# Managed by jsh
EARLYOOM_ARGS=\"-m 4 -s 15 -r 60 --avoid '(^|/)(init|systemd|Xorg|Xwayland|xfce4-session|gnome-shell|sshd)$' --prefer '(^|/)(code|waterfox|electron|zoom)$'\""
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

  jsh_run_root timedatectl set-timezone "${JSH_TIMEZONE:-America/New_York}"
  jsh_run_root sysctl --system
  jsh_run_root systemctl daemon-reload
  enable_system_unit earlyoom.service enable
  enable_system_unit systemd-zram-setup@zram0.service start
  [[ -z "${BACKUP_ROOT}" ]] || jsh_detail "Backups: ${BACKUP_ROOT}"
  jsh_success "Linux system policy configured."
}

main "$@"
