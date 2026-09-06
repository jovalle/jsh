#!/usr/bin/env bash
# Configure EndeavourOS audio policy and provide an output-cycling command.

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

readonly BINDING='Control+Mod1+Mod4 + a'
readonly BLOCK_START='# jsh audio output: start'
readonly BLOCK_END='# jsh audio output: end'

is_endeavouros() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1
  local ID=
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ "${ID:-}" == endeavouros ]]
}

output_is_excluded() {
  [[ "$1" =~ ^alsa_output\.pci-.*\.HiFi__HDMI[0-9]*__sink$ ||
    "$1" =~ ^alsa_output\.pci-0000_04_00\.6\..*$ ||
    "$1" =~ ^alsa_output\.usb-Elgato_Systems_Elgato_Wave_3_.*$ ]]
}

cycle_output() {
  local current target description index sink_input
  local -a sinks=()
  command -v pactl > /dev/null 2>&1 || {
    jsh_error "pactl is required to cycle audio outputs."
    return 1
  }
  while IFS=$'\t' read -r _ target _; do
    [[ -n "${target}" ]] || continue
    output_is_excluded "${target}" || sinks+=("${target}")
  done < <(pactl list short sinks)
  ((${#sinks[@]} > 0)) || {
    jsh_error "No enabled audio output is available."
    return 1
  }
  current=$(pactl get-default-sink 2> /dev/null || true)
  target=${sinks[0]}
  for index in "${!sinks[@]}"; do
    [[ "${sinks[${index}]}" == "${current}" ]] || continue
    target=${sinks[$(((index + 1) % ${#sinks[@]}))]}
    break
  done
  pactl set-default-sink "${target}"
  while IFS=$'\t' read -r sink_input _; do
    [[ "${sink_input}" =~ ^[0-9]+$ ]] && pactl move-sink-input "${sink_input}" "${target}" || true
  done < <(pactl list short sink-inputs)
  description=$(pactl list sinks | awk -v target="${target}" '
    /^[[:space:]]*Name:/ { name=$2 }
    /^[[:space:]]*Description:/ && name == target {
      sub(/^[[:space:]]*Description:[[:space:]]*/, ""); print; exit
    }')
  if command -v notify-send > /dev/null 2>&1; then
    notify-send --replace-id=73943 'Audio Output' "${description:-${target}}"
  else
    printf '%s\n' "${description:-${target}}"
  fi
}

configure_audio() {
  local policy="${HOME}/.config/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf"
  local bindings="${HOME}/.xbindkeysrc" existing='' cleaned content temporary
  jsh_warn "This will disable selected HDMI, onboard, and Elgato audio nodes."
  jsh_prompt "Configure EndeavourOS audio policy? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_warn "Skipping EndeavourOS audio policy."
    return
  }

  mkdir -p "$(dirname -- "${policy}")"
  cat > "${policy}" << 'EOF'
# Managed by jsh.
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~^alsa_output\\.pci-.*\\.HiFi__HDMI[0-9]*__sink$" } ]
    actions = { update-props = { node.disabled = true } }
  }
  {
    matches = [ { node.name = "~^alsa_output\\.pci-0000_04_00\\.6\\..*$" } ]
    actions = { update-props = { node.disabled = true } }
  }
  {
    matches = [ { node.name = "~^alsa_output\\.usb-Elgato_Systems_Elgato_Wave_3_.*$" } ]
    actions = { update-props = { node.disabled = true } }
  }
  {
    matches = [ { node.name = "~^alsa_input\\..*$" } ]
    actions = { update-props = { node.disabled = true } }
  }
  {
    matches = [ { node.name = "~^alsa_input\\.usb-Elgato_Systems_Elgato_Wave_3_.*$" } ]
    actions = { update-props = { node.disabled = false } }
  }
]
EOF

  [[ ! -r "${bindings}" ]] || existing=$(< "${bindings}")
  cleaned=$(awk -v start="${BLOCK_START}" -v end="${BLOCK_END}" '
    $0 == start { drop=1; next }
    $0 == end { drop=0; next }
    !drop { print }
  ' <<< "${existing}")
  content="${cleaned%$'\n'}
${BLOCK_START}
\"${SCRIPT_DIR}/audio.sh cycle\"
  ${BINDING}
${BLOCK_END}"
  temporary=$(mktemp "${bindings}.XXXXXX")
  printf '%s\n' "${content}" > "${temporary}"
  install -m 0644 "${temporary}" "${bindings}"
  rm -f "${temporary}"

  systemctl --user restart wireplumber.service
  pkill -HUP -u "$(id -u)" -x xbindkeys 2> /dev/null || xbindkeys
  jsh_success "EndeavourOS audio policy configured."
}

case ${1:-configure} in
  configure)
    [[ "$(uname -s)" == Linux ]] || exit 0
    is_endeavouros || {
      jsh_info "Skipping audio policy: EndeavourOS not detected."
      exit 0
    }
    configure_audio
    ;;
  cycle) cycle_output ;;
  *)
    jsh_error "Usage: $0 [configure|cycle]"
    exit 2
    ;;
esac
