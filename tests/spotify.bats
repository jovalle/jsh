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
  jsh::log_detail() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh::log_note() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh::log_success() { :; }
  # shellcheck disable=SC2329 # Called indirectly by sourced functions.
  jsh::log_info() { :; }
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

@test "discovers Flatpak Spotify on non-x86 Linux" {
  export JSH_SPOTIFY_PLATFORM=Linux
  export HOME="${BATS_TEST_TMPDIR}/home"
  local spotify="${HOME}/.local/share/flatpak/app/com.spotify.Client/aarch64/stable/active/files/extra/share/spotify"
  local prefs="${HOME}/.var/app/com.spotify.Client/config/spotify/prefs"
  mkdir -p "${spotify}" "${prefs%/*}"
  touch "${prefs}"
  flatpak() { return 1; }

  run spotify_paths

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} = "${spotify}" ]]
  [[ ${lines[1]} = "${prefs}" ]]
}

@test "prefers the active Flatpak deployment over stale architecture directories" {
  export JSH_SPOTIFY_PLATFORM=Linux
  export HOME="${BATS_TEST_TMPDIR}/home"
  local deployment="${HOME}/.local/share/flatpak/app/com.spotify.Client/x86_64/stable/current"
  local spotify="${deployment}/files/extra/share/spotify"
  local prefs="${HOME}/.var/app/com.spotify.Client/config/spotify/prefs"
  mkdir -p \
    "${spotify}" \
    "${HOME}/.local/share/flatpak/app/com.spotify.Client/aarch64/stable/active/files/extra/share/spotify" \
    "${prefs%/*}"
  touch "${prefs}"
  flatpak() {
    [[ $* = 'info --show-location com.spotify.Client' ]] || return 1
    printf '%s\n' "${deployment}"
  }

  run spotify_paths

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} = "${spotify}" ]]
  [[ ${lines[1]} = "${prefs}" ]]
}

@test "reports commands required for a non-writable Linux Spotify install" {
  export JSH_SPOTIFY_PLATFORM=Linux
  local spotify="${BATS_TEST_TMPDIR}/Spotify Resources"
  mkdir -p "${spotify}/Apps"
  chmod 0555 "${spotify}" "${spotify}/Apps"
  jsh::log_error() { printf '%s\n' "$*"; }
  jsh::log_detail() { printf '%s\n' "$*"; }

  run ensure_spotify_writable "${spotify}"
  chmod 0755 "${spotify}" "${spotify}/Apps"

  [[ ${status} -ne 0 ]]
  [[ ${lines[0]} = 'Spicetify needs write access to the Spotify installation.' ]]
  [[ ${lines[1]} = "sudo chmod a+wr -- ${spotify// /\\ }" ]]
  [[ ${lines[2]} = "sudo chmod -R a+wr -- ${spotify// /\\ }/Apps" ]]
}

@test "main skips configuration when Spotify is absent" {
  local marker="${BATS_TEST_TMPDIR}/spicetify-called"
  spotify_paths() { return 1; }
  # shellcheck disable=SC2329 # Mocked ensure_spicetify called by main.
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
  export SPOTIFY_CLOSE_CALLS="${BATS_TEST_TMPDIR}/spotify-close-calls"
  jsh::confirm() { [[ $* == 'Spotify is running. Close it now? --default yes' ]]; }
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
  [[ -z ${output} ]]
  grep -Fxq 'kill com.spotify.Client' "${SPOTIFY_CLOSE_CALLS}"
}

@test "main --yes closes Spotify without prompting" {
  export JSH_SPOTIFY_TTY="${BATS_TEST_TMPDIR}/empty-input"
  : > "${JSH_SPOTIFY_TTY}"
  spotify_paths() { printf '%s\n%s\n' '/opt/spotify' '/home/user/prefs'; }
  ensure_spotify_writable() { return 0; }
  # shellcheck disable=SC2034,SC2329 # SPICETIFY_BIN is consumed by main.
  ensure_spicetify() { SPICETIFY_BIN=/usr/bin/true; }
  spotify_configuration_is_current() { return 1; }
  spotify_is_running() { return 0; }
  spotify_flatpak_is_running() { return 1; }
  close_spotify() { touch "${BATS_TEST_TMPDIR}/closed-called"; }
  configure_spicetify() { :; }
  reopen_spotify() { :; }

  run main --yes

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  [[ -e ${BATS_TEST_TMPDIR}/closed-called ]]
}

