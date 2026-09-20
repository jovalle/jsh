#!/usr/bin/env bash
# Install and update native Waterfox on Debian-family AMD64 systems.

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

waterfox_latest_release() {
  local location
  location=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
    'https://github.com/BrowserWorks/Waterfox/releases/latest')
  WATERFOX_VERSION=${location##*/}
  WATERFOX_VERSION=${WATERFOX_VERSION#v}
  [[ ${WATERFOX_VERSION} =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || {
    jsh::log_error 'Could not resolve the latest Waterfox release.'
    return 1
  }
  WATERFOX_URL="https://cdn.waterfox.com/waterfox/releases/${WATERFOX_VERSION}/Linux_x86_64/waterfox-${WATERFOX_VERSION}.tar.bz2"
}

waterfox_installed_version() {
  local launcher=${JSH_WATERFOX_SYSTEM_BIN:-/usr/local/bin/waterfox} output
  [[ -x ${launcher} ]] || return 1
  output=$("${launcher}" --version 2>/dev/null) || return 1
  printf '%s\n' "${output##* }"
}

validate_waterfox_archive() {
  local archive=$1 entry listing
  if ! listing=$(bsdtar -tf "${archive}"); then
    jsh::log_error 'Could not read the Waterfox archive.'
    return 1
  fi
  while IFS= read -r entry; do
    [[ -n ${entry} && ${entry} != /* && ${entry} != *'../'* && ${entry} != '..' &&
      (${entry} == waterfox || ${entry} == waterfox/*) ]] || {
      jsh::log_error "Unsafe Waterfox archive path: ${entry}"
      return 1
    }
  done <<< "${listing}"
}

extract_waterfox_archive() {
  local archive=$1 directory=$2 link target resolved root
  validate_waterfox_archive "${archive}"
  if ! bsdtar -xjf "${archive}" -C "${directory}" --no-same-owner --no-same-permissions; then
    jsh::log_error 'Could not extract the Waterfox archive.'
    return 1
  fi
  root=$(realpath -m "${directory}/waterfox")
  [[ -x ${root}/waterfox ]] || {
    jsh::log_error 'Waterfox archive does not contain the expected executable.'
    return 1
  }
  while IFS= read -r -d '' link; do
    target=$(readlink "${link}")
    [[ ${target} != /* ]] || {
      jsh::log_error "Unsafe absolute link in Waterfox archive: ${link}"
      return 1
    }
    resolved=$(realpath -m "${link%/*}/${target}")
    [[ ${resolved} == "${root}" || ${resolved} == "${root}/"* ]] || {
      jsh::log_error "Escaping link in Waterfox archive: ${link}"
      return 1
    }
  done < <(find "${root}" -type l -print0)
}

confirm_waterfox_shutdown() {
  local process
  pgrep -x waterfox >/dev/null 2>&1 || pgrep -x waterfox-bin >/dev/null 2>&1 || return
  if [[ ${JSH_ASSUME_YES:-0} != 1 && ! -t 0 ]]; then
    jsh::log_warn 'Skipping Waterfox update while the browser is running.'
    return 1
  fi
  jsh::confirm 'Close Waterfox before updating?' --default no || return 1
  for process in waterfox waterfox-bin; do
    pkill -TERM -x "${process}" >/dev/null 2>&1 || true
  done
}

install_waterfox() {
  local installed destination launcher artifact temporary staging actual checksum
  [[ $(jsh_linux_family) == debian && $(uname -m) == x86_64 ]] || return
  waterfox_latest_release
  destination=/opt/jsh/waterfox-${WATERFOX_VERSION}
  launcher=${JSH_WATERFOX_SYSTEM_BIN:-/usr/local/bin/waterfox}
  installed=$(waterfox_installed_version || true)
  if [[ ${installed} == "${WATERFOX_VERSION}" && -x ${destination}/waterfox &&
    -L ${launcher} && $(readlink -f "${launcher}") == "${destination}/waterfox" ]]; then
    jsh::log_note "Waterfox is current (${installed})."
    return
  fi
  if [[ ${JSH_INSTALL_DRY_RUN:-${JSH_CONFIGURE_DRY_RUN:-0}} == 1 ]]; then
    jsh::log_detail "Would install Waterfox ${WATERFOX_VERSION}."
    return
  fi
  if ! confirm_waterfox_shutdown; then
    return 0
  fi
  checksum=$(curl -fsSL "${WATERFOX_URL}.sha512" | awk 'NR == 1 {print $1}')
  [[ ${checksum} =~ ^[0-9a-f]{128}$ ]] || {
    jsh::log_error 'Waterfox returned an invalid SHA-512 checksum.'
    return 1
  }
  artifact=$(jsh_download_artifact waterfox "${WATERFOX_VERSION}" "${WATERFOX_URL}" \
    .tar.bz2 "${checksum}" sha512)
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp -d "${JSH_ROOT}/tmp/waterfox-install.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  if ! extract_waterfox_archive "${artifact}" "${temporary}"; then
    rm -rf -- "${temporary}"
    return 1
  fi
  [[ ! -e ${launcher} || -L ${launcher} ]] || {
    rm -rf -- "${temporary}"
    jsh::log_error "Unmanaged Waterfox launcher exists: ${launcher}"
    return 1
  }
  jsh_run_root install -d -m 0755 /opt/jsh /usr/local/bin
  if [[ ! -e ${destination} ]]; then
    staging=${destination}.stage-$$
    jsh_interrupt_cleanup_root_path "${staging}"
    jsh_run_root cp -a "${temporary}/waterfox" "${staging}"
    jsh_run_root chown -R root:root "${staging}"
    jsh_run_root mv "${staging}" "${destination}"
  fi
  jsh_run_root ln -sfn "${destination}/waterfox" "${launcher}"
  rm -rf -- "${temporary}"
  actual=$(waterfox_installed_version || true)
  [[ ${actual} == "${WATERFOX_VERSION}" ]] || {
    jsh::log_error "Waterfox verification failed: expected ${WATERFOX_VERSION}, got ${actual:-missing}."
    return 1
  }
  jsh::log_success "Installed Waterfox ${actual}."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_waterfox
fi
