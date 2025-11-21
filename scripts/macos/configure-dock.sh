#!/usr/bin/env bash
#
# configure-dock.sh - Configure macOS Dock settings
#
# This script customizes the macOS Dock by removing all pinned icons,
# hiding the Dock, and setting the icon size to 48.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

log_info "Configuring macOS Dock..."

# Remove all persistent apps from the Dock
log_info "Removing all pinned icons..."
defaults write com.apple.dock persistent-apps -array

# Remove all persistent others (recent apps, folders, etc.)
defaults write com.apple.dock persistent-others -array

# Hide the Dock
log_info "Hiding Dock..."
defaults write com.apple.dock autohide -bool true

# Set Dock icon size to 48
log_info "Setting icon size to 48..."
defaults write com.apple.dock tilesize -int 48

# Optional: Remove the auto-hide delay for instant show/hide
# Uncomment if desired:
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.5

# Restart Dock to apply changes
log_info "Restarting Dock..."
killall Dock

log_info "Dock configuration complete!"
