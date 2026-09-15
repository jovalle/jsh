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
readonly SPICETIFY_EXTENSION=jsh-settings.js
readonly SPICETIFY_EXTENSION_SOURCE="${JSH_ROOT}/conf/spicetify/${SPICETIFY_EXTENSION}"
readonly SPICETIFY_MARKETPLACE_INSTALLER=https://raw.githubusercontent.com/spicetify/marketplace/main/resources/install.sh

SPICETIFY_BIN=

spicetify_failure_details() {
  local output=$1 cleaned
  cleaned=$(printf '%s\n' "${output}" | sed -E $'s/\033\[[0-9;]*m//g; s/^[[:space:]]*(success|info|warning|error)[[:space:]]+//')
  [[ -z ${cleaned} ]] || jsh_detail "${cleaned}"
}

spotify_paths() {
  local platform=${JSH_SPOTIFY_PLATFORM:-$(uname -s)} spotify_path='' prefs_path=''

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
      for spotify_path in \
        "${HOME}/.local/share/flatpak/app/com.spotify.Client/x86_64/stable/active/files/extra/share/spotify" \
        /var/lib/flatpak/app/com.spotify.Client/x86_64/stable/active/files/extra/share/spotify \
        /usr/share/spotify; do
        [[ -d ${spotify_path} ]] && break
      done
      if [[ -r ${HOME}/.var/app/com.spotify.Client/config/spotify/prefs ]]; then
        prefs_path="${HOME}/.var/app/com.spotify.Client/config/spotify/prefs"
      else
        prefs_path="${HOME}/.config/spotify/prefs"
      fi
      ;;
    *)
      jsh_note "Skipping Spotify configuration: unsupported platform ${platform}."
      return 1
      ;;
  esac

  [[ -d ${spotify_path} ]] || {
    jsh_note "Skipping Spotify configuration: Spotify is not installed."
    return 1
  }
  [[ -r ${prefs_path} ]] || {
    jsh_note "Skipping Spotify configuration: open Spotify and sign in first."
    return 1
  }
  printf '%s\n%s\n' "${spotify_path}" "${prefs_path}"
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
    jsh_note "Spicetify is installed."
    return
  fi

  command -v brew > /dev/null 2>&1 || {
    jsh_error "Homebrew is required to install ${SPICETIFY_FORMULA}."
    return 1
  }
  jsh_info "Installing Spicetify..."
  if ! output=$(brew install "${SPICETIFY_FORMULA}" 2>&1); then
    jsh_error "Failed to install Spicetify."
    spicetify_failure_details "${output}"
    return 1
  fi
  # shellcheck disable=SC2310 # Failure is converted to a targeted error below.
  SPICETIFY_BIN=$(spicetify_binary) || {
    jsh_error "Spicetify installation did not provide an executable."
    return 1
  }
  jsh_success "Spicetify installed."
}

spotify_is_running() {
  pgrep -f '/spotify( |$)|Spotify.app/Contents/MacOS/Spotify' > /dev/null 2>&1
}

spotify_flatpak_is_running() {
  pgrep -f '/app/extra/share/spotify/spotify' > /dev/null 2>&1
}

confirm_spotify_close() {
  local tty=${JSH_SPOTIFY_TTY:-/dev/tty} answer
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  while :; do
    jsh_prompt "Spotify is running. Close it now? [Y/n]: "
    if ! IFS= read -r answer < "${tty}"; then
      jsh_error "Could not confirm closing Spotify: no interactive input is available."
      return 1
    fi
    case ${answer} in
      '' | y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) jsh_warn "Please answer yes or no." ;;
    esac
  done
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
    jsh_note "Skipping Spotify configuration while Spotify is running."
    return 1
  fi
  # shellcheck disable=SC2310 # Shutdown failure is handled explicitly.
  if ! close_spotify; then
    jsh_error "Spotify did not close; configuration was not changed."
    return 1
  fi
  jsh_success "Spotify closed."
}

