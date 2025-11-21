#!/usr/bin/env bash
#
# configure-settings.sh - Configure macOS for optimal privacy and minimalism
#
# This script applies comprehensive macOS settings to:
# - Maximize privacy and security
# - Reduce visual and auditory distractions
# - Simplify the user interface
# - Disable telemetry and tracking
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}[====]${NC} $*"; }

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    log_error "This script is intended for macOS only."
    exit 1
fi

log_info "Starting macOS configuration for privacy, simplicity, and minimal noise..."
echo ""

###############################################################################
# PRIVACY & SECURITY
###############################################################################

log_section "Configuring Privacy & Security Settings"

# Disable analytics and telemetry
log_info "Disabling analytics and telemetry..."
defaults write com.apple.AdLib allowApplePersonalizedAdvertising -bool false 2>/dev/null || true
defaults write com.apple.AdLib allowIdentifierForAdvertising -bool false 2>/dev/null || true
if sudo -n true 2>/dev/null; then
    sudo defaults write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist AutoSubmit -bool false 2>/dev/null || true
    sudo defaults write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist ThirdPartyDataSubmit -bool false 2>/dev/null || true
fi

# Disable Siri and dictation
log_info "Disabling Siri and dictation..."
defaults write com.apple.assistant.support "Assistant Enabled" -bool false
defaults write com.apple.assistant.backedup "Session Language" -string "en-US"
defaults write com.apple.Siri StatusMenuVisible -bool false
defaults write com.apple.Siri UserHasDeclinedEnable -bool true
defaults write com.apple.assistant.support "Dictation Enabled" -bool false

# Disable Spotlight suggestions
log_info "Disabling Spotlight suggestions..."
defaults write com.apple.lookup.shared LookupSuggestionsDisabled -bool true 2>/dev/null || true

# Disable location services (requires manual configuration in System Settings)
# Note: Location services must be configured manually in System Settings > Privacy & Security

# Wi-Fi analytics
# Note: Wi-Fi analytics settings are managed through System Settings

# Disable Handoff
log_info "Disabling Handoff..."
defaults write ~/Library/Preferences/ByHost/com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
defaults write ~/Library/Preferences/ByHost/com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false

# Safari privacy settings (if Safari is installed and not sandboxed)
if [[ -d "/Applications/Safari.app" ]]; then
    log_info "Configuring Safari privacy settings..."
    defaults write com.apple.Safari SendDoNotTrackHTTPHeader -bool true 2>/dev/null || true
    defaults write com.apple.Safari AutoFillPasswords -bool false 2>/dev/null || true
    defaults write com.apple.Safari AutoFillCreditCardData -bool false 2>/dev/null || true
    defaults write com.apple.Safari IncludeInternalDebugMenu -bool true 2>/dev/null || true
    defaults write com.apple.Safari IncludeDevelopMenu -bool true 2>/dev/null || true
    defaults write com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey -bool true 2>/dev/null || true
    defaults write com.apple.Safari com.apple.Safari.ContentPageGroupIdentifier.WebKit2DeveloperExtrasEnabled -bool true 2>/dev/null || true
    defaults write com.apple.Safari WebContinuousSpellCheckingEnabled -bool false 2>/dev/null || true
    defaults write com.apple.Safari WebAutomaticSpellingCorrectionEnabled -bool false 2>/dev/null || true
fi

# Disable recent items
log_info "Clearing and limiting recent items..."
defaults write com.apple.dock show-recents -bool false
defaults write -g NSNavRecentPlacesLimit -int 0 2>/dev/null || true
defaults write NSGlobalDomain NSRecentDocumentsLimit -int 0 2>/dev/null || true

# Disable crash reporter
log_info "Disabling crash reporter..."
defaults write com.apple.CrashReporter DialogType -string "none"

# Disable automatic app updates and checks (for manual control)
log_info "Configuring software update preferences..."
defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true 2>/dev/null || true
defaults write com.apple.SoftwareUpdate AutomaticDownload -bool false 2>/dev/null || true
defaults write com.apple.commerce AutoUpdate -bool false 2>/dev/null || true

###############################################################################
# SIMPLICITY & UI MINIMALISM
###############################################################################

log_section "Configuring UI Simplicity Settings"

# Minimize menu bar items
log_info "Configuring menu bar..."
defaults write com.apple.systemuiserver menuExtras -array \
    "/System/Library/CoreServices/Menu Extras/AirPort.menu" \
    "/System/Library/CoreServices/Menu Extras/Battery.menu" \
    "/System/Library/CoreServices/Menu Extras/Clock.menu"
defaults write com.apple.controlcenter "NSStatusItem Visible Battery" -bool true
defaults write com.apple.controlcenter "NSStatusItem Visible Bluetooth" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible Clock" -bool true
defaults write com.apple.controlcenter "NSStatusItem Visible FocusModes" -bool false
defaults write com.apple.controlcenter "NSStatusItem Visible WiFi" -bool true

# Hide Spotlight icon
log_info "Hiding Spotlight icon from menu bar..."
defaults write com.apple.Spotlight MenuItemHidden -bool true 2>/dev/null || true

# Desktop - hide icons and clean appearance
log_info "Simplifying desktop..."
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowMountedServersOnDesktop -bool false
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool false

# Finder - use list view and keep it simple
log_info "Configuring Finder for simplicity..."
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
defaults write com.apple.finder AppleShowAllFiles -bool false

# Remove animations for speed
log_info "Reducing animations..."
defaults write com.apple.dock launchanim -bool false
defaults write com.apple.dock expose-animation-duration -float 0.1
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.5
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
defaults write com.apple.finder DisableAllAnimations -bool true

# Disable Dashboard
log_info "Disabling Dashboard..."
defaults write com.apple.dashboard mcx-disabled -bool true

