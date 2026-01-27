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
# Prefers Homebrew/Linuxbrew on both macOS and Linux for consistency
_install_detect_pm() {
    # Prefer brew on both platforms for CLI tools
    command -v brew >/dev/null 2>&1 && echo "brew" && return

    # Fallback to system package manager
    if [[ "$(uname -s)" == "Linux" ]]; then
        command -v dnf >/dev/null 2>&1 && echo "dnf" && return
        command -v apt >/dev/null 2>&1 && echo "apt" && return
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
            # npm scoped package or package@version - these are npm-only
            echo "npm"
            ;;
        *)
            # Auto-detect: prioritize brew, then npm, then pip
            if command -v brew >/dev/null 2>&1 && brew info "${package}" >/dev/null 2>&1; then
                echo "system"  # Use system PM (brew) for brew packages
            elif npm view "${package}" >/dev/null 2>&1; then
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

_install_cask() {
    local package="$1"

    if ! command -v brew >/dev/null 2>&1; then
        error "Homebrew is not installed"
        return 1
    fi

    info "Installing ${package} via Homebrew Cask..."
    brew install --cask "${package}"
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
# Linuxbrew Bootstrap
# =============================================================================

# Check if Linuxbrew is installed
_install_linuxbrew_installed() {
    [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]
}

# Install Linuxbrew (with user confirmation)
_install_linuxbrew() {
    echo ""
    echo "${BOLD}Linuxbrew Setup${RST}"
    echo ""
    echo "Linuxbrew provides the same packages as Homebrew on macOS,"
    echo "ensuring a consistent experience across both platforms."
    echo ""
    echo "This will install Linuxbrew to /home/linuxbrew/.linuxbrew"
    echo ""

    read -r -p "Install Linuxbrew? [Y/n] " confirm
    if [[ "${confirm}" =~ ^[Nn] ]]; then
        warn "Skipping Linuxbrew installation"
        echo "You can install it later with:"
        echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        return 1
    fi

    echo ""
    info "Installing Linuxbrew..."
    echo ""

    # Run the official Homebrew installer
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        echo ""
        prefix_success "Linuxbrew installed"

        # Add to current shell session
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

        # Create Caskroom directory (prevents errors from formulae that check for conflicting casks)
        mkdir -p /home/linuxbrew/.linuxbrew/Caskroom 2>/dev/null || true

        # Install essential build dependencies
        info "Installing build dependencies..."
        brew install gcc 2>/dev/null || true

        return 0
    else
        echo ""
        prefix_error "Linuxbrew installation failed"
        return 1
    fi
}

# Ensure Linuxbrew is available on Linux
_install_ensure_linuxbrew() {
    [[ "$(uname -s)" != "Linux" ]] && return 0

    if _install_linuxbrew_installed; then
        # Ensure brew is in current session
        if ! command -v brew &>/dev/null; then
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        fi
        # Ensure Caskroom directory exists (prevents errors from formulae that check for conflicting casks)
        mkdir -p /home/linuxbrew/.linuxbrew/Caskroom 2>/dev/null || true
        return 0
    fi

    _install_linuxbrew
}

# Prepare Linuxbrew environment for package installation
# Handles known conflicts and issues specific to Linux ARM64
_install_prepare_linuxbrew() {
    [[ "$(uname -s)" != "Linux" ]] && return 0
    command -v brew &>/dev/null || return 0

    # Ensure Caskroom directory exists (prevents errors from formulae that check for conflicting casks)
    mkdir -p /home/linuxbrew/.linuxbrew/Caskroom 2>/dev/null || true

    # Check if bash-completion is linked - it conflicts with util-linux
    # which is a dependency of many packages (mpv, etc.)
    if brew list bash-completion &>/dev/null; then
        if [[ -L "/home/linuxbrew/.linuxbrew/etc/bash_completion" ]]; then
            info "Temporarily unlinking bash-completion to avoid conflicts..."
            brew unlink bash-completion &>/dev/null || true
            _INSTALL_RELINK_BASH_COMPLETION=true
        fi
    fi
}

# Restore Linuxbrew environment after package installation
_install_restore_linuxbrew() {
    [[ "$(uname -s)" != "Linux" ]] && return 0

    # Re-link bash-completion if we unlinked it
    # Use --overwrite to handle conflicts with util-linux completions
    if [[ "${_INSTALL_RELINK_BASH_COMPLETION:-false}" == true ]]; then
        info "Re-linking bash-completion..."
        brew link --overwrite bash-completion &>/dev/null || true
        _INSTALL_RELINK_BASH_COMPLETION=false
    fi
}

# =============================================================================
# Config File Installation
# =============================================================================

# Load packages from JSON config file
# Returns packages one per line
_install_load_packages() {
    local config_file="$1"

    [[ ! -f "${config_file}" ]] && return 1

    if command -v jq >/dev/null 2>&1; then
        jq -r 'if type == "array" then .[] else .packages[]? // empty end' "${config_file}" 2>/dev/null
    else
        grep -oE '"[^"]+"' "${config_file}" | tr -d '"'
    fi
}

# Check if package is installed
_install_is_installed() {
    local pm_type="$1"
    local package="$2"

    case "${pm_type}" in
        brew)
            brew list "${package}" &>/dev/null
            ;;
        cask)
            brew list --cask "${package}" &>/dev/null
            ;;
        dnf)
            rpm -q "${package}" &>/dev/null
            ;;
        apt)
            dpkg -l "${package}" 2>/dev/null | grep -q "^ii"
            ;;
        npm)
            npm list -g "${package}" &>/dev/null
            ;;
        pip)
            pip3 show "${package}" &>/dev/null 2>&1 || pip show "${package}" &>/dev/null 2>&1
            ;;
        cargo)
            cargo install --list 2>/dev/null | grep -q "^${package} "
            ;;
        flatpak)
            flatpak list --app --columns=application 2>/dev/null | grep -qx "${package}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Collect missing packages from a config
