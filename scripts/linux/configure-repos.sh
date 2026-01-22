#!/usr/bin/env bash
#
# configure-repos.sh - Configure DNF repositories (COPR)
#
# This script enables COPR repositories for packages not in Fedora's main repos:
# - Ghostty terminal
# - Other community packages
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

# Check if running on Linux with dnf
if [[ "$(uname -s)" != "Linux" ]]; then
    log_error "This script is intended for Linux only."
    exit 1
fi

if ! command -v dnf &>/dev/null; then
    log_error "dnf not found. This script requires Fedora/RHEL."
    exit 1
fi

log_info "Configuring DNF repositories..."
echo ""

###############################################################################
# COPR REPOSITORIES
###############################################################################

log_section "COPR Repositories"

# Array of COPR repos to enable: "owner/repo|description"
copr_repos=(
    "pgdev/ghostty|Ghostty terminal emulator"
    "eyecantcu/AppImageLauncher|AppImage desktop integration"
)

for entry in "${copr_repos[@]}"; do
    repo="${entry%%|*}"
    desc="${entry#*|}"

    # Check if already enabled
    if dnf copr list 2>/dev/null | grep -q "${repo}"; then
        log_info "${repo}: already enabled"
    else
        log_info "Enabling ${repo} (${desc})..."
        if sudo dnf copr enable -y "${repo}" 2>/dev/null; then
            log_info "${repo}: enabled"
        else
            log_warn "Failed to enable ${repo}"
        fi
    fi
done

###############################################################################
# EXTERNAL REPOSITORIES (Signal, Zoom, etc.)
###############################################################################

log_section "External Repositories"

# Signal Desktop - https://signal.org/download/linux/
if ! dnf repolist 2>/dev/null | grep -q "signal-desktop"; then
    log_info "Adding Signal Desktop repository..."

    # Add Signal GPG key
    sudo rpm --import https://updates.signal.org/desktop/apt/keys.asc 2>/dev/null || true

    # Create repo file
    sudo tee /etc/yum.repos.d/signal-desktop.repo > /dev/null << 'REPO'
[signal-desktop]
name=Signal Desktop
baseurl=https://updates.signal.org/desktop/yum/stable/
enabled=1
gpgcheck=1
gpgkey=https://updates.signal.org/desktop/apt/keys.asc
REPO
    log_info "Signal Desktop: repository added"
else
    log_info "Signal Desktop: repository already configured"
fi

# Zoom - https://zoom.us/download
if ! dnf repolist 2>/dev/null | grep -q "zoom"; then
    log_info "Adding Zoom repository..."

    # Add Zoom GPG key
    sudo rpm --import https://zoom.us/linux/download/pubkey?version=5-12-6 2>/dev/null || true

    # Create repo file
    sudo tee /etc/yum.repos.d/zoom.repo > /dev/null << 'REPO'
[zoom]
name=Zoom
baseurl=https://zoom.us/linux/download/rpm/
enabled=1
gpgcheck=1
gpgkey=https://zoom.us/linux/download/pubkey?version=5-12-6
REPO
    log_info "Zoom: repository added"
else
    log_info "Zoom: repository already configured"
fi

###############################################################################
# FLATHUB
###############################################################################

log_section "Flathub Repository"

if ! command -v flatpak &>/dev/null; then
    log_warn "flatpak not installed, skipping Flathub setup"
    log_info "Install with: sudo dnf install flatpak"
else
    if flatpak remote-list 2>/dev/null | grep -q flathub; then
        log_info "Flathub: already configured"
    else
        log_info "Adding Flathub repository..."
        if flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null; then
            log_info "Flathub: added"
        else
            log_warn "Failed to add Flathub"
        fi
    fi
fi

###############################################################################
# SUMMARY
###############################################################################

log_section "Repository Status"

echo ""
echo "COPR repositories:"
dnf copr list 2>/dev/null | head -10 || echo "  (none)"

echo ""
echo "Flatpak remotes:"
flatpak remote-list 2>/dev/null || echo "  (none)"

echo ""
log_info "Repository configuration complete!"
echo ""
