#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================================
# brew.sh - Homebrew/Linuxbrew Wrapper
# ============================================================================
# Thin wrapper around brew command with additional utility subcommands:
#   setup               - Ensure Homebrew/Linuxbrew is installed and configured
#   check [package]     - Check specific package (validate exists) or comprehensive checks
#   <any other command> - Passed directly to brew
#
# ============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# Determine the root directory of the project
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ============================================================================
# Helper Functions
# ============================================================================

error() {
  echo -e "${RED}❌ $1${RESET}" >&2
}

success() {
  echo -e "${GREEN}✅ $1${RESET}"
}

warning() {
  echo -e "${YELLOW}⚠️  $1${RESET}"
}

info() {
  echo -e "${CYAN}$1"
}

confirm() {
  local prompt="$1"
  local response
  read -r -n 1 -p "$prompt (y/N): " response
  echo # Add newline after single character input
  case "$response" in
    y | Y)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

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
  elif [[ "${OSTYPE}" == "linux"* ]] || grep -qi microsoft /proc/version 2> /dev/null; then
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

apply_brew_shellenv() {
  local brew_bin="$1"
  [[ -n "$brew_bin" && -x "$brew_bin" ]] || return 1

  local brew_env
  if brew_env="$("$brew_bin" shellenv)"; then
    eval "$brew_env"
    return 0
  fi

  return 1
}

# Show usage
show_usage() {
  cat << EOF
Usage: jsh brew [command] [options]

Homebrew/Linuxbrew wrapper with additional utilities.

Subcommands:
  setup                 Ensure Homebrew/Linuxbrew is installed and configured
  check [package]       Check specific package or run comprehensive checks
  <brew command>        Pass through to brew (e.g., install, list, update)

Check Options:
  --linux               Force check as if on Linux platform
  --darwin              Force check as if on Darwin/macOS platform
  --macos               Alias for --darwin

Check Examples:
  jsh brew check              Run comprehensive checks (outdated, invalid, unsupported)
  jsh brew check jq           Validate if 'jq' is available/installed
  jsh brew check --linux jq   Check if 'jq' is available on Linux (even if on macOS)
  jsh brew check --darwin     Run comprehensive checks assuming Darwin platform

Setup Examples:
  jsh brew setup              Install Homebrew/Linuxbrew if needed and configure PATH

Passthrough Examples:
  jsh brew install git        Same as 'brew install git'
  jsh brew list --formula     Same as 'brew list --formula'
  jsh brew upgrade            Same as 'brew upgrade'

EOF
  exit 0
}

# ============================================================================
# Setup Command
# ============================================================================

brew_setup() {
  local BREW_PREFIX
  BREW_PREFIX=$(detect_brew_path)

  if [[ -n "$BREW_PREFIX" ]]; then
    success "Homebrew is already installed at: $BREW_PREFIX"
    info "Configuring environment..."

    if apply_brew_shellenv "$BREW_PREFIX/bin/brew"; then
      success "Homebrew environment configured"
      return 0
    else
      warning "Failed to configure Homebrew environment"
      return 1
    fi
  fi

  # Check for sudo access before attempting installation
  if ! sudo -n true 2> /dev/null; then
    error "Homebrew installation requires sudo access"
    info "Please ensure you have sudo permissions, or use an alternative installation method:"
    info "https://docs.brew.sh/Installation#alternative-installs"
    return 1
  fi

  info "Installing Homebrew/Linuxbrew..."
  echo ""

  # Run official install script
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Try to apply environment after installation
  BREW_PREFIX=$(detect_brew_path)
  if [[ -n "$BREW_PREFIX" ]]; then
    if apply_brew_shellenv "$BREW_PREFIX/bin/brew"; then
      success "Homebrew installation and configuration complete!"
      return 0
    fi
  fi

  warning "Homebrew installation complete, but environment could not be configured automatically"
  info "Please follow the instructions above to add Homebrew to your PATH"
  return 1
}

# ============================================================================
# Check Command - Helper Functions
# ============================================================================

# Extract package names from taskfile YAML
extract_packages() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi

  awk -v key="$key" '
    /^vars:/ {
      in_vars = 1
      next
    }
    in_vars && /^[a-zA-Z_-]+:/ && !/^  / {
      in_vars = 0
    }
    in_vars && $0 ~ "^  " key ":" {
      in_section = 1
      next
    }
    in_section && /^  [a-zA-Z_-]+:/ {
      in_section = 0
    }
    in_section && /^    - / {
      sub(/^    - /, "")
      sub(/ #.*$/, "")
      gsub(/ /, "")
      if ($0 != "") print $0
    }
  ' "$file" | sort -u
}

