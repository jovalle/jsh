#!/usr/bin/env bash
# Configure opt-in macOS appearance, Dock, wallpaper, and account picture.

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

confirm() {
  jsh_prompt "$1 [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]]
}

configure_appearance() {
  local appearance_dir="${HOME}/Library/Application Support/jsh"
  local wallpaper candidate
  wallpaper=

  for candidate in "${JSH_ROOT}"/local/wallpaper.*; do
    [[ -f "${candidate}" && -r "${candidate}" ]] || continue
    wallpaper=${candidate}
    break
  done

  defaults write NSGlobalDomain AppleInterfaceStyle -string Dark
  defaults write NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically -bool false
  defaults write com.apple.dock persistent-apps -array
  defaults write com.apple.dock persistent-others -array
  defaults write com.apple.dock launchanim -bool false
  defaults write com.apple.dock expose-animation-duration -float 0.1
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock autohide-delay -float 0
  defaults write com.apple.dock autohide-time-modifier -float 0.5
  defaults write com.apple.dock tilesize -int 48
  defaults write com.apple.dock wvous-tl-corner -int 0
  defaults write com.apple.dock wvous-tr-corner -int 0
  defaults write com.apple.dock wvous-bl-corner -int 0
  defaults write com.apple.dock wvous-br-corner -int 0

  if ! command -v osascript > /dev/null 2>&1; then
    jsh_warn "Skipping wallpaper: osascript is unavailable."
  elif [[ -z "${wallpaper}" ]] && ! command -v magick > /dev/null 2>&1; then
    jsh_warn "Skipping wallpaper: no local wallpaper was found and magick is unavailable."
  else
    if [[ -z "${wallpaper}" ]]; then
      wallpaper="${appearance_dir}/jsh-solid-black.png"
      mkdir -p "${appearance_dir}"
      magick -size 16x16 canvas:black "${wallpaper}"
    fi
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

  killall Dock > /dev/null 2>&1 || true
  killall Finder > /dev/null 2>&1 || true
  jsh_success "macOS appearance and Dock configured."
}

configure_account_picture() {
  local source="${JSH_USER_AVATAR:-${JSH_ROOT}/.github/assets/j.jpg}"
  local appearance_dir="${HOME}/Library/Application Support/jsh"
  local destination="${appearance_dir}/j-avatar.jpg"
  local username
  username=$(id -un)

  [[ -r "${source}" ]] || {
    jsh_warn "Skipping account picture: ${source} is unavailable."
    return
  }
  command -v dscl > /dev/null 2>&1 || {
    jsh_warn "Skipping account picture: dscl is unavailable."
    return
  }

  mkdir -p "${appearance_dir}"
  install -m 0644 "${source}" "${destination}"
  sudo dscl . -delete "/Users/${username}" JPEGPhoto > /dev/null 2>&1 || true
  sudo dscl . -create "/Users/${username}" Picture "${destination}"
  jsh_success "macOS account picture configured."
}

main() {
  [[ "$(uname -s)" == Darwin ]] || {
    jsh_info "Skipping macOS appearance: macOS not detected."
    return
  }
  command -v defaults > /dev/null 2>&1 || {
    jsh_error "defaults is required to configure macOS."
    return 1
  }

  jsh_warn "Appearance setup clears pinned Dock items and replaces the desktop wallpaper."
  if confirm "Configure macOS appearance and Dock?"; then
    configure_appearance
  else
    jsh_warn "Skipping macOS appearance and Dock."
  fi

  jsh_blank
  if confirm "Configure the local account picture?"; then
    configure_account_picture
  else
    jsh_warn "Skipping macOS account picture."
  fi
}

main "$@"
