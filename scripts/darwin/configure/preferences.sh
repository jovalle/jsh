#!/usr/bin/env bash
# Configure opt-in macOS privacy, input, Finder, and application preferences.

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
  jsh_info "This will apply the managed macOS privacy, input, Finder, and application preferences."
  jsh_prompt "Configure macOS preferences? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]]
}

apply_preferences() {
  local line description='' action domain key type value current current_type expected expected_type previous
  local changed=0 unchanged=0 failed=0 has_current
  local -a scope_args=()
  PREFERENCE_STATUS=0

  while IFS= read -r line; do
    case ${line} in
      '# '*) description=${line#\# } ;;
      '') ;;
      *)
        if [[ -z ${description} ]]; then
          jsh_error "Failed: managed preference has no comment: ${line}"
          ((failed += 1))
          continue
        fi
        line=${line#defaults }
        scope_args=()
        if [[ ${line} == '-currentHost '* ]]; then
          scope_args=(-currentHost)
          line=${line#-currentHost }
        fi
        # Backslash escapes keep multiword defaults keys as one field.
        # shellcheck disable=SC2162
        read action domain key type value <<< "${line}"
        if [[ ${value:0:2} == \~/ ]]; then
          value="${HOME}/${value#\~/}"
        fi
        case ${type}:${value} in
          -bool:true) expected=1; expected_type='Type is boolean' ;;
          -bool:false) expected=0; expected_type='Type is boolean' ;;
          -int:*) expected=${value}; expected_type='Type is integer' ;;
          -float:*) expected=${value}; expected_type='Type is float' ;;
          -string:*) expected=${value}; expected_type='Type is string' ;;
        esac

        has_current=0
        if current=$(defaults "${scope_args[@]}" read "${domain}" "${key}" 2> /dev/null); then
          has_current=1
          current_type=$(defaults "${scope_args[@]}" read-type "${domain}" "${key}" 2> /dev/null || true)
        fi
        if ((has_current)) && [[ ${current} == "${expected}" && ${current_type} == "${expected_type}" ]]; then
          jsh_stdout 2 '= ' "${description}"
          ((unchanged += 1))
        elif defaults "${scope_args[@]}" "${action}" "${domain}" "${key}" "${type}" "${value}"; then
          previous=${current:-unset}
          jsh_success "${description} (${previous} -> ${expected})"
          ((changed += 1))
        else
          jsh_error "${description}"
          ((failed += 1))
        fi
        description=
        ;;
    esac
  done <<'PREFERENCES'
# Apple personalized advertising is disabled
defaults write com.apple.AdLib allowApplePersonalizedAdvertising -bool false
# Use of the Apple advertising identifier is disabled
defaults write com.apple.AdLib allowIdentifierForAdvertising -bool false
# Siri is disabled
defaults write com.apple.assistant.support Assistant\ Enabled -bool false
# Dictation is disabled
defaults write com.apple.assistant.support Dictation\ Enabled -bool false
# The Siri menu item is hidden
defaults write com.apple.Siri StatusMenuVisible -bool false
# Siri setup remains declined
defaults write com.apple.Siri UserHasDeclinedEnable -bool true
# Lookup suggestions are disabled
defaults write com.apple.lookup.shared LookupSuggestionsDisabled -bool true
# Handoff activity advertising is enabled
defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true
# Handoff activity receiving is enabled
defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool true
# Crash reports do not show a dialog
defaults write com.apple.CrashReporter DialogType -string none
# The Spotlight menu item is hidden
defaults write com.apple.Spotlight MenuItemHidden -bool true

# External drives are hidden from the desktop
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
# Internal drives are hidden from the desktop
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool false
# Mounted servers are hidden from the desktop
defaults write com.apple.finder ShowMountedServersOnDesktop -bool false
# Removable media is hidden from the desktop
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool false
# Finder defaults to list view
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv
# Finder shows the path bar
defaults write com.apple.finder ShowPathbar -bool true
# Finder shows the status bar
defaults write com.apple.finder ShowStatusBar -bool true
# Finder window titles show the full POSIX path
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
# Finder shows hidden files
defaults write com.apple.finder AppleShowAllFiles -bool true
# Finder animations are disabled
defaults write com.apple.finder DisableAllAnimations -bool true
# Finder does not warn before changing a file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
# Desktop widgets are hidden
defaults write com.apple.WindowManager StandardHideWidgets -bool true
# Stage Manager widgets are hidden
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true

# Window animations are disabled
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
# Window resizing uses the minimum animation duration
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
# Holding a key repeats it instead of showing the accent picker
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
# Key repeat is fast
defaults write NSGlobalDomain KeyRepeat -int 2
# The initial key repeat delay is short
defaults write NSGlobalDomain InitialKeyRepeat -int 15
# Full keyboard navigation is enabled
defaults write NSGlobalDomain AppleKeyboardUIMode -int 3
# File extensions are always shown
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# New documents save locally by default
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
# Save dialogs start expanded
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
# New-style save dialogs start expanded
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
# Print dialogs start expanded
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
# New-style print dialogs start expanded
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
# Automatic capitalization is disabled
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
# Smart dash substitution is disabled
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
# Automatic period substitution is disabled
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
# Smart quote substitution is disabled
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
# Automatic spelling correction is disabled
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
# Interface sound feedback is disabled
defaults write NSGlobalDomain com.apple.sound.beep.feedback -bool false
# Alert volume is muted
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0

# System alert volume is muted
defaults write com.apple.systemsound com.apple.sound.beep.volume -int 0
# System interface sounds are disabled
defaults write com.apple.systemsound com.apple.sound.uiaudio.enabled -int 0
# Network volumes do not receive .DS_Store files
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
# USB volumes do not receive .DS_Store files
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
# Time Machine does not offer newly attached disks for backup
defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true
# Terminal does not show line marks
defaults write com.apple.Terminal ShowLineMarks -int 0
# TextEdit creates plain-text documents
defaults write com.apple.TextEdit RichText -int 0
# TextEdit reads plain text as UTF-8
defaults write com.apple.TextEdit PlainTextEncoding -int 4
# TextEdit writes plain text as UTF-8
defaults write com.apple.TextEdit PlainTextEncodingForWrite -int 4
# Image Capture does not open when a device connects
defaults -currentHost write com.apple.ImageCapture disableHotPlug -bool true

# Screenshots are saved in ~/Pictures/Screenshots
defaults write com.apple.screencapture location -string ~/Pictures/Screenshots
# Screenshots use PNG format
defaults write com.apple.screencapture type -string png
# Screenshots omit window shadows
defaults write com.apple.screencapture disable-shadow -bool true
PREFERENCES

  if ((failed)); then
    jsh_error "macOS preferences: ${changed} changed, ${unchanged} unchanged, ${failed} failed."
    PREFERENCE_STATUS=1
    return
  fi
  jsh_success "macOS preferences: ${changed} changed, ${unchanged} unchanged."
}

main() {
  [[ "$(uname -s)" == Darwin ]] || {
    jsh_info "Skipping macOS preferences: macOS not detected."
    return
  }
  command -v defaults > /dev/null 2>&1 || {
    jsh_error "defaults is required to configure macOS."
    return 1
  }
  confirm || {
    jsh_warn "Skipping macOS preferences."
    return
  }

  mkdir -p "${HOME}/Pictures/Screenshots"
  apply_preferences

  killall Finder > /dev/null 2>&1 || true
  killall SystemUIServer > /dev/null 2>&1 || true
  return "${PREFERENCE_STATUS}"
}

main "$@"
