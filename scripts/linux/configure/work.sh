#!/usr/bin/env bash
# Configure opt-in Linux Citrix, Zoom, and Zoom VDI integration.

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

aur_helper() {
  command -v yay 2> /dev/null || command -v paru 2> /dev/null
}

install_citrix_debian() {
  local page download_path version url installed
  [[ $(uname -m) == x86_64 ]] || {
    jsh_note "Citrix Workspace is unavailable for architecture $(uname -m)."
    return
  }
  page=$(curl -fsSL 'https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html')
  download_path=$(grep -Eo 'rel="//downloads[.]citrix[.]com/[^"?]*icaclient-gcc-8_[0-9A-Za-z.+:~-]+_amd64[.]deb[^"]*"' <<< "${page}" |
    head -n 1 | cut -d'"' -f2)
  [[ -n ${download_path} ]] || {
    jsh_error 'Unable to locate the Citrix Workspace Debian package.'
    return 1
  }
  version=$(sed -nE 's#.+icaclient-gcc-8_([^_]+)_amd64[.]deb.*#\1#p' <<< "${download_path}")
  url=https:${download_path}
  installed=$(jsh_debian_installed_version icaclient || true)
  if { [[ -z ${installed} ]] || ! dpkg --compare-versions "${installed}" ge "${version}"; } &&
    [[ ${JSH_CONFIGURE_DRY_RUN:-0} != 1 && ${JSH_INSTALL_DRY_RUN:-0} != 1 ]]; then
    printf 'icaclient app_protection/install_app_protection select no\n' |
      jsh_run_root debconf-set-selections
  fi
  jsh_debian_install_package citrix icaclient "${version}" "${url}" '' wfica ctxwebhelper
}

install_zoom_debian() {
  local url version
  [[ $(uname -m) == x86_64 ]] || {
    jsh_note "Zoom is unavailable for architecture $(uname -m)."
    return
  }
  url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' 'https://zoom.us/client/latest/zoom_amd64.deb')
  version=$(sed -nE 's#.+/prod/([^/]+)/.+#\1#p' <<< "${url}")
  [[ -n ${version} ]] || {
    jsh_error 'Unable to resolve the latest Zoom Debian package.'
    return 1
  }
  jsh_debian_install_package zoom zoom "${version}" "${url}" '' zoom
}

install_citrix_fedora() {
  local arch arch_pattern page_content download_path url temporary_dir package mgr

  citrix_healthy && return 0
  if rpm -q ICAClient > /dev/null 2>&1; then
    return 0
  fi

  arch=$(uname -m)
  case "${arch}" in
    x86_64) arch_pattern='x86_64\.rpm' ;;
    aarch64 | arm64) arch_pattern='aarch64\.rpm' ;;
    *)
      jsh_note "Citrix Workspace is unavailable for architecture ${arch}."
      return 0
      ;;
  esac

  if [[ "${JSH_CONFIGURE_DRY_RUN:-0}" == 1 || "${JSH_INSTALL_DRY_RUN:-0}" == 1 ]]; then
    jsh_detail "Would download and install Citrix Workspace for Fedora (${arch})"
    return 0
  fi

  jsh_info "Downloading Citrix Workspace for Fedora..."
  page_content=$(curl -sL 'https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html')
  download_path=$(printf '%s\n' "${page_content}" | \
    grep -o "rel=\"//downloads\.citrix\.com/[^\"]*${arch_pattern}[^\"]*\"" | \
    grep -E 'ICAClient-rhel' | head -n 1 | cut -d'"' -f2)
  if [[ -z "${download_path}" ]]; then
    jsh_error "Unable to locate Citrix Workspace RPM package download URL."
    return 1
  fi

  url="https:${download_path}"
  mkdir -p "${JSH_ROOT}/tmp"
  temporary_dir=$(mktemp -d "${JSH_ROOT}/tmp/citrix.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary_dir}"
  package="${temporary_dir}/ICAClient.rpm"

  if ! curl --fail --location --retry 2 --output "${package}" "${url}"; then
    rm -rf -- "${temporary_dir}"
    jsh_error "Failed to download Citrix Workspace package from ${url}."
    return 1
  fi

  mgr="dnf"
  command -v dnf5 > /dev/null 2>&1 && mgr="dnf5"

  jsh_info "Installing Citrix Workspace..."
  jsh_run_root "${mgr}" install -y -- "${package}"
  rm -rf -- "${temporary_dir}"
  jsh_success "Citrix Workspace installed."
}

