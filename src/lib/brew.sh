# Homebrew management functions for jsh

# ============================================================================
# Core Helper Functions
# ============================================================================

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

check_brew() {
  if ! command -v brew &> /dev/null; then
    warn "Homebrew not found. Skipping brew-related tasks."
    return 1
  fi
  return 0
}

apply_brew_shellenv() {
  local brew_bin="$1"
  [[ -n "${brew_bin}" && -x "${brew_bin}" ]] || return 1

  local brew_env
  if brew_env="$("${brew_bin}" shellenv)"; then
    eval "${brew_env}"
    return 0
  fi
  return 1
}

# Check if a user exists on the system
user_exists() {
  local username="$1"
  if is_macos; then
    dscl . -read "/Users/${username}" &> /dev/null
  else
    id "${username}" &> /dev/null
  fi
}

# Load BREW_USER from .env if available
load_brew_user() {
  local root_dir
  root_dir="$(get_root_dir)"
  local env_file="${root_dir}/.env"
  if [[ -f "${env_file}" ]]; then
    # Source the env file to get BREW_USER
    # shellcheck source=/dev/null
    source "${env_file}"
  fi
  export BREW_USER="${BREW_USER:-}"
}

# Check if user is in admin/sudo group (idempotent check)
user_in_admin_group() {
  local username="$1"
  if is_macos; then
    dseditgroup -o checkmember -m "${username}" admin &> /dev/null
  else
    if getent group sudo &> /dev/null; then
      id -nG "${username}" 2>/dev/null | grep -qw sudo
    elif getent group wheel &> /dev/null; then
      id -nG "${username}" 2>/dev/null | grep -qw wheel
    else
      return 1
    fi
  fi
}

