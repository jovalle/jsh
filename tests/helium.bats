#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Each Bats test runs in its own subshell.

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export HOME="${BATS_TEST_TMPDIR}/home"
  export XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/config"
  export HELIUM_POLICY_PATH="${BATS_TEST_TMPDIR}/policies/jsh-helium.json"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/unix/configure/helium.sh"
}

@test "Linux uses isolated Helium profile and Chromium policy paths" {
  : "${PLATFORM:?}" "${PROFILE_ROOT:?}" "${POLICY_PATH:?}"
  [[ ${PLATFORM} = Linux ]]
  [[ ${PROFILE_ROOT} = "${XDG_CONFIG_HOME}/helium" ]]
  [[ ${POLICY_PATH} = "${HELIUM_POLICY_PATH}" ]]
}

@test "Linux browser discovery cannot resolve the public wrapper" {
  if [[ -x /usr/bin/helium ]]; then
    [[ $(app_executable) = /usr/bin/helium ]]
  else
    run app_executable
    [[ ${status} -ne 0 ]]
  fi
}

@test "Linux policy contains every managed pin and forced extension" {
  local id _name managed
  local -a extension_ids=()
  local -a force_ids=()
  mkdir -p "${HELIUM_POLICY_PATH%/*}"
  while IFS=$'\t' read -r id _name managed; do
    extension_ids+=("${id}")
    [[ -z ${managed} ]] || force_ids+=("${id}")
  done < <(managed_extensions)

  profile_helper stage-policy \
    "${HELIUM_POLICY_PATH}" "${extension_ids[@]}" -- "${force_ids[@]}"

  verify_extension_policy
  [[ $(jq '.ExtensionSettings | length' "${HELIUM_POLICY_PATH}") -eq 4 ]]
  [[ $(jq '.ExtensionInstallForcelist | length' "${HELIUM_POLICY_PATH}") -eq 3 ]]
}

@test "extension verification accepts Linux Preferences storage" {
  local secure="${BATS_TEST_TMPDIR}/Secure Preferences"
  local preferences="${BATS_TEST_TMPDIR}/Preferences"
  printf '%s' '{}' > "${secure}"
  printf '%s' '{"extensions":{"pinned_extensions":["managed"],"settings":{"managed":{"incognito":true,"location":1}}}}' > "${preferences}"

  run node "${JSH_ROOT}/conf/helium/helium-extensions.mjs" \
    verify-state "${secure}" "${preferences}" managed -- managed

  [[ ${status} -eq 0 ]]
}

@test "Debian catalog pins the official Helium package" {
  run jq -er '.apps[] | select(.id == "helium") |
    [.package, .version, .arch, .sha256] | @tsv' "${JSH_ROOT}/conf/apps/debian.json"

  [[ ${status} -eq 0 ]]
  [[ ${output} = $'helium-bin\t0.17.0.1-1\tamd64\t9858f7444098b441a48786628f53531b79961c957c5d49eb3f4817d6ab1cd0c2' ]]
}

@test "public and legacy launchers delegate to the Unix implementation" {
  grep -Fq 'scripts/unix/configure/helium.sh' "${JSH_ROOT}/bin/helium"
  grep -Fq 'scripts/unix/configure/helium.sh' \
    "${JSH_ROOT}/scripts/darwin/patch/helium.sh"
}

@test "Linux dock includes the managed Helium desktop entry" {
  grep -Fq 'find_desktop_file helium.desktop' \
    "${JSH_ROOT}/scripts/linux/configure/dock.sh"
}

@test "macOS Dock includes an installed Helium application" {
  grep -Fq 'pin_dock_app /Applications/Helium.app' \
    "${JSH_ROOT}/scripts/darwin/configure/appearance.sh"
}
