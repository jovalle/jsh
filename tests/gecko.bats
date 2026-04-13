#!/usr/bin/env bats

setup() {
  project_root=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  test_root=$(mktemp -d "${BATS_TEST_TMPDIR}/gecko.XXXXXX")
  fixture_root=${test_root}/jsh
  fixture_home=${test_root}/home
  fixture_bin=${test_root}/bin

  mkdir -p "${fixture_root}/scripts" "${fixture_root}/config/gecko" \
    "${fixture_home}" "${fixture_bin}"
  cp "${project_root}/scripts/gecko.sh" "${fixture_root}/scripts/gecko.sh"
  cp "${project_root}/config/gecko/user.js" "${fixture_root}/config/gecko/user.js"
  cp "${project_root}/config/gecko/overrides.js" "${fixture_root}/config/gecko/overrides.js"
  printf '%s\n' '{"addons":[]}' >"${fixture_root}/config/gecko/addons.json"

  printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in' \
    '  *tag_name*) printf "%s\\n" v152 ;;' \
    'esac' >"${fixture_bin}/jq"
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\\n" "{\\"tag_name\\":\\"v152\\"}"' >"${fixture_bin}/curl"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"${fixture_bin}/waterfox"
  chmod 755 "${fixture_bin}/jq" "${fixture_bin}/curl" "${fixture_bin}/waterfox"
}

profile_root() {
  if [[ $(uname -s) == Darwin ]]; then
    printf '%s\n' "${fixture_home}/Library/Application Support/Waterfox"
  else
    printf '%s\n' "${fixture_home}/.waterfox"
  fi
}

run_gecko() {
  run env \
    "PATH=${fixture_bin}:${PATH}" \
    "HOME=${fixture_home}" \
    "XDG_STATE_HOME=${test_root}/state" \
    "GECKO_WATERFOX_BIN=${fixture_bin}/waterfox" \
    "GECKO_FIREFOX_BIN=${fixture_root}/missing-firefox" \
    bash "${fixture_root}/scripts/gecko.sh"
}

@test "bootstraps an installed browser profile with configured appearance" {
  run_gecko

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Bootstrapped jsh-default profile for waterfox."* ]]
  [[ "${output}" == *"Waterfox jsh-default: preferences updated"* ]]

  root=$(profile_root)
  profile="${root}/Profiles/jsh-default/user.js"
  [ -r "${root}/profiles.ini" ]
  [ -d "${root}/Profiles/jsh-default" ]
  [ -r "${profile}" ]
  grep -q '^Path=Profiles/jsh-default$' "${root}/profiles.ini"
  grep -Fqx "user_pref('browser.theme.waterfox.browserStyle', 'proton');" "${profile}"
  grep -Fqx "user_pref('browser.theme.enableWaterfoxCustomizations', 2);" "${profile}"
  grep -Fqx "user_pref('browser.nova.enabled', false);" "${profile}"
  grep -Fqx "user_pref('browser.theme.waterfox.mode', 'system');" "${profile}"
  grep -Fqx "user_pref('browser.theme.waterfox.color', 'default');" "${profile}"
  grep -Fqx "user_pref('layout.css.prefers-color-scheme.content-override', 2);" "${profile}"
}

@test "profile bootstrap is idempotent" {
  run_gecko
  [ "${status}" -eq 0 ]

  run_gecko
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Bootstrapped"* ]]
  [[ "${output}" == *"Waterfox jsh-default: preferences current"* ]]
}

@test "existing profile registry is preserved" {
  root=$(profile_root)
  mkdir -p "${root}/Profiles/existing-profile"
  printf '%s\n' \
    '[General]' \
    'StartWithLastProfile=1' \
    'Version=2' \
    '' \
    '[Profile0]' \
    'Name=existing-profile' \
    'IsRelative=1' \
    'Path=Profiles/existing-profile' \
    'Default=1' >"${root}/profiles.ini"

  run_gecko

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Bootstrapped"* ]]
  grep -q '^Name=existing-profile$' "${root}/profiles.ini"
  [ ! -d "${root}/Profiles/jsh-default" ]
  [ -r "${root}/Profiles/existing-profile/user.js" ]
}

@test "does not create a profile when no browser is installed" {
  run env \
    "PATH=${fixture_bin}:${PATH}" \
    "HOME=${fixture_home}" \
    "XDG_STATE_HOME=${test_root}/state" \
    "GECKO_WATERFOX_BIN=${fixture_root}/missing-waterfox" \
    "GECKO_FIREFOX_BIN=${fixture_root}/missing-firefox" \
    bash "${fixture_root}/scripts/gecko.sh"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No Firefox or Waterfox profiles found."* ]]
  [ ! -e "$(profile_root)" ]
}
