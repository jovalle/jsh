#!/usr/bin/env bash
# Configure opt-in EndeavourOS Citrix, Zoom, and Zoom VDI integration.

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

readonly CITRIX_ROOT=${CITRIX_ROOT:-/opt/Citrix/ICAClient}
readonly ZOOM_VDI_VERSION=${JSH_ZOOM_VDI_VERSION:-6.4.16.26870}
readonly ZOOM_VDI_RELEASE=${JSH_ZOOM_VDI_RELEASE:-6.4.16}
readonly ZOOM_VDI_SHA256=${JSH_ZOOM_VDI_SHA256:-d6de6898132f8db425c6085bc8325ccf1813f7f6da6a73d5691a4b20dfabd220}
readonly ZOOM_VDI_LIBRARY=/usr/lib/zoomvdi-universal-plugin/libZoomPlugin.so

is_endeavouros() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1
  local ID=
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ "${ID:-}" == endeavouros ]]
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -- "$@"
  fi
}

aur_helper() {
  command -v yay 2> /dev/null || command -v paru 2> /dev/null
}

install_work_packages() {
  local helper package
  local -a missing=()
  helper=$(aur_helper) || {
    jsh_error "yay or paru is required; run make install first."
    return 1
  }
  for package in icaclient zoom; do
    pacman -Q "${package}" > /dev/null 2>&1 || missing+=("${package}")
  done
  ((${#missing[@]} == 0)) || "${helper}" -S --needed --noconfirm -- "${missing[@]}"
}

citrix_healthy() {
  [[ -x "${CITRIX_ROOT}/wfica.sh" && -x "${CITRIX_ROOT}/wfica" &&
    -x "${CITRIX_ROOT}/util/ctxwebhelper" ]]
}

configure_citrix() {
  local application_dir="${HOME}/.local/share/applications"
  local settings_dir="${HOME}/.ICAClient"
  local settings="${settings_dir}/wfclient.ini" temporary
  mkdir -p "${application_dir}" "${settings_dir}"
  cat > "${application_dir}/jsh-citrix-ica.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Citrix Workspace ICA Launcher
NoDisplay=true
TryExec=${CITRIX_ROOT}/wfica.sh
Exec=${CITRIX_ROOT}/wfica.sh %f
Icon=${CITRIX_ROOT}/icons/receiver.png
MimeType=application/x-ica;
EOF
  cat > "${application_dir}/jsh-citrix-receiver.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Citrix Workspace Receiver Launcher
NoDisplay=true
TryExec=${CITRIX_ROOT}/util/ctxwebhelper
Exec=${CITRIX_ROOT}/util/ctxwebhelper %u
Icon=${CITRIX_ROOT}/icons/receiver.png
MimeType=x-scheme-handler/receiver;
EOF
  temporary=$(mktemp "${settings}.XXXXXX")
  if [[ -r "${settings}" ]]; then
    awk '
      BEGIN { found=0; section=0 }
      /^\[WFClient\]$/ { print; section=1; next }
      /^\[/ { if (section && !found) print "MouseSendsControlV=False"; section=0 }
      /^[[:space:]]*MouseSendsControlV[[:space:]]*=/ {
        if (!found) print "MouseSendsControlV=False"; found=1; next
      }
      { print }
      END { if (!found) { if (!section) print "[WFClient]"; print "MouseSendsControlV=False" } }
    ' "${settings}" > "${temporary}"
  else
    printf '[WFClient]\nVersion = 2\nMouseSendsControlV=False\n' > "${temporary}"
  fi
  install -m 0600 "${temporary}" "${settings}"
  rm -f "${temporary}"
  update-desktop-database "${application_dir}" > /dev/null 2>&1 || true
  xdg-mime default jsh-citrix-ica.desktop application/x-ica
  xdg-mime default jsh-citrix-receiver.desktop x-scheme-handler/receiver
}

zoom_vdi_healthy() {
  local module="${CITRIX_ROOT}/config/module.ini"
  [[ -r "${ZOOM_VDI_LIBRARY}" && -L "${CITRIX_ROOT}/ZoomMedia.so" ]] || return 1
  [[ "$(readlink -f "${CITRIX_ROOT}/ZoomMedia.so")" == "${ZOOM_VDI_LIBRARY}" ]] || return 1
  grep -Eq '^VirtualDriver[[:space:]]*=([[:space:]]*|.*[,[:space:]])ZoomMedia([,[:space:]]|$)' "${module}" &&
    grep -q '^\[ZoomMedia\]$' "${module}" && grep -q '^DriverName=ZoomMedia\.so$' "${module}"
}

register_zoom_vdi() {
  local module="${CITRIX_ROOT}/config/module.ini" temporary replacement backup
  run_root ln -sfn "${ZOOM_VDI_LIBRARY}" "${CITRIX_ROOT}/ZoomMedia.so"
  temporary=$(mktemp "${JSH_ROOT}/tmp/module.ini.XXXXXX")
  cp "${module}" "${temporary}"
  if ! grep -Eq '^VirtualDriver[[:space:]]*=([[:space:]]*|.*[,[:space:]])ZoomMedia([,[:space:]]|$)' "${temporary}"; then
    sed -i.bak '/^VirtualDriver[[:space:]]*=/ s/$/, ZoomMedia/' "${temporary}"
    rm -f "${temporary}.bak"
  fi
  if ! grep -q '^\[ZoomMedia\]$' "${temporary}"; then
    printf '\nZoomMedia=On\n\n[ZoomMedia]\nDriverName=ZoomMedia.so\n' >> "${temporary}"
  elif ! awk '/^\[ZoomMedia\]$/ { section=1; next } section && /^\[/ { section=0 }
    section && /^DriverName=ZoomMedia\.so$/ { found=1 } END { exit !found }' "${temporary}"; then
    replacement=$(mktemp "${JSH_ROOT}/tmp/module.ini.XXXXXX")
    awk '/^\[ZoomMedia\]$/ { print; print "DriverName=ZoomMedia.so"; section=1; next }
      section && /^\[/ { section=0 } section && /^DriverName=/ { next } { print }' \
      "${temporary}" > "${replacement}"
    mv "${replacement}" "${temporary}"
  fi
  backup="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d%H%M%S)${module}"
  mkdir -p "$(dirname -- "${backup}")"
  if [[ "$(id -u)" -eq 0 ]]; then
    cat "${module}" > "${backup}"
  else
    sudo cat "${module}" | command cat > "${backup}"
  fi
  chmod 0600 "${backup}"
  run_root install -m 0644 "${temporary}" "${module}"
  rm -f "${temporary}"
  jsh_detail "Backup: ${backup}"
}

install_zoom_vdi() {
  local temporary_dir package build_dir package_file actual url
  zoom_vdi_healthy && return
  [[ "${ZOOM_VDI_VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ &&
    "${ZOOM_VDI_RELEASE}" =~ ^[0-9]+(\.[0-9]+)*$ &&
    "${ZOOM_VDI_SHA256}" =~ ^[0-9a-f]{64}$ ]] || {
    jsh_error "Invalid Zoom VDI version or checksum."
    return 1
  }
  if [[ ! -r "${ZOOM_VDI_LIBRARY}" ]]; then
    [[ "$(id -u)" -ne 0 ]] || {
      jsh_error "Zoom VDI must be built as a regular user."
      return 1
    }
    mkdir -p "${JSH_ROOT}/tmp"
    temporary_dir=$(mktemp -d "${JSH_ROOT}/tmp/zoom-vdi.XXXXXX")
    trap 'rm -rf -- "${temporary_dir}"' RETURN
    package="${temporary_dir}/zoomvdi.deb"
    url="https://zoom.us/download/vdi/${ZOOM_VDI_VERSION}/zoomvdi-universal-plugin-ubuntu_${ZOOM_VDI_RELEASE}.deb"
    curl --fail --location --retry 2 --output "${package}" "${url}"
    actual=$(sha256sum "${package}" | awk '{ print $1 }')
    [[ "${actual}" == "${ZOOM_VDI_SHA256}" ]] || {
      jsh_error "Zoom VDI package checksum verification failed."
      return 1
    }
    build_dir="${temporary_dir}/build"
    mkdir -p "${build_dir}"
    cp "${package}" "${build_dir}/zoomvdi.deb"
    cat > "${build_dir}/PKGBUILD" << EOF
pkgname=zoomvdi-universal-plugin
pkgver=${ZOOM_VDI_VERSION}
pkgrel=1
pkgdesc='Zoom VDI Universal Plugin for Citrix Workspace'
arch=('x86_64')
url='https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0063810'
license=('custom')
depends=('glib2' 'libxcb' 'dbus' 'libpulse' 'freetype2' 'mesa')
options=('!strip')
source=('zoomvdi.deb')
sha256sums=('${actual}')
package() {
  local data_member
  data_member="\$(bsdtar -tf \"\$srcdir/zoomvdi.deb\" | awk '/^data\\.tar/ { print; exit }')"
  bsdtar -xOf "\$srcdir/zoomvdi.deb" "\$data_member" | bsdtar -xf - -C "\$pkgdir"
}
EOF
    (cd "${build_dir}" && makepkg --force --noconfirm)
    package_file=$(find "${build_dir}" -maxdepth 1 -name 'zoomvdi-universal-plugin-*.pkg.tar.*' -print -quit)
    [[ -r "${package_file}" ]] || {
      jsh_error "Zoom VDI package build failed."
      return 1
    }
    run_root pacman -U --noconfirm -- "${package_file}"
  fi
  register_zoom_vdi
  zoom_vdi_healthy
}

main() {
  [[ "$(uname -s)" == Linux ]] || return
  is_endeavouros || {
    jsh_info "Skipping work setup: EndeavourOS not detected."
    return
  }
  jsh_warn "This installs Citrix Workspace, Zoom, and a checksum-pinned Zoom VDI plugin."
  jsh_prompt "Configure the EndeavourOS work environment? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_warn "Skipping EndeavourOS work environment."
    return
  }

  install_work_packages
  citrix_healthy || {
    jsh_error "Citrix Workspace is incomplete under ${CITRIX_ROOT}."
    return 1
  }
  configure_citrix
  install_zoom_vdi
  jsh_success "EndeavourOS work environment configured."
}

main "$@"
