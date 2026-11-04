#!/usr/bin/env bash
# Install pinned GNOME extensions and configure the enabled set.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/../lib/desktop.sh"
[[ ${JSH_DESKTOP} == gnome ]] || exit 0
command -v gnome-extensions >/dev/null 2>&1 || exit 0
jsh::need jq
spec=${SCRIPT_DIR}/extensions.json
base=${XDG_DATA_HOME:-${HOME}/.local/share}/gnome-shell/extensions
present() { [[ -d ${base}/$1 || -d /usr/share/gnome-shell/extensions/$1 ]]; }
version=$(gnome-shell --version)
version=${version##* }
version=${version%%.*}
while IFS= read -r uuid; do
  jsh::activity "Checking GNOME extension ${uuid}"
  if present "${uuid}"; then
    jsh::current
    continue
  fi
  build=$(jq -c --arg uuid "${uuid}" --arg version "${version}" \
    '.install[$uuid][] | select(.shells | index($version))' "${spec}" | head -n 1)
  if [[ -z ${build} ]]; then
    jsh::notice "${uuid}: no pinned build for GNOME Shell ${version}"
    continue
  fi
  if [[ ${JSH_DRY_RUN:-0} != 1 ]]; then
    temporary=$(jsh::temp)
    archive=${temporary}/extension.zip
    jsh::download "$(jq -r .url <<<"${build}")" "${archive}"
    printf '%s  %s\n' "$(jq -r .sha256 <<<"${build}")" "${archive}" | sha256sum -c - >/dev/null
    jsh::run gnome-extensions install --force "${archive}"
  fi
  jsh::added "${uuid}"
  jsh::notice 'Log out and back in so GNOME Shell loads new extensions'
done < <(jq -r '.install | keys[]' "${spec}")
jsh::activity 'Checking enabled GNOME extensions'
enabled=$(jsh::gnome_list org.gnome.shell enabled-extensions)
wanted=$(jq -c 'map(select(. != "ding@rastersoft.com" and . != "desktop-icons@csoriano"))' <<<"${enabled}")
while IFS= read -r uuid; do
  if present "${uuid}"; then
    wanted=$(jq -c --arg uuid "${uuid}" 'if index($uuid) then . else . + [$uuid] end' <<<"${wanted}")
  else
    jsh::notice "${uuid} is not installed; rerun scripts/desktop/extensions.sh after installation"
  fi
done < <(jq -r '.enable[]' "${spec}")
[[ ${enabled} == "${wanted}" ]] || jsh::gsetting org.gnome.shell enabled-extensions "${wanted}"
disabled=$(jsh::gnome_list org.gnome.shell disabled-extensions)
wanted=$(jq -c '. as $old | reduce ["ding@rastersoft.com","desktop-icons@csoriano"][] as $id ($old; if index($id) then . else . + [$id] end)' <<<"${disabled}")
[[ ${disabled} == "${wanted}" ]] || jsh::gsetting org.gnome.shell disabled-extensions "${wanted}"
jsh::gsetting org.gnome.shell disable-user-extensions false
schemas=${base}/Vitals@CoreCoding.com/schemas
if [[ -d ${schemas} ]]; then
  jsh::gsetting org.gnome.shell.extensions.vitals hot-sensors "$(jq -r .vitals "${spec}")" "${schemas}"
fi
