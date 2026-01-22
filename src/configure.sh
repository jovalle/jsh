# configure.sh - System and application configuration
# Provides: jsh configure [all|macos|dock|apps|linux|list]
# shellcheck disable=SC2034,SC2154

# Load guard
[[ -n "${_JSH_CONFIGURE_LOADED:-}" ]] && return 0
_JSH_CONFIGURE_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

JSH_SCRIPTS_DIR="${JSH_DIR:-${HOME}/.jsh}/scripts"

# =============================================================================
# Configuration Modules
# =============================================================================

# List of available configuration modules
declare -gA CONFIG_MODULES

CONFIG_MODULES[macos]="macOS system defaults|darwin|macos/defaults.sh"
CONFIG_MODULES[dock]="macOS Dock settings|darwin|macos/dock.sh"
CONFIG_MODULES[finder]="macOS Finder settings|darwin|macos/finder.sh"
CONFIG_MODULES[apps]="Application configs (VSCode)|all|apps/vscode.sh"
CONFIG_MODULES[linux]="GNOME settings|linux|linux/configure-settings.sh"
CONFIG_MODULES[sudoers]="Sudoers configuration|linux|linux/configure-sudoers.sh"
CONFIG_MODULES[systemd]="Systemd user services|linux|linux/configure-systemd.sh"
CONFIG_MODULES[hyprland]="Hyprland/Wayland environment|linux|linux/configure-hyprland.sh"
CONFIG_MODULES[repos]="DNF repositories (COPR)|linux|linux/configure-repos.sh"

# =============================================================================
# Helper Functions
# =============================================================================

# Check if a module is applicable to current platform
_configure_module_applicable() {
    local module="$1"
    local def="${CONFIG_MODULES[$module]:-}"

    [[ -z "${def}" ]] && return 1

    local platform
    IFS='|' read -r _ platform _ <<< "${def}"

    case "${platform}" in
        all) return 0 ;;
        darwin) [[ "$(uname -s)" == "Darwin" ]] && return 0 ;;
        linux) [[ "$(uname -s)" == "Linux" ]] && return 0 ;;
    esac

    return 1
}

# Get module description
_configure_module_desc() {
    local module="$1"
    local def="${CONFIG_MODULES[$module]:-}"

    [[ -z "${def}" ]] && return 1

    local desc
    IFS='|' read -r desc _ _ <<< "${def}"
    echo "${desc}"
}

# Get module script path
_configure_module_script() {
    local module="$1"
    local def="${CONFIG_MODULES[$module]:-}"

    [[ -z "${def}" ]] && return 1

    local script
    IFS='|' read -r _ _ script <<< "${def}"
    echo "${JSH_SCRIPTS_DIR}/${script}"
}

# =============================================================================
# macOS Configuration
# =============================================================================

