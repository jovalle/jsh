#!/usr/bin/env bash
# Configure Linux audio policy, Wave:3 access, and the output shortcut.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
jsh::activity 'Checking desktop audio support'
[[ ${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce ]] || exit 0
source=${JSH_AUDIO_POLICY:-}
[[ -n ${source} || ${JSH_HOST} != colossus ]] || source=${SCRIPT_DIR}/audio/colossus.conf
if [[ ${JSH_HOST} == colossus ]] && command -v pactl >/dev/null 2>&1; then
  jsh::activity 'Checking Wave:3 device access'
  jsh::system_file "${SCRIPT_DIR}/audio/70-jsh-wave3.rules" /etc/udev/rules.d/70-jsh-wave3.rules
  if ((JSH_FILE_CHANGED)); then
    jsh::root udevadm control --reload
    jsh::root udevadm trigger --action=change --subsystem-match=usb --attr-match=idVendor=0fd9 --attr-match=idProduct=0070
    jsh::root udevadm settle
  fi
  temporary=$(jsh::temp)
  cat >"${temporary}/microphone.desktop" <<ENTRY
[Desktop Entry]
Type=Application
Name=Jsh microphone startup mute
Exec="${JSH_ROOT}/bin/microphone"
OnlyShowIn=XFCE;GNOME;
ENTRY
  jsh::file "${temporary}/microphone.desktop" "${XDG_CONFIG_HOME:-${HOME}/.config}/autostart/jsh-microphone.desktop"
fi
if [[ -n ${source} && -f ${source} ]]; then
  jsh::activity 'Checking WirePlumber audio policy'
  target=${XDG_CONFIG_HOME:-${HOME}/.config}/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf
  changed=0
  cmp -s -- "${source}" "${target}" || changed=1
  jsh::file "${source}" "${target}"
  if ((changed)) && command -v systemctl >/dev/null 2>&1; then
    jsh::activity 'Restarting WirePlumber'
    jsh::run systemctl --user restart wireplumber.service
  fi
fi
if command -v pactl >/dev/null 2>&1; then
  jsh::activity 'Checking audio output shortcut'
  jsh::shortcut 'Jsh audio output' '<Control><Alt><Super>a' '<Primary><Alt><Super>a' \
    "bash '${SCRIPT_DIR}/audio/cycle.sh' cycle"
fi
