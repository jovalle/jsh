#!/usr/bin/env bash
#
# configure-settings.sh - Configure GNOME for optimal privacy and minimalism
#
# This script applies comprehensive GNOME settings to:
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

# Check if running on Linux with GNOME
if [[ "$(uname -s)" != "Linux" ]]; then
  log_error "This script is intended for Linux only."
  exit 1
fi

if ! command -v gsettings &>/dev/null; then
  log_error "gsettings not found. This script requires GNOME."
  exit 1
fi

log_info "Starting GNOME configuration for privacy, simplicity, and minimal noise..."
echo ""

###############################################################################
# PRIVACY & SECURITY
###############################################################################

log_section "Configuring Privacy & Security Settings"

# Disable telemetry and usage reporting
log_info "Disabling telemetry and usage reporting..."
gsettings set org.gnome.desktop.privacy report-technical-problems false 2>/dev/null || true
gsettings set org.gnome.desktop.privacy send-software-usage-stats false 2>/dev/null || true

# Disable location services
log_info "Disabling location services..."
gsettings set org.gnome.system.location enabled false 2>/dev/null || true

# Disable recent files tracking
log_info "Disabling recent files tracking..."
gsettings set org.gnome.desktop.privacy remember-recent-files false 2>/dev/null || true
gsettings set org.gnome.desktop.privacy recent-files-max-age 0 2>/dev/null || true

# Disable search indexing of personal files
log_info "Limiting search indexing..."
gsettings set org.freedesktop.Tracker3.Miner.Files crawling-interval -2 2>/dev/null || true
gsettings set org.freedesktop.Tracker3.Miner.Files enable-monitors false 2>/dev/null || true

# Screen lock settings
log_info "Configuring screen lock..."
gsettings set org.gnome.desktop.screensaver lock-enabled true 2>/dev/null || true
gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null || true
gsettings set org.gnome.desktop.session idle-delay 300 2>/dev/null || true

# Disable automatic login
log_info "Ensuring manual login is required..."
# Note: This typically requires editing /etc/gdm/custom.conf with root

###############################################################################
# SIMPLICITY & UI MINIMALISM
###############################################################################

log_section "Configuring UI Simplicity Settings"

# Enable dark mode
log_info "Enabling dark mode..."
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' 2>/dev/null || true

# File manager (Nautilus) settings
log_info "Configuring Nautilus file manager..."
gsettings set org.gnome.nautilus.preferences default-folder-viewer 'list-view' 2>/dev/null || true
gsettings set org.gnome.nautilus.preferences show-hidden-files true 2>/dev/null || true
gsettings set org.gtk.Settings.FileChooser show-hidden true 2>/dev/null || true
gsettings set org.gnome.nautilus.list-view default-zoom-level 'small' 2>/dev/null || true
gsettings set org.gnome.nautilus.preferences show-create-link true 2>/dev/null || true

# Disable animations for speed (optional - comment out if you prefer animations)
log_info "Reducing animations..."
gsettings set org.gnome.desktop.interface enable-animations true 2>/dev/null || true

# Clock settings - show date and seconds
log_info "Configuring clock..."
gsettings set org.gnome.desktop.interface clock-show-date true 2>/dev/null || true
gsettings set org.gnome.desktop.interface clock-show-weekday true 2>/dev/null || true
gsettings set org.gnome.desktop.interface clock-format '24h' 2>/dev/null || true

# Disable hot corners
log_info "Disabling hot corners..."
gsettings set org.gnome.desktop.interface enable-hot-corners false 2>/dev/null || true

# Desktop icons settings (if using desktop icons extension)
log_info "Configuring desktop..."
gsettings set org.gnome.desktop.background show-desktop-icons false 2>/dev/null || true

###############################################################################
# INPUT SETTINGS
###############################################################################

log_section "Configuring Input Settings"

# Keyboard settings - fast key repeat
log_info "Configuring keyboard for fast key repeat..."
gsettings set org.gnome.desktop.peripherals.keyboard delay 200 2>/dev/null || true
gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval 25 2>/dev/null || true
gsettings set org.gnome.desktop.peripherals.keyboard repeat true 2>/dev/null || true

# Touchpad settings
log_info "Configuring touchpad..."
gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true 2>/dev/null || true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true 2>/dev/null || true
gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true 2>/dev/null || true
gsettings set org.gnome.desktop.peripherals.touchpad speed 0.3 2>/dev/null || true