# Args: pm_type config_file
# Appends to MISSING_PACKAGES array
_install_collect_missing() {
    local pm_type="$1"
    local config_file="$2"
    local label="$3"

    [[ ! -f "${config_file}" ]] && return

    local packages
    packages=$(_install_load_packages "${config_file}")
    [[ -z "${packages}" ]] && return

    local missing_in_category=()
    while IFS= read -r pkg; do
        [[ -z "${pkg}" ]] && continue
        if ! _install_is_installed "${pm_type}" "${pkg}"; then
            missing_in_category+=("${pkg}")
            MISSING_PACKAGES+=("${pm_type}|${pkg}")
        fi
    done <<< "${packages}"

    if [[ ${#missing_in_category[@]} -gt 0 ]]; then
        PACKAGE_SUMMARY+=("${label}: ${#missing_in_category[@]} package(s)")
    fi
}

# Install all packages from configs directory
_install_all_from_configs() {
    local os_type
    os_type=$(uname -s); os_type=${os_type,,}
    [[ "${os_type}" == "darwin" ]] && os_type="macos"

    # On Linux, ensure Linuxbrew is installed first
    if [[ "${os_type}" == "linux" ]]; then
        _install_ensure_linuxbrew
        _install_prepare_linuxbrew

        # Enable external repos before scanning (requires sudo, must be before spinner)
        if command -v dnf &>/dev/null; then
            _pkg_enable_external_repos false
        fi
    fi

    local platform_dir="${JSH_CONFIGS_DIR}/packages/${os_type}"
    [[ "${os_type}" == "linux" ]] && platform_dir="${JSH_CONFIGS_DIR}/packages/linux"

    # Arrays to collect what needs to be installed
    local -a MISSING_PACKAGES=()
    local -a PACKAGE_SUMMARY=()

    echo ""
    spinner_start "Scanning package configs..."

    # Collect missing packages by category
    # Use Homebrew/Linuxbrew for formulae on both macOS and Linux
    if command -v brew &>/dev/null; then
        # Platform-specific formulae config
        _install_collect_missing "brew" "${platform_dir}/formulae.json" "Homebrew formulae"

        # Casks (macOS for apps, Linux for fonts)
        if [[ -f "${platform_dir}/casks.json" ]]; then
            _install_collect_missing "cask" "${platform_dir}/casks.json" "Homebrew casks"
        fi
    fi

    if [[ "${os_type}" == "linux" ]]; then
        # System packages that require dnf (non-brew packages)
        if command -v dnf &>/dev/null && [[ -f "${platform_dir}/dnf.json" ]]; then
            _install_collect_missing "dnf" "${platform_dir}/dnf.json" "DNF packages"
        fi
        if command -v apt &>/dev/null && [[ -f "${platform_dir}/apt.json" ]]; then
            _install_collect_missing "apt" "${platform_dir}/apt.json" "APT packages"
        fi
        if command -v flatpak &>/dev/null && [[ -f "${platform_dir}/flatpak.json" ]]; then
            _install_collect_missing "flatpak" "${platform_dir}/flatpak.json" "Flatpak apps"
        fi
    fi

    # Cross-platform package managers
    if command -v npm &>/dev/null && [[ -f "${JSH_CONFIGS_DIR}/packages/npm.json" ]]; then
        _install_collect_missing "npm" "${JSH_CONFIGS_DIR}/packages/npm.json" "npm packages"
    fi
    if [[ -f "${JSH_CONFIGS_DIR}/packages/pip.json" ]]; then
        _install_collect_missing "pip" "${JSH_CONFIGS_DIR}/packages/pip.json" "pip packages"
    fi
    if command -v cargo &>/dev/null && [[ -f "${JSH_CONFIGS_DIR}/packages/cargo.json" ]]; then
        _install_collect_missing "cargo" "${JSH_CONFIGS_DIR}/packages/cargo.json" "cargo packages"
    fi

    spinner_stop

    # Show summary
    if [[ ${#MISSING_PACKAGES[@]} -eq 0 ]]; then
        echo "${GRN}✓${RST} All packages are already installed"
        echo ""
        return 0
    fi

    echo "${BOLD}Packages to install:${RST}"
    echo ""

    # Group packages by category for compact display
    local current_cat=""
    local pkg_list=""
    local pkg_count=0

    for entry in "${MISSING_PACKAGES[@]}"; do
        local pm_type="${entry%%|*}"
        local package="${entry#*|}"

        if [[ "${pm_type}" != "${current_cat}" ]]; then
            # Print previous category if exists
            if [[ -n "${current_cat}" ]] && [[ -n "${pkg_list}" ]]; then
                local cat_label
                case "${current_cat}" in
                    brew)    cat_label="Homebrew" ;;
                    cask)    cat_label="Casks" ;;
                    dnf)     cat_label="DNF" ;;
                    apt)     cat_label="APT" ;;
                    flatpak) cat_label="Flatpak" ;;
                    npm)     cat_label="npm" ;;
                    pip)     cat_label="pip" ;;
                    cargo)   cat_label="cargo" ;;
                    *)       cat_label="${current_cat}" ;;
                esac
                echo "  ${CYN}${cat_label}${RST} (${pkg_count}): ${DIM}${pkg_list% }${RST}"
            fi
            current_cat="${pm_type}"
            pkg_list=""
            pkg_count=0
        fi

        pkg_list+="${package} "
        ((pkg_count++)) || true
    done

    # Print last category
    if [[ -n "${current_cat}" ]] && [[ -n "${pkg_list}" ]]; then
        local cat_label
        case "${current_cat}" in
            brew)    cat_label="Homebrew" ;;
            cask)    cat_label="Casks" ;;
            dnf)     cat_label="DNF" ;;
            apt)     cat_label="APT" ;;
            flatpak) cat_label="Flatpak" ;;
            npm)     cat_label="npm" ;;
            pip)     cat_label="pip" ;;
            cargo)   cat_label="cargo" ;;
            *)       cat_label="${current_cat}" ;;
        esac
        echo "  ${CYN}${cat_label}${RST} (${pkg_count}): ${DIM}${pkg_list% }${RST}"
    fi

    echo ""
    echo "  ${BOLD}Total: ${#MISSING_PACKAGES[@]} package(s)${RST}"
    echo ""

    # Confirmation prompt
    read -r -p "Proceed with installation? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy] ]]; then
        info "Installation cancelled"
        return 0
    fi

    echo ""

    # Install packages
    local installed=0
    local failed=0
    local current_pm=""
    local -a FAILED_PACKAGES=()

    for entry in "${MISSING_PACKAGES[@]}"; do
        local pm_type="${entry%%|*}"
        local package="${entry#*|}"

        # Print category header with package list when category changes
        if [[ "${pm_type}" != "${current_pm}" ]]; then
            [[ -n "${current_pm}" ]] && echo ""

            # Collect all packages for this category
            local cat_packages=()
            for e in "${MISSING_PACKAGES[@]}"; do
                [[ "${e%%|*}" == "${pm_type}" ]] && cat_packages+=("${e#*|}")
            done

            case "${pm_type}" in
                brew)    echo "${CYN}Homebrew formulae:${RST} ${cat_packages[*]}" ;;
                cask)    echo "${CYN}Homebrew casks:${RST} ${cat_packages[*]}" ;;
                dnf)     echo "${CYN}DNF packages:${RST} ${cat_packages[*]}" ;;
                apt)     echo "${CYN}APT packages:${RST} ${cat_packages[*]}" ;;
                flatpak) echo "${CYN}Flatpak apps:${RST} ${cat_packages[*]}" ;;
                npm)     echo "${CYN}npm packages:${RST} ${cat_packages[*]}" ;;
                pip)     echo "${CYN}pip packages:${RST} ${cat_packages[*]}" ;;
                cargo)   echo "${CYN}cargo packages:${RST} ${cat_packages[*]}" ;;
            esac
            current_pm="${pm_type}"
        fi

        # Install the package
        local install_ok=false
        case "${pm_type}" in
            brew)
                if brew install "${package}" 2>/dev/null; then
                    install_ok=true
                fi
                ;;
            cask)
                if brew install --cask "${package}" 2>/dev/null; then
                    install_ok=true
                fi
                ;;
            dnf)
                if sudo dnf install -y "${package}"; then
                    install_ok=true
                fi
                ;;
            apt)
                if sudo apt install -y "${package}"; then
                    install_ok=true
                fi
                ;;
            flatpak)
                if flatpak install -y flathub "${package}"; then
                    install_ok=true
                fi
                ;;
            npm)
                if npm install -g "${package}"; then
                    install_ok=true
                fi
                ;;
            pip)
                if pip3 install --user "${package}" 2>/dev/null || pip install --user "${package}" 2>/dev/null; then
                    install_ok=true
                fi
                ;;
            cargo)
                if cargo install "${package}"; then
                    install_ok=true
                fi
                ;;
        esac

        if [[ "${install_ok}" == true ]]; then
            echo "  ${GRN}✓${RST} ${package}"
            ((installed++)) || true
        else
            echo "  ${RED}✗${RST} ${package}"
            ((failed++)) || true
            FAILED_PACKAGES+=("${pm_type}|${package}")
        fi
    done

    # Restore Linuxbrew environment (re-link bash-completion, etc.)
    _install_restore_linuxbrew

    # Final summary
    echo ""
    if [[ ${failed} -eq 0 ]]; then
        success "Installed ${installed} package(s)"
    else
        warn "Installed ${installed}, failed ${failed}"

        # Display failed packages grouped by manager
        echo ""
        echo "${RED}Failed packages:${RST}"
        echo ""

        local prev_pm=""
        local pkg_list=""
        local pkg_count=0

        for entry in "${FAILED_PACKAGES[@]}"; do
            local pm_type="${entry%%|*}"
            local package="${entry#*|}"

            if [[ "${pm_type}" != "${prev_pm}" ]]; then
                # Print previous group if exists
                if [[ -n "${prev_pm}" ]]; then
                    local cat_label=""
                    case "${prev_pm}" in
                        brew)    cat_label="Homebrew" ;;
                        cask)    cat_label="Casks" ;;
                        dnf)     cat_label="DNF" ;;
                        apt)     cat_label="APT" ;;
                        flatpak) cat_label="Flatpak" ;;
                        npm)     cat_label="npm" ;;
                        pip)     cat_label="pip" ;;
                        cargo)   cat_label="cargo" ;;
                        *)       cat_label="${prev_pm}" ;;
                    esac
                    echo "  ${CYN}${cat_label}${RST} (${pkg_count}): ${DIM}${pkg_list% }${RST}"
                fi
                prev_pm="${pm_type}"
                pkg_list="${package} "
                pkg_count=1
            else
                pkg_list+="${package} "
                ((pkg_count++))
            fi
        done

        # Print last group
        if [[ -n "${prev_pm}" ]]; then
            local cat_label=""
            case "${prev_pm}" in
                brew)    cat_label="Homebrew" ;;
                cask)    cat_label="Casks" ;;
                dnf)     cat_label="DNF" ;;
                apt)     cat_label="APT" ;;
                flatpak) cat_label="Flatpak" ;;
                npm)     cat_label="npm" ;;
                pip)     cat_label="pip" ;;
                cargo)   cat_label="cargo" ;;
                *)       cat_label="${prev_pm}" ;;
            esac
            echo "  ${CYN}${cat_label}${RST} (${pkg_count}): ${DIM}${pkg_list% }${RST}"
        fi
    fi
}

