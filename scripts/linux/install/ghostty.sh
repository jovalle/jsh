#!/usr/bin/env bash
# Install and update native Ghostty on Debian-family AMD64 systems.

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

install_ghostty() {
  local codename=trixie metadata asset name version url digest checksum
  [[ $(jsh_linux_family) == debian && $(uname -m) == x86_64 ]] || return 0
  if [[ -r ${JSH_OS_RELEASE:-/etc/os-release} ]]; then
    codename=$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/["\047]/, "", $2); print $2}' \
      "${JSH_OS_RELEASE:-/etc/os-release}")
    [[ -n ${codename} ]] || codename=trixie
  fi
  metadata=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/mkasberg/ghostty-ubuntu/releases/latest')
  asset=$(jq -cer --arg codename "${codename}" '
    ([.assets[] | select(.name | contains($codename)) | select(.name | test("amd64.*[.]deb$"))]
      + [.assets[] | select(.name | test("amd64.*[.]deb$"))]) | first
  ' <<< "${metadata}")
  name=$(jq -r '.name' <<< "${asset}")
  version=$(sed -nE 's/^ghostty_([^_]+)_amd64.*[.]deb$/\1/p' <<< "${name}")
  version=${version/.ppa/~ppa}
  url=$(jq -r '.browser_download_url' <<< "${asset}")
  digest=$(jq -r '.digest // empty' <<< "${asset}")
  checksum=${digest#sha256:}
  [[ -n ${version} && ${url} == https://* ]] || {
    jsh::log_error 'Could not resolve the latest Ghostty Debian package.'
    return 1
  }
  jsh_debian_install_package ghostty ghostty "${version}" "${url}" "${checksum}" ghostty
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_ghostty
fi