install_zoom_fedora() {
  local arch url temporary_dir package mgr

  if command -v zoom > /dev/null 2>&1 || rpm -q zoom > /dev/null 2>&1; then
    return 0
  fi

  arch=$(uname -m)
  case "${arch}" in
    x86_64) url="https://zoom.us/client/latest/zoom_x86_64.rpm" ;;
    aarch64 | arm64) url="https://zoom.us/client/latest/zoom_aarch64.rpm" ;;
    *)
      jsh_note "Zoom is unavailable for architecture ${arch}."
      return 0
      ;;
  esac

  if [[ "${JSH_CONFIGURE_DRY_RUN:-0}" == 1 || "${JSH_INSTALL_DRY_RUN:-0}" == 1 ]]; then
    jsh_detail "Would download and install Zoom for Fedora (${arch})"
    return 0
  fi

  jsh_info "Downloading Zoom for Fedora..."
  mkdir -p "${JSH_ROOT}/tmp"
  temporary_dir=$(mktemp -d "${JSH_ROOT}/tmp/zoom.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary_dir}"
  package="${temporary_dir}/zoom.rpm"

  if ! curl --fail --location --retry 2 --output "${package}" "${url}"; then
    rm -rf -- "${temporary_dir}"
    jsh_error "Failed to download Zoom package from ${url}."
    return 1
  fi

  mgr="dnf"
  command -v dnf5 > /dev/null 2>&1 && mgr="dnf5"

  jsh_info "Installing Zoom..."
  jsh_run_root "${mgr}" install -y -- "${package}"
  rm -rf -- "${temporary_dir}"
  jsh_success "Zoom installed."
}

install_work_packages() {
  local family helper package
  local -a missing=()
  family=$(jsh_linux_family)
  case "${family}" in
    arch)
      helper=$(aur_helper) || {
        jsh_error "yay or paru is required; run make install first."
        return 1
      }
      for package in icaclient zoom; do
        pacman -Q "${package}" > /dev/null 2>&1 || missing+=("${package}")
      done
      ((${#missing[@]} == 0)) || "${helper}" -S --needed --noconfirm -- "${missing[@]}"
      ;;
    debian)
      install_citrix_debian
      install_zoom_debian
      ;;
    fedora)
      install_citrix_fedora
      install_zoom_fedora
      ;;
    *)
      jsh_note "Automatic Citrix and Zoom package installation is unavailable for ${family}; using existing installations."
      ;;
  esac
}

citrix_healthy() {
  [[ -x "${CITRIX_ROOT}/wfica.sh" && -x "${CITRIX_ROOT}/wfica" &&
    -x "${CITRIX_ROOT}/util/ctxwebhelper" ]]
}

configure_citrix() {
  local applications=${XDG_DATA_HOME:-${HOME}/.local/share}/applications
  local temporary filename name executable argument mime current changed=0 ensure_status
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp -d "${JSH_ROOT}/tmp/citrix-config.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"

  while IFS=$'\t' read -r filename name executable argument mime; do
    {
      printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\n' "${name}"
      printf 'TryExec=%s\n' "${CITRIX_ROOT}/${executable}"
      printf 'Exec=%s %s\n' "$(jsh_desktop_executable "${CITRIX_ROOT}/${executable}")" "${argument}"
      printf 'Icon=%s\nMimeType=%s;\n' "${CITRIX_ROOT}/icons/receiver.png" "${mime}"
    } > "${temporary}/${filename}"
    if jsh_ensure_file "${applications}/${filename}" "${temporary}/${filename}" 0644; then
      changed=1
    else
      ensure_status=$?
      [[ ${ensure_status} == 1 ]] || { rm -rf -- "${temporary}"; return "${ensure_status}"; }
    fi
    current=$(xdg-mime query default "${mime}")
    if [[ ${current} != "${filename}" ]]; then
      xdg-mime default "${filename}" "${mime}"
      [[ $(xdg-mime query default "${mime}") == "${filename}" ]] || {
        jsh_error "MIME association did not take effect: ${mime}"
        rm -rf -- "${temporary}"
        return 1
      }
    fi
  done <<'EOF'
jsh-citrix-ica.desktop	Citrix Workspace ICA Launcher	wfica.sh	%f	application/x-ica
jsh-citrix-receiver.desktop	Citrix Workspace Receiver Launcher	util/ctxwebhelper	%u	x-scheme-handler/receiver
EOF

  configure_citrix_preferences "${temporary}"
  ((changed == 0)) || update-desktop-database "${applications}"
  rm -rf -- "${temporary}"
}

