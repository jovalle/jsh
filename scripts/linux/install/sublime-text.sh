#!/usr/bin/env bash
# Install Sublime Text from its signed native Linux repository.
# shellcheck disable=SC2310

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

readonly SUBLIME_KEY_URL=https://download.sublimetext.com/sublimehq-pub.gpg
readonly SUBLIME_KEY_FINGERPRINT=1EDDE2CDFC025D17F6DA9EC0ADAE6AD28A8F901A
readonly SUBLIME_APT_KEY_PATH=${SUBLIME_APT_KEY_PATH:-/etc/apt/keyrings/sublimehq-pub.gpg}
readonly SUBLIME_APT_SOURCE_PATH=${SUBLIME_APT_SOURCE_PATH:-/etc/apt/sources.list.d/sublime-text.sources}
readonly SUBLIME_RPM_KEY_PATH=${SUBLIME_RPM_KEY_PATH:-/etc/pki/rpm-gpg/RPM-GPG-KEY-sublimehq}
readonly SUBLIME_DNF_REPO_PATH=${SUBLIME_DNF_REPO_PATH:-/etc/yum.repos.d/sublime-text.repo}
readonly SUBLIME_PACMAN_CONF=${SUBLIME_PACMAN_CONF:-/etc/pacman.conf}

sublime_dry_run() {
  [[ ${JSH_INSTALL_DRY_RUN:-${JSH_CONFIGURE_DRY_RUN:-0}} == 1 ]]
}

sublime_package_installed() {
  case $1 in
    arch) pacman -Q sublime-text > /dev/null 2>&1 ;;
    fedora) rpm -q sublime-text > /dev/null 2>&1 ;;
    debian) dpkg-query -W -f='${db:Status-Status}' sublime-text 2> /dev/null | grep -Fxq installed ;;
    *) return 1 ;;
  esac
}

sublime_verify_key() {
  gpg --batch --show-keys --with-colons "$1" 2> /dev/null |
    grep -Fqx "fpr:::::::::${SUBLIME_KEY_FINGERPRINT}:"
}

sublime_download_key() {
  curl -fsSL "${SUBLIME_KEY_URL}" -o "$1"
  sublime_verify_key "$1" || {
    jsh::log_error 'Sublime Text signing key fingerprint did not match.'
    return 1
  }
}

sublime_install_root_file() {
  local source=$1 target=$2
  if [[ -r ${target} ]] && cmp -s -- "${source}" "${target}"; then
    return 0
  fi
  if [[ -e ${target} ]]; then
    jsh::log_error "Refusing to replace an existing repository file: ${target}"
    return 1
  fi
  if sublime_dry_run; then
    jsh::log_detail "Would install ${target}"
    return 0
  fi
  jsh_run_root install -d -m 0755 "${target%/*}"
  jsh_run_root install -m 0644 "${source}" "${target}"
}

sublime_ensure_apt_key() {
  local temporary
  if [[ -r ${SUBLIME_APT_KEY_PATH} ]] && sublime_verify_key "${SUBLIME_APT_KEY_PATH}"; then
    return 0
  fi
  if [[ -e ${SUBLIME_APT_KEY_PATH} ]]; then
    jsh::log_error "Existing Sublime Text signing key is invalid: ${SUBLIME_APT_KEY_PATH}"
    return 1
  fi
  if sublime_dry_run; then
    jsh::log_detail "Would install ${SUBLIME_APT_KEY_PATH}"
    return 0
  fi
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/sublime-key.XXXXXXXXXX")
  if ! sublime_download_key "${temporary}" ||
    ! sublime_install_root_file "${temporary}" "${SUBLIME_APT_KEY_PATH}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  rm -f -- "${temporary}"
}

sublime_ensure_rpm_key() {
  local temporary
  if [[ -r ${SUBLIME_RPM_KEY_PATH} ]] && sublime_verify_key "${SUBLIME_RPM_KEY_PATH}"; then
    rpm -q gpg-pubkey-8a8f901a > /dev/null 2>&1 && return 0
  elif [[ -e ${SUBLIME_RPM_KEY_PATH} ]]; then
    jsh::log_error "Existing Sublime Text signing key is invalid: ${SUBLIME_RPM_KEY_PATH}"
    return 1
  fi
  if sublime_dry_run; then
    jsh::log_detail "Would install ${SUBLIME_RPM_KEY_PATH}"
    jsh::log_detail 'Would import the Sublime Text RPM signing key.'
    return 0
  fi
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/sublime-key.XXXXXXXXXX")
  if ! sublime_download_key "${temporary}" ||
    ! sublime_install_root_file "${temporary}" "${SUBLIME_RPM_KEY_PATH}" ||
    ! jsh_run_root rpm --import "${SUBLIME_RPM_KEY_PATH}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  rm -f -- "${temporary}"
}

