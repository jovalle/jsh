#!/usr/bin/env bash
#
# Configure Windows host from WSL (Debian/Ubuntu)
# Executes PowerShell scripts with a single UAC elevation prompt
#

set -euo pipefail

# Get script directory using realpath to avoid any shell quirks
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
SCRIPT_DIR_WIN=$(wslpath -w "${SCRIPT_DIR}")

# Colors and symbols
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure Windows host with winget packages and Chocolatey fonts.

Options:
    -w, --skip-winget       Skip winget package installation
    -c, --skip-chocolatey   Skip Chocolatey and font installation
    -F, --force             Force reconfiguration even if already configured
    -h, --help              Show this help message

Examples:
    $(basename "$0")                    # Run all configurations
    $(basename "$0") --skip-chocolatey  # Skip Chocolatey/fonts
    $(basename "$0") --force            # Force reconfigure everything
EOF
}

# Parse arguments
SKIP_WINGET=""
SKIP_CHOCOLATEY=""
FORCE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--skip-winget)
            SKIP_WINGET="-SkipWinget"
            shift
            ;;
        -c|--skip-chocolatey)
            SKIP_CHOCOLATEY="-SkipChocolatey"
            shift
            ;;
        -F|--force)
            FORCE="-Force"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Banner
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}║        Windows Host Configuration (from WSL)               ║${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify we're running in WSL
if [[ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]] && [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
    error "This script must be run from WSL"
    exit 1
fi

success "Running in WSL: ${WSL_DISTRO_NAME:-unknown}"

# Verify PowerShell script exists
PS_SCRIPT="${SCRIPT_DIR}/configure-windows.ps1"
if [[ ! -f "${PS_SCRIPT}" ]]; then
    error "PowerShell script not found: ${PS_SCRIPT}"
    exit 1
fi

# Build PowerShell arguments
PS_ARGS="${SKIP_WINGET} ${SKIP_CHOCOLATEY} ${FORCE}"
PS_ARGS=$(echo "${PS_ARGS}" | xargs)  # Trim whitespace

info "Launching Windows configuration with elevated privileges..."
info "Script: ${SCRIPT_DIR_WIN}\\configure-windows.ps1"
if [[ -n "${PS_ARGS}" ]]; then
    info "Arguments: ${PS_ARGS}"
fi
warning "A UAC prompt will appear - please approve to continue"

# Create a temporary launcher script to avoid quoting hell
TEMP_LAUNCHER=$(mktemp --suffix=.ps1)
cat > "${TEMP_LAUNCHER}" <<EOFPS
Set-Location '${SCRIPT_DIR_WIN}'
& '.\configure-windows.ps1' ${PS_ARGS}
Write-Host ''
Read-Host 'Press Enter to close'
EOFPS

TEMP_LAUNCHER_WIN=$(wslpath -w "${TEMP_LAUNCHER}")

# Execute with elevation
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${TEMP_LAUNCHER_WIN}' -Wait"

EXIT_CODE=$?

# Cleanup temp file
rm -f "${TEMP_LAUNCHER}"

if [[ ${EXIT_CODE} -eq 0 ]]; then
    success "Windows configuration completed successfully!"
else
    error "Windows configuration completed with errors (exit code: ${EXIT_CODE})"
fi

exit ${EXIT_CODE}
