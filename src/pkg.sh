# pkg.sh - Package management for jsh
# Provides: jsh pkg <add|remove|list|sync|commit|status|diff|export|audit|service>
# shellcheck disable=SC2034,SC2154

# Load guard
[[ -n "${_JSH_PKG_LOADED:-}" ]] && return 0
_JSH_PKG_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

PKG_CONFIGS_DIR="${JSH_DIR:-${HOME}/.jsh}/configs/packages"
PKG_STATE_FILE="${JSH_DIR:-${HOME}/.jsh}/local/pkg-state.json"

# =============================================================================
# Core JSON Functions
# =============================================================================

# Get config file path for a package manager/type
# Usage: _pkg_config_file brew|cask|apt|dnf|npm|pip|cargo
_pkg_config_file() {
  local pm_type="$1"
  local os_type
  os_type=$(uname -s)
  os_type=${os_type,,}
  [[ "${os_type}" == "darwin" ]] && os_type="macos"

  case "${pm_type}" in
  brew | formulae)
    echo "${PKG_CONFIGS_DIR}/${os_type}/formulae.json"
    ;;
  cask | casks)
    local cask_os_type
    cask_os_type=$(uname -s)
    cask_os_type=${cask_os_type,,}
    [[ "${cask_os_type}" == "darwin" ]] && cask_os_type="macos" || cask_os_type="linux"
    echo "${PKG_CONFIGS_DIR}/${cask_os_type}/casks.json"
    ;;
  apt | dnf | pacman | apk | zypper | flatpak)
    echo "${PKG_CONFIGS_DIR}/linux/${pm_type}.json"
    ;;
  npm | pip | cargo | go)
    echo "${PKG_CONFIGS_DIR}/${pm_type}.json"
    ;;
  service | services)
    echo "${PKG_CONFIGS_DIR}/${os_type}/services.json"
    ;;
  *)
    # Try direct file path
    if [[ -f "${pm_type}" ]]; then
      echo "${pm_type}"
    else
      echo ""
    fi
    ;;
  esac
}

# Load packages from JSON file (one per line)
# Usage: _pkg_load <json_file>
_pkg_load() {
  local json_file="$1"

  if [[ ! -f "${json_file}" ]]; then
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '.[]' "${json_file}" 2>/dev/null
  else
    # Fallback: simple grep extraction for JSON arrays
    grep -oE '"[^"]*"' "${json_file}" | tr -d '"'
  fi
}

# Save packages to JSON file (sorted, deduplicated)
# Usage: _pkg_save <json_file> <packages...>
_pkg_save() {
  local json_file="$1"
  shift
  local packages=("$@")

  if ! command -v jq >/dev/null 2>&1; then
    error "jq is required for JSON manipulation"
    return 1
  fi

  # Ensure parent directory exists
  mkdir -p "$(dirname "${json_file}")"

  # Convert array to JSON, sort, and deduplicate
  printf '%s\n' "${packages[@]}" | jq -Rs 'split("\n") | map(select(length > 0)) | unique | sort' >"${json_file}"
}

# Add package to config (with duplicate check)
# Usage: _pkg_add_to_config <pm_type> <package>
_pkg_add_to_config() {
  local pm_type="$1"
  local package="$2"

  if [[ -z "${pm_type}" || -z "${package}" ]]; then
    error "Usage: _pkg_add_to_config <pm_type> <package>"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    error "jq is required for JSON manipulation"
    return 1
  fi

  local config_file
  config_file=$(_pkg_config_file "${pm_type}")

  if [[ -z "${config_file}" ]]; then
    error "Unknown package manager type: ${pm_type}"
    return 1
  fi

  # Create file with empty array if it doesn't exist
  if [[ ! -f "${config_file}" ]]; then
    mkdir -p "$(dirname "${config_file}")"
    echo "[]" >"${config_file}"
  fi

  # Check for duplicates
  if jq -e --arg pkg "${package}" 'index($pkg) != null' "${config_file}" >/dev/null 2>&1; then
    info "Package '${package}' already in $(basename "${config_file}")"
    return 0
  fi

  # Add package, sort, and save
  local temp_file
  temp_file=$(mktemp)
  if jq --arg pkg "${package}" '. + [$pkg] | unique | sort' "${config_file}" >"${temp_file}"; then
    mv "${temp_file}" "${config_file}"
    prefix_success "Added '${package}' to $(basename "${config_file}")"
    return 0
  else
    rm -f "${temp_file}"
    error "Failed to add package to ${config_file}"
    return 1
  fi
}

# Remove package from config
# Usage: _pkg_remove_from_config <pm_type> <package>
_pkg_remove_from_config() {
  local pm_type="$1"
  local package="$2"

  if [[ -z "${pm_type}" || -z "${package}" ]]; then
    error "Usage: _pkg_remove_from_config <pm_type> <package>"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    error "jq is required for JSON manipulation"
    return 1
  fi

  local config_file
  config_file=$(_pkg_config_file "${pm_type}")

  if [[ ! -f "${config_file}" ]]; then
    warn "Config file does not exist: ${config_file}"
    return 1
  fi

  # Check if package exists
  if ! jq -e --arg pkg "${package}" 'index($pkg) != null' "${config_file}" >/dev/null 2>&1; then
    info "Package '${package}' not found in $(basename "${config_file}")"
    return 1
  fi

  # Remove package
  local temp_file
  temp_file=$(mktemp)
  if jq --arg pkg "${package}" 'map(select(. != $pkg))' "${config_file}" >"${temp_file}"; then
    mv "${temp_file}" "${config_file}"
    prefix_success "Removed '${package}' from $(basename "${config_file}")"
    return 0
  else
    rm -f "${temp_file}"
    error "Failed to remove package from ${config_file}"
    return 1
  fi
}

# =============================================================================
# Package Manager Detection
# =============================================================================

# Detect the primary system package manager
# Prefers Homebrew/Linuxbrew on both platforms for consistency
_pkg_detect_system_pm() {
  # Prefer brew on both macOS and Linux
  command -v brew >/dev/null 2>&1 && echo "brew" && return

  # Fallback to native package managers on Linux
  if [[ "$(uname -s)" == "Linux" ]]; then
    command -v dnf >/dev/null 2>&1 && echo "dnf" && return
    command -v apt >/dev/null 2>&1 && echo "apt" && return
    command -v pacman >/dev/null 2>&1 && echo "pacman" && return
    command -v apk >/dev/null 2>&1 && echo "apk" && return
    command -v zypper >/dev/null 2>&1 && echo "zypper" && return
  fi
  echo "unknown"
}

