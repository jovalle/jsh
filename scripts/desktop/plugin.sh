#!/usr/bin/env bash
# Build the separate XFCE audio plugin with its hardware-aware Wave:3 indicator.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh" "$@"
jsh::activity 'Checking XFCE audio plugin prerequisites'
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/../lib/desktop.sh"
[[ $(uname -s) == Linux && ${JSH_HOST} == colossus && ${JSH_DESKTOP} == xfce ]] || exit 0
command -v apt-get >/dev/null 2>&1 || exit 0
stock=/usr/share/xfce4/panel/plugins/pulseaudio.desktop
target=/usr/share/xfce4/panel/plugins/jsh-pulseaudio.desktop
if ! command -v pkg-config >/dev/null 2>&1 || [[ ! -f ${stock} ]]; then
  jsh::notice 'XFCE audio plugin build prerequisites are missing; install the desktop packages first'
  exit 0
fi
libdir=$(pkg-config --variable=libdir libxfce4panel-2.0)
[[ -n ${libdir} ]] || {
  jsh::notice 'Missing XFCE panel library directory'
  exit 1
}
library=${libdir}/xfce4/panel/plugins/libjsh-pulseaudio.so
patch=${SCRIPT_DIR}/audio/pulseaudio.patch
sha=a0807615fb2848d0361b7e4568a44f26d189fda48011c7ba074986c8bfddc99a
fingerprint=$({
  cat "${patch}"
  printf '%s' "${sha}"
} | sha256sum)
fingerprint=${fingerprint%% *}
temporary=$(jsh::temp)
descriptor=${temporary}/jsh-pulseaudio.desktop
sed 's/X-XFCE-Module=pulseaudio-plugin/X-XFCE-Module=jsh-pulseaudio/' "${stock}" >"${descriptor}"
cmp -s "${stock}" "${descriptor}" && {
  jsh::notice 'Unrecognized XFCE audio plugin descriptor'
  exit 1
}
printf '\nX-Jsh-Fingerprint=%s\n' "${fingerprint}" >>"${descriptor}"
if [[ -f ${library} ]] && cmp -s "${descriptor}" "${target}"; then
  jsh::current
  exit 0
fi
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::changed 'XFCE Wave:3 audio plugin'
  exit 0
fi
if ! jsh::admin; then
  jsh::notice 'XFCE audio plugin needs sudo; run sudo -v first, then rerun'
  exit 0
fi
archive=${temporary}/plugin.tar.bz2
jsh::download 'https://deb.debian.org/debian/pool/main/x/xfce4-pulseaudio-plugin/xfce4-pulseaudio-plugin_0.4.9.orig.tar.bz2' "${archive}"
printf '%s  %s\n' "${sha}" "${archive}" | sha256sum -c - >/dev/null
# Extract only the known upstream release after checking its pinned digest.
tar -xjf "${archive}" -C "${temporary}"
(
  cd "${temporary}/xfce4-pulseaudio-plugin-0.4.9"
  jsh::task 'Patching XFCE audio plugin' patch -p1 -i "${patch}"
  jsh::task 'Configuring XFCE audio plugin' ./configure --prefix=/usr "--libdir=${libdir}"
  jsh::task 'Building XFCE audio plugin' make -j2
)
staged=${library}.$$.tmp
jsh::root install -m 0644 "${temporary}/xfce4-pulseaudio-plugin-0.4.9/panel-plugin/.libs/libpulseaudio-plugin.so" "${staged}"
jsh::root mv -f -- "${staged}" "${library}"
jsh::system_file "${descriptor}" "${target}"
if command -v xfce4-panel >/dev/null 2>&1 && pgrep -x xfce4-panel >/dev/null 2>&1; then
  jsh::run xfce4-panel -r || true
fi
jsh::changed 'XFCE Wave:3 audio plugin'
