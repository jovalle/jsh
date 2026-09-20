#!/usr/bin/env bash
# Configure Linux audio policy and provide an output-cycling command.

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

output_is_excluded() {
  [[ "$1" =~ ^alsa_output\.pci-.*\.HiFi__HDMI[0-9]*__sink$ ||
    "$1" =~ ^alsa_output\.pci-0000_04_00\.6\..*$ ||
    "$1" =~ ^alsa_output\.usb-Elgato_Systems_Elgato_Wave_3_.*$ ]]
}

cycle_output() {
  local current target description index sink_input
  local -a sinks=()
  command -v pactl > /dev/null 2>&1 || {
    jsh::log_error "pactl is required to cycle audio outputs."
    return 1
  }
  while IFS=$'\t' read -r _ target _; do
    [[ -n "${target}" ]] || continue
    output_is_excluded "${target}" || sinks+=("${target}")
  done < <(pactl list short sinks)
  ((${#sinks[@]} > 0)) || {
    jsh::log_error "No enabled audio output is available."
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

configure_audio_shortcut() {
  local command_path="${SCRIPT_DIR}/audio.sh cycle"
  local xfce_binding='/commands/custom/<Primary><Alt><Super>a'
  local desktop
  local bindings="${HOME}/.xbindkeysrc" existing='' cleaned content temporary
  desktop=$(jsh_linux_desktop)
  case "${desktop}" in
    xfce)
      command -v xfconf-query > /dev/null 2>&1 || return 1
      if xfconf-query -c xfce4-keyboard-shortcuts -p "${xfce_binding}" > /dev/null 2>&1; then
        xfconf-query -c xfce4-keyboard-shortcuts -p "${xfce_binding}" -s "${command_path}"
      else
        xfconf-query -c xfce4-keyboard-shortcuts -p "${xfce_binding}" -n -t string -s "${command_path}"
      fi
      ;;
    gnome)
      jsh_gnome_custom_shortcut 'Jsh audio output' '<Control><Alt><Super>a' "${command_path}"
      ;;
    *)
      command -v xbindkeys > /dev/null 2>&1 || return 1
      [[ ! -r "${bindings}" ]] || existing=$(< "${bindings}")
      cleaned=$(awk -v start="${BLOCK_START}" -v end="${BLOCK_END}" '
        $0 == start { drop=1; next }
        $0 == end { drop=0; next }
        !drop { print }
      ' <<< "${existing}")
      content="${cleaned%$'\n'}
${BLOCK_START}
\"${command_path}\"
  ${BINDING}
${BLOCK_END}"
      temporary=$(mktemp "${bindings}.XXXXXX")
      jsh_interrupt_cleanup_path "${temporary}"
      printf '%s\n' "${content}" > "${temporary}"
      install -m 0644 "${temporary}" "${bindings}"
      rm -f "${temporary}"
      pkill -HUP -u "$(id -u)" -x xbindkeys 2> /dev/null || xbindkeys
      ;;
  esac
}

configure_audio() {
  local policy="${HOME}/.config/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf"
  jsh::log_detail "This will disable selected HDMI, onboard, and Elgato audio nodes."
  if ! jsh::confirm "Configure the audio policy?" --default no; then
    jsh::log_note "Skipping audio policy."
    return
  fi

  local temporary changed=0
  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]]; then
    jsh::log_detail "Would compare the personal audio policy and shortcut."
    return 0
  fi
  temporary=$(mktemp)
  jsh_interrupt_cleanup_path "${temporary}"
  local source=${JSH_AUDIO_POLICY:-${JSH_ROOT}/conf/hosts/$(hostname -s)/audio.conf}
  if [[ ! -r ${source} ]]; then
    rm -f "${temporary}"
    jsh::log_note "No audio device policy for this host; keeping existing devices."
    configure_audio_shortcut
    return 0
  fi
  cat "${source}" > "${temporary}"
  if ! cmp -s "${temporary}" "${policy}"; then
    jsh_ensure_file "${policy}" "${temporary}" 0644
    changed=1
  fi
  rm -f "${temporary}"
  configure_audio_shortcut
  ((changed)) || { jsh::log_note "Audio policy is current."; return 0; }
  if command -v systemctl > /dev/null 2>&1; then
    systemctl --user restart wireplumber.service
  else
    jsh::log_note "Restart WirePlumber or log out to load the audio policy."
  fi
  jsh::log_success "Audio policy configured."
}

main() {
  local action=configure arg
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
      configure | cycle) action=${arg} ;;
      *)
        jsh::log_error "Usage: $0 [--yes] [configure|cycle]"
        exit 2
        ;;
    esac
  done

  case "${action}" in
    configure)
      [[ "$(uname -s)" == Linux ]] || exit 0
      configure_audio
      ;;
    cycle) cycle_output ;;
  esac
}

main "$@"
