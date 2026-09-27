#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export WATERFOX_CONFIG="${JSH_ROOT}/conf/gecko/waterfox.json"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/output.sh"
  jsh::log_info() { jsh_info "$@"; }
  jsh::log_note() { jsh_note "$@"; }
  jsh::log_success() { jsh_success "$@"; }
  jsh::log_warn() { jsh_warn "$@"; }
  jsh::log_error() { jsh_error "$@"; }
  jsh::log_detail() { jsh_detail "$@"; }
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/files.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/unix/waterfox.sh"
}

file_identity() {
  if stat -c '%i:%Y' "$1" > /dev/null 2>&1; then
    stat -c '%i:%Y' "$1"
  else
    stat -f '%i:%m' "$1"
  fi
}

@test "waterfix command provides Waterfox repair" {
  [[ -x ${JSH_ROOT}/bin/waterfix ]]
  [[ ! -e ${JSH_ROOT}/bin/flushfox ]]

  run "${JSH_ROOT}/bin/waterfix" --help

  [[ ${status} -eq 0 ]]
  [[ ${output} == *"Repair Waterfox configuration"* ]]
  [[ ${output} == *"waterfix remove"* ]]
}

@test "removes the Import bookmarks item from the bookmarks toolbar" {
  local profile="${BATS_TEST_TMPDIR}/profile"
  local state encoded managed
  mkdir -p "${profile}"
  state='{"placements":{"PersonalToolbar":["import-button","personal-bookmarks"]},"seen":["import-button"],"dirtyAreaCache":[]}'
  encoded=$(jq -Rn --arg state "${state}" '$state')
  printf 'user_pref("browser.uiCustomization.state", %s);\n' "${encoded}" > "${profile}/prefs.js"

  managed=$(managed_toolbar_state "${profile}")

  jq -e '
    .placements.PersonalToolbar == ["personal-bookmarks"]
      and (.seen | index("import-button") | not)
      and (.dirtyAreaCache | index("PersonalToolbar") != null)
  ' <<< "${managed}" > /dev/null
}

@test "rejects Waterfox archives with escaping links" {
  local fixture="${BATS_TEST_TMPDIR}/archive" output="${BATS_TEST_TMPDIR}/output"
  mkdir -p "${fixture}/waterfox" "${output}"
  printf '#!/bin/sh\n' > "${fixture}/waterfox/waterfox"
  chmod +x "${fixture}/waterfox/waterfox"
  ln -s ../../escape "${fixture}/waterfox/link"
  tar -cjf "${BATS_TEST_TMPDIR}/waterfox.tar.bz2" -C "${fixture}" waterfox

  run bash -c '
    realpath() {
      [[ $1 == -m ]] && shift
      python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
    }
    source "$1"
    extract_waterfox_archive "$2" "$3"
  ' _ \
    "${JSH_ROOT}/scripts/linux/install/waterfox.sh" \
    "${BATS_TEST_TMPDIR}/waterfox.tar.bz2" "${output}"

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'Escaping link in Waterfox archive'* ]]
}

