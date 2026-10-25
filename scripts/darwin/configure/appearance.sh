#!/usr/bin/env bash
# Configure opt-in macOS appearance, Dock, and wallpaper.

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

set_default_if_needed() {
  local domain=$1 key=$2 type=$3 value=$4 current expected current_type expected_type
  expected=${value}
  expected_type=${type#-}
  case ${type}:${value} in
    -bool:true) expected=1; expected_type=boolean ;;
    -bool:false) expected=0; expected_type=boolean ;;
    -int:*) expected_type=integer ;;
  esac
  current=$(defaults read "${domain}" "${key}" 2> /dev/null || true)
  current_type=$(defaults read-type "${domain}" "${key}" 2> /dev/null || true)
  if [[ ${current} == "${expected}" && ${current_type} == "Type is ${expected_type}" ]]; then
    return 0
  fi
  defaults write "${domain}" "${key}" "${type}" "${value}"
  if [[ ${domain} == com.apple.dock ]]; then
    dock_changed=1
  fi
}

set_empty_dock_array_if_needed() {
  local key=$1 current
  current=$(defaults read com.apple.dock "${key}" 2> /dev/null || true)
  [[ ${current//[[:space:]]/} == '()' ]] && return 0
  defaults write com.apple.dock "${key}" -array
  dock_changed=1
}

configure_appearance() {
  local appearance_dir="${HOME}/Library/Application Support/jsh"
  local wallpaper candidate current_wallpaper dock_changed=0
  wallpaper=

  for candidate in "${JSH_ROOT}"/local/wallpaper.*; do
    [[ -f "${candidate}" && -r "${candidate}" ]] || continue
    wallpaper=${candidate}
    break
  done

  set_default_if_needed NSGlobalDomain AppleInterfaceStyle -string Dark
  set_default_if_needed NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically -bool false
  set_empty_dock_array_if_needed persistent-apps
  set_empty_dock_array_if_needed persistent-others
  set_default_if_needed com.apple.dock launchanim -bool false
  set_default_if_needed com.apple.dock expose-animation-duration -float 0.1
  set_default_if_needed com.apple.dock show-recents -bool false
  set_default_if_needed com.apple.dock autohide -bool true
  set_default_if_needed com.apple.dock autohide-delay -float 0
  set_default_if_needed com.apple.dock autohide-time-modifier -float 0.5
  set_default_if_needed com.apple.dock tilesize -int 48
  set_default_if_needed com.apple.dock wvous-tl-corner -int 0
  set_default_if_needed com.apple.dock wvous-tr-corner -int 0
  set_default_if_needed com.apple.dock wvous-bl-corner -int 0
  set_default_if_needed com.apple.dock wvous-br-corner -int 0

  if ! command -v osascript > /dev/null 2>&1; then
    jsh::log_note "Skipping wallpaper: osascript is unavailable."
  elif [[ -z "${wallpaper}" ]] && ! command -v magick > /dev/null 2>&1; then
    jsh::log_note "Skipping wallpaper: no local wallpaper was found and magick is unavailable."
  else
    if [[ -z "${wallpaper}" ]]; then
      wallpaper="${appearance_dir}/jsh-solid-black.png"
      mkdir -p "${appearance_dir}"
      [[ -f ${wallpaper} ]] || magick -size 16x16 canvas:black "${wallpaper}"
    fi
    current_wallpaper=$(osascript - "${wallpaper}" << 'APPLESCRIPT' 2> /dev/null || true
on run arguments
  tell application "System Events"
    repeat with desktopItem in desktops
      if picture of desktopItem is not item 1 of arguments then return "false"
    end repeat
  end tell
  return "true"
end run
APPLESCRIPT
)
    if [[ ${current_wallpaper} != true ]]; then
      osascript - "${wallpaper}" << 'APPLESCRIPT'
on run arguments
  tell application "System Events"
    repeat with desktopItem in desktops
      set picture of desktopItem to item 1 of arguments
    end repeat
  end tell
end run
APPLESCRIPT
    fi
  fi

  if ((dock_changed)) && [[ ${JSH_CLOSE_APPS:-1} == 1 ]]; then
    killall Dock > /dev/null 2>&1 || true
  fi
  jsh::log_success "macOS appearance and Dock configured."
}

main() {
  [[ "$(uname -s)" == Darwin ]] || {
    jsh::log_note "Skipping macOS appearance: macOS not detected."
    return
  }
  command -v defaults > /dev/null 2>&1 || {
    jsh::log_error "defaults is required to configure macOS."
    return 1
  }

  local arg
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
    esac
  done

  jsh::log_warn "Appearance setup clears pinned Dock items and replaces the desktop wallpaper."
  if jsh::confirm "Configure macOS appearance and Dock?" --default no; then
    configure_appearance
  else
    jsh::log_note "Skipping macOS appearance and Dock."
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
