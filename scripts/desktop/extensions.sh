#!/usr/bin/env bash
# Install and update GNOME extensions from extensions.gnome.org and configure the enabled set.

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
temporary=$(jsh::temp)
while IFS= read -r uuid; do
  jsh::activity "Checking GNOME extension ${uuid}"
  [[ ${uuid} =~ ^[A-Za-z0-9._@-]+$ ]] || {
    jsh::notice "invalid extension UUID: ${uuid}"
    exit 1
  }
  installed=''
  if [[ -d ${base}/${uuid} ]]; then
    [[ ${JSH_UPDATE:-0} == 1 ]] || {
      jsh::current
      continue
    }
    [[ ! -f ${base}/${uuid}/metadata.json ]] || installed=$(jq -r '.version // empty' "${base}/${uuid}/metadata.json")
  elif present "${uuid}" || [[ ${JSH_UPDATE:-0} == 1 ]]; then
    # System extensions belong to the distribution; updates only touch installed ones.
    jsh::current
    continue
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    if [[ -d ${base}/${uuid} ]]; then jsh::notice "would check for a ${uuid} update"; else jsh::added "${uuid}"; fi
    continue
  fi
  jsh::download "https://extensions.gnome.org/extension-info/?uuid=${uuid}&shell_version=${version}" "${temporary}/info.json"
  build=$(jq -c --arg version "${version}" '.shell_version_map[$version] // empty' "${temporary}/info.json")
  if [[ -z ${build} ]]; then
    jsh::notice "${uuid}: no release for GNOME Shell ${version}"
    continue
  fi
  release=$(jq -er '.version | tostring' <<<"${build}")
  tag=$(jq -er '.pk | tostring' <<<"${build}")
  [[ ${tag} =~ ^[0-9]+$ ]] || {
    jsh::notice "${uuid}: invalid release tag"
    exit 1
  }
  if [[ ${installed} == "${release}" ]]; then
    jsh::current
    continue
  fi
  jsh::download "https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${tag}" "${temporary}/extension.zip"
  jsh::run gnome-extensions install --force "${temporary}/extension.zip"
  if [[ -n ${installed} ]]; then jsh::changed "${uuid} ${installed} → ${release}"; else jsh::added "${uuid}"; fi
  jsh::notice 'Log out and back in so GNOME Shell loads extension changes'
done < <(jq -r '.install[]' "${spec}")
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