@test "Waterfox updates replace the stable install directory in place" {
  local fixture="${BATS_TEST_TMPDIR}/archive" destination="${BATS_TEST_TMPDIR}/opt/waterfox"
  local launcher="${BATS_TEST_TMPDIR}/bin/waterfox"
  mkdir -p "${fixture}/waterfox" "${destination}" "${launcher%/*}"
  printf '#!/bin/sh\necho "Mozilla Waterfox 2.0"\n' > "${fixture}/waterfox/waterfox"
  chmod +x "${fixture}/waterfox/waterfox"
  tar -cjf "${BATS_TEST_TMPDIR}/waterfox.tar.bz2" -C "${fixture}" waterfox
  printf '#!/bin/sh\necho "Mozilla Waterfox 1.0"\n' > "${destination}/waterfox"
  chmod +x "${destination}/waterfox"
  touch "${destination}/stale"
  ln -s "${destination}/waterfox" "${launcher}"

  run env JSH_WATERFOX_INSTALL_DIR="${destination}" JSH_WATERFOX_SYSTEM_BIN="${launcher}" bash -c '
    source "$1"
    archive=$2
    jsh_linux_family() { printf "debian\n"; }
    uname() { printf "x86_64\n"; }
    pgrep() { return 1; }
    waterfox_latest_release() { WATERFOX_VERSION=2.0; WATERFOX_URL=https://example.invalid/waterfox; }
    curl() { printf "%0128d\n" 0; }
    jsh_download_artifact() { printf "%s\n" "${archive}"; }
    jsh_run_root() { [[ $1 == chown ]] || "$@"; }
    install_waterfox
  ' _ "${JSH_ROOT}/scripts/linux/install/waterfox.sh" "${BATS_TEST_TMPDIR}/waterfox.tar.bz2"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Installed Waterfox 2.0'* ]]
  [[ $(readlink "${launcher}") == "${destination}/waterfox" ]]
  [[ ! -e ${destination}/stale ]]
  [[ -z $(find "${destination%/*}" -maxdepth 1 -name 'waterfox.*') ]]
}

@test "Waterfox prefers the profile registered for the stable install" {
  local root="${BATS_TEST_TMPDIR}/waterfox-root"
  mkdir -p "${root}/old" "${root}/managed"
  printf '[Profile0]\nName=old\nIsRelative=1\nPath=old\n\n[Profile1]\nName=managed\nIsRelative=1\nPath=managed\n' \
    > "${root}/profiles.ini"
  printf '[0000]\nDefault=old\nLocked=1\n\n[FFFF]\nDefault=managed\nLocked=1\n' > "${root}/installs.ini"

  run bash -c 'source "$1"; selected_profile "$2" FFFF' _ \
    "${JSH_ROOT}/scripts/unix/configure/waterfox.sh" "${root}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == "$(cd -P -- "${root}/managed" && pwd)" ]]
}

@test "Waterfox registers the managed profile for the stable install idempotently" {
  local root="${BATS_TEST_TMPDIR}/waterfox-root" before
  mkdir -p "${root}/managed"
  printf '[Profile0]\nName=managed\nIsRelative=1\nPath=managed\n\n[InstallFFFF]\nDefault=other\nLocked=1\n' \
    > "${root}/profiles.ini"
  printf '[0000]\nDefault=managed\nLocked=1\n' > "${root}/installs.ini"

  run env XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state" bash -c '
    source "$1"
    register_install_profile "$2" managed FFFF
    ini_value "$2/installs.ini" FFFF Default
    ini_value "$2/profiles.ini" InstallFFFF Default
    ini_value "$2/installs.ini" 0000 Default
  ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh" "${root}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'managed\nmanaged\nmanaged' ]]
  [[ $(grep -c '^\[InstallFFFF\]$' "${root}/profiles.ini") -eq 1 ]]
  before=$(cat "${root}/installs.ini" "${root}/profiles.ini")
  run bash -c 'source "$1"; register_install_profile "$2" managed FFFF' _ \
    "${JSH_ROOT}/scripts/unix/configure/waterfox.sh" "${root}"
  [[ $(cat "${root}/installs.ini" "${root}/profiles.ini") == "${before}" ]]
}

@test "Waterfox install hash applies only to the stable Linux install" {
  local install="${BATS_TEST_TMPDIR}/opt/waterfox"
  mkdir -p "${install}"
  printf '#!/bin/sh\n' > "${install}/waterfox"
  chmod +x "${install}/waterfox"

  run env JSH_WATERFOX_INSTALL_DIR="$(cd -P -- "${install}" && pwd)" JSH_WATERFOX_INSTALL_HASH=FFFF bash -c '
    source "$1"
    uname() { printf "Linux\n"; }
    waterfox_install_hash "$2"
    waterfox_install_hash /usr/bin/true || printf "none\n"
  ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh" "${install}/waterfox"

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'FFFF\nnone' ]]
}

