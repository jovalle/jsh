#!/usr/bin/env bash
# Install distro-native system packages and cross-distribution Flatpak applications.

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

DRY_RUN=${JSH_INSTALL_DRY_RUN:-${JSH_CONFIGURE_DRY_RUN:-0}}
PACKAGE_MANAGER=
MANIFEST_MANAGER=
DISTRO_FAMILY=
NATIVE_PACKAGES=()
FLATPAK_APPLICATIONS=()
NATIVE_PREPARED=0

manifest_list() {
  jsh_manifest_list "$1"
}

confirm() {
  local answer
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  while :; do
    jsh_prompt "$1 [Y/n]: "
    if [[ ${JSH_ASSUME_YES:-0} == 1 ]]; then answer=y; else read -r answer || answer=; fi
    case "${answer}" in
      '' | y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) jsh_warn "Please answer yes or no." ;;
    esac
  done
}

select_native_packages() {
  local native_output flatpak_output

  DISTRO_FAMILY=$(jsh_linux_family)
  case "${DISTRO_FAMILY}" in
    arch)
      PACKAGE_MANAGER=pacman
      MANIFEST_MANAGER=pacman
      ;;
    fedora)
      if command -v dnf5 > /dev/null 2>&1; then
        PACKAGE_MANAGER=dnf5
      else
        PACKAGE_MANAGER=dnf
      fi
      MANIFEST_MANAGER=dnf
      ;;
    debian)
      PACKAGE_MANAGER=apt-get
      MANIFEST_MANAGER=apt
      ;;
    unknown) return 1 ;;
    *) return 1 ;;
  esac
  native_output=$(manifest_list "${MANIFEST_MANAGER}") || return
  flatpak_output=$(manifest_list flatpak) || return
  if [[ -n "${native_output}" ]]; then mapfile -t NATIVE_PACKAGES <<< "${native_output}"; fi
  if [[ -n "${flatpak_output}" ]]; then mapfile -t FLATPAK_APPLICATIONS <<< "${flatpak_output}"; fi
}

package_installed() {
  case "${DISTRO_FAMILY}" in
    arch) pacman -Q "$1" > /dev/null 2>&1 ;;
    fedora) rpm -q "$1" > /dev/null 2>&1 ;;
    debian) dpkg-query -W -f='${db:Status-Status}' "$1" 2> /dev/null | grep -Fxq installed ;;
    *) return 1 ;;
  esac
}

package_available() {
  package_installed "$1" && return
  case "${DISTRO_FAMILY}" in
    arch) pacman -Si "$1" > /dev/null 2>&1 ;;
    fedora) "${PACKAGE_MANAGER}" --quiet list --available "$1" > /dev/null 2>&1 ;;
    debian) apt-cache policy "$1" | awk '$1 == "Candidate:" && $2 != "(none)" { found=1 } END { exit !found }'  ;;
    *) return 1 ;;
  esac
}