@test "uses AppleScript to close Spotify on macOS" {
  local running=1
  export JSH_SPOTIFY_PLATFORM=Darwin
  export SPOTIFY_CLOSE_CALLS="${BATS_TEST_TMPDIR}/spotify-close-calls"
  jsh::confirm() { return 0; }
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
  jsh::log_error() { printf '%s\n' "$*" >&2; }

  run close_spotify_if_running

  [[ ${status} -ne 0 ]]
  [[ ${output} = *'no interactive input is available'* ]]
}

@test "installs and enables managed extensions before applying Spicetify" {
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
  run configure_spicetify "${binary}" '/opt/Spotify Resources' '/home/user/Spotify prefs'

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  cmp -s "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"
  cmp -s "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/adder.js"
  cmp -s "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/spotifix.js"
  mapfile -t calls < "${SPICETIFY_CALLS}"
  [[ ${calls[0]} = '-c' ]]
  [[ ${calls[1]} = 'config spotify_path /opt/Spotify Resources prefs_path /home/user/Spotify prefs' ]]
  [[ ${calls[2]} = 'config extensions settings.js' ]]
  [[ ${calls[3]} = 'config extensions adder.js' ]]
  [[ ${calls[4]} = 'config extensions spotifix.js' ]]
  [[ ${calls[5]} = 'config' ]]
  [[ ${calls[6]} = '--no-restart backup apply' ]]
}

@test "renames the managed settings extension" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  mkdir -p "${BATS_TEST_TMPDIR}/config/Extensions"
  touch "${BATS_TEST_TMPDIR}/config/Extensions/jsh-settings.js"
  cat > "${SPICETIFY_CONFIG}" <<'EOF'
[Setting]
spotify_path = /opt/spotify
prefs_path = /home/user/prefs

[AdditionalOptions]
extensions = jsh-settings.js|adder.js

[Backup]
version = 1.2.3
EOF
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/adder.js"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$1" = -c ]; then
  printf '%s\n' "${SPICETIFY_CONFIG}"
fi
EOF
  chmod +x "${binary}"

  run configure_spicetify "${binary}" '/opt/spotify' '/home/user/prefs'

  [[ ${status} -eq 0 ]]
  grep -Fxq 'config extensions settings.js' "${SPICETIFY_CALLS}"
  grep -Fxq 'config extensions jsh-settings.js-' "${SPICETIFY_CALLS}"
  [[ ! -e ${BATS_TEST_TMPDIR}/config/Extensions/jsh-settings.js ]]
  cmp -s "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"
}

@test "renames the managed Spotify command extension" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  mkdir -p "${BATS_TEST_TMPDIR}/config/Extensions"
  touch "${BATS_TEST_TMPDIR}/config/Extensions/spotifi.js"
  touch "${BATS_TEST_TMPDIR}/config/Extensions/spotify.js"
  cat > "${SPICETIFY_CONFIG}" <<'EOF'
[Setting]
spotify_path = /opt/spotify
prefs_path = /home/user/prefs

[AdditionalOptions]
extensions = settings.js|adder.js|spotifi.js|spotify.js

[Backup]
version = 1.2.3
EOF
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/adder.js"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$1" = -c ]; then
  printf '%s\n' "${SPICETIFY_CONFIG}"
fi
EOF
  chmod +x "${binary}"

  run configure_spicetify "${binary}" '/opt/spotify' '/home/user/prefs'

  [[ ${status} -eq 0 ]]
  grep -Fxq 'config extensions spotifix.js' "${SPICETIFY_CALLS}"
  grep -Fxq 'config extensions spotifi.js-' "${SPICETIFY_CALLS}"
  grep -Fxq 'config extensions spotify.js-' "${SPICETIFY_CALLS}"
  [[ ! -e ${BATS_TEST_TMPDIR}/config/Extensions/spotifi.js ]]
  [[ ! -e ${BATS_TEST_TMPDIR}/config/Extensions/spotify.js ]]
  cmp -s "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/spotifix.js"
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
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"

  run configure_spicetify "${binary}" '/opt/spotify' '/home/user/prefs'

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  last_call=$(tail -n 1 "${SPICETIFY_CALLS}")
  [[ ${last_call} = '--no-restart apply' ]]
}