@test "rejects truncated Waterfox archives" {
  printf 'not an archive' > "${BATS_TEST_TMPDIR}/waterfox.tar.bz2"
  mkdir -p "${BATS_TEST_TMPDIR}/output"

  run bash -c 'source "$1"; extract_waterfox_archive "$2" "$3"' _ \
    "${JSH_ROOT}/scripts/linux/install/waterfox.sh" \
    "${BATS_TEST_TMPDIR}/waterfox.tar.bz2" "${BATS_TEST_TMPDIR}/output"

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'Could not read the Waterfox archive'* ]]
}

@test "Waterfox configuration dry run stops before profile mutation" {
  run env JSH_CONFIGURE_DRY_RUN=1 JSH_WATERFOX_BIN=/usr/bin/true \
    JSH_WATERFOX_ROOT="${BATS_TEST_TMPDIR}/profile" bash -c '
      source "$1"
      validate_manifest() { :; }
      validate_waterfox_config() { :; }
      configure_linux_entry_points() { return 99; }
      bootstrap_profile() { return 99; }
      apply_configuration
    ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Would reconcile the Waterfox profile'* ]]
  [[ ! -e ${BATS_TEST_TMPDIR}/profile ]]
}

@test "Waterfox removal clears only selected stale extension policy" {
  (
    # shellcheck source=/dev/null
    source "${JSH_ROOT}/scripts/unix/configure/waterfox.sh"
    export TEMP_DIR="${BATS_TEST_TMPDIR}/policy-stage"
    export POLICY_TARGET="${BATS_TEST_TMPDIR}/distribution/policies.json"
    export JSH_WATERFOX_REMOVE_ADDON_IDS='["stale@example.test"]'
    POLICY_CHANGED=0
    POLICY_SOURCE=
    mkdir -p "${TEMP_DIR}" "${POLICY_TARGET%/*}"
    cat > "${POLICY_TARGET}" <<'JSON'
{"policies":{"ExtensionSettings":{"keep@example.test":{"installation_mode":"normal_installed","install_url":"https://old.example/keep.xpi"},"stale@example.test":{"installation_mode":"normal_installed","install_url":"https://old.example/stale.xpi"}}}}
JSON
    uname() { printf 'Linux\n'; }
    waterfox_binary() { printf '/usr/bin/true\n'; }
    waterfox_config_json() {
      cat <<'JSON'
{"addons":[{"id":"keep@example.test","name":"Keep","installUrl":"https://addons.mozilla.org/firefox/downloads/latest/keep/latest.xpi"}],"citrix":{"protocol":"receiver","allowedOrigins":[]},"search":{"default":"Google","privateDefault":"DuckDuckGo"}}
JSON
    }

    prepare_policy

    [[ ${POLICY_CHANGED} -eq 1 ]]
    jq -e '
      .policies.ExtensionSettings["stale@example.test"] == null
        and .policies.ExtensionSettings["keep@example.test"].install_url
          == "https://addons.mozilla.org/firefox/downloads/latest/keep/latest.xpi"
    ' "${POLICY_SOURCE}" > /dev/null
  )
}

@test "Waterfox Linux entry points are a successful no-op off Linux" {
  run bash -c '
    source "$1"
    uname() { printf "Darwin\n"; }
    configure_linux_entry_points /bin/true
  ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh"

  [[ ${status} -eq 0 ]]
}