# Detect best package manager for a package
# Usage: _pkg_detect_manager <package>
_pkg_detect_manager() {
  local package="$1"

  # Check package name patterns
  case "${package}" in
  @*/* | *@*)
    # npm scoped package or package@version
    echo "npm"
    return
    ;;
  *-cli | create-*)
    # Common npm CLI patterns
    echo "npm"
    return
    ;;
  esac

  # Use system package manager as default
  _pkg_detect_system_pm
}

# Check if package is installed via a package manager
# Usage: _pkg_is_installed <pm_type> <package>
_pkg_is_installed() {
  local pm_type="$1"
  local package="$2"

  case "${pm_type}" in
  brew | formulae)
    brew list "${package}" >/dev/null 2>&1
    ;;
  cask | casks)
    brew list --cask "${package}" >/dev/null 2>&1
    ;;
  npm)
    npm list -g "${package}" >/dev/null 2>&1
    ;;
  pip)
    pip3 show "${package}" >/dev/null 2>&1 || pip show "${package}" >/dev/null 2>&1
    ;;
  cargo)
    cargo install --list 2>/dev/null | grep -q "^${package} "
    ;;
  go)
    # Extract binary name from go install path (last component before @)
    local bin_name
    bin_name=$(basename "${package%%@*}")
    command -v "${bin_name}" >/dev/null 2>&1
    ;;
  apt)
    dpkg -l "${package}" 2>/dev/null | grep -q "^ii"
    ;;
  dnf)
    dnf list installed "${package}" >/dev/null 2>&1
    ;;
  pacman)
    pacman -Q "${package}" >/dev/null 2>&1
    ;;
  apk)
    apk info -e "${package}" >/dev/null 2>&1
    ;;
  zypper)
    zypper se -i "${package}" >/dev/null 2>&1
    ;;
  flatpak)
    flatpak list --app --columns=application 2>/dev/null | grep -qx "${package}"
    ;;
  *)
    return 1
    ;;
  esac
}

# =============================================================================
# Package Installation Cache (for bulk operations)
# =============================================================================

# Cache for installed packages (pipe-delimited lists)
# Note: Declared inside _pkg_cache_init to ensure proper associative array behavior
declare -A _PKG_INSTALLED_CACHE 2>/dev/null || true

# Initialize cache array (must be called before first use)
_pkg_cache_init() {
  # Ensure we have a proper associative array
  unset _PKG_INSTALLED_CACHE 2>/dev/null || true
  declare -gA _PKG_INSTALLED_CACHE
}

# Populate cache for a package manager type
# Usage: _pkg_cache_installed <pm_type>
_pkg_cache_installed() {
  local pm_type="$1"

  case "${pm_type}" in
  brew | formulae)
    _PKG_INSTALLED_CACHE[brew]=$(brew list --formula 2>/dev/null | tr '\n' '|')
    ;;
  cask | casks)
    _PKG_INSTALLED_CACHE[cask]=$(brew list --cask 2>/dev/null | tr '\n' '|')
    ;;
  npm)
    _PKG_INSTALLED_CACHE[npm]=$(npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/.*── //' | cut -d@ -f1 | tr '\n' '|')
    ;;
  cargo)
    _PKG_INSTALLED_CACHE[cargo]=$(cargo install --list 2>/dev/null | grep -v '^ ' | cut -d' ' -f1 | tr '\n' '|')
    ;;
  pip)
    _PKG_INSTALLED_CACHE[pip]=$(pip3 list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '\n' '|')
    ;;
  esac
}

# Check if package is installed using cached data
# Usage: _pkg_is_installed_cached <pm_type> <package>
_pkg_is_installed_cached() {
  local pm_type="$1"
  local package="$2"
  local cache_key="${pm_type}"

  # Normalize cache key
  [[ "${pm_type}" == "formulae" ]] && cache_key="brew"
  [[ "${pm_type}" == "casks" ]] && cache_key="cask"

  # Check if in cache (pipe-delimited list)
  [[ "|${_PKG_INSTALLED_CACHE[${cache_key}]}|" == *"|${package}|"* ]]
}

# Install package via package manager
# Usage: _pkg_install <pm_type> <package>
_pkg_install() {
  local pm_type="$1"
  local package="$2"

  case "${pm_type}" in
  brew | formulae)
    brew install "${package}"
    ;;
  cask | casks)
    brew install --cask "${package}"
    ;;
  npm)
    npm install -g "${package}"
    ;;
  pip)
    pip3 install --user "${package}" 2>/dev/null || pip install --user "${package}"
    ;;
  cargo)
    cargo install "${package}"
    ;;
  go)
    go install "${package}"
    ;;
  apt)
    sudo apt install -y "${package}"
    ;;
  dnf)
    sudo dnf install -y "${package}"
    ;;
  pacman)
    sudo pacman -S --noconfirm "${package}"
    ;;
  apk)
    sudo apk add "${package}"
    ;;
  zypper)
    sudo zypper install -y "${package}"
    ;;
  flatpak)
    flatpak install -y flathub "${package}"
    ;;
  *)
    error "Unknown package manager: ${pm_type}"
    return 1
    ;;
  esac
}

# =============================================================================
# Service Management
# =============================================================================

# Get services config file for current platform
_pkg_services_file() {
  local os_type
  os_type=$(uname -s)
  os_type=${os_type,,}
  [[ "${os_type}" == "darwin" ]] && os_type="macos"

  echo "${PKG_CONFIGS_DIR}/${os_type}/services.json"
}

# List managed services
_pkg_service_list() {
  local services_file
  services_file=$(_pkg_services_file)

  echo ""
  echo "${BOLD}Managed Services${RST}"
  echo ""

  if [[ ! -f "${services_file}" ]]; then
    info "No services configured"
    return 0
  fi

  local services
  services=$(_pkg_load "${services_file}")

  if [[ -z "${services}" ]]; then
    info "No services configured"
    return 0
  fi

  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue

    local status_icon status_text
    if _pkg_service_status "${service}" >/dev/null 2>&1; then
      status_icon="${GRN}●${RST}"
      status_text="running"
    else
      status_icon="${RED}○${RST}"
      status_text="stopped"
    fi

    echo "  ${status_icon} ${service} ${DIM}(${status_text})${RST}"
  done <<<"${services}"
}

# Check if service is running
_pkg_service_status() {
  local service="$1"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    brew services list 2>/dev/null | grep -q "^${service}.*started"
  else
    # Try user service first, then system service
    systemctl --user is-active "${service}" >/dev/null 2>&1 ||
      systemctl is-active "${service}" >/dev/null 2>&1
  fi
}

# Start a service
_pkg_service_start() {
  local service="$1"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    brew services start "${service}"
  else
    # Try user service first (syncthing, ssh-agent, etc.)
    if systemctl --user list-unit-files "${service}.service" &>/dev/null ||
      systemctl --user list-unit-files "${service}" &>/dev/null; then
      systemctl --user enable "${service}"
      systemctl --user start "${service}"
    else
      # Fall back to system service
      sudo systemctl enable "${service}"
      sudo systemctl start "${service}"
    fi
  fi
}

# Stop a service
_pkg_service_stop() {
  local service="$1"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    brew services stop "${service}"
  else
    # Try user service first
    if systemctl --user is-active "${service}" &>/dev/null; then
      systemctl --user stop "${service}"
    else
      sudo systemctl stop "${service}"
    fi
  fi
}

# Restart a service
_pkg_service_restart() {
  local service="$1"

  if [[ "$(uname -s)" == "Darwin" ]]; then
    brew services restart "${service}"
  else
    # Try user service first
    if systemctl --user is-active "${service}" &>/dev/null ||
      systemctl --user is-enabled "${service}" &>/dev/null; then
      systemctl --user restart "${service}"
    else
      sudo systemctl restart "${service}"
    fi
  fi
}

# Add service to config
_pkg_service_add() {
  local service="$1"
  _pkg_add_to_config "services" "${service}"
}

# Remove service from config
_pkg_service_remove() {
  local service="$1"
  _pkg_remove_from_config "services" "${service}"
}

# Start all managed services
_pkg_services_start_all() {
  local services_file
  services_file=$(_pkg_services_file)

  if [[ ! -f "${services_file}" ]]; then
    return 0
  fi

  local services
  services=$(_pkg_load "${services_file}")

  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue

    if ! _pkg_service_status "${service}"; then
      info "Starting ${service}..."
      _pkg_service_start "${service}"
    fi
  done <<<"${services}"
}

# =============================================================================
# Git Integration
# =============================================================================

# Show uncommitted changes in configs
_pkg_git_status() {
  local configs_dir="${JSH_DIR:-${HOME}/.jsh}/configs"

  cd "${JSH_DIR:-${HOME}/.jsh}" || return 1

  echo ""
  echo "${BOLD}Package Config Changes${RST}"
  echo ""

  local changes
  changes=$(git status --porcelain "${configs_dir}" 2>/dev/null)

  if [[ -z "${changes}" ]]; then
    prefix_success "No uncommitted changes"
    return 0
  fi

  while IFS= read -r line; do
    local status="${line:0:2}"
    local file="${line:3}"

    case "${status}" in
    " M" | "M ")
      echo "  ${YLW}modified${RST}: ${file}"
      ;;
    "A " | " A")
      echo "  ${GRN}added${RST}: ${file}"
      ;;
    "D " | " D")
      echo "  ${RED}deleted${RST}: ${file}"
      ;;
    "??")
      echo "  ${CYN}new${RST}: ${file}"
      ;;
    esac
  done <<<"${changes}"
}

# Commit config changes
_pkg_git_commit() {
  local message="${1:-Update package configs}"

  local configs_dir="${JSH_DIR:-${HOME}/.jsh}/configs"

  cd "${JSH_DIR:-${HOME}/.jsh}" || return 1

  # Check for changes
  if git diff --quiet "${configs_dir}" &&
    git diff --cached --quiet "${configs_dir}" &&
    [[ -z "$(git ls-files --others --exclude-standard "${configs_dir}")" ]]; then
    info "No changes to commit"
    return 0
  fi

  # Stage config changes
  git add "${configs_dir}"

  # Commit
  if git commit -m "${message}"; then
    prefix_success "Committed: ${message}"
  else
    error "Commit failed"
    return 1
  fi
}

# =============================================================================
# Diff and Audit
# =============================================================================

# Compare config vs installed packages
_pkg_diff() {
  local pm_type="${1:-}"

  if [[ -z "${pm_type}" ]]; then
    pm_type=$(_pkg_detect_system_pm)
  fi

  local config_file
  config_file=$(_pkg_config_file "${pm_type}")

  if [[ ! -f "${config_file}" ]]; then
    warn "No config file for ${pm_type}"
    return 1
  fi

  echo ""
  echo "${BOLD}Package Diff: ${pm_type}${RST}"
  echo ""

  local config_packages
  config_packages=$(_pkg_load "${config_file}")

  local missing=()
  local orphaned=()

  # Check config packages against installed
  while IFS= read -r package; do
    [[ -z "${package}" ]] && continue

    if ! _pkg_is_installed "${pm_type}" "${package}"; then
      missing+=("${package}")
    fi
  done <<<"${config_packages}"

  # Show missing (in config but not installed)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "${YLW}Missing (in config, not installed):${RST}"
    for pkg in "${missing[@]}"; do
      echo "  - ${pkg}"
    done
    echo ""
  fi

  # For brew, check orphaned (installed but not in config)
  if [[ "${pm_type}" == "brew" ]] && command -v brew >/dev/null 2>&1; then
    local installed_packages
    installed_packages=$(brew list --formula 2>/dev/null)

    while IFS= read -r package; do
      [[ -z "${package}" ]] && continue

      if ! echo "${config_packages}" | grep -qx "${package}"; then
        orphaned+=("${package}")
      fi
    done <<<"${installed_packages}"

    if [[ ${#orphaned[@]} -gt 0 ]]; then
      echo "${CYN}Orphaned (installed, not in config):${RST}"
      for pkg in "${orphaned[@]}"; do
        echo "  + ${pkg}"
      done
      echo ""
    fi
  fi

  if [[ ${#missing[@]} -eq 0 ]] && [[ ${#orphaned[@]} -eq 0 ]]; then
    prefix_success "Config and installed packages are in sync"
  fi
}

# Export installed packages to config
_pkg_export() {
  local pm_type="${1:-}"
  local overwrite="${2:-false}"

  if [[ -z "${pm_type}" ]]; then
    pm_type=$(_pkg_detect_system_pm)
  fi

  echo ""
  info "Exporting installed ${pm_type} packages to config..."

  local packages=()

  case "${pm_type}" in
  brew)
    mapfile -t packages < <(brew list --formula 2>/dev/null)
    ;;
  npm)
    mapfile -t packages < <(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies // {} | keys[]')
    ;;
  pip)
    mapfile -t packages < <(pip3 list --user --format=freeze 2>/dev/null | cut -d= -f1)
    ;;
  cargo)
    mapfile -t packages < <(cargo install --list 2>/dev/null | grep -v '^ ' | cut -d' ' -f1)
    ;;
  *)
    error "Export not supported for ${pm_type}"
    return 1
    ;;
  esac

  if [[ ${#packages[@]} -eq 0 ]]; then
    warn "No packages found"
    return 0
  fi

  local config_file
  config_file=$(_pkg_config_file "${pm_type}")

  if [[ -f "${config_file}" ]] && [[ "${overwrite}" != "true" ]]; then
    # Merge with existing
    local existing
    mapfile -t existing < <(_pkg_load "${config_file}")

    # Combine and dedupe
    local combined=()
    for pkg in "${existing[@]}" "${packages[@]}"; do
      combined+=("${pkg}")
    done

    _pkg_save "${config_file}" "${combined[@]}"
  else
    _pkg_save "${config_file}" "${packages[@]}"
  fi

  prefix_success "Exported ${#packages[@]} package(s) to ${config_file}"
}

# Audit package configs
_pkg_audit() {
  local check="${1:-all}"

  echo ""
  echo "${BOLD}Package Audit${RST}"
  echo ""

  local issues=0

  # Check for orphaned packages (installed but not in config)
  if [[ "${check}" == "all" || "${check}" == "orphans" ]]; then
    echo "${CYN}Checking orphaned packages...${RST}"
    local orphan_output
    orphan_output=$(_pkg_diff "brew" 2>/dev/null)
    if echo "${orphan_output}" | grep -q "Orphaned"; then
      echo "${orphan_output}" | grep -A100 "Orphaned"
      ((issues++))
    else
      prefix_success "No orphaned packages"
    fi
    echo ""
  fi

  # Check for true duplicates (same package in multiple configs on same platform)
  if [[ "${check}" == "all" || "${check}" == "duplicates" ]]; then
    echo "${CYN}Checking for platform duplicates...${RST}"

    local found_duplicates=false

    # Check Linux configs for duplicates
    local linux_configs=()
    for f in "${PKG_CONFIGS_DIR}"/linux/*.json; do
      [[ -f "$f" ]] && [[ "$(basename "$f")" != "services.json" ]] && linux_configs+=("$f")
    done

    if [[ ${#linux_configs[@]} -gt 1 ]]; then
      # Collect all Linux packages with their source
      local linux_packages=()
      for config_file in "${linux_configs[@]}"; do
        local source_name
        source_name=$(basename "${config_file}" .json)
        while IFS= read -r pkg; do
          [[ -z "${pkg}" ]] && continue
          linux_packages+=("${pkg}|${source_name}")
        done < <(_pkg_load "${config_file}" 2>/dev/null)
      done

      # Find duplicates by package name
      local seen=()
      local reported=()
      for entry in "${linux_packages[@]}"; do
        local pkg="${entry%%|*}"
        local source="${entry#*|}"

        for prev in "${seen[@]}"; do
          local prev_pkg="${prev%%|*}"
          local prev_source="${prev#*|}"

          if [[ "${pkg}" == "${prev_pkg}" ]] && [[ "${source}" != "${prev_source}" ]]; then
            # Check if already reported
            local already_reported=false
            for r in "${reported[@]}"; do
              [[ "${r}" == "${pkg}" ]] && already_reported=true && break
            done

            if [[ "${already_reported}" == false ]]; then
              if [[ "${found_duplicates}" == false ]]; then
                echo "${YLW}Linux platform duplicates:${RST}"
                found_duplicates=true
              fi
              echo "  ${pkg}: ${prev_source} + ${source}"
              reported+=("${pkg}")
              ((issues++))
            fi
          fi
        done
        seen+=("${entry}")
      done
    fi

    # Check macOS configs for duplicates (formulae vs casks with same name)
    local macos_formulae="${PKG_CONFIGS_DIR}/macos/formulae.json"
    local macos_casks="${PKG_CONFIGS_DIR}/macos/casks.json"

    if [[ -f "${macos_formulae}" ]] && [[ -f "${macos_casks}" ]]; then
      local formulae_list casks_list
      formulae_list=$(_pkg_load "${macos_formulae}" 2>/dev/null)
      casks_list=$(_pkg_load "${macos_casks}" 2>/dev/null)

      local macos_dups
      macos_dups=$(comm -12 <(echo "${formulae_list}" | sort) <(echo "${casks_list}" | sort))

      if [[ -n "${macos_dups}" ]]; then
        if [[ "${found_duplicates}" == false ]]; then
          found_duplicates=true
        fi
        echo "${YLW}macOS platform duplicates (formula + cask):${RST}"
        while IFS= read -r dup; do
          [[ -n "${dup}" ]] && echo "  ${dup}" && ((issues++))
        done <<<"${macos_dups}"
      fi
    fi

    if [[ "${found_duplicates}" == false ]]; then
      prefix_success "No platform duplicates"
    fi
    echo ""
  fi

  # Summary
  if [[ ${issues} -eq 0 ]]; then
    prefix_success "Audit passed - no issues found"
  else
    prefix_warn "Audit found ${issues} issue(s) to review"
  fi
}

# =============================================================================
# List Command
# =============================================================================

# Get current platform name for config paths
_pkg_current_platform() {
  local os_type
  os_type=$(uname -s)
  os_type=${os_type,,}
  [[ "${os_type}" == "darwin" ]] && echo "macos" || echo "linux"
}

_pkg_list() {
  local category="${1:-}"
  local filter="${2:-all}"    # all, installed, missing
  local platform="${3:-}"     # macos, linux, common, all (empty = current + common)
  local verbose="${4:-false}" # true = show packages, false = show counts

  echo ""

  if [[ -z "${category}" ]]; then
    # List categories, optionally filtered by platform
    local current_platform
    current_platform=$(_pkg_current_platform)

    # Default: show current platform + common
    if [[ -z "${platform}" ]]; then
      platform="current"
    fi

    if [[ "${verbose}" != true ]]; then
      echo "${BOLD}Package Categories${RST}"
    else
      echo "${BOLD}Packages${RST}"
    fi
    if [[ "${platform}" != "all" ]] && [[ "${platform}" != "current" ]]; then
      echo "${DIM}Platform: ${platform}${RST}"
    elif [[ "${platform}" == "current" ]]; then
      echo "${DIM}Platform: ${current_platform} (current)${RST}"
    fi
    echo ""

    # In verbose mode, pre-cache installed packages for fast lookup
    if [[ "${verbose}" == true ]]; then
      _pkg_cache_init
      _pkg_cache_installed "brew"
      _pkg_cache_installed "cask"
      _pkg_cache_installed "npm"
      _pkg_cache_installed "cargo"
      _pkg_cache_installed "pip"
    fi

    # Find all config files (root level + subdirectories)
    local config_files=()
    while IFS= read -r -d '' f; do
      config_files+=("$f")
    done < <(find "${PKG_CONFIGS_DIR}" -name "*.json" -type f -print0 2>/dev/null | sort -z)

    for config_file in "${config_files[@]}"; do
      [[ -f "${config_file}" ]] || continue

      local rel_path="${config_file#"${PKG_CONFIGS_DIR}/"}"
      local category_name="${rel_path%.json}"

      # Apply platform filter
      case "${platform}" in
      macos)
        [[ "${rel_path}" != macos/* ]] && continue
        ;;
      linux)
        [[ "${rel_path}" != linux/* ]] && continue
        ;;
      common)
        # Common packages are at root level (npm.json, pip.json, cargo.json)
        [[ "${rel_path}" == */* ]] && continue
        ;;
      current)
        # Show current platform + common (root level)
        if [[ "${rel_path}" == */* ]]; then
          [[ "${rel_path}" != ${current_platform}/* ]] && continue
        fi
        ;;
      all)
        # Show everything
        ;;
      esac

      if [[ "${verbose}" != true ]]; then
        # Summary mode: show counts
        local count
        count=$(_pkg_load "${config_file}" | wc -l | tr -d ' ')
        printf "  ${CYN}%-30s${RST} %d package(s)\n" "${category_name}" "${count}"
      else
        # Verbose mode: show packages with status
        local packages
        packages=$(_pkg_load "${config_file}" | sort)

        [[ -z "${packages}" ]] && continue

        # Determine package manager type for status checking
        local pm_type
        case "${category_name}" in
        macos/formulae | linux/formulae) pm_type="brew" ;;
        macos/casks | linux/casks) pm_type="cask" ;;
        macos/services | linux/services) pm_type="services" ;;
        npm) pm_type="npm" ;;
        pip) pm_type="pip" ;;
        cargo) pm_type="cargo" ;;
        go) pm_type="go" ;;
        linux/apt) pm_type="apt" ;;
        linux/dnf) pm_type="dnf" ;;
        linux/pacman) pm_type="pacman" ;;
        linux/apk) pm_type="apk" ;;
        linux/zypper) pm_type="zypper" ;;
        linux/flatpak) pm_type="flatpak" ;;
        *) pm_type="unknown" ;;
        esac

        echo "${CYN}${category_name}${RST}"

        while IFS= read -r package; do
          [[ -z "${package}" ]] && continue

          local is_installed=false
          local status_icon status_color

          # Check installation status (skip for services, use cached lookup)
          if [[ "${pm_type}" != "services" ]] && [[ "${pm_type}" != "unknown" ]]; then
            _pkg_is_installed_cached "${pm_type}" "${package}" && is_installed=true
          fi

          # Apply filter
          case "${filter}" in
          installed)
            [[ "${is_installed}" != true ]] && continue
            ;;
          missing)
            [[ "${is_installed}" == true ]] && continue
            ;;
          esac

          if [[ "${is_installed}" == true ]]; then
            status_icon="${GRN}✓${RST}"
          else
            status_icon="${DIM}○${RST}"
          fi

          echo "  ${status_icon} ${package}"
        done <<<"${packages}"
        echo ""
      fi
    done
    return 0
  fi

  # List packages in category
  local config_file
  config_file=$(_pkg_config_file "${category}")

  if [[ ! -f "${config_file}" ]]; then
    error "Unknown category: ${category}"
    return 1
  fi

  echo "${BOLD}Packages: ${category}${RST}"
  echo ""

  local packages
  packages=$(_pkg_load "${config_file}")

  while IFS= read -r package; do
    [[ -z "${package}" ]] && continue

    local is_installed=false
    _pkg_is_installed "${category}" "${package}" && is_installed=true

    # Apply filter
    case "${filter}" in
    installed)
      [[ "${is_installed}" != true ]] && continue
      ;;
    missing)
      [[ "${is_installed}" == true ]] && continue
      ;;
    esac

    if [[ "${is_installed}" == true ]]; then
      echo "  ${GRN}✓${RST} ${package}"
    else
      echo "  ${DIM}○${RST} ${package}"
    fi
  done <<<"${packages}"
}

# =============================================================================
# AppImage Management (Linux)
# =============================================================================

# Directory for AppImages
APPIMAGE_DIR="${HOME}/Applications"

# Download and install AppImage
# Usage: _pkg_install_appimage <name> <url> <filename>
_pkg_install_appimage() {
  local name="$1"
  local url="$2"
  local filename="$3"
  local target="${APPIMAGE_DIR}/${filename}"

  # Create Applications directory if needed
  mkdir -p "${APPIMAGE_DIR}"

  # Check if already installed
  if [[ -f "${target}" ]]; then
    return 0
  fi

  # Download the AppImage
  info "Downloading ${name}..."
  if curl -fSL -o "${target}" "${url}" 2>/dev/null; then
    chmod +x "${target}"

    # If AppImageLauncher is installed, integrate the AppImage
    if command -v AppImageLauncher &>/dev/null || command -v ail-cli &>/dev/null; then
      # ail-cli can integrate without GUI prompts
      if command -v ail-cli &>/dev/null; then
        ail-cli integrate "${target}" 2>/dev/null || true
      fi
    fi
    return 0
  else
    rm -f "${target}"
    return 1
  fi
}

# Check if AppImage is installed
# Usage: _pkg_is_appimage_installed <filename>
_pkg_is_appimage_installed() {
  local filename="$1"
  [[ -f "${APPIMAGE_DIR}/${filename}" ]] ||
    [[ -f "${HOME}/.local/share/applications/${filename%.AppImage}.desktop" ]]
}

# Sync AppImages from config
# Usage: _pkg_sync_appimages [dry_run]
_pkg_sync_appimages() {
  local dry_run="${1:-false}"
  local config_file="${PKG_CONFIGS_DIR}/linux/appimage.json"

  [[ ! -f "${config_file}" ]] && return 0

  echo "${CYN}appimage:${RST}"

  installed=0
  failed=0

  # Parse JSON array of objects
  local entries
  entries=$(jq -c '.[]' "${config_file}" 2>/dev/null)

  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue

    local name url filename
    name=$(echo "${entry}" | jq -r '.name')
    url=$(echo "${entry}" | jq -r '.url')
    filename=$(echo "${entry}" | jq -r '.filename')

    if _pkg_is_appimage_installed "${filename}"; then
      continue
    fi

    if [[ "${dry_run}" == true ]]; then
      echo "  Would install: ${name}"
    else
      if _pkg_install_appimage "${name}" "${url}" "${filename}"; then
        prefix_success "Installed ${name}"
        ((installed++))
      else
        prefix_error "Failed to install ${name}"
        ((failed++))
      fi
    fi
  done <<<"${entries}"

  if [[ ${installed} -eq 0 ]] && [[ ${failed} -eq 0 ]] && [[ "${dry_run}" != true ]]; then
    prefix_info "All AppImages up to date"
  fi

  echo ""
}

# =============================================================================
# COPR Repository Management (Linux/DNF)
# =============================================================================

# Enable COPR repositories from config
# Usage: _pkg_enable_copr_repos [dry_run]
_pkg_enable_copr_repos() {
  local dry_run="${1:-false}"
  local copr_config="${PKG_CONFIGS_DIR}/linux/copr.json"

  [[ ! -f "${copr_config}" ]] && return 0

  local repos
  repos=$(_pkg_load "${copr_config}")
  [[ -z "${repos}" ]] && return 0

  echo "${CYN}copr:${RST}"

  while IFS= read -r repo; do
    [[ -z "${repo}" ]] && continue

    # Check if COPR repo is already enabled
    local repo_id
    repo_id=$(echo "${repo}" | sed 's|/|:|g')

    if dnf repolist 2>/dev/null | grep -qi "copr.*${repo_id}"; then
      prefix_info "${repo} already enabled"
    else
      if [[ "${dry_run}" == true ]]; then
        echo "  Would enable: ${repo}"
      else
        if sudo dnf copr enable -y "${repo}" 2>/dev/null; then
          prefix_success "Enabled ${repo}"
        else
          prefix_error "Failed to enable ${repo}"
        fi
      fi
    fi
  done <<<"${repos}"

  echo ""
}

# Enable external repositories that require GPG keys
# Usage: _pkg_enable_external_repos [dry_run]
_pkg_enable_external_repos() {
  local dry_run="${1:-false}"

  command -v dnf &>/dev/null || return 0

  # VS Code - https://code.visualstudio.com/docs/setup/linux
  if ! dnf repolist 2>/dev/null | grep -q "^code "; then
    if [[ "${dry_run}" == true ]]; then
      echo "  Would add: VS Code repository"
    else
      # Import Microsoft GPG key
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true

      # Create repo file
      sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
      prefix_success "Added VS Code repository"
    fi
  fi
}

# =============================================================================
# Sync Command
# =============================================================================

# =============================================================================
# Linuxbrew Environment Preparation
# =============================================================================

# Track if we need to re-link bash-completion after sync
_PKG_RELINK_BASH_COMPLETION=false

# Prepare Linuxbrew environment for package installation
# Handles known conflicts and issues specific to Linux ARM64
_pkg_prepare_linuxbrew() {
  local dry_run="${1:-false}"
  [[ "$(uname -s)" != "Linux" ]] && return 0
  command -v brew &>/dev/null || return 0

  # Ensure Caskroom directory exists (prevents errors from formulae that check for conflicting casks)
  mkdir -p /home/linuxbrew/.linuxbrew/Caskroom 2>/dev/null || true

  # Check if bash-completion is linked - it conflicts with util-linux
  # which is a dependency of many packages (mpv, ffmpeg-full, etc.)
  if brew list bash-completion &>/dev/null 2>&1; then
    if [[ -L "/home/linuxbrew/.linuxbrew/etc/bash_completion" ]] ||
      [[ -L "/home/linuxbrew/.linuxbrew/share/bash-completion" ]]; then
      if [[ "${dry_run}" != true ]]; then
        info "Temporarily unlinking bash-completion to avoid conflicts..."
        brew unlink bash-completion &>/dev/null || true
      fi
      _PKG_RELINK_BASH_COMPLETION=true
    fi
  fi
}

# Restore Linuxbrew environment after package installation
_pkg_restore_linuxbrew() {
  local dry_run="${1:-false}"
  [[ "$(uname -s)" != "Linux" ]] && return 0

  # Re-link bash-completion if we unlinked it
  # Use --overwrite to handle conflicts with util-linux completions
  if [[ "${_PKG_RELINK_BASH_COMPLETION}" == true ]]; then
    if [[ "${dry_run}" != true ]]; then
      info "Re-linking bash-completion..."
      brew link --overwrite bash-completion &>/dev/null || true
    fi
    _PKG_RELINK_BASH_COMPLETION=false
  fi
}

# =============================================================================
# Sync Functions
# =============================================================================

# Sync Homebrew/Linuxbrew formulae from platform-specific config
_pkg_sync_formulae() {
  local dry_run="${1:-false}"
  local os_type
  os_type=$(uname -s)
  os_type=${os_type,,}
  [[ "${os_type}" == "darwin" ]] && os_type="macos" || os_type="linux"
  local config_file="${PKG_CONFIGS_DIR}/${os_type}/formulae.json"

  [[ ! -f "${config_file}" ]] && return 0

  echo "${CYN}brew:${RST}"

  installed=0
  failed=0

  local packages
  packages=$(_pkg_load "${config_file}")

  while IFS= read -r package; do
    [[ -z "${package}" ]] && continue

    if _pkg_is_installed "brew" "${package}"; then
      continue
    fi

    if [[ "${dry_run}" == true ]]; then
      echo "  Would install: ${package}"
    else
      if _pkg_install "brew" "${package}"; then
        prefix_success "Installed ${package}"
        ((installed++))
      else
        prefix_error "Failed to install ${package}"
        ((failed++))
      fi
    fi
  done <<<"${packages}"

  if [[ ${installed} -eq 0 ]] && [[ ${failed} -eq 0 ]] && [[ "${dry_run}" != true ]]; then
    prefix_info "All packages up to date"
  fi

  echo ""
}

_pkg_sync() {
  local dry_run="${1:-false}"
  local pm
  pm=$(_pkg_detect_system_pm)
  local os_type
  os_type=$(uname -s)

  echo ""
  echo "${BOLD}Package Sync${RST}"
  echo ""

  # Prepare Linuxbrew environment on Linux (handle bash-completion conflict, etc.)
  if [[ "${os_type}" == "Linux" ]] && [[ "${pm}" == "brew" ]]; then
    _pkg_prepare_linuxbrew "${dry_run}"
  fi

  local total_installed=0
  local total_failed=0

  # Homebrew/Linuxbrew formulae (platform-specific configs)
  local formulae_config
  if [[ "${os_type}" == "Darwin" ]]; then
    formulae_config="${PKG_CONFIGS_DIR}/macos/formulae.json"
  else
    formulae_config="${PKG_CONFIGS_DIR}/linux/formulae.json"
  fi
  if [[ "${pm}" == "brew" ]] && [[ -f "${formulae_config}" ]]; then
    _pkg_sync_formulae "${dry_run}"
    total_installed=$((total_installed + installed))
    total_failed=$((total_failed + failed))
  fi

  # Casks (macOS and Linux - fonts, etc.)
  local casks_config
  if [[ "${os_type}" == "Darwin" ]]; then
    casks_config="${PKG_CONFIGS_DIR}/macos/casks.json"
  else
    casks_config="${PKG_CONFIGS_DIR}/linux/casks.json"
  fi
  if [[ -f "${casks_config}" ]]; then
    _pkg_sync_category "cask" "${dry_run}"
    total_installed=$((total_installed + installed))
    total_failed=$((total_failed + failed))
  fi

  # Linux-specific: DNF for system packages (if brew not available or for system-only packages)
  if [[ "${os_type}" == "Linux" ]]; then
    # Enable COPR repos if using dnf
    if command -v dnf &>/dev/null && [[ -f "${PKG_CONFIGS_DIR}/linux/copr.json" ]]; then
      _pkg_enable_copr_repos "${dry_run}"
    fi

    # Enable external repos (VS Code, etc.) before DNF install
    if command -v dnf &>/dev/null; then
      _pkg_enable_external_repos "${dry_run}"
    fi

    # DNF packages (system-specific, when brew unavailable or for desktop integration)
    if [[ -f "${PKG_CONFIGS_DIR}/linux/dnf.json" ]] && command -v dnf &>/dev/null; then
      _pkg_sync_category "dnf" "${dry_run}"
      total_installed=$((total_installed + installed))
      total_failed=$((total_failed + failed))
    fi

    # Flatpak apps
    if [[ -f "${PKG_CONFIGS_DIR}/linux/flatpak.json" ]] && command -v flatpak &>/dev/null; then
      _pkg_sync_category "flatpak" "${dry_run}"
      total_installed=$((total_installed + installed))
      total_failed=$((total_failed + failed))
    fi

    # AppImages
    if [[ -f "${PKG_CONFIGS_DIR}/linux/appimage.json" ]]; then
      _pkg_sync_appimages "${dry_run}"
      total_installed=$((total_installed + installed))
      total_failed=$((total_failed + failed))
    fi
  fi

  # Sync npm packages
  if [[ -f "${PKG_CONFIGS_DIR}/npm.json" ]] && command -v npm >/dev/null 2>&1; then
    _pkg_sync_category "npm" "${dry_run}"
    total_installed=$((total_installed + installed))
    total_failed=$((total_failed + failed))
  fi

  # Sync pip packages
  if [[ -f "${PKG_CONFIGS_DIR}/pip.json" ]]; then
    _pkg_sync_category "pip" "${dry_run}"
    total_installed=$((total_installed + installed))
    total_failed=$((total_failed + failed))
  fi

  # Sync cargo packages
  if [[ -f "${PKG_CONFIGS_DIR}/cargo.json" ]] && command -v cargo >/dev/null 2>&1; then
    _pkg_sync_category "cargo" "${dry_run}"
    total_installed=$((total_installed + installed))
    total_failed=$((total_failed + failed))
  fi

  # Sync go packages
  if [[ -f "${PKG_CONFIGS_DIR}/go.json" ]] && command -v go >/dev/null 2>&1; then
    _pkg_sync_category "go" "${dry_run}"
    total_installed=$((total_installed + installed))
    total_failed=$((total_failed + failed))
  fi

  # Start services
  if [[ "${dry_run}" != true ]]; then
    echo ""
    info "Starting managed services..."
    _pkg_services_start_all
  fi

  # Restore Linuxbrew environment on Linux (re-link bash-completion, etc.)
  if [[ "${os_type}" == "Linux" ]] && [[ "${pm}" == "brew" ]]; then
    _pkg_restore_linuxbrew "${dry_run}"
  fi

  # Summary
  echo ""
  if [[ "${dry_run}" == true ]]; then
    info "Dry run complete"
  elif [[ ${total_failed} -eq 0 ]]; then
    success "Sync complete: ${total_installed} package(s) installed"
  else
    warn "Sync complete with ${total_failed} failure(s)"
  fi
}

# Sync a single category
_pkg_sync_category() {
  local pm_type="$1"
  local dry_run="${2:-false}"

  local config_file
  config_file=$(_pkg_config_file "${pm_type}")

  if [[ ! -f "${config_file}" ]]; then
    return 0
  fi

  echo "${CYN}${pm_type}:${RST}"

  installed=0
  failed=0

  local packages
  packages=$(_pkg_load "${config_file}")

  while IFS= read -r package; do
    [[ -z "${package}" ]] && continue

    if _pkg_is_installed "${pm_type}" "${package}"; then
      continue
    fi

    if [[ "${dry_run}" == true ]]; then
      echo "  Would install: ${package}"
    else
      if _pkg_install "${pm_type}" "${package}"; then
        prefix_success "Installed ${package}"
        ((installed++))
      else
        prefix_error "Failed to install ${package}"
        ((failed++))
      fi
    fi
  done <<<"${packages}"

  if [[ ${installed} -eq 0 ]] && [[ ${failed} -eq 0 ]] && [[ "${dry_run}" != true ]]; then
    prefix_info "All packages up to date"
  fi

  echo ""
}

# =============================================================================
# Main Command
# =============================================================================

# @jsh-cmd pkg Manage packages (add, remove, list, sync, commit, status, diff, export, audit, service)
# @jsh-sub add Add package to config
# @jsh-sub remove Remove package from config
# @jsh-sub list List packages
# @jsh-sub sync Install packages from config
# @jsh-sub commit Commit config changes
# @jsh-sub status Show uncommitted changes
# @jsh-sub diff Compare config vs installed
# @jsh-sub export Export installed to config
# @jsh-sub audit Health checks
# @jsh-sub service Manage services
cmd_pkg() {
  local subcmd="${1:-help}"
  shift 2>/dev/null || true

  case "${subcmd}" in
  add | a)
    _pkg_cmd_add "$@"
    ;;
  remove | rm | r)
    _pkg_cmd_remove "$@"
    ;;
  list | ls | l)
    _pkg_cmd_list "$@"
    ;;
  sync | s)
    _pkg_cmd_sync "$@"
    ;;
  commit | c)
    _pkg_git_commit "$@"
    ;;
  status | st)
    _pkg_git_status
    ;;
  diff | d)
    _pkg_diff "$@"
    ;;
  export | e)
    _pkg_cmd_export "$@"
    ;;
  audit)
    _pkg_audit "$@"
    ;;
  service | svc)
    _pkg_cmd_service "$@"
    ;;
  help | -h | --help)
    _pkg_help
    ;;
  *)
    error "Unknown subcommand: ${subcmd}"
    echo ""
    _pkg_help
    return 1
    ;;
  esac
}

# =============================================================================
# CLI Subcommand Handlers
# =============================================================================

_pkg_cmd_add() {
  local package=""
  local pm_type=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --brew)
      pm_type="brew"
      shift
      ;;
    --cask)
      pm_type="cask"
      shift
      ;;
    --npm)
      pm_type="npm"
      shift
      ;;
    --pip)
      pm_type="pip"
      shift
      ;;
    --cargo)
      pm_type="cargo"
      shift
      ;;
    --go)
      pm_type="go"
      shift
      ;;
    --apt)
      pm_type="apt"
      shift
      ;;
    --dnf)
      pm_type="dnf"
      shift
      ;;
    --pacman)
      pm_type="pacman"
      shift
      ;;
    --flatpak)
      pm_type="flatpak"
      shift
      ;;
    -*)
      warn "Unknown option: $1"
      shift
      ;;
    *)
      package="$1"
      shift
      ;;
    esac
  done

  if [[ -z "${package}" ]]; then
    error "Usage: jsh pkg add <package> [--brew|--cask|--npm|--pip|--cargo|--go|--apt|--dnf|--flatpak]"
    return 1
  fi

  # Auto-detect package manager if not specified
  if [[ -z "${pm_type}" ]]; then
    pm_type=$(_pkg_detect_manager "${package}")
  fi

  echo ""
  info "Adding ${package} to ${pm_type} config..."

  _pkg_add_to_config "${pm_type}" "${package}"

  echo ""
  info "Run '${CYN}jsh pkg commit${RST}' to save changes to git."
}

_pkg_cmd_remove() {
  local package=""
  local pm_type=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --brew)
      pm_type="brew"
      shift
      ;;
    --cask)
      pm_type="cask"
      shift
      ;;
    --npm)
      pm_type="npm"
      shift
      ;;
    --pip)
      pm_type="pip"
      shift
      ;;
    --cargo)
      pm_type="cargo"
      shift
      ;;
    --go)
      pm_type="go"
      shift
      ;;
    --apt)
      pm_type="apt"
      shift
      ;;
    --dnf)
      pm_type="dnf"
      shift
      ;;
    --flatpak)
      pm_type="flatpak"
      shift
      ;;
    -*)
      warn "Unknown option: $1"
      shift
      ;;
    *)
      package="$1"
      shift
      ;;
    esac
  done

  if [[ -z "${package}" ]]; then
    error "Usage: jsh pkg remove <package> [--brew|--cask|--npm|--pip|--cargo|--go|--flatpak]"
    return 1
  fi

  # Auto-detect package manager if not specified
  if [[ -z "${pm_type}" ]]; then
    pm_type=$(_pkg_detect_manager "${package}")
  fi

  _pkg_remove_from_config "${pm_type}" "${package}"
}

_pkg_cmd_list() {
  local category=""
  local filter="all"
  local platform=""
  local verbose=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --installed)
      filter="installed"
      shift
      ;;
    --missing)
      filter="missing"
      shift
      ;;
    --all)
      filter="all"
      shift
      ;;
    --macos)
      platform="macos"
      shift
      ;;
    --linux)
      platform="linux"
      shift
      ;;
    --common)
      platform="common"
      shift
      ;;
    --all-platforms)
      platform="all"
      shift
      ;;
    --verbose | -v)
      verbose=true
      shift
      ;;
    -*)
      warn "Unknown option: $1"
      shift
      ;;
    *)
      category="$1"
      shift
      ;;
    esac
  done

  _pkg_list "${category}" "${filter}" "${platform}" "${verbose}"
}

_pkg_cmd_sync() {
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dry-run | -n)
      dry_run=true
      shift
      ;;
    *) shift ;;
    esac
  done

  _pkg_sync "${dry_run}"
}

_pkg_cmd_export() {
  local pm_type=""
  local overwrite=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --overwrite)
      overwrite=true
      shift
      ;;
    -*)
      warn "Unknown option: $1"
      shift
      ;;
    *)
      pm_type="$1"
      shift
      ;;
    esac
  done

  _pkg_export "${pm_type}" "${overwrite}"
}

_pkg_cmd_service() {
  local action="${1:-list}"
  local service="${2:-}"

  case "${action}" in
  list | ls | l)
    _pkg_service_list
    ;;
  add | a)
    [[ -z "${service}" ]] && {
      error "Usage: jsh pkg service add <name>"
      return 1
    }
    _pkg_service_add "${service}"
    ;;
  remove | rm | r)
    [[ -z "${service}" ]] && {
      error "Usage: jsh pkg service remove <name>"
      return 1
    }
    _pkg_service_remove "${service}"
    ;;
  start)
    if [[ -z "${service}" ]]; then
      _pkg_services_start_all
    else
      _pkg_service_start "${service}"
    fi
    ;;
  stop)
    [[ -z "${service}" ]] && {
      error "Usage: jsh pkg service stop <name>"
      return 1
    }
    _pkg_service_stop "${service}"
    ;;
  restart)
    [[ -z "${service}" ]] && {
      error "Usage: jsh pkg service restart <name>"
      return 1
    }
    _pkg_service_restart "${service}"
    ;;
  *)
    echo "${BOLD}jsh pkg service${RST} - Service management"
    echo ""
    echo "${BOLD}USAGE:${RST}"
    echo "    jsh pkg service <command> [name]"
    echo ""
    echo "${BOLD}COMMANDS:${RST}"
    echo "    ${CYN}list${RST}            List managed services"
    echo "    ${CYN}add${RST} <name>      Add service to config"
    echo "    ${CYN}remove${RST} <name>   Remove service from config"
    echo "    ${CYN}start${RST} [name]    Start service(s)"
    echo "    ${CYN}stop${RST} <name>     Stop a service"
    echo "    ${CYN}restart${RST} <name>  Restart a service"
    ;;
  esac
}

_pkg_help() {
  cat <<HELP
${BOLD}jsh pkg${RST} - Package management

${BOLD}USAGE:${RST}
    jsh pkg <command> [options]

${BOLD}CORE COMMANDS:${RST}
    ${CYN}add${RST} <pkg> [--brew|--cask|--npm|--pip|--cargo|--go]  Add package to config
    ${CYN}remove${RST} <pkg>                                   Remove package from config
    ${CYN}list${RST} [category] [options]                      List packages
        ${DIM}-v, --verbose${RST}   Show all packages with status
        ${DIM}--installed${RST}     Show only installed packages
        ${DIM}--missing${RST}       Show only missing packages
        ${DIM}--macos${RST}         Show macOS packages only
        ${DIM}--linux${RST}         Show Linux packages only
        ${DIM}--common${RST}        Show common packages only (npm, pip, cargo)
        ${DIM}--all-platforms${RST} Show all platforms
    ${CYN}sync${RST} [--dry-run]                               Install packages from config

${BOLD}GIT COMMANDS:${RST}
    ${CYN}commit${RST} [message]     Commit config changes
    ${CYN}status${RST}               Show uncommitted changes

${BOLD}UTILITY:${RST}
    ${CYN}diff${RST}                 Compare config vs installed
    ${CYN}export${RST} [--overwrite] Export installed to config
    ${CYN}audit${RST}                Health checks

${BOLD}SERVICES:${RST}
    ${CYN}service list${RST}             List managed services
    ${CYN}service add${RST} <name>       Add service to start on sync
    ${CYN}service remove${RST} <name>    Remove service from config
    ${CYN}service start${RST} [name]     Start service(s)
    ${CYN}service stop${RST} <name>      Stop a service
    ${CYN}service restart${RST} <name>   Restart a service

${BOLD}EXAMPLES:${RST}
    jsh pkg add bat                 # Add to system package manager
    jsh pkg add typescript --npm    # Add to npm config
    jsh pkg sync --dry-run          # Preview what would be installed
    jsh pkg commit "Add dev tools"

${BOLD}CONFIG FILES:${RST}
    ${DIM}${PKG_CONFIGS_DIR}/${RST}
HELP
}