@test "refreshes a stale Spicetify backup without reinstalling Spotify" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$*" = '--no-restart apply' ]; then
  printf '%s\n' \
    'Spotify version and backup version are mismatched.' \
    'Spotify client is in stock state' \
    'Please run "spicetify backup apply"'
  exit 1
fi
EOF
  chmod +x "${binary}"

  run apply_spicetify "${binary}" apply

  [[ ${status} -eq 0 ]]
  mapfile -t calls < "${SPICETIFY_CALLS}"
  [[ ${calls[0]} = '--no-restart apply' ]]
  [[ ${calls[1]} = '--no-restart backup apply' ]]
}

@test "restores Spotify when Spicetify requires it before refreshing backup" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$*" = '--no-restart apply' ]; then
  printf '%s\n' \
    'A backup is available' \
    'Please restore first then backup, run "spicetify restore backup"'
  exit 1
fi
EOF
  chmod +x "${binary}"

  run apply_spicetify "${binary}" apply

  [[ ${status} -eq 0 ]]
  mapfile -t calls < "${SPICETIFY_CALLS}"
  [[ ${calls[0]} = '--no-restart apply' ]]
  [[ ${calls[1]} = '--no-restart restore' ]]
  [[ ${calls[2]} = '--no-restart backup apply' ]]
}

@test "restores outdated preprocessed data using Spicetify's requested recovery" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$*" = '--no-restart apply' ]; then
  printf '%s\n' \
    'spicetify v2.45.1' \
    'Preprocessed Spotify data is outdated. Please run "spicetify restore backup apply" to receive new features and bug fixes'
  exit 1
fi
EOF
  chmod +x "${binary}"

  run apply_spicetify "${binary}" apply

  [[ ${status} -eq 0 ]]
  mapfile -t calls < "${SPICETIFY_CALLS}"
  [[ ${calls[0]} = '--no-restart apply' ]]
  [[ ${calls[1]} = '--no-restart restore' ]]
  [[ ${calls[2]} = '--no-restart backup apply' ]]
}

@test "restores Spotify when backup refresh discovers an existing backup" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_BACKUP_ATTEMPTS="${BATS_TEST_TMPDIR}/backup-attempts"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
if [ "$*" = '--no-restart apply' ]; then
  printf '%s\n' 'Please run "spicetify backup apply"'
  exit 1
fi
if [ "$*" = '--no-restart backup apply' ] && [ ! -e "${SPICETIFY_BACKUP_ATTEMPTS}" ]; then
  : > "${SPICETIFY_BACKUP_ATTEMPTS}"
  printf '%s\n' 'Please restore first then backup, run "spicetify restore backup"'
  exit 1
fi
EOF
  chmod +x "${binary}"

  run apply_spicetify "${binary}" apply

  [[ ${status} -eq 0 ]]
  mapfile -t calls < "${SPICETIFY_CALLS}"
  [[ ${calls[0]} = '--no-restart apply' ]]
  [[ ${calls[1]} = '--no-restart backup apply' ]]
  [[ ${calls[2]} = '--no-restart restore' ]]
  [[ ${calls[3]} = '--no-restart backup apply' ]]
}

@test "does not reinstall an unbackupable Spotify client" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
printf '%s\n' \
  'Spotify version and backup version are mismatched.' \
  'Spotify cannot be backed up at this state.'
exit 1
EOF
  chmod +x "${binary}"
  jsh::log_error() { :; }

  run apply_spicetify "${binary}" apply

  [[ ${status} -ne 0 ]]
  [[ $(wc -l < "${SPICETIFY_CALLS}") -eq 1 ]]
  [[ $(< "${SPICETIFY_CALLS}") = '--no-restart apply' ]]
}

@test "removes third-party status prefixes from failure details" {
  jsh::log_detail() { printf '%s\n' "$*"; }

  run spicetify_failure_details $'spicetify v2.45.0\n\033[36m info \033[0m Apply the config\n warning  Restore the backup'

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} = 'spicetify v2.45.0' ]]
  [[ ${lines[1]} = 'Apply the config' ]]
  [[ ${lines[2]} = 'Restore the backup' ]]
}