install_native_packages() {
  local package
  local -a candidates=() missing=() unavailable=()

  for package in "${NATIVE_PACKAGES[@]}"; do
    package_installed "${package}" || candidates+=("${package}")
  done
  if ((${#candidates[@]} > 0)); then
    prepare_native_packages
  fi
  for package in "${candidates[@]}"; do
    package_installed "${package}" && continue
    if package_available "${package}"; then
      missing+=("${package}")
    else
      unavailable+=("${package}")
    fi
  done
  if ((${#unavailable[@]} > 0)); then
    jsh_error "Unresolved ${DISTRO_FAMILY} packages: ${unavailable[*]}"
    return 1
  fi
  if ((${#missing[@]} > 0)); then
    if [[ "${DRY_RUN}" == 1 ]]; then
      jsh_detail "Would install native packages: ${missing[*]}"
    else
      case "${DISTRO_FAMILY}" in
        arch) jsh_run_root pacman -S --needed --noconfirm -- "${missing[@]}" ;;
        fedora) jsh_run_root "${PACKAGE_MANAGER}" install -y -- "${missing[@]}" ;;
        debian)
          if [[ ${JSH_ASSUME_YES:-0} == 1 ]]; then
            jsh_run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${missing[@]}"
          else
            jsh_run_root apt-get install -y -- "${missing[@]}"
          fi
          ;;
        *) return 1 ;;
      esac
    fi
  fi
  if [[ "${DISTRO_FAMILY}" == debian && "$(jsh_linux_desktop)" == xfce ]] && package_installed xfce4-screensaver && package_installed light-locker; then
    if [[ "${DRY_RUN}" == 1 ]]; then
      jsh_detail "Would remove light-locker (breaks display wakeup; replaced by xfce4-screensaver)."
    else
      jsh_run_root apt-get remove -y light-locker
    fi
  fi
  if [[ ${DRY_RUN} != 1 ]]; then
    for package in "${NATIVE_PACKAGES[@]}"; do
      package_installed "${package}" || { jsh_error "Package verification failed: ${package}"; return 1; }
    done
    if ((${#missing[@]})); then
      jsh_success "Native ${DISTRO_FAMILY} packages are installed."
    else
      jsh_note "Native ${DISTRO_FAMILY} packages are current."
    fi
  fi
}

update_native_packages() {
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would update native ${DISTRO_FAMILY} packages."
    return
  fi
  case "${DISTRO_FAMILY}" in
    arch) jsh_run_root pacman -Syu --noconfirm ;;
    fedora) jsh_run_root "${PACKAGE_MANAGER}" upgrade --refresh -y ;;
    debian)
      jsh_run_root apt-get update
      jsh_run_root apt-get upgrade -y
      ;;
    *) return 1 ;;
  esac
  jsh_success "Native ${DISTRO_FAMILY} packages are up to date."
}

prepare_native_packages() {
  [[ ${NATIVE_PREPARED} == 0 ]] || return
  if [[ ${JSH_UPGRADE_SYSTEM:-0} == 1 || "${DISTRO_FAMILY}" == arch ]]; then
    update_native_packages
  elif [[ "${DISTRO_FAMILY}" == debian ]]; then
    if [[ "${DRY_RUN}" == 1 ]]; then
      jsh_detail "Would refresh Debian package metadata."
    else
      jsh_run_root apt-get update
    fi
  fi
  NATIVE_PREPARED=1
}

install_flatpaks() {
  local application
  local -a missing=()

  for application in "${FLATPAK_APPLICATIONS[@]}"; do
    flatpak info --user "${application}" > /dev/null 2>&1 || missing+=("${application}")
  done
  if ((${#missing[@]} == 0)); then
    jsh_note "Flatpak applications are current."
    return
  fi
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would configure Flathub and install: ${missing[*]}"
    return
  fi
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  for application in "${missing[@]}"; do
    flatpak install --user --noninteractive flathub "${application}"
  done
  for application in "${FLATPAK_APPLICATIONS[@]}"; do
    flatpak info --user "${application}" > /dev/null 2>&1 || {
      jsh_error "Flatpak verification failed: ${application}"
      return 1
    }
  done
  jsh_success "Flatpak applications are installed."
}

update_flatpaks() {
  command -v flatpak > /dev/null 2>&1 || return
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would update user Flatpak applications."
    return
  fi
  flatpak update --user --noninteractive
  jsh_success "Flatpak applications are up to date."
}

configure_native_aliases() {
  local name native executable temporary ensure_status
  for name in fd bat; do
    case ${name} in
      fd) native=fdfind ;;
      bat) native=batcat ;;
    esac
    executable=$(command -v "${native}" 2>/dev/null || true)
    [[ -n ${executable} ]] || continue
    command -v "${name}" >/dev/null 2>&1 && continue
    mkdir -p "${JSH_ROOT}/tmp"
    temporary=$(mktemp "${JSH_ROOT}/tmp/${name}.XXXXXXXXXX")
    jsh_interrupt_cleanup_path "${temporary}"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "${executable}" > "${temporary}"
    jsh_ensure_file "${HOME}/.local/bin/${name}" "${temporary}" 0755 || {
      ensure_status=$?
      rm -f -- "${temporary}"
      [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
    }
    rm -f -- "${temporary}"
  done
}

main() {
  local package platform
  platform=$(uname -s)

  if [[ ${1:-} == --list-installed-packages ]]; then
    [[ "${platform}" == Linux ]] || return 0
    select_native_packages || return 0
    command -v "${PACKAGE_MANAGER}" > /dev/null 2>&1 || return 0
    for package in "${NATIVE_PACKAGES[@]}"; do
      package_installed "${package}" && printf '%s\n' "${package}"
    done
    return 0
  fi

  [[ "${platform}" == Linux ]] || return
  select_native_packages || {
    jsh_note "No native package map for this Linux distribution; using portable installers."
    return
  }

  command -v "${PACKAGE_MANAGER}" > /dev/null 2>&1 || {
    jsh_error "${PACKAGE_MANAGER} is required on ${DISTRO_FAMILY}-family systems."
    return 1
  }
  confirm "Install native ${DISTRO_FAMILY} and Flatpak packages?" || {
    jsh_note "Skipping native packages."
    return 0
  }
  if [[ ${JSH_UPGRADE_SYSTEM:-0} == 1 ]]; then prepare_native_packages; fi
  install_native_packages
  install_flatpaks
  configure_native_aliases
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    update_flatpaks
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