# Don't show recent applications in Dock
defaults write com.apple.dock show-recents -bool false

# Hot corners - disable all
log_info "Disabling hot corners..."
defaults write com.apple.dock wvous-tl-corner -int 0
defaults write com.apple.dock wvous-tr-corner -int 0
defaults write com.apple.dock wvous-bl-corner -int 0
defaults write com.apple.dock wvous-br-corner -int 0

# Launchpad - reset and minimize
log_info "Resetting Launchpad..."
find ~/Library/Application\ Support/Dock -name "*.db" -maxdepth 1 -delete 2>/dev/null || true

###############################################################################
# NOISE CANCELLATION (SOUNDS, NOTIFICATIONS, DISTRACTIONS)
###############################################################################

log_section "Configuring Noise Cancellation Settings"

# Disable all system sounds
log_info "Disabling system sounds..."
defaults write com.apple.systemsound "com.apple.sound.beep.volume" -int 0
defaults write com.apple.systemsound "com.apple.sound.uiaudio.enabled" -int 0
defaults write NSGlobalDomain com.apple.sound.beep.feedback -bool false
defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0

# Disable sound effects on boot (requires admin privileges)
if sudo -n true 2>/dev/null; then
    sudo nvram SystemAudioVolume=" " 2>/dev/null || log_warn "Could not disable boot sound (may require SIP disabled)"
fi

# Disable user interface sound effects
defaults write com.apple.systemsound "com.apple.sound.uiaudio.enabled" -int 0

# Notification Center - minimize
log_info "Minimizing Notification Center..."
defaults write com.apple.notificationcenterui ShowInNotificationCenter -bool false
defaults write com.apple.notificationcenterui DisplayNotificationCenter -bool false

# Disable automatic brightness (requires admin privileges)
if sudo -n true 2>/dev/null; then
    sudo defaults write /Library/Preferences/com.apple.iokit.AmbientLightSensor "Automatic Display Enabled" -bool false 2>/dev/null || true
fi

# Disable keyboard illumination in low light (requires admin privileges)
if sudo -n true 2>/dev/null; then
    sudo defaults write /Library/Preferences/com.apple.iokit.AmbientLightSensor "Automatic Keyboard Enabled" -bool false 2>/dev/null || true
fi

# Disable time machine prompts
log_info "Disabling Time Machine prompts..."
defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true

# Disable Photos opening automatically
log_info "Disabling Photos auto-launch..."
defaults -currentHost write com.apple.ImageCapture disableHotPlug -bool true

# Reduce transparency for better focus
log_info "Reducing transparency..."
defaults write com.apple.universalaccess reduceTransparency -bool true 2>/dev/null || defaults write NSGlobalDomain AppleReduceDesktopTinting -bool true 2>/dev/null || true

# Disable automatic app termination
log_info "Disabling automatic app termination..."
defaults write NSGlobalDomain NSDisableAutomaticTermination -bool true

# Disable press-and-hold for accented characters (enables key repeat)
log_info "Enabling key repeat..."
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false

# Set fast key repeat rate
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

###############################################################################
# ADDITIONAL OPTIMIZATIONS
###############################################################################

log_section "Applying Additional Optimizations"

# Expand save panel by default
log_info "Expanding save and print panels by default..."
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true

# Save to disk (not to iCloud) by default
log_info "Setting default save location to disk..."
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

# Disable automatic capitalization
log_info "Disabling automatic text transformations..."
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# Disable smart quotes and dashes
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false

# Trackpad: enable tap to click
log_info "Enabling tap to click..."
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

# Increase sound quality for Bluetooth headphones
log_info "Improving Bluetooth audio quality..."
defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 40

# Enable full keyboard access for all controls
log_info "Enabling full keyboard access..."
defaults write NSGlobalDomain AppleKeyboardUIMode -int 3

# Disable "Are you sure you want to open this application?" dialogs
log_info "Disabling quarantine warnings..."
defaults write com.apple.LaunchServices LSQuarantine -bool false

# Avoid creating .DS_Store files on network or USB volumes
log_info "Preventing .DS_Store on network volumes..."
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Show all filename extensions
log_info "Showing all filename extensions..."
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Disable warning when changing file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Enable AirDrop over Ethernet and on unsupported Macs
defaults write com.apple.NetworkBrowser BrowseAllInterfaces -bool true

# Screenshots - save to dedicated folder
log_info "Configuring screenshot location..."
mkdir -p "${HOME}/Pictures/Screenshots"
defaults write com.apple.screencapture location -string "${HOME}/Pictures/Screenshots"
defaults write com.apple.screencapture type -string "png"
defaults write com.apple.screencapture disable-shadow -bool true

###############################################################################
# TERMINAL & DEVELOPMENT
###############################################################################

log_section "Configuring Terminal & Development Settings"

# Terminal - disable line marks
log_info "Configuring Terminal..."
defaults write com.apple.Terminal ShowLineMarks -int 0

# TextEdit - use plain text mode for new documents
log_info "Configuring TextEdit for plain text..."
defaults write com.apple.TextEdit RichText -int 0
defaults write com.apple.TextEdit PlainTextEncoding -int 4
defaults write com.apple.TextEdit PlainTextEncodingForWrite -int 4

###############################################################################
# CLEANUP & RESTART
###############################################################################

log_section "Finalizing Configuration"

# Kill affected applications
log_info "Restarting affected applications..."
for app in "Activity Monitor" "cfprefsd" "Dock" "Finder" "Safari" "SystemUIServer" "Terminal"; do
    killall "${app}" &>/dev/null || true
done

echo ""
log_info "✓ macOS configuration complete!"
log_warn "Some changes may require a full system restart to take effect."
log_warn "You may want to restart your Mac now."
echo ""
