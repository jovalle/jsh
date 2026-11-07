#!/usr/bin/env bash
# Apply Helium policy, profile preferences, and locally selected unpacked extensions.
set -euo pipefail
# shellcheck disable=SC2034 # APP_LAUNCH is consumed by app::with_closed.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
jsh::packages helium
jsh::activity 'Checking Helium installation'
APP_TMP=${APP_TMP:?}
if [[ $(uname -s) == Darwin ]]; then
  profile_root=${HOME}/Library/Application\ Support/net.imput.helium
  policy=/Library/Managed\ Preferences/$(id -un)/net.imput.helium.plist
  APP_LAUNCH=(open -a Helium)
else
  profile_root=${XDG_CONFIG_HOME:-${HOME}/.config}/helium
  policy=/etc/chromium/policies/managed/jsh-helium.json
  APP_LAUNCH=(helium)
fi
if ! command -v helium >/dev/null 2>&1 && [[ ! -d ${profile_root} && ! -d /Applications/Helium.app ]]; then exit 0; fi
app::desired helium policy.json >"${APP_TMP}/policy.json"
app::policy "${APP_TMP}/policy.json" "${policy}"
jsh::activity 'Finding Helium profiles'
shopt -s nullglob
profiles=("${profile_root}"/*/Preferences)
if [[ -f ${profile_root}/Default/Preferences ]]; then profiles=("${profile_root}/Default/Preferences"); fi
if [[ ${#profiles[@]} == 0 ]]; then
  jsh::notice 'open Helium once to create a profile, then rerun scripts/helium.sh'
  exit 0
fi
if [[ ${#profiles[@]} != 1 ]]; then
  jsh::notice 'several profiles and no Default profile; choose one by hand'
  exit 0
fi
preferences=${profiles[0]}
# Linux Chromium needs experimental web-platform features for Kingpin's Web Bluetooth.
# Keep the user's other browser flags when adding this setting.
helium::state() {
  local current=${APP_TMP}/helium-current-state.json
  if [[ -f "${profile_root}/Local State" ]]; then app::jsonc "${profile_root}/Local State" >"${current}"
  else printf '{}\n' >"${current}"; fi
  app::jsonc "${SCRIPT_DIR}/helium/state.json" >"${APP_TMP}/helium-base-state.json"
  jq -n --slurpfile state "${APP_TMP}/helium-base-state.json" --slurpfile current "${current}" '
    ($current[0].browser.enabled_labs_experiments // []) as $flags |
    if ($flags | type) != "array" or any($flags[]; type != "string") then
      error("Helium experimental flags must be a string array")
    else $state[0] * {browser: {enabled_labs_experiments:
      (($flags | map(select(. != "enable-experimental-web-platform-features" and
        (startswith("enable-experimental-web-platform-features@") | not)))) +
        ["enable-experimental-web-platform-features"])}} end' >"${APP_TMP}/helium-state.json"
}
helium::state
jsh::activity 'Checking Helium profile preferences'
helium::preferences() {
  local current=${APP_TMP}/helium-current-preferences.json
  app::jsonc "${preferences}" >"${current}"
  jq -n --slurpfile base "${SCRIPT_DIR}/helium/preferences.json" --slurpfile policy "${APP_TMP}/policy.json" --slurpfile current "${current}" '
    [$policy[0].ExtensionSettings // {} | to_entries[] | select(.value.toolbar_pin == "force_pinned") | .key] as $pinned |
    ($current[0].extensions.pinned_extensions // []) as $existing |
    if ($existing | type) != "array" or any($existing[]; type != "string") then
      error("Helium pinned extensions must be a string array")
    else $base[0] * {extensions: {pinned_extensions:
      ($pinned + [$existing[] | select(. as $id | $pinned | index($id) | not)])}} end' >"${APP_TMP}/helium-preferences.json"
}
helium::preferences
secure=${preferences%/*}/Secure\ Preferences
pending=0
app::pending "${APP_TMP}/helium-preferences.json" "${preferences}"
[[ ${APP_PENDING} == 0 ]] || pending=1
app::pending "${APP_TMP}/helium-state.json" "${profile_root}/Local State"
[[ ${APP_PENDING} == 0 ]] || pending=1
: >"${APP_TMP}/unpacked"
unpacked=$(app::local helium unpacked.json)
if [[ $(uname -s) == Darwin && -n ${unpacked} ]]; then
  # Extension IDs hash the canonical on-disk path, so resolve symlinks before hashing.
  jq -er 'if type == "array" and all(.[]; type == "string") then .[] else error("unpacked.json must be a path array") end' \
    "${unpacked}" >"${APP_TMP}/requested"
  while IFS= read -r path; do
    case ${path} in \~/*) path=${HOME}/${path#\~/} ;; esac
    [[ -f ${path}/manifest.json ]] || continue
    canonical=$(cd -- "${path}" && pwd -P)
    id=$(printf '%s' "${canonical}" | shasum -a 256 | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop')
    printf '%s\t%s\n' "${id}" "${canonical}" >>"${APP_TMP}/unpacked"
  done <"${APP_TMP}/requested"
fi
read_secure() {
  if [[ -f ${secure} ]]; then
    app::jsonc "${secure}" >"${APP_TMP}/secure.json"
  else printf '{}\n' >"${APP_TMP}/secure.json"; fi
}
unpacked_pending=0
jsh::activity 'Checking Helium unpacked extensions'
if [[ -s ${APP_TMP}/unpacked ]]; then
  read_secure
  if ! jq -e '.extensions.ui.developer_mode == true' "${APP_TMP}/secure.json" >/dev/null; then unpacked_pending=1; fi
  while IFS=$'\t' read -r id path; do
    if ! jq -e --arg id "${id}" --arg path "${path}" \
      '.extensions.settings[$id] | .location == 4 and .path == $path' "${APP_TMP}/secure.json" >/dev/null; then unpacked_pending=1; fi
  done <"${APP_TMP}/unpacked"
fi
if [[ ${pending} == 0 && ${unpacked_pending} == 0 ]]; then
  jsh::current
  exit 0
fi
helium_mac() {
  local path=$1 json=$2 canonical
  canonical=$(jq -Sc . "${json}" | sed 's/</\\u003C/g')
  printf '%s' "${device}${path}${canonical}" | openssl dgst -sha256 -hmac '' | awk '{ print toupper($NF) }'
}
helium_prune() {
  jq 'def prune: if type == "object" then with_entries(.value |= prune | select(.value != {} and .value != []))
    elif type == "array" then map(prune) else . end; prune' "$1"
}
load_unpacked() {
  local path id mac scratch status=0
  jsh::activity 'Loading Helium unpacked extensions'
  scratch=$(jsh::temp)
  paths=$(cut -f2 "${APP_TMP}/unpacked" | paste -sd , -)
  binary=/Applications/Helium.app/Contents/MacOS/Helium
  app::bounded 60 "${binary}" "--user-data-dir=${scratch}" --no-first-run --headless=new \
    "--load-extension=${paths}" --dump-dom about:blank >"${APP_TMP}/headless.log" 2>&1 || status=$?
  if [[ ! -f ${scratch}/Default/Secure\ Preferences ]]; then
    jsh::notice "Helium could not load unpacked extensions (exit ${status})"
    return
  fi
  loaded=0
  while IFS=$'\t' read -r id path; do
    if ! jq -e --arg id "${id}" '.extensions.settings[$id] // empty' "${scratch}/Default/Secure Preferences" >"${APP_TMP}/entry.json"; then
      jsh::notice "Helium could not load the unpacked extension in ${path}"
      continue
    fi
    jq '.location = 4 | .disable_reasons = []' "${APP_TMP}/entry.json" >"${APP_TMP}/entry-updated.json"
    helium_prune "${APP_TMP}/entry-updated.json" >"${APP_TMP}/entry-pruned.json"
    mac=$(helium_mac "extensions.settings.${id}" "${APP_TMP}/entry-pruned.json")
    jq --arg id "${id}" --arg mac "${mac}" --slurpfile entry "${APP_TMP}/entry-updated.json" \
      '.extensions.settings[$id] = $entry[0] | .protection.macs.extensions.settings[$id] = $mac' \
      "${APP_TMP}/secure.json" >"${APP_TMP}/secure-updated.json"
    mv "${APP_TMP}/secure-updated.json" "${APP_TMP}/secure.json"
    loaded=1
  done <"${APP_TMP}/unpacked"
  [[ ${loaded} == 1 ]] || return 0
  printf 'true\n' >"${APP_TMP}/true.json"
  mac=$(helium_mac extensions.ui.developer_mode "${APP_TMP}/true.json")
  jq --arg mac "${mac}" '.extensions.ui.developer_mode = true |
    .protection.macs.extensions.ui.developer_mode = $mac |
    del(.protection.macs.extensions.settings_encrypted_hash,
      .protection.macs.extensions.ui.developer_mode_encrypted_hash)' \
    "${APP_TMP}/secure.json" >"${APP_TMP}/secure-updated.json"
  mv "${APP_TMP}/secure-updated.json" "${APP_TMP}/secure.json"
}
write_secure() {
  local mac
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::changed "${secure}"
    return
  fi
  jsh::need openssl
  device=$(ioreg -rd1 -c IOPlatformExpertDevice | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p')
  [[ -n ${device} ]] || {
    jsh::notice 'could not read platform UUID for Helium preferences'
    return
  }
  read_secure
  cp "${APP_TMP}/secure.json" "${APP_TMP}/secure-before.json"
  if [[ ${unpacked_pending} == 1 ]]; then load_unpacked; fi
  cmp -s "${APP_TMP}/secure.json" "${APP_TMP}/secure-before.json" && return
  jq 'del(.protection.super_encrypted_hash)' "${APP_TMP}/secure.json" >"${APP_TMP}/secure-updated.json"
  jq '.protection.macs' "${APP_TMP}/secure-updated.json" >"${APP_TMP}/macs.json"
  mac=$(helium_mac '' "${APP_TMP}/macs.json")
  jq -c --arg mac "${mac}" '.protection.super_mac = $mac' "${APP_TMP}/secure-updated.json" >"${APP_TMP}/secure-final.json"
  jsh::file "${APP_TMP}/secure-final.json" "${secure}"
}
configure_helium() {
  jsh::activity 'Applying Helium profile preferences'
  helium::preferences
  app::json "${APP_TMP}/helium-preferences.json" "${preferences}"
  helium::state
  app::json "${APP_TMP}/helium-state.json" "${profile_root}/Local State"
  if [[ ${unpacked_pending} == 1 ]]; then write_secure; fi
}
app::with_closed Helium 'helium|Helium|helium-bin' configure_helium