@test "Waterfox launcher resolves a symlinked binary for its icon" {
  local home="${BATS_TEST_TMPDIR}/home" install="${BATS_TEST_TMPDIR}/waterfox-1" resolved_install
  mkdir -p "${home}/bin" "${install}/browser/chrome/icons/default"
  printf '#!/bin/sh\n' > "${install}/waterfox"
  printf 'icon\n' > "${install}/browser/chrome/icons/default/default128.png"
  chmod +x "${install}/waterfox"
  ln -s "${install}/waterfox" "${home}/bin/waterfox"
  resolved_install=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${install}")

  run env HOME="${home}" XDG_DATA_HOME="${home}/share" \
    JSH_WATERFOX_SYSTEM_BIN="${home}/bin/waterfox" bash -c '
    source "$1"
    uname() { printf "Linux\n"; }
    readlink() {
      if [[ $1 == -f ]]; then
        shift
        [[ ${1:-} == -- ]] && shift
        python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
      else
        command readlink "$@"
      fi
    }
    configure_linux_entry_points "$(waterfox_binary)"
  ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh"

  [[ ${status} -eq 0 ]]
  grep -Fxq "Exec=${home}/bin/waterfox %u" "${home}/share/applications/waterfox.desktop"
  grep -Fxq "Icon=${resolved_install}/browser/chrome/icons/default/default128.png" \
    "${home}/share/applications/waterfox.desktop"
  grep -Fxq 'StartupWMClass=waterfox' "${home}/share/applications/waterfox.desktop"
}

@test "Waterfox launcher pins the managed profile across install directories" {
  local home="${BATS_TEST_TMPDIR}/home" root profile
  root="${home}/.waterfox"
  mkdir -p "${root}/old.default-release" "${root}/new.default-release-1"
  printf '[Profile1]\nName=default-release-1\nIsRelative=1\nPath=new.default-release-1\n\n[Profile0]\nName=default release\nIsRelative=1\nPath=old.default-release\n' \
    > "${root}/profiles.ini"
  profile=$(cd -P -- "${root}/old.default-release" && pwd)

  run env HOME="${home}" XDG_DATA_HOME="${home}/share" bash -c '
    source "$1"
    uname() { printf "Linux\n"; }
    configure_linux_entry_points /usr/bin/true "$(profile_name "$2" "$3")"
  ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh" "${root}" "${profile}"

  [[ ${status} -eq 0 ]]
  grep -Fxq 'Exec=/usr/bin/true -P "default release" %u' "${home}/share/applications/waterfox.desktop"
}

@test "Waterfox launcher uses the themed icon for a nonstandard binary" {
  local home="${BATS_TEST_TMPDIR}/home"

  run env HOME="${home}" XDG_DATA_HOME="${home}/share" bash -c '
    source "$1"
    uname() { printf "Linux\n"; }
    configure_linux_entry_points /usr/bin/true
  ' _ "${JSH_ROOT}/scripts/unix/configure/waterfox.sh"

  [[ ${status} -eq 0 ]]
  grep -Fxq 'Icon=waterfox' "${home}/share/applications/waterfox.desktop"
}

@test "XFCE browser helper preserves unrelated preferences idempotently" {
  export HOME="${BATS_TEST_TMPDIR}/home"
  export XDG_DATA_HOME="${BATS_TEST_TMPDIR}/data"
  export XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/config"
  export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state"
  export XDG_CURRENT_DESKTOP=XFCE
  mkdir -p "${XDG_DATA_HOME}/applications" "${XDG_CONFIG_HOME}/xfce4"
  printf '[Desktop Entry]\nExec=/bin/true %%u\n' > "${XDG_DATA_HOME}/applications/waterfox.desktop"
  printf 'WebBrowser=firefox\nTerminalEmulator=custom-terminal\n' > "${XDG_CONFIG_HOME}/xfce4/helpers.rc"
  xdg-mime() { [[ $1 == query ]] && printf 'waterfox.desktop\n'; }
  xdg-settings() { [[ $1 == get ]] && printf 'waterfox.desktop\n'; }

  configure_linux_default_browser waterfox.desktop
  local before
  before=$(file_identity "${XDG_CONFIG_HOME}/xfce4/helpers.rc")
  configure_linux_default_browser waterfox.desktop

  grep -Fxq WebBrowser=waterfox "${XDG_CONFIG_HOME}/xfce4/helpers.rc"
  grep -Fxq TerminalEmulator=custom-terminal "${XDG_CONFIG_HOME}/xfce4/helpers.rc"
  [[ $(file_identity "${XDG_CONFIG_HOME}/xfce4/helpers.rc") == "${before}" ]]
}
