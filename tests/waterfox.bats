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

@test "waterfox command provides Waterfox repair" {
  [[ -x ${JSH_ROOT}/bin/waterfox ]]
  [[ ! -e ${JSH_ROOT}/bin/flushfox ]]

  run "${JSH_ROOT}/bin/waterfox" --help

  [[ ${status} -eq 0 ]]
  [[ ${output} == *"Organize Waterfox bookmarks"* ]]
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
  grep -Fxq "Icon=${resolved_install}/browser/chrome/icons/default/default128.png" \
    "${home}/share/applications/waterfox.desktop"
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
