#!/usr/bin/env bash
# Cycle Linux audio outputs while excluding managed disabled sinks.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh" "$@"

output_is_excluded() {
  [[ $1 =~ ^alsa_output\.pci-.*\.HiFi__HDMI[0-9]*__sink$ ||
    $1 =~ ^alsa_output\.pci-0000_04_00\.6\..*$ ||
    $1 =~ ^alsa_output\.usb-Elgato_Systems_Elgato_Wave_3_.*$ ]]
}

[[ ${1:-cycle} == cycle || ${1:-} == --dry-run ]] || {
  jsh::log_error "Usage: $0 [cycle]"
  exit 2
}
command -v pactl >/dev/null 2>&1 || {
  jsh::log_error 'pactl is required to cycle audio outputs.'
  exit 1
}
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::log_note '  › would cycle the default audio output'
  exit 0
fi

sinks=()
while IFS=$'\t' read -r _ sink _; do
  [[ -n ${sink} ]] || continue
  output_is_excluded "${sink}" || sinks+=("${sink}")
done < <(pactl list short sinks)
((${#sinks[@]})) || {
  jsh::log_error 'No enabled audio output is available.'
  exit 1
}
current=$(pactl get-default-sink 2>/dev/null || true)
target=${sinks[0]}
for index in "${!sinks[@]}"; do
  [[ ${sinks[${index}]} == "${current}" ]] || continue
  target=${sinks[$(((index + 1) % ${#sinks[@]}))]}
  break
done
pactl set-default-sink "${target}"
while IFS=$'\t' read -r sink_input _; do
  [[ ${sink_input} =~ ^[0-9]+$ ]] && pactl move-sink-input "${sink_input}" "${target}" || true
done < <(pactl list short sink-inputs)
description=$(pactl list sinks | awk -v target="${target}" '
  /^[[:space:]]*Name:/ { name=$2 }
  /^[[:space:]]*Description:/ && name == target {
    sub(/^[[:space:]]*Description:[[:space:]]*/, ""); print; exit
  }')
if command -v notify-send >/dev/null 2>&1; then
  notify-send --replace-id=73943 'Audio Output' "${description:-${target}}"
else
  jsh::log_info "${description:-${target}}"
fi
