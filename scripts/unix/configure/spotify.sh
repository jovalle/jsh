#!/usr/bin/env bash
# Configure Spotify preferences and prepare Spicetify on Linux and macOS.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

readonly SPICETIFY_FORMULA=spicetify-cli
readonly SPICETIFY_EXTENSION_DIR="${JSH_ROOT}/conf/spicetify"
readonly SPICETIFY_LEGACY_SETTINGS_EXTENSION=jsh-settings.js
readonly -a SPICETIFY_LEGACY_COMMAND_EXTENSIONS=(spotifi.js spotify.js)
readonly -a SPICETIFY_EXTENSIONS=(settings.js adder.js spotifix.js)

SPICETIFY_BIN=

spicetify_failure_details() {
  local output=$1 cleaned
  cleaned=$(printf '%s\n' "${output}" | sed -E $'s/\033\[[0-9;]*m//g; s/^[[:space:]]*(success|info|warning|error)[[:space:]]+//')
  [[ -z ${cleaned} ]] || jsh::log_detail "${cleaned}"
}

spotify_paths() {
  local platform=${JSH_SPOTIFY_PLATFORM:-$(uname -s)} spotify_path='' prefs_path=''
  local flatpak_deployment=''

  if [[ -n ${JSH_SPOTIFY_PATH:-} && -n ${JSH_SPOTIFY_PREFS:-} ]]; then
    printf '%s\n%s\n' "${JSH_SPOTIFY_PATH}" "${JSH_SPOTIFY_PREFS}"
    return
  fi

  case ${platform} in
    Darwin)
      spotify_path=/Applications/Spotify.app/Contents/Resources
      [[ -d ${spotify_path} ]] || spotify_path="${HOME}/Applications/Spotify.app/Contents/Resources"
      prefs_path="${HOME}/Library/Application Support/Spotify/prefs"
      ;;
    Linux)
      if command -v flatpak > /dev/null 2>&1; then
        flatpak_deployment=$(flatpak info --show-location com.spotify.Client 2> /dev/null || true)
        if [[ -d ${flatpak_deployment}/files/extra/share/spotify ]]; then
          spotify_path=${flatpak_deployment}/files/extra/share/spotify
        fi
      fi
      if [[ -z ${spotify_path} ]]; then
        for spotify_path in \
          "${HOME}/.local/share/flatpak/app/com.spotify.Client/"*/stable/active/files/extra/share/spotify \
          /var/lib/flatpak/app/com.spotify.Client/*/stable/active/files/extra/share/spotify \
          /usr/share/spotify; do
          [[ -d ${spotify_path} ]] && break
        done
      fi
      if [[ -r ${HOME}/.var/app/com.spotify.Client/config/spotify/prefs ]]; then
        prefs_path="${HOME}/.var/app/com.spotify.Client/config/spotify/prefs"
      else
        prefs_path="${HOME}/.config/spotify/prefs"
      fi
      ;;
    *)
      jsh::log_note "Skipping Spotify configuration: unsupported platform ${platform}."
      return 1
      ;;
  esac

  [[ -d ${spotify_path} ]] || {
    jsh::log_note "Skipping Spotify configuration: Spotify is not installed."
    return 1
  }
  [[ -r ${prefs_path} ]] || {
    jsh::log_note "Skipping Spotify configuration: open Spotify and sign in first."
    return 1
  }
  printf '%s\n%s\n' "${spotify_path}" "${prefs_path}"
}

ensure_spotify_writable() {
  local spotify_path=$1 platform=${JSH_SPOTIFY_PLATFORM:-$(uname -s)}
  [[ ${platform} == Linux ]] || return 0
  [[ -w ${spotify_path} && -w ${spotify_path}/Apps ]] && return 0

  jsh::log_error "Spicetify needs write access to the Spotify installation."
  jsh::log_detail "sudo chmod a+wr -- $(printf '%q' "${spotify_path}")"
  jsh::log_detail "sudo chmod -R a+wr -- $(printf '%q' "${spotify_path}/Apps")"
  return 1
}

spicetify_binary() {
  if command -v spicetify > /dev/null 2>&1; then
    command -v spicetify
  elif [[ -x ${HOME}/.spicetify/spicetify ]]; then
    printf '%s\n' "${HOME}/.spicetify/spicetify"
  else
    return 1
  fi
}

ensure_spicetify() {
  local output
  # shellcheck disable=SC2310 # spicetify_binary is intentionally used as a predicate.
  if SPICETIFY_BIN=$(spicetify_binary); then
    jsh::log_note "Spicetify is installed."
    return
  fi

  command -v brew > /dev/null 2>&1 || {
    jsh::log_error "Homebrew is required to install ${SPICETIFY_FORMULA}."
    return 1
  }
  jsh::log_info "Installing Spicetify..."
  if ! output=$(brew install "${SPICETIFY_FORMULA}" 2>&1); then
    jsh::log_error "Failed to install Spicetify."
    spicetify_failure_details "${output}"
    return 1
  fi
  # shellcheck disable=SC2310 # Failure is converted to a targeted error below.
  SPICETIFY_BIN=$(spicetify_binary) || {
    jsh::log_error "Spicetify installation did not provide an executable."
    return 1
  }
  jsh::log_success "Spicetify installed."
}

spotify_is_running() {
  pgrep -f '/spotify( |$)|Spotify.app/Contents/MacOS/Spotify' > /dev/null 2>&1
}

spotify_flatpak_is_running() {
  pgrep -f '/app/extra/share/spotify/spotify' > /dev/null 2>&1
}

confirm_spotify_close() {
  local tty=${JSH_SPOTIFY_TTY:-/dev/tty} input_fd previous_input_fd=${JSH_UI_INPUT_FD:-0}
  local previous_interactive=${JSH_INTERACTIVE:-0} confirm_status=0
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  [[ ! -f ${tty} || -s ${tty} ]] || {
    jsh::log_error "Could not confirm closing Spotify: no interactive input is available."
    return 1
  }
  exec {input_fd}< "${tty}" || {
    jsh::log_error "Could not confirm closing Spotify: no interactive input is available."
    return 1
  }
  JSH_UI_INPUT_FD=${input_fd}
  JSH_INTERACTIVE=1
  jsh::confirm "Spotify is running. Close it now?" --default yes || confirm_status=$?
  exec {input_fd}<&-
  JSH_UI_INPUT_FD=${previous_input_fd}
  JSH_INTERACTIVE=${previous_interactive}
  return "${confirm_status}"
}

close_spotify() {
  local platform=${JSH_SPOTIFY_PLATFORM:-$(uname -s)} attempt
  case ${platform} in
    Darwin)
      osascript -e 'tell application "Spotify" to quit' > /dev/null || return
      ;;
    Linux)
      # shellcheck disable=SC2310 # spotify_flatpak_is_running is intentionally used as a predicate.
      if spotify_flatpak_is_running && command -v flatpak > /dev/null 2>&1; then
        flatpak kill com.spotify.Client 2> /dev/null || return
      else
        pkill -TERM -f '/spotify( |$)' 2> /dev/null || return
      fi
      ;;
    *) return 1 ;;
  esac

  for ((attempt = 0; attempt < 50; attempt++)); do
    # shellcheck disable=SC2310 # spotify_is_running is intentionally used as a predicate.
    spotify_is_running || return 0
    sleep 0.2
  done
  return 1
}

close_spotify_if_running() {
  # shellcheck disable=SC2310 # spotify_is_running is intentionally used as a predicate.
  spotify_is_running || return 0
  # shellcheck disable=SC2310 # Confirmation failure is handled explicitly.
  if ! confirm_spotify_close; then
    jsh::log_note "Skipping Spotify configuration while Spotify is running."
    return 1
  fi
  # shellcheck disable=SC2310 # Shutdown failure is handled explicitly.
  if ! close_spotify; then
    jsh::log_error "Spotify did not close; configuration was not changed."
    return 1
  fi
  jsh::log_success "Spotify closed."
}

reopen_spotify() {
  local was_flatpak=${1:-0} platform=${JSH_SPOTIFY_PLATFORM:-$(uname -s)}
  case ${platform} in
    Darwin)
      open -a Spotify > /dev/null 2>&1
      ;;
    Linux)
      if ((was_flatpak)); then
        flatpak run com.spotify.Client > /dev/null 2>&1 &
      elif command -v spotify > /dev/null 2>&1; then
        spotify > /dev/null 2>&1 &
      else
        jsh::log_error "Spotify was closed but could not be reopened."
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

spicetify_backup_can_refresh() {
  [[ $1 == *'run "spicetify backup apply"'* ||
    $1 == *'Run "spicetify backup apply"'* ]]
}

spicetify_backup_needs_restore() {
  [[ $1 == *'run "spicetify restore backup'* ||
    $1 == *'Run "spicetify restore backup'* ]]
}

apply_spicetify() {
  local binary=$1 output
  shift
  if output=$("${binary}" --no-restart "$@" 2>&1); then
    return 0
  fi
  # shellcheck disable=SC2310 # Retry only when Spicetify requires a restore first.
  if spicetify_backup_needs_restore "${output}"; then
    jsh::log_info "Restoring Spotify before refreshing Spicetify's backup..."
    if ! output=$("${binary}" --no-restart restore 2>&1); then
      jsh::log_error "Failed to restore Spotify before refreshing Spicetify's backup."
      spicetify_failure_details "${output}"
      return 1
    fi
    if ! output=$("${binary}" --no-restart backup apply 2>&1); then
      jsh::log_error "Failed to restore, refresh, and apply Spicetify."
      spicetify_failure_details "${output}"
      return 1
    fi
    return 0
  fi
  # shellcheck disable=SC2310 # Retry only when Spicetify reports a backupable client.
  if ! spicetify_backup_can_refresh "${output}"; then
    jsh::log_error "Failed to apply Spicetify."
    spicetify_failure_details "${output}"
    return 1
  fi
  jsh::log_info "Refreshing Spicetify's backup for the current Spotify version..."
  if ! output=$("${binary}" --no-restart backup apply 2>&1); then
    # shellcheck disable=SC2310 # Retry only when backup refresh requires a restore first.
    if spicetify_backup_needs_restore "${output}"; then
      jsh::log_info "Restoring Spotify before refreshing Spicetify's backup..."
      if ! output=$("${binary}" --no-restart restore 2>&1); then
        jsh::log_error "Failed to restore Spotify before refreshing Spicetify's backup."
        spicetify_failure_details "${output}"
        return 1
      fi
      if output=$("${binary}" --no-restart backup apply 2>&1); then
        return 0
      fi
    fi
    jsh::log_error "Failed to refresh and apply Spicetify."
    spicetify_failure_details "${output}"
    return 1
  fi
}

spicetify_config_value() {
  local config_file=$1 key=$2
  [[ -r ${config_file} ]] || return 1
  awk -F= -v key="${key}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      val = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      print val
      exit
    }
  ' "${config_file}"
}

spicetify_has_extension() {
  local config_file=$1 extension=$2 current_extensions
  # shellcheck disable=SC2310 # Failure handled explicitly.
  current_extensions=$(spicetify_config_value "${config_file}" "extensions") || return 1
  [[ "|${current_extensions// /}|" == *"|${extension}|"* ]]
}

spicetify_paths_match() {
  local config_file=$1 expected_spotify=$2 expected_prefs=$3
  local current_spotify current_prefs
  # shellcheck disable=SC2310 # Failure handled explicitly.
  current_spotify=$(spicetify_config_value "${config_file}" "spotify_path") || return 1
  # shellcheck disable=SC2310 # Failure handled explicitly.
  current_prefs=$(spicetify_config_value "${config_file}" "prefs_path") || return 1
  [[ "${current_spotify%/}" == "${expected_spotify%/}" && "${current_prefs}" == "${expected_prefs}" ]]
}

spicetify_backup_version() {
  local target=${1:-}
  if [[ -n ${target} && -r ${target} ]]; then
    awk '
      {
        line = $0
        gsub(/\033\[[0-9;]*m/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
      }
      line == "[Backup]" || line == "Backup" { in_backup = 1; next }
      /^\[.*\]$/ { in_backup = 0 }
      in_backup && $1 == "version" {
        if (index(line, "=") > 0) {
          val = substr(line, index(line, "=") + 1)
        } else {
          val = $2
        }
        sub(/^[[:space:]]+/, "", val)
        sub(/[[:space:]]+$/, "", val)
        print val
        exit
      }
    ' "${target}"
  else
    awk '
      {
        line = $0
        gsub(/\033\[[0-9;]*m/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
      }
      line == "[Backup]" || line == "Backup" { in_backup = 1; next }
      /^\[.*\]$/ { in_backup = 0 }
      in_backup && $1 == "version" {
        if (index(line, "=") > 0) {
          val = substr(line, index(line, "=") + 1)
        } else {
          val = $2
        }
        sub(/^[[:space:]]+/, "", val)
        sub(/[[:space:]]+$/, "", val)
        print val
        exit
      }
    '
  fi
}

spicetify_is_applied() {
  local spotify_path=$1 backup_version=$2 extension
  [[ -n ${backup_version} ]] || return 1
  [[ -r ${spotify_path}/Apps/xpui/index.html ]] || return 1
  grep -Fq 'spicetifyWrapper.js' "${spotify_path}/Apps/xpui/index.html" || return 1
  for extension in "${SPICETIFY_EXTENSIONS[@]}"; do
    [[ -r ${spotify_path}/Apps/xpui/extensions/${extension} ]] || return 1
    cmp -s -- "${SPICETIFY_EXTENSION_DIR}/${extension}" \
      "${spotify_path}/Apps/xpui/extensions/${extension}" || return 1
  done
}

spotify_configuration_is_current() {
  local binary=$1 spotify_path=$2 prefs_path=$3
  local config_file config_dir backup_version extension legacy_extension

  [[ -x ${binary} ]] || return 1
  config_file=$("${binary}" -c 2> /dev/null) || return 1
  [[ -r ${config_file} ]] || return 1
  config_dir=${config_file%/*}

  # shellcheck disable=SC2310 # State queries are used as predicates.
  spicetify_paths_match "${config_file}" "${spotify_path}" "${prefs_path}" || return 1
  for extension in "${SPICETIFY_EXTENSIONS[@]}"; do
    cmp -s -- "${SPICETIFY_EXTENSION_DIR}/${extension}" \
      "${config_dir}/Extensions/${extension}" || return 1
    # shellcheck disable=SC2310 # State queries are used as predicates.
    spicetify_has_extension "${config_file}" "${extension}" || return 1
  done
  # shellcheck disable=SC2310 # Legacy state is used as a predicate.
  spicetify_has_extension "${config_file}" "${SPICETIFY_LEGACY_SETTINGS_EXTENSION}" && return 1
  [[ ! -e ${config_dir}/Extensions/${SPICETIFY_LEGACY_SETTINGS_EXTENSION} ]] || return 1
  for legacy_extension in "${SPICETIFY_LEGACY_COMMAND_EXTENSIONS[@]}"; do
    # shellcheck disable=SC2310 # Legacy state is used as a predicate.
    spicetify_has_extension "${config_file}" "${legacy_extension}" && return 1
    [[ ! -e ${config_dir}/Extensions/${legacy_extension} ]] || return 1
  done

  backup_version=$(spicetify_backup_version "${config_file}")
  [[ -n ${backup_version} ]] || return 1

  # shellcheck disable=SC2310 # State queries are used as predicates.
  spicetify_is_applied "${spotify_path}" "${backup_version}" || return 1
  return 0
}

configure_spicetify() {
  local binary=$1 spotify_path=$2 prefs_path=$3
  local config_file config_dir extension extension_dir output backup_version legacy_extension
  local needs_apply=0
  local -a apply_command=(backup apply)

  if ! config_file=$("${binary}" -c 2>&1); then
    jsh::log_error "Failed to locate the Spicetify configuration."
    spicetify_failure_details "${config_file}"
    return 1
  fi
  config_dir=${config_file%/*}
  extension_dir="${config_dir}/Extensions"

  # shellcheck disable=SC2310 # State queries are used as predicates.
  if spicetify_paths_match "${config_file}" "${spotify_path}" "${prefs_path}"; then
    :
  else
    jsh::log_info "Configuring Spicetify..."
    if ! output=$("${binary}" config spotify_path "${spotify_path}" prefs_path "${prefs_path}" 2>&1); then
      jsh::log_error "Failed to configure Spicetify paths."
      spicetify_failure_details "${output}"
      return 1
    fi
    needs_apply=1
  fi

  install -d -m 0700 -- "${extension_dir}"
  for extension in "${SPICETIFY_EXTENSIONS[@]}"; do
    if cmp -s -- "${SPICETIFY_EXTENSION_DIR}/${extension}" "${extension_dir}/${extension}"; then
      jsh::log_note "Spicetify extension ${extension} is current."
    else
      install -m 0600 -- "${SPICETIFY_EXTENSION_DIR}/${extension}" "${extension_dir}/${extension}"
      jsh::log_success "Spicetify extension ${extension} updated."
      needs_apply=1
    fi

    # shellcheck disable=SC2310 # State queries are used as predicates.
    if ! spicetify_has_extension "${config_file}" "${extension}"; then
      if ! output=$("${binary}" config extensions "${extension}" 2>&1); then
        jsh::log_error "Failed to enable Spicetify extension ${extension}."
        spicetify_failure_details "${output}"
        return 1
      fi
      needs_apply=1
    fi
  done

  # shellcheck disable=SC2310 # Legacy state is used as a predicate.
  if spicetify_has_extension "${config_file}" "${SPICETIFY_LEGACY_SETTINGS_EXTENSION}"; then
    if ! output=$("${binary}" config extensions "${SPICETIFY_LEGACY_SETTINGS_EXTENSION}-" 2>&1); then
      jsh::log_error "Failed to disable the renamed Spotify settings extension."
      spicetify_failure_details "${output}"
      return 1
    fi
    needs_apply=1
  fi
  rm -f -- "${extension_dir}/${SPICETIFY_LEGACY_SETTINGS_EXTENSION}"

  for legacy_extension in "${SPICETIFY_LEGACY_COMMAND_EXTENSIONS[@]}"; do
    # shellcheck disable=SC2310 # Legacy state is used as a predicate.
    if spicetify_has_extension "${config_file}" "${legacy_extension}"; then
      if ! output=$("${binary}" config extensions "${legacy_extension}-" 2>&1); then
        jsh::log_error "Failed to disable the renamed Spotify command extension ${legacy_extension}."
        spicetify_failure_details "${output}"
        return 1
      fi
      needs_apply=1
    fi
    rm -f -- "${extension_dir}/${legacy_extension}"
  done

  if [[ -r ${config_file} ]]; then
    backup_version=$(spicetify_backup_version "${config_file}")
  fi
  if [[ -z ${backup_version:-} ]]; then
    if output=$(NO_COLOR=1 "${binary}" config 2>&1); then
      backup_version=$(spicetify_backup_version <<< "${output}")
    fi
  fi
  [[ -z ${backup_version:-} ]] || apply_command=(apply)

  # shellcheck disable=SC2310 # State queries are used as predicates.
  if ((!needs_apply)) && spicetify_is_applied "${spotify_path}" "${backup_version:-}"; then
    jsh::log_note "Spicetify is applied."
    return 0
  fi

  jsh::log_info "Applying Spicetify..."
  apply_spicetify "${binary}" "${apply_command[@]}" || return 1
  jsh::log_success "Spicetify applied."
}

main() {
  local spotify_path prefs_path locations spotify_was_running=0 spotify_was_flatpak=0
  local -a spotify_locations=()
  while (($#)); do
    case $1 in
      -y | --yes) JSH_ASSUME_YES=1 ;;
      *)
        jsh::log_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  # shellcheck disable=SC2310 # Missing Spotify state is a supported skip.
  locations=$(spotify_paths) || return 0
  mapfile -t spotify_locations <<< "${locations}"
  spotify_path=${spotify_locations[0]}
  prefs_path=${spotify_locations[1]}

  ensure_spotify_writable "${spotify_path}" || return 1
  ensure_spicetify

  # shellcheck disable=SC2310 # State check is used as a predicate.
  if spotify_configuration_is_current "${SPICETIFY_BIN}" "${spotify_path}" "${prefs_path}"; then
    # shellcheck disable=SC2310 # Status check is used as a predicate.
    if spotify_is_running; then
      jsh::log_note "Spotify configuration is current; leaving Spotify open."
    else
      jsh::log_note "Spotify configuration is current."
    fi
    return 0
  fi

  # shellcheck disable=SC2310 # Status checks determine whether Spotify should be restored.
  if spotify_is_running; then
    spotify_was_running=1
    spotify_flatpak_is_running && spotify_was_flatpak=1
  fi

  # shellcheck disable=SC2310 # Shutdown failure is handled explicitly.
  close_spotify_if_running || return 1
  configure_spicetify "${SPICETIFY_BIN}" "${spotify_path}" "${prefs_path}"
  if ((spotify_was_running)); then
    reopen_spotify "${spotify_was_flatpak}" || return 1
    jsh::log_success "Spotify configuration complete. Spotify reopened."
  else
    jsh::log_success "Spotify configuration complete. Settings apply on next launch."
  fi
}

if [[ ${JSH_SPOTIFY_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