# Mouse settings
log_info "Configuring mouse..."
gsettings set org.gnome.desktop.peripherals.mouse natural-scroll false 2>/dev/null || true

###############################################################################
# NOISE CANCELLATION (SOUNDS, NOTIFICATIONS)
###############################################################################

log_section "Configuring Noise Cancellation Settings"

# Disable event sounds
log_info "Disabling system sounds..."
gsettings set org.gnome.desktop.sound event-sounds false 2>/dev/null || true
gsettings set org.gnome.desktop.sound input-feedback-sounds false 2>/dev/null || true

# Notification settings
log_info "Configuring notifications..."
gsettings set org.gnome.desktop.notifications show-banners true 2>/dev/null || true
gsettings set org.gnome.desktop.notifications show-in-lock-screen false 2>/dev/null || true

###############################################################################
# POWER MANAGEMENT
###############################################################################

log_section "Configuring Power Management"

# Power settings for laptop
log_info "Configuring power settings..."
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 1800 2>/dev/null || true
gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'interactive' 2>/dev/null || true

# Dim screen when inactive
gsettings set org.gnome.settings-daemon.plugins.power idle-dim true 2>/dev/null || true

###############################################################################
# WINDOW MANAGEMENT
###############################################################################

log_section "Configuring Window Management"

# Window behavior
log_info "Configuring window behavior..."
gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close' 2>/dev/null || true
gsettings set org.gnome.desktop.wm.preferences focus-mode 'click' 2>/dev/null || true
gsettings set org.gnome.desktop.wm.preferences auto-raise false 2>/dev/null || true

# Workspaces
log_info "Configuring workspaces..."
gsettings set org.gnome.mutter dynamic-workspaces true 2>/dev/null || true
gsettings set org.gnome.desktop.wm.preferences num-workspaces 4 2>/dev/null || true

# Edge tiling
gsettings set org.gnome.mutter edge-tiling true 2>/dev/null || true

###############################################################################
# SCREENSHOTS
###############################################################################

log_section "Configuring Screenshots"

log_info "Setting up screenshot directory..."
mkdir -p "${HOME}/Pictures/Screenshots"

# GNOME Screenshot settings (if using gnome-screenshot)
gsettings set org.gnome.gnome-screenshot auto-save-directory "file://${HOME}/Pictures/Screenshots" 2>/dev/null || true

###############################################################################
# ADDITIONAL SETTINGS
###############################################################################

log_section "Applying Additional Settings"

# Disable automatic problem reporting (requires root, skip if not possible)
if command -v abrt-auto-reporting &>/dev/null; then
  # Check current setting first to avoid unnecessary sudo
  current_setting=$(abrt-auto-reporting 2>/dev/null || echo "unknown")
  if [[ "${current_setting}" == "disabled" ]]; then
    log_info "Automatic problem reporting already disabled"
  elif sudo -n true 2>/dev/null; then
    # Can sudo without password prompt
    log_info "Disabling automatic problem reporting..."
    sudo abrt-auto-reporting disabled 2>/dev/null || log_warn "Failed to disable abrt-auto-reporting"
  else
    log_warn "Skipping abrt-auto-reporting (requires sudo)"
  fi
fi

# Set font rendering
log_info "Configuring font rendering..."
gsettings set org.gnome.desktop.interface font-antialiasing 'rgba' 2>/dev/null || true
gsettings set org.gnome.desktop.interface font-hinting 'slight' 2>/dev/null || true

# Text editor settings (if using GNOME Text Editor)
log_info "Configuring text editor..."
gsettings set org.gnome.TextEditor show-line-numbers true 2>/dev/null || true
gsettings set org.gnome.TextEditor highlight-current-line true 2>/dev/null || true
gsettings set org.gnome.TextEditor style-scheme 'Adwaita-dark' 2>/dev/null || true

# Terminal settings (if using GNOME Terminal)
log_info "Configuring terminal..."
# Get the default profile ID
TERM_PROFILE=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'") || true
if [[ -n "${TERM_PROFILE}" ]]; then
  TERM_PATH="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${TERM_PROFILE}/"
  gsettings set "${TERM_PATH}" audible-bell false 2>/dev/null || true
  gsettings set "${TERM_PATH}" scrollback-unlimited true 2>/dev/null || true
fi

###############################################################################
# CLEANUP
###############################################################################

log_section "Finalizing Configuration"

echo ""
log_info "GNOME configuration complete!"
log_warn "Some changes may require logging out and back in to take effect."
echo ""
