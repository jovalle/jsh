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
    jsh::log_detail "Would back up ${source} to ${backup}"
    return
  fi
  mkdir -p "$(dirname -- "${backup}")"
  jsh_run_root cat -- "${source}" > "${backup}"
  chmod 0600 "${backup}"
}

root_text_matches() {
  local destination=$1 content=$2 temporary matches=1
  [[ -e "${destination}" ]] || return 1
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/system-check.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  printf '%s\n' "${content}" > "${temporary}"
  if [[ -r "${destination}" ]] && cmp -s "${temporary}" "${destination}"; then
    matches=0
  elif jsh_run_root cmp -s "${temporary}" "${destination}" 2> /dev/null; then
    matches=0
  else
    matches=1
  fi
  rm -f "${temporary}"
  return "${matches}"
}

install_root_text() {
  local destination=$1 content=$2 temporary
  if [[ "${DRY_RUN}" != 1 ]] && root_text_matches "${destination}" "${content}"; then
    return 0
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh::log_detail "Would write configuration to ${destination}"
    return 0
  fi
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/system-config.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  printf '%s\n' "${content}" > "${temporary}"
  backup_root_file "${destination}"
  jsh_run_root install -D -o root -g root -m 0644 "${temporary}" "${destination}"
  rm -f "${temporary}"
}

enable_system_unit() {
  local unit=$1 action=$2
  if ! jsh_run_root systemctl cat "${unit}" > /dev/null 2>&1; then
    jsh::log_note "Skipping unavailable system unit: ${unit}"
    return
  fi
  case "${action}" in
    enable)
      if systemctl is-enabled --quiet "${unit}" 2> /dev/null &&
        systemctl is-active --quiet "${unit}" 2> /dev/null; then
        return 0
      fi
      jsh_run_root systemctl enable --now "${unit}"
      ;;
    start)
      if systemctl is-active --quiet "${unit}" 2> /dev/null; then
        return 0
      fi
      jsh_run_root systemctl start "${unit}"
      ;;
  esac
}

