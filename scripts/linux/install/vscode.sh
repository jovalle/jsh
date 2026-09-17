#!/usr/bin/env bash
# Install and update native Visual Studio Code on Debian-family AMD64 systems.

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

install_vscode() {
  local metadata url version checksum
  [[ $(jsh_linux_family) == debian && $(uname -m) == x86_64 ]] || return
  metadata=$(curl -fsSL -H 'User-Agent: jsh/vscode' \
    'https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest')
  url=$(jq -r '.url // empty' <<< "${metadata}")
  checksum=$(jq -r '.sha256hash // empty' <<< "${metadata}")
  version=$(sed -nE 's#.+/code_([^_]+)_amd64[.]deb.*#\1#p' <<< "${url}")
  [[ -n ${version} ]] || version=$(jq -r '.name // empty' <<< "${metadata}")
  [[ -n ${version} && ${url} == https://* ]] || {
    jsh_error 'Could not resolve the latest Visual Studio Code release.'
    return 1
  }
  [[ -z ${checksum} || ${checksum} =~ ^[0-9a-f]{64}$ ]] || {
    jsh_error 'Visual Studio Code returned an invalid checksum.'
    return 1
  }
  jsh_debian_install_package vscode code "${version}" "${url}" "${checksum}" code
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_vscode
fi