sublime_ensure_pacman_key() {
  local temporary
  pacman-key --list-keys "${SUBLIME_KEY_FINGERPRINT}" > /dev/null 2>&1 && return 0
  if sublime_dry_run; then
    jsh::log_detail 'Would import and locally sign the Sublime Text pacman key.'
    return 0
  fi
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/sublime-key.XXXXXXXXXX")
  if ! sublime_download_key "${temporary}" ||
    ! jsh_run_root pacman-key --add "${temporary}" ||
    ! jsh_run_root pacman-key --lsign-key "${SUBLIME_KEY_FINGERPRINT}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  rm -f -- "${temporary}"
}

sublime_ensure_pacman_repo() {
  local architecture=$1 repository temporary
  repository="https://download.sublimetext.com/arch/stable/${architecture}"
  if grep -Eq '^\[sublime-text\][[:space:]]*$' "${SUBLIME_PACMAN_CONF}" 2> /dev/null; then
    awk -v expected="Server = ${repository}" '
      /^\[sublime-text\][[:space:]]*$/ { active=1; next }
      /^\[/ { active=0 }
      active && $0 == expected { found=1 }
      END { exit !found }
    ' "${SUBLIME_PACMAN_CONF}" && return 0
    jsh::log_error "Existing Sublime Text repository is not the stable ${architecture} repository."
    return 1
  fi
  if sublime_dry_run; then
    jsh::log_detail "Would add the Sublime Text repository to ${SUBLIME_PACMAN_CONF}"
    return 0
  fi
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/sublime-pacman.XXXXXXXXXX")
  printf '\n[sublime-text]\nServer = %s\n' "${repository}" > "${temporary}"
  if ! jsh_run_root tee -a "${SUBLIME_PACMAN_CONF}" < "${temporary}" > /dev/null; then
    rm -f -- "${temporary}"
    return 1
  fi
  rm -f -- "${temporary}"
}

install_sublime_text() {
  local architecture family manager
  family=$(jsh_linux_family) || return 0
  case ${family} in
    debian)
      sublime_ensure_apt_key
      sublime_install_root_file "${JSH_ROOT}/conf/sublime/sublime-text.sources" "${SUBLIME_APT_SOURCE_PATH}"
      manager=apt-get
      ;;
    fedora)
      architecture=$(uname -m)
      [[ ${architecture} == x86_64 ]] || {
        jsh::log_note "Sublime Text is unavailable for architecture ${architecture}."
        return 0
      }
      sublime_ensure_rpm_key
      sublime_install_root_file "${JSH_ROOT}/conf/sublime/sublime-text.repo" "${SUBLIME_DNF_REPO_PATH}"
      manager=$(command -v dnf5 > /dev/null 2>&1 && printf dnf5 || printf dnf)
      ;;
    arch)
      architecture=$(uname -m)
      case ${architecture} in
        x86_64 | aarch64) ;;
        *) jsh::log_note "Sublime Text is unavailable for architecture ${architecture}."; return 0 ;;
      esac
      sublime_ensure_pacman_key
      sublime_ensure_pacman_repo "${architecture}"
      manager=pacman
      ;;
    *) return 0 ;;
  esac

  if sublime_package_installed "${family}"; then
    if [[ ${JSH_UPDATE:-0} != 1 ]]; then
      jsh::log_note 'Sublime Text is already installed.'
      return 0
    fi
  fi
  case ${family} in
    debian)
      jsh_run_root apt-get update
      jsh_run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sublime-text
      ;;
    fedora) jsh_run_root "${manager}" install -y -- sublime-text ;;
    arch) jsh_run_root pacman -Syu --needed --noconfirm -- sublime-text ;;
    *) return 1 ;;
  esac
  jsh::log_success 'Sublime Text is installed.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_sublime_text
fi