configure_kernel_tweaks() {
  local key desired current tweak
  local -A tweaks=(
    ["vm.swappiness"]="180"
    ["vm.watermark_boost_factor"]="0"
    ["vm.watermark_scale_factor"]="125"
    ["vm.page-cluster"]="0"
  )
  local -a keys=("vm.swappiness" "vm.watermark_boost_factor" "vm.watermark_scale_factor" "vm.page-cluster")
  local -a missing_tweaks=()
  local sysctl_conf="/etc/sysctl.d/99-jsh-memory.conf"
  local desired_conf="# Managed by jsh
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0"

  local conf_needs_update=0
  if ! root_text_matches "${sysctl_conf}" "${desired_conf}"; then
    conf_needs_update=1
  fi

  for key in "${keys[@]}"; do
    desired="${tweaks[${key}]}"
    current=$(sysctl -n "${key}" 2> /dev/null || true)
    current=$(printf '%s' "${current}" | tr -d '[:space:]')
    if [[ "${current}" != "${desired}" ]]; then
      missing_tweaks+=("${key}=${desired}")
    fi
  done

  if ((conf_needs_update == 0 && ${#missing_tweaks[@]} == 0)); then
    jsh::log_note "Kernel tweaks are already set."
    return 0
  fi

  if ((conf_needs_update)); then
    install_root_text "${sysctl_conf}" "${desired_conf}"
  fi

  if ((${#missing_tweaks[@]} > 0)); then
    for tweak in "${missing_tweaks[@]}"; do
      jsh::log_detail "Applying kernel tweak: ${tweak}"
      jsh_run_root sysctl -w "${tweak}"
    done
  fi
}

configure_timezone() {
  local target_tz="${JSH_TIMEZONE:-America/New_York}"
  local current_tz
  current_tz=$(timedatectl show -p Timezone --value 2> /dev/null || true)
  if [[ -n "${current_tz}" && "${current_tz}" == "${target_tz}" ]]; then
    jsh::log_note "Timezone is already ${target_tz}."
    return 0
  fi
  jsh_run_root timedatectl set-timezone "${target_tz}"
}

main() {
  local command arg
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
    esac
  done

  [[ "$(uname -s)" == Linux ]] || return
  export PATH="${PATH}:/usr/sbin:/sbin"
  for command in systemctl sysctl timedatectl; do
    command -v "${command}" > /dev/null 2>&1 || {
      jsh::log_error "${command} is required to configure Linux system policy."
      return 1
    }
  done

  jsh::log_detail "This will change memory policy, disable coredump storage, enable earlyoom and zram, and configure USB wakeup and power management."
  if ! jsh::confirm "Configure Linux system policy?" --default no; then
    jsh::log_note "Skipping Linux system policy."
    return
  fi

  local earlyoom_conf="# Managed by jsh
EARLYOOM_ARGS=\"-m 4 -s 15 -r 60 --avoid '(^|/)(init|systemd|Xorg|Xwayland|xfce4-session|gnome-shell|sshd)$' --prefer '(^|/)(code|waterfox|electron|zoom)$'\""
  local coredump_conf="# Managed by jsh
[Coredump]
Storage=none
ProcessSizeMax=0"
  local zram_conf="# Managed by jsh
[zram0]
zram-size = ram
compression-algorithm = zstd"
  local sleep_conf="# Managed by jsh
[Login]
HandlePowerKey=suspend
HandlePowerKeyLongPress=poweroff
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend"
  local usb_rules="# Managed by jsh
ACTION==\"add|change\", SUBSYSTEM==\"usb\", TEST==\"power/wakeup\", ATTR{power/wakeup}=\"enabled\""

  local systemd_reload_needed=0
  local udev_reload_needed=0
  local logind_reload_needed=0

  if ! root_text_matches /etc/default/earlyoom "${earlyoom_conf}"; then
    install_root_text /etc/default/earlyoom "${earlyoom_conf}"
    systemd_reload_needed=1
  fi

  configure_kernel_tweaks

  if ! root_text_matches /etc/systemd/coredump.conf.d/99-jsh-storage.conf "${coredump_conf}"; then
    install_root_text /etc/systemd/coredump.conf.d/99-jsh-storage.conf "${coredump_conf}"
    systemd_reload_needed=1
  fi

  if ! root_text_matches /etc/systemd/zram-generator.conf "${zram_conf}"; then
    install_root_text /etc/systemd/zram-generator.conf "${zram_conf}"
    systemd_reload_needed=1
  fi

  if ! root_text_matches /etc/systemd/logind.conf.d/99-jsh-sleep.conf "${sleep_conf}"; then
    install_root_text /etc/systemd/logind.conf.d/99-jsh-sleep.conf "${sleep_conf}"
    logind_reload_needed=1
  fi

  if ! root_text_matches /etc/udev/rules.d/90-jsh-usb-wakeup.rules "${usb_rules}"; then
    install_root_text /etc/udev/rules.d/90-jsh-usb-wakeup.rules "${usb_rules}"
    udev_reload_needed=1
  fi

  configure_timezone

  if ((systemd_reload_needed)); then
    jsh_run_root systemctl daemon-reload
  fi

  if ((udev_reload_needed)) && command -v udevadm > /dev/null 2>&1; then
    jsh_run_root udevadm control --reload
    jsh_run_root udevadm trigger --subsystem-match=usb
  fi

  if ((logind_reload_needed)); then
    jsh_run_root systemctl kill -s HUP systemd-logind.service 2> /dev/null || true
  fi

  enable_system_unit earlyoom.service enable
  enable_system_unit systemd-zram-setup@zram0.service start
  [[ -z "${BACKUP_ROOT}" ]] || jsh::log_detail "Backups: ${BACKUP_ROOT}"
  jsh::log_success "Linux system policy configured."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
