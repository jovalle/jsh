#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Each Bats test runs in its own subshell.

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export JSH_ASSUME_YES=0
  export JSH_SPOTIFY_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/unix/configure/spotify.sh"
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh_detail() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh_note() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh_success() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh_info() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh_prompt() { printf '%s' "$*"; }
}

@test "uses explicit Spotify paths for platform-independent testing" {
  export JSH_SPOTIFY_PATH="${BATS_TEST_TMPDIR}/spotify"
  export JSH_SPOTIFY_PREFS="${BATS_TEST_TMPDIR}/prefs"

  run spotify_paths

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} = "${JSH_SPOTIFY_PATH}" ]]
  [[ ${lines[1]} = "${JSH_SPOTIFY_PREFS}" ]]
}

@test "main skips configuration when Spotify is absent" {
  local marker="${BATS_TEST_TMPDIR}/spicetify-called"
  spotify_paths() { return 1; }
  ensure_spicetify() { touch "${marker}"; }

  run main

  [[ ${status} -eq 0 ]]
  [[ ! -e ${marker} ]]
}

@test "reports missing Spicetify instead of returning an empty command" {
  mkdir -p "${BATS_TEST_TMPDIR}/empty-home"

  run bash -c '
    source "$1"
    HOME="$2" PATH=/usr/bin:/bin spicetify_binary
  ' _ "${JSH_ROOT}/scripts/unix/configure/spotify.sh" "${BATS_TEST_TMPDIR}/empty-home"

  [[ ${status} -ne 0 ]]
  [[ -z ${output} ]]
}

@test "confirmation closes a running Spotify Flatpak" {
  local running=1
  export JSH_SPOTIFY_PLATFORM=Linux
  export JSH_SPOTIFY_TTY="${BATS_TEST_TMPDIR}/spotify-input"
  printf '\n' > "${JSH_SPOTIFY_TTY}"
  export SPOTIFY_CLOSE_CALLS="${BATS_TEST_TMPDIR}/spotify-close-calls"
  # shellcheck disable=SC2329 # Called indirectly by close_spotify_if_running.
  spotify_is_running() { [[ ${running} -eq 1 ]]; }
  # shellcheck disable=SC2329 # Called indirectly by close_spotify.
  spotify_flatpak_is_running() { return 0; }
  flatpak() {
    printf '%s\n' "$*" >> "${SPOTIFY_CLOSE_CALLS}"
    running=0
  }

  run close_spotify_if_running

  [[ ${status} -eq 0 ]]
  [[ ${output} = 'Spotify is running. Close it now? [Y/n]: ' ]]
  grep -Fxq 'kill com.spotify.Client' "${SPOTIFY_CLOSE_CALLS}"
}

@test "uses AppleScript to close Spotify on macOS" {
  local running=1
  export JSH_SPOTIFY_PLATFORM=Darwin
  export JSH_SPOTIFY_TTY="${BATS_TEST_TMPDIR}/spotify-input"
  printf 'y\n' > "${JSH_SPOTIFY_TTY}"
  export SPOTIFY_CLOSE_CALLS="${BATS_TEST_TMPDIR}/spotify-close-calls"
  # shellcheck disable=SC2329 # Called indirectly by close_spotify_if_running.
  spotify_is_running() { [[ ${running} -eq 1 ]]; }
  osascript() {
    printf '%s\n' "$*" >> "${SPOTIFY_CLOSE_CALLS}"
    running=0
  }

  run close_spotify_if_running

  [[ ${status} -eq 0 ]]
  grep -Fxq -- '-e tell application "Spotify" to quit' "${SPOTIFY_CLOSE_CALLS}"
}

@test "fails clearly when closing Spotify cannot be confirmed" {
  export JSH_SPOTIFY_TTY="${BATS_TEST_TMPDIR}/empty-input"
  : > "${JSH_SPOTIFY_TTY}"
  # shellcheck disable=SC2329 # Called indirectly by close_spotify_if_running.
  spotify_is_running() { return 0; }
  jsh_error() { printf '%s\n' "$*" >&2; }

  run close_spotify_if_running

  [[ ${status} -ne 0 ]]
  [[ ${output} = *'no interactive input is available'* ]]
}

@test "installs and enables the managed extension before applying Spicetify" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$1" = -c ]; then
  printf '%s\n' "${SPICETIFY_CONFIG}"
fi
EOF
  chmod +x "${binary}"
  # shellcheck disable=SC2329 # Called indirectly by configure_spicetify.
  ensure_spicetify_marketplace() { :; }

  run configure_spicetify "${binary}" '/opt/Spotify Resources' '/home/user/Spotify prefs'

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  cmp -s "${JSH_ROOT}/conf/spicetify/jsh-settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/jsh-settings.js"
  mapfile -t calls < "${SPICETIFY_CALLS}"
  [[ ${calls[0]} = 'config spotify_path /opt/Spotify Resources prefs_path /home/user/Spotify prefs' ]]
  [[ ${calls[1]} = '-c' ]]
  [[ ${calls[2]} = 'config extensions jsh-settings.js' ]]
  [[ ${calls[3]} = 'config' ]]
  [[ ${calls[4]} = '--no-restart backup apply' ]]
}

@test "reuses an existing Spicetify backup" {
  local binary="${BATS_TEST_TMPDIR}/spicetify" last_call
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
case "$*" in
  -c) printf '%s\n' "${SPICETIFY_CONFIG}" ;;
  config) printf '\033[1mBackup\033[0m\nversion 1.2.3\n' ;;
  *) printf 'raw Spicetify output\n' ;;
esac
EOF
  chmod +x "${binary}"
  mkdir -p "${BATS_TEST_TMPDIR}/config/Extensions"
  cp "${JSH_ROOT}/conf/spicetify/jsh-settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/jsh-settings.js"
  # shellcheck disable=SC2329 # Called indirectly by configure_spicetify.
  ensure_spicetify_marketplace() { :; }

  run configure_spicetify "${binary}" '/opt/spotify' '/home/user/prefs'

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  last_call=$(tail -n 1 "${SPICETIFY_CALLS}")
  [[ ${last_call} = '--no-restart apply' ]]
}

@test "removes third-party status prefixes from failure details" {
  jsh_detail() { printf '%s\n' "$*"; }

  run spicetify_failure_details $'spicetify v2.45.0\n\033[36m info \033[0m Apply the config\n warning  Restore the backup'

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} = 'spicetify v2.45.0' ]]
  [[ ${lines[1]} = 'Apply the config' ]]
  [[ ${lines[2]} = 'Restore the backup' ]]
}