@test "skips configuring paths and extensions when already present in config" {
  local binary="${BATS_TEST_TMPDIR}/spicetify" last_call
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  mkdir -p "${BATS_TEST_TMPDIR}/config/Extensions"
  cat > "${SPICETIFY_CONFIG}" <<EOF
[Setting]
spotify_path = /opt/spotify
prefs_path = /home/user/prefs

[AdditionalOptions]
extensions = settings.js|adder.js|spotifix.js
custom_apps =

[Backup]
version = 1.2.3
EOF
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/adder.js"
  cp "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/spotifix.js"
  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
case "$*" in
  -c) printf '%s\n' "${SPICETIFY_CONFIG}" ;;
  *) printf 'ok\n' ;;
esac
EOF
  chmod +x "${binary}"
  run configure_spicetify "${binary}" '/opt/spotify' '/home/user/prefs'

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  run grep -q 'config spotify_path' "${SPICETIFY_CALLS}"
  [[ ${status} -ne 0 ]]
  run grep -q 'config extensions' "${SPICETIFY_CALLS}"
  [[ ${status} -ne 0 ]]
  last_call=$(tail -n 1 "${SPICETIFY_CALLS}")
  [[ ${last_call} = '--no-restart apply' ]]
}

@test "skips apply when Spicetify is already applied to Spotify bundle" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  mkdir -p "${BATS_TEST_TMPDIR}/config/Extensions"
  cat > "${SPICETIFY_CONFIG}" <<EOF
[Setting]
spotify_path = ${BATS_TEST_TMPDIR}/spotify
prefs_path = /home/user/prefs

[AdditionalOptions]
extensions = settings.js|adder.js|spotifix.js
custom_apps =

[Backup]
version = 1.2.3
EOF
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/adder.js"
  cp "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/spotifix.js"

  mkdir -p "${BATS_TEST_TMPDIR}/spotify/Apps/xpui/extensions"
  printf '<script src="helper/spicetifyWrapper.js"></script>\n' > "${BATS_TEST_TMPDIR}/spotify/Apps/xpui/index.html"
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/spotify/Apps/xpui/extensions/settings.js"
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/spotify/Apps/xpui/extensions/adder.js"
  cp "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${BATS_TEST_TMPDIR}/spotify/Apps/xpui/extensions/spotifix.js"

  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
case "$*" in
  -c) printf '%s\n' "${SPICETIFY_CONFIG}" ;;
  *) printf 'ok\n' ;;
esac
EOF
  chmod +x "${binary}"

  run configure_spicetify "${binary}" "${BATS_TEST_TMPDIR}/spotify" '/home/user/prefs'

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  run grep -q 'apply' "${SPICETIFY_CALLS}"
  [[ ${status} -ne 0 ]]
  run grep -q 'config spotify_path' "${SPICETIFY_CALLS}"
  [[ ${status} -ne 0 ]]
  run grep -q 'config extensions' "${SPICETIFY_CALLS}"
  [[ ${status} -ne 0 ]]
}

@test "main leaves running Spotify open and makes no changes when current" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export JSH_SPOTIFY_PATH="${BATS_TEST_TMPDIR}/spotify"
  export JSH_SPOTIFY_PREFS="${BATS_TEST_TMPDIR}/prefs"
  touch "${JSH_SPOTIFY_PREFS}"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"
  mkdir -p "${BATS_TEST_TMPDIR}/config/Extensions"
  cat > "${SPICETIFY_CONFIG}" <<EOF
[Setting]
spotify_path = ${JSH_SPOTIFY_PATH}
prefs_path = ${JSH_SPOTIFY_PREFS}

[AdditionalOptions]
extensions = settings.js|adder.js|spotifix.js
custom_apps =

