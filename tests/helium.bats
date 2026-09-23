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
  export PLATFORM=Linux
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

@test "Linux desktop entry launches the native browser with the managed profile" {
  local browser="${BATS_TEST_TMPDIR}/helium-native"
  export HELIUM_BINARY="${browser}"
  export XDG_DATA_HOME="${BATS_TEST_TMPDIR}/share"
  printf '#!/usr/bin/env bash\n' > "${browser}"
  chmod +x "${browser}"

  install_linux_launcher

  grep -Fxq "Exec=${browser} \"--user-data-dir=${PROFILE_ROOT}\" --profile-directory=Default --no-first-run --no-default-browser-check --disable-sync --disable-notifications --disable-breakpad --new-window %U" \
    "${XDG_DATA_HOME}/applications/helium.desktop"
}

@test "desktop launch loads Homebrew dependencies outside PATH" {
  local brew_root="${BATS_TEST_TMPDIR}/brew"
  mkdir -p "${brew_root}/bin"
  printf '#!/usr/bin/env bash\nprintf '\''export PATH=%%q:$PATH\\n'\'' %q\n' \
    "${brew_root}/bin" > "${brew_root}/bin/brew"
  printf '#!/usr/bin/env bash\n' > "${brew_root}/bin/node"
  printf '#!/usr/bin/env bash\n' > "${brew_root}/bin/sqlite3"
  chmod +x "${brew_root}/bin/brew" "${brew_root}/bin/node" "${brew_root}/bin/sqlite3"
  PATH=/usr/bin:/bin
  export HELIUM_BREW="${brew_root}/bin/brew"

  load_brew

  [[ $(command -v node) = "${brew_root}/bin/node" ]]
  [[ $(command -v sqlite3) = "${brew_root}/bin/sqlite3" ]]
}

@test "profile verification permits browser metadata but rejects managed exceptions" {
  local preferences="${BATS_TEST_TMPDIR}/Preferences"
  local local_state="${BATS_TEST_TMPDIR}/Local State"
  local staged_preferences="${BATS_TEST_TMPDIR}/Preferences.new"
  local staged_local_state="${BATS_TEST_TMPDIR}/Local State.new"
  load_brew
  profile_helper stage "${preferences}" "${local_state}" \
    "${staged_preferences}" "${staged_local_state}"
  jq '.profile.content_settings.exceptions.app_banner = {
    "https://example.test:443,*": {"setting": {"couldShowBannerEvents": 1}}
  } | .profile.content_settings.exceptions.media_engagement = {
    "https://example.test:443,*": {"setting": {"last_media_playback_time": 1}}
  }' "${staged_preferences}" > "${preferences}"
  mv "${staged_local_state}" "${local_state}"

  profile_helper verify "${preferences}" "${local_state}"

  jq '.profile.content_settings.exceptions.notifications = {
    "https://example.test:443,*": {"setting": 1}
  }' "${preferences}" > "${staged_preferences}"
  run profile_helper verify "${staged_preferences}" "${local_state}"

  [[ ${status} -ne 0 ]]
  [[ ${output} = "content-setting exceptions remain: notifications" ]]
}

@test "Linux launch propagates the browser status to the desktop launcher" {
  local browser="${BATS_TEST_TMPDIR}/helium-browser"
  printf '#!/usr/bin/env bash\nexit 23\n' > "${browser}"
  chmod +x "${browser}"

  require_command() { :; }
  load_brew() { :; }
  verify_app() { :; }
  verify_profile() { :; }
  app_executable() { printf '%s\n' "${browser}"; }

  run launch -- https://example.test/

  [[ ${status} -eq 23 ]]
}

@test "dispatches the shared lifecycle command baseline" {
  launch() { printf 'open:%s\n' "${1:-}"; }
  stop() { printf 'stop\n'; }

  run main open https://example.test/
  [[ ${status} -eq 0 ]]
  [[ ${output} = 'open:https://example.test/' ]]

  run main stop
  [[ ${status} -eq 0 ]]
  [[ ${output} = 'stop' ]]

  run main restart
  [[ ${status} -eq 0 ]]
  [[ ${output} = $'stop\nopen:' ]]

  run main launch
  [[ ${status} -eq 0 ]]
  [[ ${output} = 'open:' ]]
}

