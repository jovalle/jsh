#!/usr/bin/env bash
# Apply Linux file-watching limits, memory and power policy, and the timezone.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

conf=${SCRIPT_DIR}
current_items=()
updated_items=()

# Usage: root_file TARGET CONTENT. Succeeds only when TARGET needed a change.
root_file() {
  local target=$1 content=$2 temporary backup
  if [[ $(cat -- "${target}" 2>/dev/null || true) == "${content}" ]]; then
    current_items+=("${target}")
    return 1
  fi
  updated_items+=("${target}")
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::log_note "  › would write ${target}"
    return 0
  fi
  mkdir -p -- "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/system.XXXXXXXX")
  printf '%s\n' "${content}" >"${temporary}"
  if [[ -e ${target} ]]; then
    backup=${target}.$(date +%Y%m%d-%H%M%S)-$$.bak
    jsh::root cp -p -- "${target}" "${backup}"
    jsh::log_note "  › backup ${backup}"
  fi
  jsh::root install -D -m 0644 -- "${temporary}" "${target}"
  rm -f -- "${temporary}"
}

# Usage: kernel_settings FILE TARGET minimum|exact
kernel_settings() {
  local file=$1 target=$2 mode=$3 key value current content
  content=$(sed -n '/^#/p' "${file}")
  while IFS='=' read -r key value; do
    [[ -n ${key} && ${key} != '#'* ]] || continue
    key=${key//[[:space:]]/}
    value=${value//[[:space:]]/}
    current=$(sysctl -n "${key}" | tr -d '[:space:]')
    # Preserve larger limits already used by the machine, including on reboot.
    if [[ ${mode} == minimum ]] && ((current > value)); then value=${current}; fi
    content+=$'\n'"${key} = ${value}"
    if [[ ${current} != "${value}" ]]; then
      jsh::root sysctl -w "${key}=${value}"
      updated_items+=("${key}")
    else
      current_items+=("${key}")
    fi
  done <"${file}"
  root_file "${target}" "${content}" || true
}

# Usage: system_unit UNIT enable|start [restart]
system_unit() {
  local unit=$1 action=$2 restart=${3:-0}
  command -v systemctl >/dev/null 2>&1 && systemctl cat "${unit}" >/dev/null 2>&1 || {
    jsh::log_note "  › skipped unavailable unit ${unit}"
    return 0
  }
  if ! systemctl is-active --quiet "${unit}" ||
    { [[ ${action} == enable ]] && ! systemctl is-enabled --quiet "${unit}"; }; then
    if [[ ${action} == enable ]]; then
      jsh::root systemctl enable --now "${unit}"
    else
      jsh::root systemctl start "${unit}"
    fi
    updated_items+=("${unit}")
  elif ((restart)); then
    jsh::root systemctl restart "${unit}"
    updated_items+=("${unit}")
  else
    current_items+=("${unit}")
  fi
}

kernel_settings "${conf}/sysctl.conf" /etc/sysctl.d/90-jsh.conf minimum
kernel_settings "${conf}/memory.conf" /etc/sysctl.d/99-jsh-memory.conf exact

reload_systemd=0
earlyoom_changed=0
if root_file /etc/default/earlyoom "$(<"${conf}/earlyoom")"; then
  reload_systemd=1 earlyoom_changed=1
fi
if root_file /etc/systemd/coredump.conf.d/99-jsh-storage.conf "$(<"${conf}/coredump.conf")"; then
  reload_systemd=1
fi
if root_file /etc/systemd/zram-generator.conf "$(<"${conf}/zram.conf")"; then
  reload_systemd=1
fi
if root_file /etc/systemd/logind.conf.d/99-jsh-sleep.conf "$(<"${conf}/logind.conf")"; then
  jsh::root systemctl kill -s HUP systemd-logind.service 2>/dev/null || true
fi
if root_file /etc/udev/rules.d/90-jsh-usb-wakeup.rules "$(<"${conf}/usb.rules")" &&
  command -v udevadm >/dev/null 2>&1; then
  jsh::root udevadm control --reload
  jsh::root udevadm trigger --subsystem-match=usb
fi
((reload_systemd == 0)) || ! command -v systemctl >/dev/null 2>&1 ||
  jsh::root systemctl daemon-reload
system_unit earlyoom.service enable "${earlyoom_changed}"
system_unit systemd-zram-setup@zram0.service start

timezone=${JSH_TIMEZONE:-America/New_York}
if command -v timedatectl >/dev/null 2>&1; then
  if [[ $(timedatectl show --property=Timezone --value) != "${timezone}" ]]; then
    jsh::root timedatectl set-timezone "${timezone}"
    updated_items+=("timezone ${timezone}")
  else
    current_items+=("timezone ${timezone}")
  fi
fi

jsh::current "${#current_items[@]}"
for item in ${updated_items[@]+"${updated_items[@]}"}; do jsh::changed "${item}"; done