[Backup]
version = 1.2.3
EOF
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/settings.js"
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/adder.js"
  cp "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${BATS_TEST_TMPDIR}/config/Extensions/spotifix.js"

  mkdir -p "${JSH_SPOTIFY_PATH}/Apps/xpui/extensions"
  printf '<script src="helper/spicetifyWrapper.js"></script>\n' > "${JSH_SPOTIFY_PATH}/Apps/xpui/index.html"
  cp "${JSH_ROOT}/conf/spicetify/settings.js" \
    "${JSH_SPOTIFY_PATH}/Apps/xpui/extensions/settings.js"
  cp "${JSH_ROOT}/conf/spicetify/adder.js" \
    "${JSH_SPOTIFY_PATH}/Apps/xpui/extensions/adder.js"
  cp "${JSH_ROOT}/conf/spicetify/spotifix.js" \
    "${JSH_SPOTIFY_PATH}/Apps/xpui/extensions/spotifix.js"

  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
case "$*" in
  -c) printf '%s\n' "${SPICETIFY_CONFIG}" ;;
  *) printf 'ok\n' ;;
esac
EOF
  chmod +x "${binary}"

  # shellcheck disable=SC2329 # Called indirectly by main.
  ensure_spicetify() { SPICETIFY_BIN="${binary}"; }
  # shellcheck disable=SC2329 # Called indirectly by main.
  spotify_is_running() { return 0; }
  # shellcheck disable=SC2329 # Called indirectly by main.
  close_spotify_if_running() { return 1; }

  run main

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  run grep -q 'apply' "${SPICETIFY_CALLS}"
  [[ ${status} -ne 0 ]]
}

@test "main closes and reopens Spotify when configuration requires changes" {
  local binary="${BATS_TEST_TMPDIR}/spicetify"
  export JSH_SPOTIFY_PATH="${BATS_TEST_TMPDIR}/spotify"
  export JSH_SPOTIFY_PREFS="${BATS_TEST_TMPDIR}/prefs"
  mkdir -p "${JSH_SPOTIFY_PATH}/Apps"
  touch "${JSH_SPOTIFY_PREFS}"
  export SPICETIFY_CALLS="${BATS_TEST_TMPDIR}/spicetify-calls"
  export SPICETIFY_CONFIG="${BATS_TEST_TMPDIR}/config/config-xpui.ini"

  cat > "${binary}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SPICETIFY_CALLS}"
case "$*" in
  -c) printf '%s\n' "${SPICETIFY_CONFIG}" ;;
  *) printf 'ok\n' ;;
esac
EOF
  chmod +x "${binary}"

  # shellcheck disable=SC2034,SC2329 # SPICETIFY_BIN is consumed by main.
  ensure_spicetify() { SPICETIFY_BIN="${binary}"; }
  # shellcheck disable=SC2329 # Called indirectly by main.
  spotify_is_running() { return 0; }
  # shellcheck disable=SC2329 # Called indirectly by main.
  spotify_flatpak_is_running() { return 0; }
  # shellcheck disable=SC2329 # Called indirectly by main.
  close_spotify_if_running() { touch "${BATS_TEST_TMPDIR}/closed-called"; return 0; }
  # shellcheck disable=SC2329 # Called indirectly by main.
  reopen_spotify() { printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/reopened-called"; }

  run main

  [[ ${status} -eq 0 ]]
  [[ -e ${BATS_TEST_TMPDIR}/closed-called ]]
  [[ $(< "${BATS_TEST_TMPDIR}/reopened-called") = 1 ]]
  grep -q 'apply' "${SPICETIFY_CALLS}"
}

@test "main leaves Spotify closed when configuration changes while not running" {
  spotify_paths() { printf '%s\n%s\n' '/opt/spotify' '/home/user/prefs'; }
  ensure_spotify_writable() { return 0; }
  # shellcheck disable=SC2034,SC2329 # SPICETIFY_BIN is consumed by main.
  ensure_spicetify() { SPICETIFY_BIN=/usr/bin/true; }
  spotify_configuration_is_current() { return 1; }
  spotify_is_running() { return 1; }
  close_spotify_if_running() { return 0; }
  configure_spicetify() { touch "${BATS_TEST_TMPDIR}/configured-called"; }
  reopen_spotify() { touch "${BATS_TEST_TMPDIR}/reopened-called"; }

  run main

  [[ ${status} -eq 0 ]]
  [[ -e ${BATS_TEST_TMPDIR}/configured-called ]]
  [[ ! -e ${BATS_TEST_TMPDIR}/reopened-called ]]
}