_configure_macos_defaults() {
    local dry_run="${1:-false}"

    echo "${BOLD}macOS System Defaults${RST}"
    echo ""

    local changes=(
        # Finder
        "defaults write com.apple.finder AppleShowAllFiles -bool true|Show hidden files in Finder"
        "defaults write com.apple.finder ShowPathbar -bool true|Show path bar in Finder"
        "defaults write com.apple.finder ShowStatusBar -bool true|Show status bar in Finder"
        "defaults write NSGlobalDomain AppleShowAllExtensions -bool true|Show all file extensions"

        # Keyboard
        "defaults write NSGlobalDomain KeyRepeat -int 2|Fast key repeat rate"
        "defaults write NSGlobalDomain InitialKeyRepeat -int 15|Short delay before key repeat"
        "defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false|Disable press-and-hold for accents"

        # Trackpad
        "defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true|Enable tap to click"
        "defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false|Natural scrolling off"

        # Screenshots
        "defaults write com.apple.screencapture location -string '${HOME}/Desktop'|Screenshots to Desktop"
        "defaults write com.apple.screencapture type -string 'png'|Screenshot format: PNG"
        "defaults write com.apple.screencapture disable-shadow -bool true|Disable screenshot shadows"

        # Dock
        "defaults write com.apple.dock autohide -bool true|Auto-hide Dock"
        "defaults write com.apple.dock autohide-delay -float 0|No Dock reveal delay"
        "defaults write com.apple.dock show-recents -bool false|Don't show recent apps in Dock"
        "defaults write com.apple.dock mineffect -string 'scale'|Minimize with scale effect"

        # Mission Control
        "defaults write com.apple.dock mru-spaces -bool false|Don't rearrange spaces by recent use"

        # Security
        "defaults write com.apple.screensaver askForPassword -int 1|Require password after screensaver"
        "defaults write com.apple.screensaver askForPasswordDelay -int 0|Require password immediately"
    )

    for entry in "${changes[@]}"; do
        local cmd="${entry%%|*}"
        local desc="${entry#*|}"

        if [[ "${dry_run}" == true ]]; then
            printf "  ${DIM}[dry-run]${RST} %s\n" "${desc}"
        else
            printf "  Setting: %s..." "${desc}"
            if eval "${cmd}" 2>/dev/null; then
                echo " ${GRN}done${RST}"
            else
                echo " ${YLW}skipped${RST}"
            fi
        fi
    done

    if [[ "${dry_run}" != true ]]; then
        echo ""
        info "Restarting affected services..."
        killall Finder 2>/dev/null || true
        killall Dock 2>/dev/null || true
        killall SystemUIServer 2>/dev/null || true
    fi
}

_configure_dock() {
    local dry_run="${1:-false}"

    echo "${BOLD}macOS Dock Configuration${RST}"
    echo ""

    if [[ "${dry_run}" == true ]]; then
        echo "  ${DIM}[dry-run] Would configure Dock settings${RST}"
        return 0
    fi

    # Dock settings
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock autohide-delay -float 0
    defaults write com.apple.dock autohide-time-modifier -float 0.5
    defaults write com.apple.dock show-recents -bool false
    defaults write com.apple.dock tilesize -int 48
    defaults write com.apple.dock magnification -bool false
    defaults write com.apple.dock largesize -int 64
    defaults write com.apple.dock orientation -string "bottom"
    defaults write com.apple.dock minimize-to-application -bool true
    defaults write com.apple.dock mineffect -string "scale"

    # Restart Dock
    killall Dock

    prefix_success "Dock configured"
}

# =============================================================================
# Application Configuration
# =============================================================================

