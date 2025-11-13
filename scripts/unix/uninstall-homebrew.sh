#!/usr/bin/env bash
# shellcheck shell=bash
# Completely uninstall Homebrew and all packages
# This script provides multiple confirmation prompts before destructive actions
# Works on both macOS and Linux

set -e
set -u
set -o pipefail

# Detect OS and set Homebrew path
detect_brew_path() {
    if [[ "${OSTYPE}" == "darwin"* ]]; then
        # macOS - check both Apple Silicon and Intel paths
        if [[ -d "/opt/homebrew" ]]; then
            echo "/opt/homebrew"
        elif [[ -d "/usr/local/Homebrew" ]]; then
            echo "/usr/local"
        else
            echo ""
        fi
    elif [[ "${OSTYPE}" == "linux"* ]] || grep -qi microsoft /proc/version 2>/dev/null; then
        # Linux or WSL
        if [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
            echo "/home/linuxbrew/.linuxbrew"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

BREW_PREFIX=$(detect_brew_path)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

info() {
    echo -e "$1"
}

# Function to prompt for confirmation
confirm() {
    local prompt="$1"
    local response
    read -r -n 1 -p "$prompt (y/N): " response
    echo  # Add newline after single character input
    case "$response" in
        y|Y)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Main uninstall function
main() {
    # Check if Homebrew is installed
    if [[ -z "$BREW_PREFIX" ]]; then
        error "Homebrew installation not found."
        exit 1
    fi

    info "Found Homebrew at: $BREW_PREFIX"
    echo ""

    warning "WARNING: This will completely uninstall Homebrew and all packages!"
    echo ""
    info "This process will:"
    info "  1. Stop all Homebrew services"
    info "  2. Uninstall all casks and formulae"
    info "  3. Run the official Homebrew uninstall script"
    info "  4. Remove all Homebrew directories from $BREW_PREFIX"
    echo ""

    if ! confirm "Are you ABSOLUTELY sure you want to continue?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    # Step 1: Stop services
    echo ""
    info "Step 1/4: Stopping all Homebrew services..."
    if ! confirm "Continue with stopping services?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    if brew services stop --all 2>/dev/null; then
        success "Services stopped"
    else
        warning "No services running or failed to stop services"
    fi

    # Step 2: Unlink formulae
    echo ""
    info "Step 2/4: Unlinking all Homebrew formulae..."
    if brew list --formula 2>/dev/null | xargs -n1 brew unlink 2>/dev/null; then
        success "Formulae unlinked"
    else
        warning "No formulae to unlink or unlinking failed"
    fi

    # Step 3: Uninstall packages
    echo ""
    info "Step 3/4: Uninstalling all casks and formulae..."
    if ! confirm "Continue with uninstalling all packages?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    info "Uninstalling casks..."
    if brew list --cask 2>/dev/null | xargs -n1 brew uninstall --cask --force 2>/dev/null; then
        success "Casks uninstalled"
    else
        warning "No casks installed or uninstall failed"
    fi

    info "Uninstalling formulae..."
    if brew list --formula 2>/dev/null | xargs -n1 brew uninstall --force --ignore-dependencies 2>/dev/null; then
        success "Formulae uninstalled"
    else
        warning "No formulae installed or uninstall failed"
    fi

    # Step 4: Run official uninstall script
    echo ""
    info "Step 4/4: Running official Homebrew uninstall script..."
    if ! confirm "Continue with running Homebrew uninstall script?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"

    # Step 5: Clean up remaining directories
    echo ""
    info "Step 5/5: Removing remaining Homebrew directories..."
    info "The following directories will be deleted from $BREW_PREFIX:"

    # Common directories across macOS and Linux
    local dirs_to_remove=(
        "bin"
        "etc"
        "include"
        "lib"
        "opt"
        "sbin"
        "share"
        "var"
    )

    # macOS-specific directories
    if [[ "${OSTYPE}" == "darwin"* ]]; then
        dirs_to_remove+=(
            ".DS_Store"
            "AGENTS.md"
            "CHANGES.rst"
            "Frameworks"
            "README.rst"
        )
    fi

    # List directories to be removed
    for item in "${dirs_to_remove[@]}"; do
        info "  - $BREW_PREFIX/$item"
    done
    echo ""

    if ! confirm "Continue with removing directories?"; then
        warning "Uninstall cancelled at final step. Homebrew may be partially uninstalled."
        exit 1
    fi

    # Remove directories and files
    for item in "${dirs_to_remove[@]}"; do
        local path="$BREW_PREFIX/$item"
        if [[ -d "$path" ]]; then
            sudo rm -rf "$path" 2>/dev/null || true
        elif [[ -f "$path" ]]; then
            sudo rm -f "$path" 2>/dev/null || true
        fi
    done

    echo ""
    success "Homebrew uninstallation complete!"
}

# Run main function
main "$@"
