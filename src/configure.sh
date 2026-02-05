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

_configure_module_rows() {
    cat <<'ROWS'
macos|darwin|macOS system defaults
dock|darwin|macOS Dock settings
apps|all|Application configs (VSCode)
linux|linux|GNOME settings
sudoers|linux|Sudoers configuration
systemd|linux|Systemd user services
hyprland|linux|Hyprland/Wayland environment
repos|linux|DNF repositories (COPR)
ROWS
}

_configure_platform_applicable() {
    local platform="$1"
    case "${platform}" in
        all) return 0 ;;
        darwin) [[ "$(uname -s)" == "Darwin" ]] && return 0 ;;
        linux) [[ "$(uname -s)" == "Linux" ]] && return 0 ;;
    esac
    return 1
}

# =============================================================================
# macOS Configuration
# =============================================================================

_configure_macos_defaults() {
    local dry_run="${1:-false}"
    local script_path="${JSH_SCRIPTS_DIR}/macos/configure-settings.sh"

    jsh_section "macOS System Defaults"

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
        return 0
    fi

    if [[ -x "${script_path}" ]]; then
        bash "${script_path}"
    else
        warn "Script not found or not executable: ${script_path}"
        return 1
    fi
}

_configure_dock() {
    local dry_run="${1:-false}"
    local script_path="${JSH_SCRIPTS_DIR}/macos/configure-dock.sh"

    jsh_section "macOS Dock Configuration"

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
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
# Application Configuration
# =============================================================================

_configure_vscode() {
    local dry_run="${1:-false}"

    jsh_section "VS Code Configuration"

    local vscode_settings_dir
    if [[ "$(uname -s)" == "Darwin" ]]; then
        vscode_settings_dir="${HOME}/Library/Application Support/Code/User"
    else
        vscode_settings_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User"
    fi

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would configure VS Code at: ${vscode_settings_dir}${RST}"
        return 0
    fi

    if [[ ! -d "${vscode_settings_dir}" ]]; then
        warn "VS Code not installed or settings directory not found"
        return 1
    fi

    # Link our VS Code settings if they exist
    local jsh_vscode_dir="${JSH_DIR:-${HOME}/.jsh}/dotfiles/.vscode/user"
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

    jsh_section "Linux System Configuration (GNOME)"

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-settings.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
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

    jsh_section "Systemd User Services"

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-systemd.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
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

    jsh_section "Hyprland/Wayland Environment"

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-hyprland.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
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

    jsh_section "DNF Repositories (COPR)"

    local script_path="${JSH_SCRIPTS_DIR}/linux/configure-repos.sh"

    if [[ "${dry_run}" == true ]]; then
        echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
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
    jsh_section "Available Configuration Modules"

    while IFS='|' read -r module platform desc; do
        [[ -z "${module}" ]] && continue
        if _configure_platform_applicable "${platform}"; then
            printf "%b %-12s %s\n" "${GRN}✓${RST}" "${module}" "${desc}"
        else
            printf "%b %-12s %s %b\n" "${DIM}-${RST}" "${module}" "${desc}" "${DIM}(not applicable)${RST}"
        fi
    done < <(_configure_module_rows)
}

cmd_configure_all() {
    local dry_run="${1:-false}"
    local skip_confirm="${2:-false}"

    jsh_section "jsh configure all"

    if [[ "${skip_confirm}" != true ]] && [[ "${dry_run}" != true ]]; then
        if ! ui_confirm "Run all applicable configurations?" "n"; then
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
                echo "${DIM}[dry-run] Would run: ${script_path}${RST}"
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
            jsh_section "jsh configure"
            jsh_note "System and application configuration"
            jsh_section "Usage"
            echo "jsh configure [command] [options]"
            jsh_section "Commands"
            echo "${CYN}all${RST} Run all applicable configurations (default)"
            echo "${CYN}macos${RST} macOS system defaults"
            echo "${CYN}dock${RST} macOS Dock settings"
            echo "${CYN}apps${RST} Application configs (VS Code)"
            echo "${CYN}linux${RST} GNOME desktop settings"
            echo "${CYN}systemd${RST} Systemd user services"
            echo "${CYN}hyprland${RST} Hyprland/Wayland environment"
            echo "${CYN}repos${RST} DNF repositories (COPR)"
            echo "${CYN}sudoers${RST} Sudoers configuration"
            echo "${CYN}list${RST} Show available configurations"
            jsh_section "Options"
            echo "--check, -n Dry run - show what would be changed"
            echo "--yes, -y Skip confirmation prompts"
            jsh_section "Examples"
            echo "jsh configure # Run all (with confirmation)"
            echo "jsh configure --check # Preview all changes"
            echo "jsh configure macos # macOS defaults only"
            echo "jsh configure dock # Dock settings only"
            echo "jsh configure linux # GNOME settings (Linux)"
            echo "jsh configure hyprland # Hyprland/Wayland setup (Linux)"
            echo "jsh configure systemd # Enable user services (Linux)"
            echo "jsh configure repos # Enable COPR repos (Linux)"
            echo "jsh configure list # List available modules"
            ;;
        *)
            error "Unknown command: ${subcmd}"
            echo ""
            cmd_configure --help
            return 1
            ;;
    esac
}
