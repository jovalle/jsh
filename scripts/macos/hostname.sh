#!/usr/bin/env bash

set -euo pipefail

command -v scutil >/dev/null 2>&1 || {
  printf 'scutil is required to configure the macOS hostname.\n' >&2
  exit 1
}

# macOS uses LocalHostName.local as the fallback when HostName is not set.
current_hostname=$(scutil --get HostName 2>/dev/null || true)
if [[ -n ${current_hostname} ]]; then
  printf 'Custom hostname is already set to %s.\n' "${current_hostname}"
  exit 0
fi

display_hostname=$(hostname)
if [[ ! -t 0 ]]; then
  printf 'No custom hostname is set (current hostname: %s); skipping the interactive prompt.\n' \
    "${display_hostname}"
  exit 0
fi

printf 'No custom hostname is set (current hostname: %s).\n' "${display_hostname}"
if ! read -r -n 1 -p 'Would you like to set a custom hostname? [y/N] ' answer; then
  printf '\nKeeping the current hostname.\n'
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
    printf 'Keeping the current hostname.\n'
    exit 0
    ;;
esac

while :; do
  if ! read -r -p 'What should the custom hostname be? ' custom_hostname; then
    printf '\nKeeping the current hostname.\n'
    exit 0
  fi
  if [[ -n ${custom_hostname} ]]; then
    break
  fi
  printf 'A hostname is required; please try again.\n' >&2
done

if [[ ${EUID} -eq 0 ]]; then
  scutil --set HostName "${custom_hostname}"
else
  sudo scutil --set HostName "${custom_hostname}"
fi

printf 'Custom hostname set to %s.\n' "${custom_hostname}"
