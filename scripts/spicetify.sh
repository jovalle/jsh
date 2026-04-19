#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
root_dir=$(cd -- "${script_dir}/.." && pwd -P)
tmp_dir="${root_dir}/tmp"
config_dir="${SPICETIFY_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/spicetify}"
marketplace_dir="${config_dir}/CustomApps/marketplace"
marketplace_installer_url="${SPICETIFY_MARKETPLACE_INSTALLER_URL:-https://raw.githubusercontent.com/spicetify/marketplace/main/resources/install.sh}"

mkdir -p "${tmp_dir}"
installer=$(mktemp "${tmp_dir}/spicetify-marketplace.XXXXXX")
trap 'rm -f -- "${installer}"' EXIT

config_file=$(spicetify -c)
if [[ -r ${config_file} ]] && awk -F= '
  /^\[Backup\]$/ { backup = 1; next }
  /^\[/ { backup = 0 }
  backup && $1 ~ /^[[:space:]]*version[[:space:]]*$/ && $2 ~ /[^[:space:]]/ { found = 1 }
  END { exit !found }
' "${config_file}"; then
  patch_command=(apply)
  failure_hint='Run `spicetify restore backup apply`, then rerun this task.'
else
  patch_command=(backup apply)
  failure_hint='Open Spotify, log in, leave it open for 60 seconds, then rerun this task.'
fi

if ! spicetify "${patch_command[@]}"; then
  printf 'Spicetify could not patch Spotify. %s\n' "${failure_hint}" >&2
  exit 1
fi

if [[ -d ${marketplace_dir} ]]; then
  printf 'Spicetify configuration current; Marketplace is installed.\n'
  exit 0
fi

curl -fsSL --retry 2 --output "${installer}" "${marketplace_installer_url}"
SPICETIFY_CONFIG="${config_dir}" sh "${installer}"
printf 'Spicetify configured; Marketplace installed.\n'