@test "apply dry run stops before browser or profile mutation" {
  export JSH_CONFIGURE_DRY_RUN=1
  stop_for_apply() { return 99; }
  upgrade_app() { return 99; }
  apply_profile() { return 99; }

  run apply

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Would inspect, update, and harden Helium.'* ]]
}

@test "macOS update reinstalls an app that still fails verification" {
  local calls="${BATS_TEST_TMPDIR}/brew-calls"
  local app_path="${BATS_TEST_TMPDIR}/Helium.app"
  mkdir -p "${app_path}"

  run env CALLS="${calls}" APP_STATE="${calls}.valid" \
    HELIUM_PLATFORM=Darwin HELIUM_APP_PATH="${app_path}" bash -c '
    source "$1"
    verify_app() { [[ -e ${APP_STATE} ]]; }
    brew() {
      local IFS=" "
      printf "%s\n" "$*" >> "${CALLS}"
      [[ $1 != reinstall ]] || : > "${APP_STATE}"
    }
    upgrade_app
  ' _ "${JSH_ROOT}/scripts/unix/configure/helium.sh"

  [[ ${status} -eq 0 ]]
  diff -u <(printf 'update\nlist --cask helium-browser\nupgrade --cask helium-browser\nreinstall --cask --force helium-browser\n') "${calls}"
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

@test "reset safety accepts only the expected profile below home" {
  local isolated_home="${BATS_TEST_TMPDIR}/isolated-home"
  mkdir -p "${isolated_home}/.config/helium"

  run env HOME="${isolated_home}" XDG_CONFIG_HOME="${isolated_home}/.config" HELIUM_PLATFORM=Linux \
    bash -c 'source "$1"; profile_root_is_safe' _ \
    "${JSH_ROOT}/scripts/unix/configure/helium.sh"

  [[ ${status} -eq 0 ]]

  run env HOME="${isolated_home}" XDG_CONFIG_HOME="${isolated_home}/.config" \
    HELIUM_PLATFORM=Linux HELIUM_PROFILE_ROOT="${isolated_home}" \
    bash -c 'source "$1"; profile_root_is_safe' _ \
    "${JSH_ROOT}/scripts/unix/configure/helium.sh"

  [[ ${status} -ne 0 ]]
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

@test "Linux installer delegates Helium to its component lifecycle" {
  grep -Fq 'scripts/unix/configure/helium.sh' \
    "${JSH_ROOT}/scripts/linux/install/helium.sh"
  grep -Fq 'jsh_debian_install_package helium helium-bin' \
    "${JSH_ROOT}/scripts/unix/configure/helium.sh"
}

@test "shared implementation accepts readonly caller paths" {
  run bash -c '
    SCRIPT_DIR=$1/scripts/linux/install
    readonly SCRIPT_DIR
    JSH_ROOT=$1
    readonly JSH_ROOT
    source "$JSH_ROOT/scripts/unix/configure/helium.sh"
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
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

@test "macOS failed verification does not abort installation repair" {
  run env HELIUM_PLATFORM=Darwin HELIUM_APP_PATH="${BATS_TEST_TMPDIR}/Helium.app" bash -c '
    source "$1/scripts/unix/configure/helium.sh"
    verify_app() { exit 1; }
    brew() { local IFS=" "; printf "brew:%s\n" "$*"; }
    upgrade_app
  ' _ "${JSH_ROOT}"
  [[ ${status} -eq 1 ]]
  [[ ${output} == *"brew:upgrade --cask helium-browser"* ]]
  [[ ${output} == *"brew:reinstall --cask --force helium-browser"* ]]
}

@test "apply accepts yes and quit together without interactive input" {
  export JSH_CONFIGURE_DRY_RUN=1
  run main apply --yes --quit
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Would inspect, update, and harden Helium.'* ]]
}

@test "macOS manifest declares Helium for the package phase" {
  export JSH_MANIFEST_OS=darwin
  run jsh_manifest_main brewfile
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'cask "helium-browser"'* ]]
}

@test "macOS apply does not fail at the Linux launcher step" {
  run env HELIUM_PLATFORM=Darwin bash -c '
    source "$1/scripts/unix/configure/helium.sh"
    install_linux_launcher
  ' _ "${JSH_ROOT}"
  [[ ${status} -eq 0 ]]
}
