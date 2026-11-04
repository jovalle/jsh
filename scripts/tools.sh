#!/usr/bin/env bash
# Keep Git metadata, dependencies, and machine-local jsh data out of Syncthing.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
jsh::packages tools
command -v syncthing >/dev/null 2>&1 || {
  jsh::current
  exit 0
}
query() { app::bounded 15 syncthing cli "$@"; }

jsh::activity 'Checking Syncthing settings'
if ! query config folders list >"${APP_TMP}/folders" ||
  ! query config defaults ignores dump-json >"${APP_TMP}/defaults.json"; then
  jsh::notice 'start Syncthing and rerun scripts/tools.sh to protect synced folders'
  exit 0
fi
jq -r '([".git", "node_modules"] + [.lines[] | select(. != ".git" and . != "node_modules")])[]' \
  "${APP_TMP}/defaults.json" >"${APP_TMP}/ignores"
if cmp -s "${APP_TMP}/ignores" <(jq -r '.lines[]' "${APP_TMP}/defaults.json"); then
  jsh::current
else
  jsh::task 'Updating Syncthing ignores' syncthing cli operations default-ignores "${APP_TMP}/ignores"
  jsh::changed 'Syncthing default ignores'
fi
while IFS= read -r folder; do
  [[ -n ${folder} ]] || continue
  jsh::activity "Checking Syncthing folder ${folder}"
  if ! directory=$(query config folders "${folder}" path get); then
    jsh::notice "could not read Syncthing folder: ${folder}"
    exit 1
  fi
  case ${directory} in \~/*) directory=${HOME}/${directory#\~/} ;; esac
  if [[ ! -d ${directory} ]]; then
    jsh::notice "Syncthing folder is unavailable: ${directory}"
    continue
  fi
  printf '.git\nnode_modules\n' >"${APP_TMP}/rules"
  if [[ $(cd -- "${directory}" && pwd -P) == "${JSH_ROOT}" ]]; then printf '/local/\n' >>"${APP_TMP}/rules"; fi
  target=${directory}/.stignore
  if [[ -f ${target} ]] && cmp -s "${APP_TMP}/rules" <(head -n "$(wc -l <"${APP_TMP}/rules" | tr -d ' ')" "${target}"); then
    jsh::current
    continue
  fi
  cp "${APP_TMP}/rules" "${APP_TMP}/ignore-updated"
  [[ ! -f ${target} ]] || cat "${target}" >>"${APP_TMP}/ignore-updated"
  jsh::file "${APP_TMP}/ignore-updated" "${target}"
done <"${APP_TMP}/folders"
