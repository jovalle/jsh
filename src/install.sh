# install.sh - Multi-package manager installer
# Provides: jsh install [package] [--brew|--npm|--pip|--cargo]
# shellcheck disable=SC2034,SC2154

# Load guard
[[ -n "${_JSH_INSTALL_LOADED:-}" ]] && return 0
_JSH_INSTALL_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

JSH_CONFIGS_DIR="${JSH_DIR:-${HOME}/.jsh}/configs"

# =============================================================================
# Package Manager Detection
# =============================================================================

# Detect best package manager for current platform
_install_detect_pm() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        command -v brew >/dev/null 2>&1 && echo "brew" && return
    elif [[ "$(uname -s)" == "Linux" ]]; then
        command -v apt >/dev/null 2>&1 && echo "apt" && return
        command -v dnf >/dev/null 2>&1 && echo "dnf" && return
        command -v pacman >/dev/null 2>&1 && echo "pacman" && return
        command -v apk >/dev/null 2>&1 && echo "apk" && return
    fi
    echo "unknown"
}

# Detect package type from name
_install_detect_type() {
    local package="$1"

    case "${package}" in
        @*/*|*@*)
            # npm scoped package or package@version
            echo "npm"
            ;;
        *-cli|create-*)
            # Common npm CLI patterns
            echo "npm"
            ;;
        *)
            # Try to auto-detect
            if npm view "${package}" >/dev/null 2>&1; then
                echo "npm"
            elif pip3 show "${package}" >/dev/null 2>&1 || pip show "${package}" >/dev/null 2>&1; then
                echo "pip"
            else
                echo "system"  # Fall back to system package manager
            fi
            ;;
    esac
}

# =============================================================================
# Install Functions
# =============================================================================

_install_brew() {
    local package="$1"

    if ! command -v brew >/dev/null 2>&1; then
        error "Homebrew is not installed"
        return 1
    fi

    info "Installing ${package} via Homebrew..."
    brew install "${package}"
}

_install_npm() {
    local package="$1"
    local global="${2:-true}"

    if ! command -v npm >/dev/null 2>&1; then
        error "npm is not installed"
        return 1
    fi

    if [[ "${global}" == true ]]; then
        info "Installing ${package} via npm (global)..."
        npm install -g "${package}"
    else
        info "Installing ${package} via npm (local)..."
        npm install "${package}"
    fi
}

_install_pip() {
    local package="$1"

    local pip_cmd="pip3"
    if ! command -v pip3 >/dev/null 2>&1; then
        pip_cmd="pip"
    fi

    if ! command -v "${pip_cmd}" >/dev/null 2>&1; then
        error "pip is not installed"
        return 1
    fi

    info "Installing ${package} via pip..."
    "${pip_cmd}" install --user "${package}"
}

_install_cargo() {
    local package="$1"

    if ! command -v cargo >/dev/null 2>&1; then
        error "cargo (Rust) is not installed"
        return 1
    fi

    info "Installing ${package} via cargo..."
    cargo install "${package}"
}

_install_apt() {
    local package="$1"

    if ! command -v apt >/dev/null 2>&1; then
        error "apt is not available"
        return 1
    fi

    info "Installing ${package} via apt..."
    sudo apt install -y "${package}"
}

_install_dnf() {
    local package="$1"

    if ! command -v dnf >/dev/null 2>&1; then
        error "dnf is not available"
        return 1
    fi

    info "Installing ${package} via dnf..."
    sudo dnf install -y "${package}"
}

# =============================================================================
# Config File Installation
# =============================================================================

# Install packages from a JSON config file
_install_from_config() {
    local config_file="$1"
    local pm_type="$2"

    if [[ ! -f "${config_file}" ]]; then
        warn "Config file not found: ${config_file}"
        return 1
    fi

    local packages
    if command -v jq >/dev/null 2>&1; then
        packages=$(jq -r '.packages[]' "${config_file}" 2>/dev/null)
    else
        # Simple fallback without jq
        packages=$(grep -oE '"[^"]+"\s*[,\]]' "${config_file}" | tr -d '",]' | tr -d ' ')
    fi

    if [[ -z "${packages}" ]]; then
        warn "No packages found in ${config_file}"
        return 1
    fi

    local count=0
    while IFS= read -r package; do
        [[ -z "${package}" ]] && continue

        case "${pm_type}" in
            brew)   _install_brew "${package}" && ((count++)) ;;
            npm)    _install_npm "${package}" && ((count++)) ;;
            pip)    _install_pip "${package}" && ((count++)) ;;
            cargo)  _install_cargo "${package}" && ((count++)) ;;
        esac
    done <<< "${packages}"

    success "Installed ${count} package(s) from ${config_file}"
}

# Install all packages from configs directory
_install_all_from_configs() {
    local os_type
    os_type=$(uname -s); os_type=${os_type,,}
    [[ "${os_type}" == "darwin" ]] && os_type="macos"

    echo ""
    echo "${BOLD}Installing packages from configs...${RST}"
    echo ""

    # Platform-specific configs
    local platform_dir="${JSH_CONFIGS_DIR}/${os_type}"

    # Homebrew (macOS)
    if [[ "${os_type}" == "macos" ]] && command -v brew >/dev/null 2>&1; then
        if [[ -f "${platform_dir}/formulae.json" ]]; then
            echo "${CYAN}Homebrew formulae:${RST}"
            _install_from_config "${platform_dir}/formulae.json" "brew"
        fi
        if [[ -f "${platform_dir}/casks.json" ]]; then
            echo "${CYAN}Homebrew casks:${RST}"
            # Casks need special handling
            local casks
            casks=$(jq -r '.packages[]' "${platform_dir}/casks.json" 2>/dev/null)
            while IFS= read -r cask; do
                [[ -z "${cask}" ]] && continue
                info "Installing cask: ${cask}"
                brew install --cask "${cask}" 2>/dev/null || warn "Failed to install cask: ${cask}"
            done <<< "${casks}"
        fi
    fi

    # npm packages
    if [[ -f "${JSH_CONFIGS_DIR}/npm.json" ]] && command -v npm >/dev/null 2>&1; then
        echo "${CYAN}npm packages:${RST}"
        _install_from_config "${JSH_CONFIGS_DIR}/npm.json" "npm"
    fi

    # pip packages
    if [[ -f "${JSH_CONFIGS_DIR}/pip.json" ]]; then
        echo "${CYAN}pip packages:${RST}"
        _install_from_config "${JSH_CONFIGS_DIR}/pip.json" "pip"
    fi

    # cargo packages
    if [[ -f "${JSH_CONFIGS_DIR}/cargo.json" ]] && command -v cargo >/dev/null 2>&1; then
        echo "${CYAN}cargo packages:${RST}"
        _install_from_config "${JSH_CONFIGS_DIR}/cargo.json" "cargo"
    fi

    echo ""
    success "Package installation complete"
}

# =============================================================================
# Main Command
# =============================================================================

# @jsh-cmd install Install packages (brew, npm, pip, cargo)
# @jsh-opt --brew Force installation via Homebrew
# @jsh-opt --npm Force installation via npm
# @jsh-opt --pip Force installation via pip
# @jsh-opt --cargo Force installation via cargo
# @jsh-opt --track Add package to pkg config after installation
cmd_install() {
    local package=""
    local force_pm=""
    local track=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --brew)
                force_pm="brew"
                shift
                ;;
            --npm)
                force_pm="npm"
                shift
                ;;
            --pip)
                force_pm="pip"
                shift
                ;;
            --cargo)
                force_pm="cargo"
                shift
                ;;
            --track|-t)
                track=true
                shift
                ;;
            -h|--help)
                echo "${BOLD}jsh install${RST} - Multi-package manager installer"
                echo ""
                echo "${BOLD}USAGE:${RST}"
                echo "    jsh install [package] [options]"
                echo "    jsh install              # Install from config files"
                echo ""
                echo "${BOLD}OPTIONS:${RST}"
                echo "    --brew      Force installation via Homebrew"
                echo "    --npm       Force installation via npm"
                echo "    --pip       Force installation via pip"
                echo "    --cargo     Force installation via cargo"
                echo "    --track     Add package to pkg config after installation"
                echo ""
                echo "${BOLD}CONFIG FILES:${RST}"
                echo "    ${JSH_CONFIGS_DIR}/npm.json"
                echo "    ${JSH_CONFIGS_DIR}/pip.json"
                echo "    ${JSH_CONFIGS_DIR}/cargo.json"
                echo "    ${JSH_CONFIGS_DIR}/macos/formulae.json"
                echo "    ${JSH_CONFIGS_DIR}/macos/casks.json"
                echo "    ${JSH_CONFIGS_DIR}/linux/apt.json"
                echo ""
                echo "${BOLD}EXAMPLES:${RST}"
                echo "    jsh install               # Install all from configs"
                echo "    jsh install ripgrep       # Auto-detect package manager"
                echo "    jsh install fd --brew     # Force Homebrew"
                echo "    jsh install eslint --npm  # Force npm"
                echo ""
                return 0
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

    # If no package specified, install from configs
    if [[ -z "${package}" ]]; then
        _install_all_from_configs
        return $?
    fi

    # Determine package manager
    local pm="${force_pm}"
    if [[ -z "${pm}" ]]; then
        # Auto-detect
        local detected_type
        detected_type=$(_install_detect_type "${package}")

        case "${detected_type}" in
            npm)    pm="npm" ;;
            pip)    pm="pip" ;;
            system)
                pm=$(_install_detect_pm)
                ;;
            *)
                pm=$(_install_detect_pm)
                ;;
        esac
    fi

    # Install package
    local install_result=0
    case "${pm}" in
        brew)   _install_brew "${package}" || install_result=$? ;;
        npm)    _install_npm "${package}" || install_result=$? ;;
        pip)    _install_pip "${package}" || install_result=$? ;;
        cargo)  _install_cargo "${package}" || install_result=$? ;;
        apt)    _install_apt "${package}" || install_result=$? ;;
        dnf)    _install_dnf "${package}" || install_result=$? ;;
        *)
            error "No suitable package manager found"
            return 1
            ;;
    esac

    # Track package in config if --track was specified and install succeeded
    if [[ "${track}" == true ]] && [[ ${install_result} -eq 0 ]]; then
        if declare -f _pkg_add_to_config >/dev/null 2>&1; then
            _pkg_add_to_config "${pm}" "${package}"
        else
            warn "Package tracking not available (pkg.sh not loaded)"
        fi
    fi

    return ${install_result}
}
