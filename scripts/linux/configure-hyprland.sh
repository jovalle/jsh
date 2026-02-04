#!/usr/bin/env bash
#
# configure-hyprland.sh - Configure Hyprland/Wayland environment
#
# This script:
# - Symlinks Hyprland, Waybar, Wofi, Ghostty configs
# - Sets up XDG desktop portal
# - Configures environment variables for Wayland
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}[====]${NC} $*"; }

JSH_DIR="${JSH_DIR:-${HOME}/.jsh}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"

# Check if running on Linux
if [[ "$(uname -s)" != "Linux" ]]; then
    log_error "This script is intended for Linux only."
    exit 1
fi

log_info "Configuring Hyprland/Wayland environment..."
echo ""

###############################################################################
# VERIFY CONFIGS EXIST
###############################################################################

log_section "Checking jsh config sources"

# Array of configs to link: "source_dir|target_dir|required"
# required: true = error if missing, false = warn and skip
configs=(
    "hypr|hypr|true"
    "waybar|waybar|true"
    "wofi|wofi|false"
    "ghostty|ghostty|false"
)

# First pass: verify required configs exist
missing_required=false
for entry in "${configs[@]}"; do
    src_name="${entry%%|*}"
    rest="${entry#*|}"
    tgt_name="${rest%%|*}"
    required="${rest#*|}"

    src_dir="${JSH_DIR}/dotfiles/.config/${src_name}"
    if [[ ! -d "${src_dir}" ]]; then
        if [[ "${required}" == "true" ]]; then
            log_error "Required config missing: ${src_dir}"
            missing_required=true
        fi
    else
        log_info "Found: .config/${src_name}"
    fi
done

if [[ "${missing_required}" == "true" ]]; then
    log_error "Missing required Hyprland configs in jsh"
    log_info "Ensure ${JSH_DIR}/dotfiles/.config/hypr and ${JSH_DIR}/dotfiles/.config/waybar exist"
    exit 1
fi

###############################################################################
# SYMLINK CONFIGS
###############################################################################

log_section "Linking configuration files"

for entry in "${configs[@]}"; do
    src_name="${entry%%|*}"
    rest="${entry#*|}"
    tgt_name="${rest%%|*}"

    src_dir="${JSH_DIR}/dotfiles/.config/${src_name}"
    tgt_dir="${XDG_CONFIG_HOME}/${tgt_name}"

    if [[ ! -d "${src_dir}" ]]; then
        log_warn "Source not found: ${src_dir}, skipping"
        continue
    fi

    if [[ -L "${tgt_dir}" ]]; then
        # Already a symlink
        current_target=$(readlink -f "${tgt_dir}" 2>/dev/null || true)
        if [[ "${current_target}" == "${src_dir}" ]]; then
            log_info "${tgt_name}: already linked"
        else
            log_warn "${tgt_name}: symlink exists but points elsewhere"
        fi
    elif [[ -d "${tgt_dir}" ]]; then
        # Directory exists, back it up
        backup_dir="${tgt_dir}.backup.$(date +%Y%m%d%H%M%S)"
        log_warn "${tgt_name}: backing up existing to ${backup_dir}"
        mv "${tgt_dir}" "${backup_dir}"
        ln -s "${src_dir}" "${tgt_dir}"
        log_info "${tgt_name}: linked (backup created)"
    else
        # Create parent if needed
        mkdir -p "$(dirname "${tgt_dir}")"
        ln -s "${src_dir}" "${tgt_dir}"
        log_info "${tgt_name}: linked"
    fi
done

###############################################################################
# WAYLAND ENVIRONMENT VARIABLES
###############################################################################

log_section "Configuring Wayland environment"

env_file="${XDG_CONFIG_HOME}/environment.d/wayland.conf"
mkdir -p "$(dirname "${env_file}")"

if [[ ! -f "${env_file}" ]]; then
    cat > "${env_file}" << 'EOF'
# Wayland environment variables
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
GDK_BACKEND=wayland,x11
SDL_VIDEODRIVER=wayland
CLUTTER_BACKEND=wayland
XDG_SESSION_TYPE=wayland
EOF
    log_info "Created ${env_file}"
else
    log_info "Wayland environment already configured"
fi

###############################################################################
# XDG PORTAL
###############################################################################

log_section "XDG Desktop Portal"

# Check if hyprland portal is installed
if command -v /usr/libexec/xdg-desktop-portal-hyprland &>/dev/null; then
    log_info "xdg-desktop-portal-hyprland is installed"
else
    log_warn "xdg-desktop-portal-hyprland not found"
    log_warn "Install with: sudo dnf install xdg-desktop-portal-hyprland"
fi

###############################################################################
# GHOSTTY (Terminal)
###############################################################################

log_section "Ghostty Terminal"

if command -v ghostty &>/dev/null; then
    log_info "Ghostty is installed"
else
    log_warn "Ghostty not found"
    log_info "Ghostty requires manual installation or Copr:"
    log_info "  Option 1: Build from source (https://ghostty.org)"
    log_info "  Option 2: Check for Copr repo availability"
fi

###############################################################################
# SUMMARY
###############################################################################

log_section "Summary"

echo ""
echo "Hyprland environment configured!"
echo ""
echo "To start Hyprland:"
echo "  1. Log out of your current session"
echo "  2. Select 'Hyprland' from your display manager"
echo "  3. Or run 'Hyprland' from a TTY"
echo ""
echo "Key bindings (configured in hyprland.conf):"
echo "  Super + Return    Open terminal (Ghostty)"
echo "  Super + D         App launcher (Wofi)"
echo "  Super + Q         Close window"
echo "  Super + H/J/K/L   Move focus (vim keys)"
echo ""