# Check if a package is available in Homebrew API
check_package_in_api() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  local api_url=""
  if [[ "$pkg_type" == "cask" ]]; then
    api_url="https://formulae.brew.sh/api/cask/${pkg}.json"
  else
    api_url="https://formulae.brew.sh/api/formula/${pkg}.json"
  fi

  # Use curl to check if the package exists in the API
  if curl -sf "$api_url" &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# Check if a package exists locally
check_package_locally() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  if [[ "$pkg_type" == "cask" ]]; then
    brew info --cask "$pkg" &> /dev/null
    return $?
  else
    brew info --formula "$pkg" &> /dev/null
    return $?
  fi
}

# Validate a specific package exists
validate_package() {
  local pkg="$1"
  local forced_platform="${2:-}" # Optional forced platform: 'linux' or 'darwin'

  info "Checking package: $pkg"

  # Determine which platform to check against
  local check_platform="${forced_platform}"
  if [[ -z "$check_platform" ]]; then
    if [[ "${OSTYPE}" == "darwin"* ]]; then
      check_platform="darwin"
    else
      check_platform="linux"
    fi
  fi

  # Try as formula first
  if check_package_locally "$pkg" "formula"; then
    # On Linux, check if the formula has macOS-only requirements
    if [[ "$check_platform" == "linux" ]]; then
      # Get the formula info and check for platform requirements
      local brew_info
      brew_info=$(brew info --formula "$pkg" 2>&1 || echo "")

      if echo "$brew_info" | grep -q "Required: macOS"; then
        error "Package '$pkg' is not supported on Linux (macOS-only package)"
        return 1
      fi
    fi

    success "Package '$pkg' is available as a formula"
    return 0
  fi

  # Try as cask on macOS
  if [[ "$check_platform" == "darwin" ]]; then
    if check_package_locally "$pkg" "cask"; then
      success "Package '$pkg' is available as a cask"
      return 0
    fi
  fi

  # Check API with platform validation
  if check_package_in_api "$pkg" "formula"; then
    # For Linux, double-check via API metadata
    if [[ "${OSTYPE}" == "linux"* ]] || grep -qi microsoft /proc/version 2> /dev/null; then
      # Fetch API metadata to check platform support
      local api_response
      api_response=$(curl -sf "https://formulae.brew.sh/api/formula/${pkg}.json" 2> /dev/null || echo "")

      if [[ -n "$api_response" ]]; then
        # Check if the package has platform requirements
        local platforms
        platforms=$(echo "$api_response" | jq -r '.platform | keys[]' 2> /dev/null || echo "")

        if [[ -n "$platforms" ]]; then
          # If platform info exists, check if linux is in it
          if echo "$platforms" | grep -q "linux"; then
            success " Package '$pkg' exists in Homebrew repository and supports Linux"
            return 0
          else
            error "Package '$pkg' is not supported on Linux (Darwin-only package)"
            return 1
          fi
        else
          # No platform info, assume it's cross-platform
          success " Package '$pkg' exists in Homebrew repository"
          return 0
        fi
      fi
    else
      success " Package '$pkg' exists in Homebrew repository"
      return 0
    fi
  fi

  if [[ "${OSTYPE}" == "darwin"* ]] && check_package_in_api "$pkg" "cask"; then
    success " Package '$pkg' exists as a cask in Homebrew repository"
    return 0
  fi

  error "Package '$pkg' not found in Homebrew repository"
  return 1
}

