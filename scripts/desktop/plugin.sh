#!/usr/bin/env bash
# Build the latest XFCE audio plugin release with its hardware-aware Wave:3 indicator.

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
releases=https://archive.xfce.org/src/panel-plugins/xfce4-pulseaudio-plugin
if ! command -v pkg-config >/dev/null 2>&1 || ! command -v meson >/dev/null 2>&1 || [[ ! -f ${stock} ]]; then
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
fingerprint=$(sha256sum <"${patch}")
fingerprint=${fingerprint%% *}
temporary=$(jsh::temp)
descriptor=${temporary}/jsh-pulseaudio.desktop
describe() {
  sed 's/X-XFCE-Module=pulseaudio-plugin/X-XFCE-Module=jsh-pulseaudio/' "${stock}" >"${descriptor}"
  cmp -s "${stock}" "${descriptor}" && {
    jsh::notice 'Unrecognized XFCE audio plugin descriptor'
    exit 1
  }
  printf '\nX-Jsh-Fingerprint=%s\nX-Jsh-Version=%s\n' "${fingerprint}" "$1" >>"${descriptor}"
}
installed=''
if [[ -f ${library} && -f ${target} ]]; then installed=$(sed -n 's/^X-Jsh-Version=//p' "${target}"); fi
if [[ -n ${installed} && ${JSH_UPDATE:-0} != 1 ]]; then
  describe "${installed}"
  if cmp -s "${descriptor}" "${target}"; then
    jsh::current
    exit 0
  fi
fi
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  if [[ -n ${installed} ]]; then jsh::notice 'would check for an XFCE audio plugin update'; else jsh::changed 'XFCE Wave:3 audio plugin'; fi
  exit 0
fi
jsh::download "${releases}/" "${temporary}/series.html"
series=$(grep -oE 'href="[0-9]+\.[0-9]+/"' "${temporary}/series.html" | grep -oE '[0-9]+\.[0-9]+' | sort -V | tail -n 1)
[[ -n ${series} ]] || {
  jsh::notice 'No XFCE audio plugin releases found'
  exit 1
}
jsh::download "${releases}/${series}/" "${temporary}/releases.html"
asset=$(grep -oE 'xfce4-pulseaudio-plugin-[0-9]+(\.[0-9]+)+\.tar\.(xz|bz2)' "${temporary}/releases.html" | sort -u -V | tail -n 1)
version=${asset#xfce4-pulseaudio-plugin-}
version=${version%.tar.*}
[[ -n ${asset} ]] || {
  jsh::notice "No XFCE audio plugin release found in ${series}"
  exit 1
}
describe "${version}"
if [[ -f ${library} ]] && cmp -s "${descriptor}" "${target}"; then
  jsh::current
  exit 0
fi
if ! jsh::admin; then
  jsh::notice "XFCE audio plugin ${version} needs sudo; run sudo -v first, then rerun"
  exit 0
fi
source=${temporary}/xfce4-pulseaudio-plugin-${version}
jsh::download "${releases}/${series}/${asset}" "${temporary}/${asset}"
tar -xf "${temporary}/${asset}" -C "${temporary}"
if [[ ! -f ${source}/meson.build ]] || ! patch -d "${source}" -p1 --dry-run -s -i "${patch}" >/dev/null 2>&1; then
  jsh::notice "scripts/desktop/audio/pulseaudio.patch does not apply to XFCE audio plugin ${version}; port it, then rerun${installed:+ (keeping ${installed})}"
  exit 0
fi
jsh::task 'Patching XFCE audio plugin' patch -d "${source}" -p1 -i "${patch}"
jsh::task 'Configuring XFCE audio plugin' meson setup "${source}/build" "${source}" --prefix=/usr "--libdir=${libdir}" --buildtype=release
jsh::task 'Building XFCE audio plugin' meson compile -C "${source}/build"
staged=${library}.$$.tmp
jsh::root install -m 0644 "${source}/build/panel-plugin/libpulseaudio-plugin.so" "${staged}"
jsh::root mv -f -- "${staged}" "${library}"
jsh::system_file "${descriptor}" "${target}"
if command -v xfce4-panel >/dev/null 2>&1 && pgrep -x xfce4-panel >/dev/null 2>&1; then
  jsh::run xfce4-panel -r || true
fi
if [[ -n ${installed} && ${installed} != "${version}" ]]; then
  jsh::changed "XFCE Wave:3 audio plugin ${installed} → ${version}"
else
  jsh::changed "XFCE Wave:3 audio plugin ${version}"
fi