configure_citrix_preferences() {
  local temporary_dir=$1 settings=${HOME}/.ICAClient/wfclient.ini source candidate ensure_status
  source=${settings}
  if [[ ! -f ${source} ]]; then
    source=${temporary_dir}/wfclient.default.ini
    printf '[WFClient]\nVersion = 2\n' > "${source}"
  fi
  candidate=${temporary_dir}/wfclient.ini
  awk '
    function emit_key() { if (inside && !found_key) { print "MouseSendsControlV=False"; found_key=1 } }
    /^[[:space:]]*\[/ {
      emit_key()
      inside=(tolower($0) == "[wfclient]")
      if (inside) found_section=1
    }
    inside && /^[[:space:]]*MouseSendsControlV[[:space:]]*=/ {
      if (!found_key) { print "MouseSendsControlV=False"; found_key=1 }
      next
    }
    { print }
    END {
      emit_key()
      if (!found_section) print "\n[WFClient]"
      if (!found_key) print "MouseSendsControlV=False"
    }
  ' "${source}" > "${candidate}"
  jsh_ensure_file "${settings}" "${candidate}" 0600 || {
    ensure_status=$?
    [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
  }
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
  jsh_run_root ln -sfn "${ZOOM_VDI_LIBRARY}" "${CITRIX_ROOT}/ZoomMedia.so"
  temporary=$(mktemp "${JSH_ROOT}/tmp/module.ini.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
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
    jsh_interrupt_cleanup_path "${replacement}"
    awk '/^\[ZoomMedia\]$/ { print; print "DriverName=ZoomMedia.so"; section=1; next }
      section && /^\[/ { section=0 } section && /^DriverName=/ { next } { print }' \
      "${temporary}" > "${replacement}"
    mv "${replacement}" "${temporary}"
  fi
  backup="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d%H%M%S)${module}"
  mkdir -p "$(dirname -- "${backup}")"
  jsh_run_root cat "${module}" > "${backup}"
  chmod 0600 "${backup}"
  jsh_run_root install -m 0644 "${temporary}" "${module}"
  rm -f "${temporary}"
  jsh_detail "Backup: ${backup}"
}

install_zoom_vdi() {
  local family temporary_dir package build_dir package_file actual url installed_version
  if zoom_vdi_healthy; then
    if [[ $(jsh_linux_family) != debian ]]; then return 0; fi
    installed_version=$(dpkg-query -W -f='${Version}' zoomvdi-universal-plugin)
    [[ ${installed_version} == "${ZOOM_VDI_VERSION}"-* ]] && return 0
    jsh_error "Zoom VDI version differs from the approved version: ${installed_version} (expected ${ZOOM_VDI_VERSION})."
    return 1
  fi
  [[ "${ZOOM_VDI_VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ &&
    "${ZOOM_VDI_RELEASE}" =~ ^[0-9]+(\.[0-9]+)*$ &&
    "${ZOOM_VDI_SHA256}" =~ ^[0-9a-f]{64}$ ]] || {
    jsh_error "Invalid Zoom VDI version or checksum."
    return 1
  }
  if [[ ! -r "${ZOOM_VDI_LIBRARY}" ]]; then
    family=$(jsh_linux_family)
    if [[ "${family}" == debian ]]; then
      jsh_info "Installing Zoom VDI for Debian..."
      mkdir -p "${JSH_ROOT}/tmp"
      temporary_dir=$(mktemp -d "${JSH_ROOT}/tmp/zoom-vdi.XXXXXX")
      jsh_interrupt_cleanup_path "${temporary_dir}"
      trap 'rm -rf -- "${temporary_dir}"' RETURN
      package="${temporary_dir}/zoomvdi.deb"
      url="https://zoom.us/download/vdi/${ZOOM_VDI_VERSION}/zoomvdi-universal-plugin-ubuntu_${ZOOM_VDI_RELEASE}.deb"
      curl --fail --location --retry 2 --output "${package}" "${url}"
      actual=$(sha256sum "${package}" | awk '{ print $1 }')
      if [[ "${actual}" != "${ZOOM_VDI_SHA256}" ]]; then
        jsh_error "Zoom VDI package checksum verification failed."
        return 1
      fi
      jsh_run_root apt-get install -y -- "${package}"
      rm -rf -- "${temporary_dir}"
      trap - RETURN
    elif [[ "${family}" == arch ]]; then
      [[ "$(id -u)" -ne 0 ]] || {
        jsh_error "Zoom VDI must be built as a regular user."
        return 1
      }
      mkdir -p "${JSH_ROOT}/tmp"
      temporary_dir=$(mktemp -d "${JSH_ROOT}/tmp/zoom-vdi.XXXXXX")
      jsh_interrupt_cleanup_path "${temporary_dir}"
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
      jsh_run_root pacman -U --noconfirm -- "${package_file}"
      rm -rf -- "${temporary_dir}"
      trap - RETURN
    else
      jsh_note "Skipping Zoom VDI installation on ${family}; install the vendor plugin before rerunning this setup."
      return
    fi
  fi
  register_zoom_vdi
  zoom_vdi_healthy
}

main() {
  local arg answer
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) JSH_ASSUME_YES=1 ;;
    esac
  done

  [[ "$(uname -s)" == Linux ]] || return
  jsh_detail "This configures Citrix Workspace, Zoom, and the checksum-pinned Zoom VDI integration."
  if [[ ${JSH_ASSUME_YES:-0} != 1 ]]; then
    jsh_prompt "Configure the Linux work environment? [y/N]: "
    read -r answer || answer=
    [[ "${answer}" =~ ^[Yy]$ ]] || {
      jsh_note "Skipping Linux work environment."
      return
    }
  fi

  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 || ${JSH_INSTALL_DRY_RUN:-0} == 1 ]]; then
    jsh_detail "Would inspect/install Citrix, Zoom and VDI, then reconcile their integration."
    return 0
  fi
  install_work_packages
  if ! citrix_healthy; then
    jsh_error "Citrix Workspace is missing or incomplete under ${CITRIX_ROOT}."
    return 1
  fi
  configure_citrix
  install_zoom_vdi
  jsh_success "Linux work environment configured."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