# =============================================================================
# Main Command
# =============================================================================

# @jsh-cmd install Install packages (brew, npm, pip, cargo)
# @jsh-opt --brew Force installation via Homebrew formula
# @jsh-opt --cask Force installation via Homebrew Cask
# @jsh-opt --npm Force installation via npm
# @jsh-opt --pip Force installation via pip
# @jsh-opt --cargo Force installation via cargo
# @jsh-opt -y,--yes Skip confirmation prompt (auto-detect)
# @jsh-opt --track Add package to pkg config after installation
cmd_install() {
    local package=""
    local force_pm=""
    local track=false
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --brew)
                force_pm="brew"
                shift
                ;;
            --cask)
                force_pm="cask"
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
            -y|--yes)
                skip_confirm=true
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
                echo "    --brew      Force installation via Homebrew formula"
                echo "    --cask      Force installation via Homebrew Cask"
                echo "    --npm       Force installation via npm"
                echo "    --pip       Force installation via pip"
                echo "    --cargo     Force installation via cargo"
                echo "    -y, --yes   Skip confirmation prompt (auto-detect)"
                echo "    --track     Add package to pkg config after installation"
                echo ""
                echo "${BOLD}CONFIG FILES:${RST}"
                echo "    ${JSH_CONFIGS_DIR}/packages/npm.json"
                echo "    ${JSH_CONFIGS_DIR}/packages/pip.json"
                echo "    ${JSH_CONFIGS_DIR}/packages/cargo.json"
                echo "    ${JSH_CONFIGS_DIR}/packages/macos/formulae.json"
                echo "    ${JSH_CONFIGS_DIR}/packages/macos/casks.json"
                echo "    ${JSH_CONFIGS_DIR}/packages/linux/dnf.json"
                echo "    ${JSH_CONFIGS_DIR}/packages/linux/flatpak.json"
                echo ""
                echo "${BOLD}EXAMPLES:${RST}"
                echo "    jsh install               # Install all from configs"
                echo "    jsh install ripgrep       # Auto-detect (with confirmation)"
                echo "    jsh install ripgrep -y    # Auto-detect (no confirmation)"
                echo "    jsh install fd --brew     # Force Homebrew formula"
                echo "    jsh install firefox --cask  # Force Homebrew Cask"
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
    local auto_detected=false
    if [[ -z "${pm}" ]]; then
        auto_detected=true
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

    # Format manager name for display
    local pm_display="${pm}"
    case "${pm}" in
        brew)    pm_display="Homebrew" ;;
        cask)    pm_display="Homebrew Cask" ;;
        npm)     pm_display="npm" ;;
        pip)     pm_display="pip" ;;
        cargo)   pm_display="cargo" ;;
        apt)     pm_display="apt" ;;
        dnf)     pm_display="dnf" ;;
    esac

    # Confirm with user if auto-detected (unless -y flag)
    if [[ "${auto_detected}" == true ]] && [[ "${skip_confirm}" == false ]]; then
        read -r -p "Install ${BOLD}${package}${RST} via ${CYN}${pm_display}${RST}? [Y/n] " confirm
        if [[ "${confirm}" =~ ^[Nn] ]]; then
            info "Installation cancelled"
            echo ""
            echo "To install with a specific manager:"
            echo "  jsh install ${package} --brew   # Homebrew formula"
            echo "  jsh install ${package} --cask   # Homebrew Cask"
            echo "  jsh install ${package} --npm    # npm"
            echo "  jsh install ${package} --pip    # pip"
            echo "  jsh install ${package} --cargo  # cargo"
            return 0
        fi
    fi

    # Install package
    local install_result=0
    case "${pm}" in
        brew)   _install_brew "${package}" || install_result=$? ;;
        cask)   _install_cask "${package}" || install_result=$? ;;
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