# Comprehensive check: outdated packages, invalid packages, unsupported platform packages
comprehensive_check() {
  local forced_platform="${1:-}"  # Optional forced platform: 'linux' or 'darwin'
  local quiet_mode="${2:-false}"  # Optional quiet mode
  local force_check="${3:-false}" # Optional force check

  local marker_file="${ROOT_DIR}/.brewcheck"

  if [[ "$force_check" != "true" ]] && [[ -f "$marker_file" ]]; then
    # Check if file is less than 24 hours old
    if [[ -n $(find "$marker_file" -mtime -1 2> /dev/null) ]]; then
      [[ "$quiet_mode" != "true" ]] && info "⏳ Brew check ran recently. Skipping..."
      return 0
    fi
  fi

  if [[ "$quiet_mode" != "true" ]]; then
    info "🔍 Running comprehensive Homebrew check..."
    echo ""
  fi

  # Get current OS or use forced platform
  local current_os="${forced_platform}"
  if [[ -z "$current_os" ]]; then
    if [[ "${OSTYPE}" == "darwin"* ]]; then
      current_os="darwin"
    else
      current_os="linux"
    fi
  fi

  local issues_found=0

  # 1. Check for outdated packages (only on actual platform, not forced)
  if [[ -z "${1:-}" ]]; then
    [[ "$quiet_mode" != "true" ]] && info "📦 Checking for outdated packages..."
    local outdated_count=0

    if outdated=$(brew outdated --quiet 2> /dev/null); then
      outdated_count=$(echo "$outdated" | grep -c . 2> /dev/null || true)
      outdated_count=${outdated_count:-0}
      outdated_count=$((${outdated_count//[!0-9]/}))
      if [[ $outdated_count -gt 0 ]]; then
        warning "Found $outdated_count outdated package(s):"
        echo "$outdated" | while IFS= read -r pkg; do
          [[ -n "$pkg" ]] && echo "  - $pkg"
        done
        ((issues_found++))
      else
        [[ "$quiet_mode" != "true" ]] && success "All packages are up to date"
      fi
    fi
    [[ "$quiet_mode" != "true" ]] && echo ""
  else
    [[ "$quiet_mode" != "true" ]] && info "📦 Skipping outdated package check (forced platform mode)"
    [[ "$quiet_mode" != "true" ]] && echo ""
  fi

  # 2. Check taskfiles for unsupported platform packages
  local darwin_taskfile="${ROOT_DIR}/.taskfiles/darwin/taskfile.yaml"
  local linux_taskfile="${ROOT_DIR}/.taskfiles/linux/taskfile.yaml"
  local current_taskfile

  # Determine which taskfile to use based on current OS
  case "$current_os" in
    darwin)
      current_taskfile="$darwin_taskfile"
      ;;
    linux)
      current_taskfile="$linux_taskfile"
      ;;
    *)
      current_taskfile=""
      ;;
  esac

  if [[ -f "$current_taskfile" ]]; then
    [[ "$quiet_mode" != "true" ]] && info "🔍 Checking $current_os packages for issues..."

    # Check for unsupported package types based on platform
    case "$current_os" in
      darwin)
        # Darwin supports both casks and formulae; no validation needed
        :
        ;;
      linux)
        # Linux does not support casks; check if any exist
        local casks
        casks=$(extract_packages "$current_taskfile" "casks")
        if [[ -n "$casks" ]]; then
          warning "Found cask(s) in Linux configuration (not supported on Linux):"
          echo "$casks" | while IFS= read -r cask; do
            [[ -n "$cask" ]] && echo "  - $cask (cask)"
          done
          ((issues_found++))
        fi
        ;;
    esac
  fi

  # Update marker file
  touch "$marker_file"

  # Summary
  if [[ $issues_found -eq 0 ]]; then
    [[ "$quiet_mode" != "true" ]] && success "All checks passed! No issues found."
    return 0
  else
    warning "Found $issues_found issue(s). Review the output above."
    return 1
  fi
}

brew_check() {
  # If no brew is installed, skip
  if ! command -v brew &> /dev/null; then
    warning "Homebrew is not installed. Run: $0 setup"
    return 1
  fi

  local forced_platform=""
  local quiet_mode=false
  local force_check=false
  local args=()

  # Parse platform flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --linux)
        forced_platform="linux"
        shift
        ;;
      --darwin | --macos)
        forced_platform="darwin"
        shift
        ;;
      --quiet | -q)
        quiet_mode=true
        shift
        ;;
      --force | -f)
        force_check=true
        shift
        ;;
      --help | -h)
        info "Usage: jsh brew check [--quiet] [--force] [--linux|--darwin|--macos] [package]"
        info "  --quiet   Silent mode, only output if issues found"
        info "  --force   Force check even if run recently"
        info "  --linux   Force check as if on Linux platform"
        info "  --darwin  Force check as if on Darwin/macOS platform"
        info "  --macos   Alias for --darwin"
        return 0
        ;;
      -*)
        error "Unknown flag: $1"
        info "Usage: jsh brew check [--quiet] [--force] [--linux|--darwin|--macos] [package]"
        return 1
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  # If a package name is provided, just validate that package
  if [[ ${#args[@]} -gt 0 ]]; then
    validate_package "${args[0]}" "$forced_platform"
    return $?
  fi

  # Otherwise run comprehensive checks
  comprehensive_check "$forced_platform" "$quiet_mode" "$force_check"
}

# ============================================================================
# Main Logic
# ============================================================================

show_usage_and_exit() {
  show_usage
  exit 0
}

# If no arguments, show usage
if [[ $# -eq 0 ]]; then
  show_usage_and_exit
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
  setup)
    brew_setup
    ;;
  check)
    brew_check "$@"
    ;;
  help | --help | -h)
    show_usage_and_exit
    ;;
  *)
    # Pass through to brew
    if ! command -v brew &> /dev/null; then
      error "Homebrew is not installed"
      info "Run: $0 setup"
      exit 1
    fi

    # Forward all arguments to brew
    brew "$COMMAND" "$@"
    ;;
esac