_configure_vscode() {
    local dry_run="${1:-false}"

    echo "${BOLD}VS Code Configuration${RST}"
    echo ""

    local vscode_settings_dir
    if [[ "$(uname -s)" == "Darwin" ]]; then
        vscode_settings_dir="${HOME}/Library/Application Support/Code/User"
    else
        vscode_settings_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User"
    fi

    if [[ "${dry_run}" == true ]]; then
        echo "  ${DIM}[dry-run] Would configure VS Code at: ${vscode_settings_dir}${RST}"
        return 0
    fi

    if [[ ! -d "${vscode_settings_dir}" ]]; then
        warn "VS Code not installed or settings directory not found"
        return 1
    fi

    # Link our VS Code settings if they exist
    local jsh_vscode_dir="${JSH_DIR:-${HOME}/.jsh}/.vscode/user"
    if [[ -d "${jsh_vscode_dir}" ]]; then
        for file in "${jsh_vscode_dir}"/*; do
            [[ -f "${file}" ]] || continue
            local filename
            filename=$(basename "${file}")
            local target="${vscode_settings_dir}/${filename}"

            if [[ -L "${target}" ]]; then
                prefix_info "${filename} already linked"
            elif [[ -f "${target}" ]]; then
                prefix_warn "${filename} exists, skipping"
            else
                ln -s "${file}" "${target}"
                prefix_success "Linked ${filename}"
            fi
        done
    else
        info "No jsh VS Code settings found at ${jsh_vscode_dir}"
    fi
}

# =============================================================================
# Linux Configuration
# =============================================================================

_configure_linux() {
    local dry_run="${1:-false}"

    echo "${BOLD}Linux System Configuration (GNOME)${RST}"
    echo ""

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-settings.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "  ${DIM}[dry-run] Would run: ${script_path}${RST}"
        return 0
    fi

    if [[ -x "${script_path}" ]]; then
        bash "${script_path}"
    else
        warn "Script not found or not executable: ${script_path}"
        return 1
    fi
}

_configure_systemd() {
    local dry_run="${1:-false}"

    echo "${BOLD}Systemd User Services${RST}"
    echo ""

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-systemd.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "  ${DIM}[dry-run] Would run: ${script_path}${RST}"
        return 0
    fi

    if [[ -x "${script_path}" ]]; then
        bash "${script_path}"
    else
        warn "Script not found or not executable: ${script_path}"
        return 1
    fi
}

_configure_hyprland() {
    local dry_run="${1:-false}"

    echo "${BOLD}Hyprland/Wayland Environment${RST}"
    echo ""

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-hyprland.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "  ${DIM}[dry-run] Would run: ${script_path}${RST}"
        return 0
    fi

    if [[ -x "${script_path}" ]]; then
        bash "${script_path}"
    else
        warn "Script not found or not executable: ${script_path}"
        return 1
    fi
}

_configure_repos() {
    local dry_run="${1:-false}"

    echo "${BOLD}DNF Repositories (COPR)${RST}"
    echo ""

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-repos.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "  ${DIM}[dry-run] Would run: ${script_path}${RST}"
        return 0
    fi

    if [[ -x "${script_path}" ]]; then
        bash "${script_path}"
    else
        warn "Script not found or not executable: ${script_path}"
        return 1
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_configure_list() {
    echo ""
    echo "${BOLD}Available Configuration Modules${RST}"
    echo ""

    local os_type
    os_type=$(uname -s)

    for module in "${!CONFIG_MODULES[@]}"; do
        local desc
        desc=$(_configure_module_desc "${module}")

        if _configure_module_applicable "${module}"; then
            printf "  ${GRN}✓${RST} %-12s %s\n" "${module}" "${desc}"
        else
            printf "  ${DIM}-${RST} %-12s %s ${DIM}(not applicable)${RST}\n" "${module}" "${desc}"
        fi
    done | sort

    echo ""
}

cmd_configure_all() {
    local dry_run="${1:-false}"
    local skip_confirm="${2:-false}"

    echo ""
    echo "${BOLD}jsh configure all${RST}"
    echo ""

    if [[ "${skip_confirm}" != true ]] && [[ "${dry_run}" != true ]]; then
        read -r -p "Run all applicable configurations? [y/N] " confirm
        if [[ ! "${confirm}" =~ ^[Yy] ]]; then
            info "Cancelled"
            return 0
        fi
        echo ""
    fi

    local os_type
    os_type=$(uname -s)

    if [[ "${os_type}" == "Darwin" ]]; then
        _configure_macos_defaults "${dry_run}"
        echo ""
        _configure_dock "${dry_run}"
    elif [[ "${os_type}" == "Linux" ]]; then
        _configure_linux "${dry_run}"
        echo ""
        _configure_systemd "${dry_run}"
    fi

    echo ""
    _configure_vscode "${dry_run}"

    echo ""
    success "Configuration complete"
}

# =============================================================================
# Main Command
# =============================================================================

# @jsh-cmd configure Configure system settings and applications
# @jsh-sub all Run all applicable configurations
# @jsh-sub macos macOS system defaults
# @jsh-sub dock macOS Dock settings
# @jsh-sub finder macOS Finder settings
# @jsh-sub apps Application configs (VS Code)
# @jsh-sub linux Linux system settings
# @jsh-sub list Show available configurations
# @jsh-opt -n,--check Dry run - show what would change
# @jsh-opt -y,--yes Skip confirmation prompts
cmd_configure() {
    local subcmd="${1:-all}"
    shift 2>/dev/null || true

    local dry_run=false
    local skip_confirm=false

    # Parse remaining arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|--dry-run|-n)
                dry_run=true
                shift
                ;;
            --yes|-y)
                skip_confirm=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    case "${subcmd}" in
        all)
            cmd_configure_all "${dry_run}" "${skip_confirm}"
            ;;
        macos)
            if [[ "$(uname -s)" != "Darwin" ]]; then
                error "macOS configuration only available on macOS"
                return 1
            fi
            _configure_macos_defaults "${dry_run}"
            ;;
        dock)
            if [[ "$(uname -s)" != "Darwin" ]]; then
                error "Dock configuration only available on macOS"
                return 1
            fi
            _configure_dock "${dry_run}"
            ;;
        apps|vscode)
            _configure_vscode "${dry_run}"
            ;;
        linux)
            if [[ "$(uname -s)" != "Linux" ]]; then
                error "Linux configuration only available on Linux"
                return 1
            fi
            _configure_linux "${dry_run}"
            ;;
        systemd)
            if [[ "$(uname -s)" != "Linux" ]]; then
                error "Systemd configuration only available on Linux"
                return 1
            fi
            _configure_systemd "${dry_run}"
            ;;
        hyprland)
            if [[ "$(uname -s)" != "Linux" ]]; then
                error "Hyprland configuration only available on Linux"
                return 1
            fi
            _configure_hyprland "${dry_run}"
            ;;
        repos)
            if [[ "$(uname -s)" != "Linux" ]]; then
                error "Repository configuration only available on Linux"
                return 1
            fi
            _configure_repos "${dry_run}"
            ;;
        sudoers)
            if [[ "$(uname -s)" != "Linux" ]]; then
                error "Sudoers configuration only available on Linux"
                return 1
            fi
            local script_path="${JSH_SCRIPTS_DIR}/linux/configure-sudoers.sh"
            if [[ "${dry_run}" == true ]]; then
                echo "  ${DIM}[dry-run] Would run: ${script_path}${RST}"
            elif [[ -x "${script_path}" ]]; then
                bash "${script_path}"
            else
                warn "Script not found: ${script_path}"
            fi
            ;;
        list|ls)
            cmd_configure_list
            ;;
        -h|--help|help)
            echo "${BOLD}jsh configure${RST} - System and application configuration"
            echo ""
            echo "${BOLD}USAGE:${RST}"
            echo "    jsh configure [command] [options]"
            echo ""
            echo "${BOLD}COMMANDS:${RST}"
            echo "    ${CYAN}all${RST}           Run all applicable configurations (default)"
            echo "    ${CYAN}macos${RST}         macOS system defaults"
            echo "    ${CYAN}dock${RST}          macOS Dock settings"
            echo "    ${CYAN}apps${RST}          Application configs (VS Code)"
            echo "    ${CYAN}linux${RST}         GNOME desktop settings"
            echo "    ${CYAN}systemd${RST}       Systemd user services"
            echo "    ${CYAN}hyprland${RST}      Hyprland/Wayland environment"
            echo "    ${CYAN}repos${RST}         DNF repositories (COPR)"
            echo "    ${CYAN}sudoers${RST}       Sudoers configuration"
            echo "    ${CYAN}list${RST}          Show available configurations"
            echo ""
            echo "${BOLD}OPTIONS:${RST}"
            echo "    --check, -n   Dry run - show what would be changed"
            echo "    --yes, -y     Skip confirmation prompts"
            echo ""
            echo "${BOLD}EXAMPLES:${RST}"
            echo "    jsh configure                # Run all (with confirmation)"
            echo "    jsh configure --check        # Preview all changes"
            echo "    jsh configure macos          # macOS defaults only"
            echo "    jsh configure dock           # Dock settings only"
            echo "    jsh configure linux          # GNOME settings (Linux)"
            echo "    jsh configure hyprland       # Hyprland/Wayland setup (Linux)"
            echo "    jsh configure systemd        # Enable user services (Linux)"
            echo "    jsh configure repos          # Enable COPR repos (Linux)"
            echo "    jsh configure list           # List available modules"
            ;;
        *)
            error "Unknown command: ${subcmd}"
            echo ""
            cmd_configure --help
            return 1
            ;;
    esac
}
