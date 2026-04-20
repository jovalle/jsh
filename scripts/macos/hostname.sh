#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
# shellcheck source=../ui.sh
. "${script_dir}/../ui.sh"

command -v scutil >/dev/null 2>&1 || {
  jsh_error 'scutil is required to configure the macOS hostname.'
  exit 1
}

# macOS uses LocalHostName.local as the fallback when HostName is not set.
current_hostname=$(scutil --get HostName 2>/dev/null || true)
if [[ -n ${current_hostname} ]]; then
  jsh_success "Custom hostname is already set to ${current_hostname}."
  exit 0
fi

display_hostname=$(hostname)
if [[ ! -t 0 ]]; then
  jsh_info "No custom hostname is set (current hostname: ${display_hostname}); skipping the interactive prompt."
  exit 0
fi

jsh_info "No custom hostname is set (current hostname: ${display_hostname})."
if ! read -r -n 1 -p 'Would you like to set a custom hostname? [y/N] ' answer; then
  printf '\n'
  jsh_info 'Keeping the current hostname.'
  exit 0
fi
printf '\n'
# Do not let an optional Enter after the single-character answer become the
# empty hostname on the next prompt.
if read -r -t 0; then
  read -r
fi

case ${answer} in
  [Yy] | [Yy][Ee][Ss]) ;;
  *)
    jsh_info 'Keeping the current hostname.'
    exit 0
    ;;
esac

while :; do
  if ! read -r -p 'What should the custom hostname be? ' custom_hostname; then
    printf '\n'
    jsh_info 'Keeping the current hostname.'
    exit 0
  fi
  if [[ -n ${custom_hostname} ]]; then
    break
  fi
  jsh_error 'A hostname is required; please try again.'
done

if [[ ${EUID} -eq 0 ]]; then
  scutil --set HostName "${custom_hostname}"
else
  sudo scutil --set HostName "${custom_hostname}"
fi

jsh_success "Custom hostname set to ${custom_hostname}."