ensure_spicetify_marketplace() {
  local binary=$1 config_dir=$2 installer output custom_apps wrapper_dir
  custom_apps=$("${binary}" config custom_apps 2> /dev/null || true)
  if [[ -r ${config_dir}/CustomApps/marketplace/manifest.json && " ${custom_apps} " == *' marketplace '* ]]; then
    jsh_note "Spicetify Marketplace is installed."
    return
  fi

  jsh_info "Installing Spicetify Marketplace..."
  mkdir -p "${JSH_ROOT}/tmp"
  installer=$(mktemp "${JSH_ROOT}/tmp/spicetify-marketplace.XXXXXX")
  if ! output=$(curl -fsSL --retry 2 --output "${installer}" "${SPICETIFY_MARKETPLACE_INSTALLER}" 2>&1); then
    rm -f -- "${installer}"
    jsh_error "Failed to download the Spicetify Marketplace installer."
    spicetify_failure_details "${output}"
    return 1
  fi
  wrapper_dir=$(mktemp -d "${JSH_ROOT}/tmp/spicetify-wrapper.XXXXXX")
  # shellcheck disable=SC2016 # Variables expand when the generated wrapper runs.
  printf '#!/bin/sh\nexec "$SPICETIFY_REAL" --no-restart "$@"\n' > "${wrapper_dir}/spicetify"
  chmod 0700 "${wrapper_dir}/spicetify"
  if ! output=$(SPICETIFY_CONFIG="${config_dir}" SPICETIFY_REAL="${binary}" \
    PATH="${wrapper_dir}:${PATH}" sh "${installer}" 2>&1); then
    rm -rf -- "${installer}" "${wrapper_dir}"
    jsh_error "Failed to install Spicetify Marketplace."
    spicetify_failure_details "${output}"
    return 1
  fi
  rm -rf -- "${installer}" "${wrapper_dir}"
  jsh_success "Spicetify Marketplace installed."
}

configure_spicetify() {
  local binary=$1 spotify_path=$2 prefs_path=$3 config_file config_dir extension_dir output backup_version
  local -a apply_command=(backup apply)

  jsh_info "Configuring Spicetify..."
  if ! output=$("${binary}" config spotify_path "${spotify_path}" prefs_path "${prefs_path}" 2>&1); then
    jsh_error "Failed to configure Spicetify paths."
    spicetify_failure_details "${output}"
    return 1
  fi
  if ! config_file=$("${binary}" -c 2>&1); then
    jsh_error "Failed to locate the Spicetify configuration."
    spicetify_failure_details "${config_file}"
    return 1
  fi
  config_dir=${config_file%/*}
  extension_dir="${config_file%/*}/Extensions"
  install -d -m 0700 -- "${extension_dir}"
  if cmp -s -- "${SPICETIFY_EXTENSION_SOURCE}" "${extension_dir}/${SPICETIFY_EXTENSION}"; then
    jsh_note "Spotify settings extension is current."
  else
    install -m 0600 -- "${SPICETIFY_EXTENSION_SOURCE}" "${extension_dir}/${SPICETIFY_EXTENSION}"
    jsh_success "Spotify settings extension updated."
  fi
  if ! output=$("${binary}" config extensions "${SPICETIFY_EXTENSION}" 2>&1); then
    jsh_error "Failed to enable the Spotify settings extension."
    spicetify_failure_details "${output}"
    return 1
  fi

  ensure_spicetify_marketplace "${binary}" "${config_dir}"
  if output=$(NO_COLOR=1 "${binary}" config 2>&1); then
    backup_version=$(awk '
      {
        line = $0
        gsub(/\033\[[0-9;]*m/, "", line)
      }
      line == "Backup" { in_backup = 1; next }
      in_backup && $1 == "version" { print $2; exit }
    ' <<< "${output}")
    [[ -z ${backup_version} ]] || apply_command=(apply)
  fi

  jsh_info "Applying Spicetify..."
  if ! output=$("${binary}" --no-restart "${apply_command[@]}" 2>&1); then
    jsh_error "Failed to apply Spicetify."
    spicetify_failure_details "${output}"
    return 1
  fi
  jsh_success "Spicetify applied."
}

main() {
  local spotify_path prefs_path locations
  local -a spotify_locations=()
  # shellcheck disable=SC2310 # Missing Spotify state is a supported skip.
  locations=$(spotify_paths) || return 0
  mapfile -t spotify_locations <<< "${locations}"
  spotify_path=${spotify_locations[0]}
  prefs_path=${spotify_locations[1]}

  close_spotify_if_running
  ensure_spicetify
  configure_spicetify "${SPICETIFY_BIN}" "${spotify_path}" "${prefs_path}"
  jsh_success "Spotify configuration complete; settings apply on next launch."
}

if [[ ${JSH_SPOTIFY_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
