#!/usr/bin/env bash
# Build the latest XFCE audio plugin release with its hardware-aware Wave:3 indicator.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT:?}/scripts/lib/common.sh" "$@"
# shellcheck source=ansible/helpers/desktop.sh
. "${JSH_ROOT:?}/ansible/helpers/desktop.sh"
[[ $(uname -s) == Linux && ${JSH_HOST} == colossus && ${JSH_DESKTOP} == xfce ]] ||
  jsh::skip "XFCE audio plugin: requires Linux XFCE on colossus"
command -v apt-get >/dev/null 2>&1 || jsh::skip "XFCE audio plugin: apt-get is not available"
stock=/usr/share/xfce4/panel/plugins/pulseaudio.desktop
target=/usr/share/xfce4/panel/plugins/jsh-pulseaudio.desktop
releases=https://archive.xfce.org/src/panel-plugins/xfce4-pulseaudio-plugin
if ! command -v pkg-config >/dev/null 2>&1 || ! command -v meson >/dev/null 2>&1 || [[ ! -f ${stock} ]]; then
  jsh::notice "XFCE audio plugin build prerequisites are missing; install the desktop packages first"
  exit 0
fi
libdir=$(pkg-config --variable=libdir libxfce4panel-2.0)
[[ -n ${libdir} ]] || {
  jsh::notice 'Missing XFCE panel library directory'
  exit 1
}
library=${libdir}/xfce4/panel/plugins/libjsh-pulseaudio.so
patch=${SCRIPT_DIR}/pulseaudio.patch
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
jsh::step check "XFCE audio plugin"
installed=''
if [[ -f ${library} && -f ${target} ]]; then installed=$(sed -n 's/^X-Jsh-Version=//p' "${target}"); fi
if [[ -n ${installed} && ${JSH_UPDATE:-0} != 1 ]]; then
  describe "${installed}"
  if cmp -s "${descriptor}" "${target}"; then
    jsh::ok "XFCE Wave:3 audio plugin is ${installed}"
    exit 0
  fi
fi
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  if [[ -n ${installed} && ${JSH_UPDATE:-0} == 1 ]]; then
    jsh::info "XFCE Wave:3 audio plugin update is unchecked in preview"
  elif [[ -n ${installed} ]]; then
    jsh::changed "XFCE Wave:3 audio plugin rebuilt" \
      "XFCE Wave:3 audio plugin is out of date"
  else
    jsh::changed "XFCE Wave:3 audio plugin installed" "XFCE Wave:3 audio plugin is missing"
  fi
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
  jsh::ok "XFCE Wave:3 audio plugin is ${version}"
  exit 0
fi
if ! jsh::admin; then
  jsh::notice "XFCE audio plugin ${version} needs sudo; run \`sudo -v\` first, then rerun"
  exit 0
fi
source=${temporary}/xfce4-pulseaudio-plugin-${version}
jsh::download "${releases}/${series}/${asset}" "${temporary}/${asset}"
tar -xf "${temporary}/${asset}" -C "${temporary}"
if [[ ! -f ${source}/meson.build ]] || ! patch -d "${source}" -p1 --dry-run -s -i "${patch}" >/dev/null 2>&1; then
  jsh::notice "ansible/roles/desktop/files/pulseaudio.patch does not apply to XFCE audio plugin ${version}; port it, then rerun${installed:+ (keeping ${installed})}"
  exit 0
fi
jsh::task 'Patching XFCE audio plugin' patch -d "${source}" -p1 -i "${patch}"
jsh::task 'Configuring XFCE audio plugin' meson setup "${source}/build" "${source}" --prefix=/usr "--libdir=${libdir}" --buildtype=release
jsh::task 'Building XFCE audio plugin' meson compile -C "${source}/build"
staged=${library}.$$.tmp
jsh::root install -m 0644 "${source}/build/panel-plugin/libpulseaudio-plugin.so" "${staged}"
jsh::root mv -f -- "${staged}" "${library}"
jsh::system_file "${descriptor}" "${target}"
if [[ -n ${installed} && ${installed} != "${version}" ]]; then
  jsh::changed "XFCE Wave:3 audio plugin set ${version}" \
    "XFCE Wave:3 audio plugin is not ${version}"
else
  jsh::changed "XFCE Wave:3 audio plugin installed at ${version}" \
    "XFCE Wave:3 audio plugin is missing"
fi
