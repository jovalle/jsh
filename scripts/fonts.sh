#!/usr/bin/env bash
# Install the verified JetBrains Mono Nerd Font release on Linux.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
jsh::packages fonts
jsh::activity 'Checking JetBrains Mono fonts'
[[ $(uname -s) != Darwin ]] || exit 0
spec=${SCRIPT_DIR}/fonts/fonts.json
jq -e '.repository | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")' "${spec}" >/dev/null
jq -e '.asset | test("^[^/]+[.]tar[.]xz$")' "${spec}" >/dev/null
jq -e '.files | length > 0 and all(.[]; test("^[^/]+[.]ttf$"))' "${spec}" >/dev/null
repository=$(jq -r .repository "${spec}")
asset=$(jq -r .asset "${spec}")
target=${XDG_DATA_HOME:-${HOME}/.local/share}/fonts/jsh
missing=0
while IFS= read -r name; do [[ -f ${target}/${name} ]] || missing=1; done < <(jq -r '.files[]' "${spec}")
if [[ ${missing} == 0 && ${JSH_UPDATE:-0} != 1 ]]; then
  jsh::current
  exit 0
fi
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::changed 'JetBrains Mono Nerd Font'
  exit 0
fi
jsh::download "https://api.github.com/repos/${repository}/releases/latest" "${APP_TMP}/release.json"
jq -e --arg asset "${asset}" '[.assets[] | select(.name == $asset)] | length == 1' "${APP_TMP}/release.json" >/dev/null
url=$(jq -r --arg asset "${asset}" '.assets[] | select(.name == $asset) | .browser_download_url' "${APP_TMP}/release.json")
digest=$(jq -r --arg asset "${asset}" '.assets[] | select(.name == $asset) | .digest | sub("^sha256:"; "")' "${APP_TMP}/release.json")
app::download "${url}" "${APP_TMP}/${asset}" "${digest}"
changed=0
while IFS= read -r name; do
  jsh::activity "Extracting font ${name}"
  tar -xOf "${APP_TMP}/${asset}" "${name}" >"${APP_TMP}/${name}"
  if ! cmp -s "${APP_TMP}/${name}" "${target}/${name}"; then changed=1; fi
  jsh::file "${APP_TMP}/${name}" "${target}/${name}" 644
done < <(jq -r '.files[]' "${spec}")
if [[ ${changed} == 1 ]] && command -v fc-cache >/dev/null 2>&1; then
  jsh::activity 'Refreshing font cache'
  jsh::run fc-cache "${target}"
fi