# Detect OS and set Homebrew path
detect_brew_path() {
  if is_macos; then
    # macOS - check both Apple Silicon and Intel paths
    if [[ -d "/opt/homebrew" ]]; then
      echo "/opt/homebrew"
    elif [[ -d "/usr/local/Homebrew" ]]; then
      echo "/usr/local"
    else
      echo ""
    fi
  elif is_linux || grep -qi microsoft /proc/version 2> /dev/null; then
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

# Run a command as the brew user (for root delegation)
run_as_brew_user() {
  local brew_user="${BREW_USER:-}"

  if [[ -z "${brew_user}" ]]; then
    error "BREW_USER is not configured. Run 'jsh init' to set up brew delegation."
  fi

  if ! user_exists "${brew_user}"; then
    error "Brew user '${brew_user}' does not exist."
  fi

  local brew_user_home
  brew_user_home=$(eval echo "~${brew_user}")

  # Detect brew path and set up environment
  local brew_prefix
  brew_prefix=$(detect_brew_path)

  if [[ -n "${brew_prefix}" ]]; then
    # Run with brew environment properly configured
    sudo -u "${brew_user}" bash -c "cd '${brew_user_home}' && eval \"\$(${brew_prefix}/bin/brew shellenv)\" && \"\$@\"" -- "$@"
  else
    # Fallback to basic execution
    sudo -u "${brew_user}" bash -c "cd '${brew_user_home}' && \"\$@\"" -- "$@"
  fi
}

# Prompt for and create a standard user for brew delegation
# Args: default_user, non_interactive (true/false)
# Note: This function outputs the username to stdout for capture.
#       All info/status messages go to stderr to avoid corrupting the output.
create_brew_user() {
  local default_user="${1:-jay}"
  local non_interactive="${2:-false}"
  local username

  # In non-interactive mode, use default user directly
  if [[ "${non_interactive}" == "true" ]]; then
    username="${default_user}"
    info "Non-interactive mode: using user '${username}' for brew operations." >&2
  else
    echo "" >&2
    warn "Homebrew cannot be run as root." >&2
    info "A standard (non-root) user is required to install and manage Homebrew." >&2
    echo "" >&2

    # Prompt for username
    read -r -p "Enter username for brew operations [${default_user}]: " username
    username="${username:-${default_user}}"
  fi

  # Validate username
  if [[ ! "${username}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    error "Invalid username. Use lowercase letters, numbers, underscores, and hyphens."
    return 1
  fi

  # Check if user already exists (idempotent)
  if user_exists "${username}"; then
    info "User '${username}' already exists." >&2

    # Ensure user is in admin/sudo group (idempotent)
    if ! user_in_admin_group "${username}"; then
      info "Adding '${username}' to admin/sudo group..." >&2
      if is_macos; then
        sudo dseditgroup -o edit -a "${username}" -t user admin 2>/dev/null || true
      else
        if getent group sudo &> /dev/null; then
          sudo usermod -aG sudo "${username}" 2>/dev/null || true
        elif getent group wheel &> /dev/null; then
          sudo usermod -aG wheel "${username}" 2>/dev/null || true
        fi
      fi
    fi

    if [[ "${non_interactive}" == "true" ]]; then
      echo "${username}"
      return 0
    fi

    if confirm "Use '${username}' for brew operations?"; then
      echo "${username}"
      return 0
    else
      return 1
    fi
  fi

  # Create the user
  info "Creating user '${username}'..." >&2

  if is_macos; then
    # macOS user creation
    local max_id
    max_id=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    local new_id=$((max_id + 1))

    sudo dscl . -create "/Users/${username}"
    sudo dscl . -create "/Users/${username}" UserShell /bin/zsh
    sudo dscl . -create "/Users/${username}" RealName "${username}"
    sudo dscl . -create "/Users/${username}" UniqueID "${new_id}"
    sudo dscl . -create "/Users/${username}" PrimaryGroupID 20
    sudo dscl . -create "/Users/${username}" NFSHomeDirectory "/Users/${username}"

    sudo mkdir -p "/Users/${username}"
    sudo chown "${username}:staff" "/Users/${username}"

    # Set password (skip in non-interactive mode)
    if [[ "${non_interactive}" != "true" ]]; then
      info "Setting password for ${username}..." >&2
      sudo dscl . -passwd "/Users/${username}"
    else
      info "Skipping password setup in non-interactive mode." >&2
      info "Set password later with: sudo dscl . -passwd /Users/${username}" >&2
    fi

    # Add to admin group (idempotent)
    sudo dseditgroup -o edit -a "${username}" -t user admin 2>/dev/null || true
  else
    # Linux user creation
    if command -v useradd &> /dev/null; then
      sudo useradd -m -s /bin/bash "${username}"
    elif command -v adduser &> /dev/null; then
      sudo adduser --disabled-password --gecos "" "${username}"
    else
      error "No supported user creation tool found (useradd or adduser)"
      return 1
    fi

    # Set password (skip in non-interactive mode)
    if [[ "${non_interactive}" != "true" ]]; then
      info "Setting password for ${username}..." >&2
      sudo passwd "${username}"
    else
      info "Skipping password setup in non-interactive mode." >&2
      info "Set password later with: sudo passwd ${username}" >&2
    fi

    # Add to sudo/wheel group (idempotent)
    if getent group sudo &> /dev/null; then
      sudo usermod -aG sudo "${username}" 2>/dev/null || true
    elif getent group wheel &> /dev/null; then
      sudo usermod -aG wheel "${username}" 2>/dev/null || true
    fi
  fi

  if user_exists "${username}"; then
    success "User '${username}' created successfully." >&2
    echo "${username}"
    return 0
  else
    error "Failed to create user '${username}'"
    return 1
  fi
}

# Configure brew user delegation and save to .env
configure_brew_delegation() {
  local brew_user="$1"
  local root_dir
  root_dir="$(get_root_dir)"
  local env_file="${root_dir}/.env"

  if [[ -z "${brew_user}" ]]; then
    error "No brew user specified for delegation"
    return 1
  fi

  if [[ -f "${env_file}" ]]; then
    if grep -q "^BREW_USER=" "${env_file}"; then
      if is_macos; then
        sed -i '' "s/^BREW_USER=.*/BREW_USER=${brew_user}/" "${env_file}"
      else
        sed -i "s/^BREW_USER=.*/BREW_USER=${brew_user}/" "${env_file}"
      fi
    else
      echo "BREW_USER=${brew_user}" >> "${env_file}"
    fi
  else
    echo "BREW_USER=${brew_user}" > "${env_file}"
  fi

  export BREW_USER="${brew_user}"
  success "Brew delegation configured for user: ${brew_user}"
}

confirm() {
  local prompt="$1"
  local response
  read -r -n 1 -p "${prompt} (y/N): " response
  echo # Add newline after single character input
  case "${response}" in
    y | Y)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Fix hostname resolution for sudo if needed
fix_hostname_resolution() {
  if is_linux; then
    local hostname
    hostname=$(cat /etc/hostname 2>/dev/null || hostname)

    if [[ -n "${hostname}" ]] && ! grep -q "127.0.0.1.*${hostname}" /etc/hosts 2>/dev/null; then
      info "Fixing hostname resolution in /etc/hosts..."
      # Add hostname to the first 127.0.0.1 line if not already present
      if grep -q "^127.0.0.1" /etc/hosts; then
        sudo sed -i "0,/^127.0.0.1/{s/127.0.0.1\s/127.0.0.1       ${hostname} /}" /etc/hosts
      else
        echo "127.0.0.1       ${hostname}" | sudo tee -a /etc/hosts > /dev/null
      fi
      success "Hostname '${hostname}' added to /etc/hosts"
    fi
  fi
}

# ============================================================================
# Setup Command
# ============================================================================

brew_setup() {
  # Fix hostname resolution to prevent sudo warnings
  fix_hostname_resolution

  # Load any existing BREW_USER configuration
  load_brew_user

  # Handle root user - need to delegate to a standard user
  if is_root; then
    warn "Running as root. Homebrew must be installed as a non-root user."
    echo ""

    # Check if BREW_USER is already configured and user exists
    if [[ -n "${BREW_USER:-}" ]] && user_exists "${BREW_USER}"; then
      info "Using configured brew user: ${BREW_USER}"
      # Ensure user is in admin group (idempotent)
      if ! user_in_admin_group "${BREW_USER}"; then
        info "Ensuring '${BREW_USER}' has admin/sudo access..."
        if is_macos; then
          sudo dseditgroup -o edit -a "${BREW_USER}" -t user admin 2>/dev/null || true
        else
          if getent group sudo &> /dev/null; then
            sudo usermod -aG sudo "${BREW_USER}" 2>/dev/null || true
          elif getent group wheel &> /dev/null; then
            sudo usermod -aG wheel "${BREW_USER}" 2>/dev/null || true
          fi
        fi
      fi
    elif [[ -n "${BREW_USER:-}" ]]; then
      # BREW_USER is set but user doesn't exist - create it (non-interactive)
      info "BREW_USER='${BREW_USER}' is configured but user does not exist."
      local brew_user
      brew_user=$(create_brew_user "${BREW_USER}" "true")
      if [[ -z "${brew_user}" ]]; then
        error "Failed to create configured brew user."
        return 1
      fi
      configure_brew_delegation "${brew_user}"
    else
      # Need to set up brew user delegation interactively
      if ! confirm "Would you like to configure a user for brew operations?"; then
        warn "Skipping brew setup. Homebrew requires a non-root user."
        return 1
      fi

      local brew_user
      brew_user=$(create_brew_user "jay" "false")

      if [[ -z "${brew_user}" ]]; then
        error "Brew user setup cancelled."
        return 1
      fi

      configure_brew_delegation "${brew_user}"
    fi

    # Check if brew is already installed
    local BREW_PREFIX
    BREW_PREFIX=$(detect_brew_path)

    if [[ -n "${BREW_PREFIX}" ]]; then
      success "Homebrew is already installed at: ${BREW_PREFIX}"
      info "Brew commands will be delegated to user: ${BREW_USER}"
      return 0
    fi

    # Install Homebrew as the brew user
    info "Installing Homebrew as user: ${BREW_USER}"
    echo ""

    # Prepare the linuxbrew directory with proper ownership
    if is_linux || grep -qi microsoft /proc/version 2> /dev/null; then
      if [[ ! -d "/home/linuxbrew" ]]; then
        info "Creating /home/linuxbrew directory..."
        mkdir -p /home/linuxbrew/.linuxbrew
        chown -R "${BREW_USER}:${BREW_USER}" /home/linuxbrew
      elif [[ ! -w "/home/linuxbrew/.linuxbrew" ]] || [[ "$(stat -c '%U' /home/linuxbrew 2>/dev/null)" != "${BREW_USER}" ]]; then
        info "Fixing ownership of /home/linuxbrew..."
        chown -R "${BREW_USER}:${BREW_USER}" /home/linuxbrew
      fi
    fi

    local install_script
    install_script="$(mktemp)"
    chmod 644 "${install_script}"

    if curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "${install_script}"; then
      if sudo -u "${BREW_USER}" NONINTERACTIVE=1 /bin/bash "${install_script}"; then
        rm -f "${install_script}"
        success "Homebrew installed successfully for user: ${BREW_USER}"
        info ""
        info "To use brew commands as root, use: jsh brew <command>"
        info "The BREW_USER setting is saved in $(get_root_dir)/.env"
        return 0
      else
        rm -f "${install_script}"
        error "Failed to install Homebrew as user: ${BREW_USER}"
        return 1
      fi
    else
      error "Failed to download Homebrew install script."
      return 1
    fi
  fi

  # Non-root path - original behavior
  local BREW_PREFIX
  BREW_PREFIX=$(detect_brew_path)

  if [[ -n "${BREW_PREFIX}" ]]; then
    success "Homebrew is already installed at: ${BREW_PREFIX}"
    info "Configuring environment..."

    if apply_brew_shellenv "${BREW_PREFIX}/bin/brew"; then
      success "Homebrew environment configured"
      return 0
    else
      warn "Failed to configure Homebrew environment"
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
  if [[ -n "${BREW_PREFIX}" ]]; then
    if apply_brew_shellenv "${BREW_PREFIX}/bin/brew"; then
      success "Homebrew installation and configuration complete!"
      return 0
    fi
  fi

  warn "Homebrew installation complete, but environment could not be configured automatically"
  info "Please follow the instructions above to add Homebrew to your PATH"
  return 1
}

# ============================================================================
# Check Command - Helper Functions
# ============================================================================

# Extract package names from JSON config files
extract_packages_from_json() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo ""
    return
  fi
  jq -r '.packages[]? // empty' "${file}" 2>/dev/null | sort -u
}

# Check if a package is available in Homebrew API
check_package_in_api() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  local api_url=""
  if [[ "${pkg_type}" == "cask" ]]; then
    api_url="https://formulae.brew.sh/api/cask/${pkg}.json"
  else
    api_url="https://formulae.brew.sh/api/formula/${pkg}.json"
  fi

  # Use curl to check if the package exists in the API
  if curl -sf "${api_url}" &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# Check if a package exists locally
check_package_locally() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  if [[ "${pkg_type}" == "cask" ]]; then
    brew info --cask "${pkg}" &> /dev/null
    return $?
  else
    brew info --formula "${pkg}" &> /dev/null
    return $?
  fi
}

# Validate a specific package exists
validate_package() {
  local pkg="$1"
  local forced_platform="${2:-}" # Optional forced platform: 'linux' or 'darwin'

  info "Checking package: ${pkg}"

  # Determine which platform to check against
  local check_platform="${forced_platform}"
  if [[ -z "${check_platform}" ]]; then
    if is_macos; then
      check_platform="darwin"
    else
      check_platform="linux"
    fi
  fi

  # Try as formula first
  if check_package_locally "${pkg}" "formula"; then
    # On Linux, check if the formula has macOS-only requirements
    if [[ "${check_platform}" == "linux" ]]; then
      # Get the formula info and check for platform requirements
      local brew_info
      brew_info=$(brew info --formula "${pkg}" 2>&1 || echo "")

      if echo "${brew_info}" | grep -q "Required: macOS"; then
        error "Package '${pkg}' is not supported on Linux (macOS-only package)"
        return 1
      fi
    fi

    success "Package '${pkg}' is available as a formula"
    return 0
  fi

  # Try as cask on macOS
  if [[ "${check_platform}" == "darwin" ]]; then
    if check_package_locally "${pkg}" "cask"; then
      success "Package '${pkg}' is available as a cask"
      return 0
    fi
  fi

  # Check API with platform validation
  if check_package_in_api "${pkg}" "formula"; then
    # For Linux, double-check via API metadata
    if is_linux || grep -qi microsoft /proc/version 2> /dev/null; then
      # Fetch API metadata to check platform support
      local api_response
      api_response=$(curl -sf "https://formulae.brew.sh/api/formula/${pkg}.json" 2> /dev/null || echo "")

      if [[ -n "${api_response}" ]]; then
        # Check if the package has platform requirements
        local platforms
        platforms=$(echo "${api_response}" | jq -r '.platform | keys[]' 2> /dev/null || echo "")

        if [[ -n "${platforms}" ]]; then
          # If platform info exists, check if linux is in it
          if echo "${platforms}" | grep -q "linux"; then
            success "Package '${pkg}' exists in Homebrew repository and supports Linux"
            return 0
          else
            error "Package '${pkg}' is not supported on Linux (Darwin-only package)"
            return 1
          fi
        else
          # No platform info, assume it's cross-platform
          success "Package '${pkg}' exists in Homebrew repository"
          return 0
        fi
      fi
    else
      success "Package '${pkg}' exists in Homebrew repository"
      return 0
    fi
  fi

  if is_macos && check_package_in_api "${pkg}" "cask"; then
    success "Package '${pkg}' exists as a cask in Homebrew repository"
    return 0
  fi

  error "Package '${pkg}' not found in Homebrew repository"
  return 1
}

# Comprehensive check: outdated packages, invalid packages, unsupported platform packages
comprehensive_check() {
  local forced_platform="${1:-}"  # Optional forced platform: 'linux' or 'darwin'
  local quiet_mode="${2:-false}"  # Optional quiet mode
  local force_check="${3:-false}" # Optional force check
  local root_dir
  root_dir="$(get_root_dir)"

  local marker_file="${root_dir}/.brewcheck"

  if [[ "${force_check}" != "true" ]] && [[ -f "${marker_file}" ]]; then
    # Check if file is less than 24 hours old
    if [[ -n $(find "${marker_file}" -mtime -1 2> /dev/null) ]]; then
      if [[ "${quiet_mode}" != "true" ]]; then
        # Calculate relative time
        local now file_time elapsed_secs
        now=$(date +%s)
        if is_macos; then
          file_time=$(stat -f %m "${marker_file}")
        else
          file_time=$(stat -c %Y "${marker_file}")
        fi
        elapsed_secs=$((now - file_time))

        local time_ago
        if [[ ${elapsed_secs} -lt 60 ]]; then
          time_ago="just now"
        elif [[ ${elapsed_secs} -lt 3600 ]]; then
          time_ago="$((elapsed_secs / 60))m ago"
        else
          time_ago="$((elapsed_secs / 3600))h ago"
        fi
        info "⏳ Brew check ran ${time_ago}. Skipping... (use --force to override)"
      fi
      return 0
    fi
  fi

  if [[ "${quiet_mode}" != "true" ]]; then
    info "🔍 Running comprehensive Homebrew check..."
    echo ""
  fi

  # Get current OS or use forced platform
  local current_os="${forced_platform}"
  if [[ -z "${current_os}" ]]; then
    if is_macos; then
      current_os="darwin"
    else
      current_os="linux"
    fi
  fi

  local issues_found=0

  # 1. Check for outdated packages (only on actual platform, not forced)
  if [[ -z "${1:-}" ]]; then
    [[ "${quiet_mode}" != "true" ]] && info "📦 Checking for outdated packages..."
    local outdated_count=0

    if outdated=$(brew outdated --quiet 2> /dev/null); then
      outdated_count=$(echo "${outdated}" | grep -c . 2> /dev/null || true)
      outdated_count=${outdated_count:-0}
      outdated_count=$((${outdated_count//[!0-9]/}))
      if [[ ${outdated_count} -gt 0 ]]; then
        if [[ "${quiet_mode}" != "true" ]]; then
          warn "Found ${outdated_count} outdated package(s):"
          echo "${outdated}" | while IFS= read -r pkg; do
            [[ -n "${pkg}" ]] && echo "  - ${pkg}"
          done
        fi
        ((issues_found++))
      else
        [[ "${quiet_mode}" != "true" ]] && success "All packages are up to date"
      fi
    fi
    [[ "${quiet_mode}" != "true" ]] && echo ""
  else
    [[ "${quiet_mode}" != "true" ]] && info "📦 Skipping outdated package check (forced platform mode)"
    [[ "${quiet_mode}" != "true" ]] && echo ""
  fi

  # Update marker file
  touch "${marker_file}"

  # Summary
  if [[ ${issues_found} -eq 0 ]]; then
    [[ "${quiet_mode}" != "true" ]] && success "All checks passed! No issues found."
    return 0
  else
    if [[ "${quiet_mode}" == "true" ]]; then
      echo "jsh: ${outdated_count} outdated brew package(s). Run 'jsh brew check' or 'brew upgrade'"
    else
      warn "Found ${issues_found} issue(s). Review the output above."
    fi
    return 1
  fi
}

brew_check() {
  # Check if brew is installed (handle root delegation)
  load_brew_user

  local brew_available=false
  if is_root; then
    # When root, check if brew path exists and BREW_USER is configured
    if [[ -n "${BREW_USER:-}" ]] && [[ -n "$(detect_brew_path)" ]]; then
      brew_available=true
    fi
  else
    if command -v brew &> /dev/null; then
      brew_available=true
    fi
  fi

  if [[ "${brew_available}" != "true" ]]; then
    warn "Homebrew is not installed. Run: jsh brew setup"
    return 1
  fi

  local forced_platform=""
  local quiet_mode=false
  local force_check=false
  local -a pkg_args
  pkg_args=()

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
        pkg_args+=("$1")
        shift
        ;;
    esac
  done

  # If a package name is provided, just validate that package
  if [[ ${#pkg_args[@]} -gt 0 ]]; then
    validate_package "${pkg_args[0]}" "${forced_platform}"
    return $?
  fi

  # Otherwise run comprehensive checks
  comprehensive_check "${forced_platform}" "${quiet_mode}" "${force_check}"
}

# ============================================================================
# Brew Wrapper Function (with root delegation)
# ============================================================================

# Helper function to run brew (handles root delegation)
run_brew() {
  load_brew_user

  if is_root; then
    if [[ -z "${BREW_USER:-}" ]]; then
      error "Running as root without configured brew user."
      info "Run: jsh brew setup"
      return 1
    fi

    if ! user_exists "${BREW_USER}"; then
      error "Brew user '${BREW_USER}' does not exist."
      info "Run: jsh brew setup"
      return 1
    fi

    # Use run_as_brew_user to properly setup environment
    run_as_brew_user brew "$@"
  else
    brew "$@"
  fi
}

# Wrapper for brew command that handles root delegation
brew_cmd() {
  load_brew_user

  if is_root; then
    if [[ -z "${BREW_USER:-}" ]]; then
      warn "Running as root without configured brew user."
      warn "Please run 'jsh brew setup' to configure brew delegation."
      return 1
    fi
    run_as_brew_user brew "$@"
  else
    brew "$@"
  fi
}

# Get the user's login shell
get_user_shell() {
  local user_shell
  if is_macos; then
    user_shell=$(dscl . -read ~/ UserShell 2> /dev/null | awk '{print $2}')
  else
    user_shell=$(getent passwd "$(whoami)" 2> /dev/null | cut -d: -f7)
  fi
  echo "${user_shell}"
}
