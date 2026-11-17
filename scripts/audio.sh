#!/usr/bin/env bash
# Configure Linux audio policy, Wave:3 access, and the output shortcut.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
[[ ${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce ]] ||
  jsh::skip "audio policy: no GNOME or XFCE session"
source=${JSH_AUDIO_POLICY:-}
[[ -n ${source} || ${JSH_HOST} != colossus ]] || source=${SCRIPT_DIR}/audio/colossus.conf
if [[ ${JSH_HOST} == colossus ]] && command -v pactl >/dev/null 2>&1; then
  jsh::step check "Wave:3 device access"
  jsh::system_file "${SCRIPT_DIR}/audio/70-jsh-wave3.rules" /etc/udev/rules.d/70-jsh-wave3.rules
  if ((JSH_FILE_CHANGED)); then
    jsh::root udevadm control --reload
    jsh::root udevadm trigger --action=change --subsystem-match=usb --attr-match=idVendor=0fd9 --attr-match=idProduct=0070
    jsh::root udevadm settle
    jsh::changed "Wave:3 udev rules reloaded" "Wave:3 udev rules need a reload"
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
  jsh::step check "WirePlumber audio policy"
  target=${XDG_CONFIG_HOME:-${HOME}/.config}/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf
  changed=0
  cmp -s -- "${source}" "${target}" || changed=1
  jsh::file "${source}" "${target}"
  if ((changed)) && command -v systemctl >/dev/null 2>&1; then
    jsh::task 'restarting WirePlumber' systemctl --user restart wireplumber.service
    jsh::changed "WirePlumber restarted" "WirePlumber needs a restart"
  fi
fi
if command -v pactl >/dev/null 2>&1; then
  jsh::step check "audio output shortcut"
  jsh::shortcut 'Jsh audio output' '<Control><Alt><Super>a' '<Primary><Alt><Super>a' \
    "bash '${SCRIPT_DIR}/audio/cycle.sh' cycle"
fi
