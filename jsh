#!/usr/bin/env bash
# jsh - J Shell Management CLI
# Install, configure, and manage your shell environment
#
# Quick Install:
#   curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/jsh | bash

# Only set options if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

VERSION="0.2.0"
JSH_REPO="${JSH_REPO:-https://github.com/jovalle/jsh.git}"
JSH_BRANCH="${JSH_BRANCH:-main}"
JSH_DIR="${JSH_DIR:-${HOME}/.jsh}"

# Source core utilities for platform detection and helpers
# shellcheck disable=SC1091
if [[ -f "${JSH_DIR}/src/core.sh" ]]; then
    source "${JSH_DIR}/src/core.sh" 2>/dev/null || true
fi

# =============================================================================
# Platform Helpers
# =============================================================================

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

# Attempt to change default shell to zsh
set_default_shell_zsh() {
    local zsh_path

    # Find zsh path
    if has zsh; then
        zsh_path=$(command -v zsh)
    else
        prefix_warn "zsh not found, skipping shell change"
        return 0
    fi

    # Check if already using zsh
    if [[ "${SHELL}" == *"zsh"* ]]; then
        prefix_info "Default shell is already zsh"
        return 0
    fi

    # Check if user is a local user (exists in /etc/passwd) or domain/AD user
    local is_local_user=false
    local username="${USER%%@*}"  # Strip domain suffix if present
    if grep -q "^${username}:" /etc/passwd 2>/dev/null; then
        is_local_user=true
    fi

    if [[ "${is_local_user}" == true ]]; then
        # Local user: try chsh
        # Ensure zsh is in /etc/shells
        if ! grep -qx "${zsh_path}" /etc/shells 2>/dev/null; then
            prefix_warn "zsh not in /etc/shells, attempting to add..."
            if ! echo "${zsh_path}" | sudo tee -a /etc/shells >/dev/null 2>&1; then
                prefix_warn "Could not add zsh to /etc/shells (requires sudo), skipping shell change"
                return 0
            fi
        fi

        # Attempt to change shell
        info "Changing default shell to zsh..."
        if chsh -s "${zsh_path}" 2>/dev/null; then
            prefix_success "Default shell changed to zsh"
        else
            prefix_warn "Could not change default shell (may require password or sudo)"
            prefix_info "Run manually: chsh -s ${zsh_path}"
        fi
    else
        # Domain/AD user: chsh won't work, use .bashrc exec fallback
        info "Domain user detected, configuring zsh via .bashrc..."
        _configure_bashrc_zsh_exec "${zsh_path}"
    fi
}

# Configure .bashrc to exec zsh for domain/AD users where chsh doesn't work
_configure_bashrc_zsh_exec() {
    local zsh_path="$1"
    local bashrc="${HOME}/.bashrc"
    local marker="# jsh: exec zsh"

    # Check if already configured
    if [[ -f "${bashrc}" ]] && grep -q "${marker}" "${bashrc}" 2>/dev/null; then
        prefix_info ".bashrc already configured to exec zsh"
        return 0
    fi

    # Create .bashrc if it doesn't exist
    touch "${bashrc}" 2>/dev/null || {
        prefix_warn "Could not create/modify .bashrc, skipping"
        return 0
    }

    # Append zsh exec block
    cat >> "${bashrc}" << EOF

${marker}
# Switch to zsh if available and not already running
if [ -x "${zsh_path}" ] && [ -z "\$ZSH_VERSION" ]; then
    exec "${zsh_path}" -l
fi
EOF

    if [[ $? -eq 0 ]]; then
        prefix_success "Configured .bashrc to launch zsh"
    else
        prefix_warn "Could not configure .bashrc"
    fi
}

# =============================================================================
# Banner and Requirements
# =============================================================================

show_banner() {
    echo ""
    echo "${BOLD}${CYN}"
    echo "     ██╗███████╗██╗  ██╗"
    echo "     ██║██╔════╝██║  ██║"
    echo "     ██║███████╗███████║"
    echo "██   ██║╚════██║██╔══██║"
    echo "╚█████╔╝███████║██║  ██║"
    echo " ╚════╝ ╚══════╝╚═╝  ╚═╝"
    echo "${RST}"
    echo ""
}

check_requirements() {
    local skip_git="${1:-false}"
    local cmd_name="${2:-bootstrap}"

    info "Checking requirements..."

    if [[ "${skip_git}" != true ]]; then
        if ! has git; then
            error "git is required but not installed"
            prefix_info "If jsh is already cloned, use: jsh ${cmd_name} --no-git"
            exit 1
        fi
    fi

    if ! has curl && ! has wget; then
        warn "curl/wget not found (needed for tool downloads)"
        prefix_info "Install with: apt-get install curl (Linux) or brew install curl (macOS)"
    fi

    if ! has zsh; then
        warn "zsh is not installed (recommended for full experience)"
    fi

    success "Requirements met"
}

show_next_steps() {
    echo ""
    echo "${BOLD}Next steps:${RST}"
    echo ""
    echo "1. Reload your shell:"
    echo ""
    echo "   ${CYN}exec \$SHELL${RST}"
    echo ""
    echo "${BOLD}Useful commands:${RST}"
    echo "  ${CYN}jsh status${RST}   - Show installation status"
    echo ""
}

# =============================================================================
# Bootstrap: External Download Management
# =============================================================================
# All operations requiring external downloads are grouped here.
# Users must approve a summary before ANY downloads occur.

# Detect platform for binary downloads
_bootstrap_detect_platform() {
    if declare -f detect_platform >/dev/null 2>&1; then
        detect_platform
    else
        local os arch
        os="$(uname -s)"; os="${os,,}"
        arch="$(uname -m)"
        case "${arch}" in
            x86_64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
        esac
        echo "${os}-${arch}"
    fi
}

# Prompt for Y/n with default
_bootstrap_confirm() {
    local prompt="$1" default="${2:-y}"
    local response

    # Non-interactive mode: return default when no TTY
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        [[ "${default}" == "y" ]]
        return
    fi

    if [[ "${default}" == "y" ]]; then
        read -r -p "${prompt} [Y/n] " response
        [[ ! "${response}" =~ ^[Nn] ]]
    else
        read -r -p "${prompt} [y/N] " response
        [[ "${response}" =~ ^[Yy] ]]
    fi
}

# Gather user selections for all external downloads
# Sets global variables: BOOTSTRAP_SHELL_TOOLS
# Note: ZSH plugins are embedded in lib/zsh-plugins/ (managed by Renovate/GitHub Actions)
_bootstrap_gather_selections() {
    BOOTSTRAP_SHELL_TOOLS=false
    BOOTSTRAP_ALL_PLATFORMS=false

    # Check if download tools are available
    local can_download=false
    if has curl || has wget; then
        can_download=true
    fi

    # Check if jq/fzf already available
    local has_jq=false has_fzf=false
    has jq && has_jq=true
    has fzf && has_fzf=true

    # Skip download section entirely if tools are installed or downloads impossible
    if [[ "${has_jq}" == true ]] && [[ "${has_fzf}" == true ]]; then
        echo ""
        echo "${CYN}Shell Tools:${RST}"
        echo "  ${GRN}✔${RST} jq and fzf already installed"
        return 0
    fi

    if [[ "${can_download}" == false ]]; then
        echo ""
        echo "${CYN}Shell Tools:${RST}"
        echo "  ${YLW}⚠${RST} curl/wget not available - cannot download tools"
        echo "  ${DIM}Install missing tools via package manager:${RST}"
        echo "  ${DIM}  macOS: brew install jq fzf${RST}"
        echo "  ${DIM}  Linux: apt install jq fzf curl${RST}"
        return 0
    fi

    # Show download options
    echo ""
    echo "${BOLD}External Downloads${RST}"
    echo "${DIM}The following optional components require downloading from GitHub.${RST}"
    echo "${DIM}Select what you'd like to install:${RST}"
    echo ""

    # --- Shell Tools (jq, fzf) ---
    echo "${CYN}Shell Tools (jq, fzf):${RST}"
    echo ""
    echo "  ${BOLD}jq${RST}  - JSON processor (required for jsh features)"
    echo "  ${BOLD}fzf${RST} - Fuzzy finder (recommended for enhanced experience)"
    echo ""
    echo "  ${DIM}These can be downloaded to bin/<platform>/ or installed via:${RST}"
    echo "  ${DIM}  macOS: brew install jq fzf${RST}"
    echo "  ${DIM}  Linux: apt install jq fzf${RST}"
    echo ""

    if _bootstrap_confirm "  Download jq and fzf binaries?" "y"; then
        BOOTSTRAP_SHELL_TOOLS=true
    fi

    # --- Multi-platform binaries (for jssh portability) ---
    if [[ "${BOOTSTRAP_SHELL_TOOLS}" == true ]]; then
        echo ""
        echo "${CYN}Multi-Platform Support (for jssh):${RST}"
        echo ""
        echo "  ${DIM}Download binaries for all platforms (darwin/linux, arm64/amd64)${RST}"
        echo "  ${DIM}This enables portable shell environment via jssh.${RST}"
        echo ""

        if _bootstrap_confirm "  Download for all platforms?" "n"; then
            BOOTSTRAP_ALL_PLATFORMS=true
        fi
    fi
}

# Show summary of all pending downloads and get final approval
# Returns: 0 if approved, 1 if cancelled
_bootstrap_show_download_summary() {
    local has_downloads=false

    echo ""
    echo "${BOLD}════════════════════════════════════════════════════════════════${RST}"
    echo "${BOLD}                    Download Summary${RST}"
    echo "${BOLD}════════════════════════════════════════════════════════════════${RST}"
    echo ""

    # Always show local operations
    echo "${CYN}Local Operations:${RST}"
    if [[ "${BOOTSTRAP_SKIP_GIT:-false}" == true ]]; then
        echo "  ${DIM}-${RST} Git operations skipped (--no-git)"
    elif [[ ! -d "${JSH_DIR}/.git" ]]; then
        echo "  ${GRN}•${RST} Clone jsh repository to ${JSH_DIR}"
        echo "  ${GRN}•${RST} Initialize git submodules (fzf, zsh-completions, fzf-tab)"
    else
        echo "  ${GRN}•${RST} Update jsh repository"
        echo "  ${GRN}•${RST} Initialize git submodules (fzf, zsh-completions, fzf-tab)"
    fi
    echo "  ${GRN}•${RST} Create symlinks for dotfiles"
    echo ""

    # Show shell tools downloads
    if [[ "${BOOTSTRAP_SHELL_TOOLS:-false}" == true ]]; then
        has_downloads=true
        if [[ "${BOOTSTRAP_ALL_PLATFORMS:-false}" == true ]]; then
            echo "${CYN}Shell Tools (all platforms for jssh portability):${RST}"
            echo "  ${YLW}↓${RST} jq - JSON processor"
            echo "  ${YLW}↓${RST} fzf - Fuzzy finder"
            echo "  ${DIM}    Platforms: darwin-arm64, darwin-amd64, linux-arm64, linux-amd64${RST}"
        else
            local platform
            platform=$(_bootstrap_detect_platform)
            echo "${CYN}Shell Tools (from GitHub → bin/${platform}/):${RST}"
            echo "  ${YLW}↓${RST} jq - JSON processor"
            echo "  ${YLW}↓${RST} fzf - Fuzzy finder"
        fi
        echo ""
    fi

    if [[ "${has_downloads}" == false ]]; then
        echo "${DIM}No external downloads selected.${RST}"
        echo ""
    fi

    echo "${BOLD}════════════════════════════════════════════════════════════════${RST}"
    echo ""

    if [[ "${has_downloads}" == true ]]; then
        echo "${YLW}The above items will be downloaded from external sources.${RST}"
    fi

    if ! _bootstrap_confirm "Proceed with installation?" "y"; then
        info "Installation cancelled."
        return 1
    fi

    return 0
}

# Execute shell tools downloads (jq, fzf)
_bootstrap_download_shell_tools() {
    if [[ "${BOOTSTRAP_SHELL_TOOLS:-false}" != true ]]; then
        return 0
    fi

    info "Downloading shell tools..."

    # Source deps.sh for download functions
    if [[ -f "${JSH_DIR}/src/deps.sh" ]]; then
        # shellcheck disable=SC1091
        source "${JSH_DIR}/src/deps.sh"
    else
        prefix_error "deps.sh not found - cannot download tools"
        prefix_info "Install manually: brew install jq fzf (macOS) or apt install jq fzf (Linux)"
        return 1
    fi

    local errors=0

    # Download for all platforms (jssh portability) or just current
    if [[ "${BOOTSTRAP_ALL_PLATFORMS:-false}" == true ]]; then
        download_all_platforms || ((errors++))
    else
        # Download jq (required)
        if ! command -v jq >/dev/null 2>&1; then
            download_binary "jq" || ((errors++))
        else
            prefix_success "jq (system)"
        fi

        # Download fzf (recommended)
        if ! command -v fzf >/dev/null 2>&1; then
            download_binary "fzf" || ((errors++))
        else
            prefix_success "fzf (system)"
        fi
    fi

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        warn "Some tools failed to download."
        echo "  ${DIM}You can still use jsh, but some features may be limited.${RST}"
        echo "  ${DIM}Install via package manager: brew install jq fzf${RST}"
        # Don't fail the entire bootstrap - graceful degradation
    fi

    return 0
}

# =============================================================================
# Load Dependency Management
# =============================================================================

# Source dependency management functions (if available)
# shellcheck disable=SC1091
if [[ -f "${JSH_DIR}/src/deps.sh" ]]; then
    # Load core first for platform detection
    source "${JSH_DIR}/src/core.sh"
    source "${JSH_DIR}/src/deps.sh"
    # Load command modules
    source_if "${JSH_DIR}/src/symlinks.sh"
    source_if "${JSH_DIR}/src/status.sh"
    source_if "${JSH_DIR}/src/upgrade.sh"
    source_if "${JSH_DIR}/src/host.sh"
    source_if "${JSH_DIR}/src/tools.sh"
    source_if "${JSH_DIR}/src/clean.sh"
    source_if "${JSH_DIR}/src/install.sh"
    source_if "${JSH_DIR}/src/sync.sh"
    source_if "${JSH_DIR}/src/configure.sh"
    source_if "${JSH_DIR}/src/pkg.sh"
fi

# =============================================================================
# Commands
# =============================================================================

cmd_help() {
    cat << HELP
${BOLD}jsh${RST} - J Shell Management CLI v${VERSION}

${BOLD}QUICK INSTALL:${RST}
    curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/jsh | bash

${BOLD}USAGE:${RST}
    jsh <command> [options]

${BOLD}SETUP COMMANDS:${RST}
    ${CYN}bootstrap${RST}   Clone/update repo and setup (for fresh installs)
    ${CYN}setup${RST}       Setup jsh (link dotfiles)
    ${CYN}teardown${RST}    Remove jsh symlinks and optionally the entire installation
    ${CYN}upgrade${RST}     Check for plugin/binary updates and manage versions

${BOLD}SYMLINK COMMANDS:${RST}
    ${CYN}link${RST}        Create symlinks for managed dotfiles
    ${CYN}unlink${RST}      Remove symlinks (optionally restore backups)

${BOLD}INFO COMMANDS:${RST}
    ${CYN}status${RST}      Show installation status, symlinks, and check for issues
    ${CYN}doctor${RST}      Comprehensive health check with diagnostics and fixes

${BOLD}PACKAGE & TOOLS:${RST}
    ${CYN}pkg${RST}         Manage packages (add, remove, list, sync, bundle, service)
    ${CYN}install${RST}     Install packages (brew, npm, pip, cargo)
    ${CYN}clean${RST}       Clean caches and temporary files
    ${CYN}tools${RST}       Discover and manage development tools
    ${CYN}cli${RST}         CLI helper for script discovery and completions

${BOLD}CONFIGURATION:${RST}
    ${CYN}sync${RST}        Sync git repo with remote (safe bidirectional)
    ${CYN}configure${RST}   Configure system settings and applications

${BOLD}DEPENDENCY COMMANDS:${RST}
    ${CYN}deps${RST}        Manage dependencies (status, check, refresh, doctor)
    ${CYN}host${RST}        Manage remote host configurations for jssh

${BOLD}OPTIONS:${RST}
    -h, --help      Show this help
    -v, --version   Show version
    -r, --reload    Reload shell configuration

${BOLD}TEARDOWN OPTIONS:${RST}
    --full          Remove entire Jsh directory (default: only unlink dotfiles)
    --restore       Restore backed up dotfiles before unlinking
    --yes, -y       Skip confirmation prompt

${BOLD}STATUS OPTIONS:${RST}
    --fix, -f       Fix issues (remove broken symlinks)

${BOLD}UNLINK OPTIONS:${RST}
    --restore       Restore from latest backup after unlinking
    --restore=NAME  Restore from a specific backup

${BOLD}EXAMPLES:${RST}
    jsh setup                 # Setup jsh locally
    jsh link                  # Create dotfile symlinks
    jsh unlink                # Remove symlinks only
    jsh unlink --restore      # Restore original dotfiles and unlink
    jsh teardown --full       # Remove everything

${BOLD}ENVIRONMENT:${RST}
    JSH_DIR           Jsh installation directory (default: ~/.jsh)
    JSH_REPO          Git repository URL (default: github.com/jovalle/jsh)
    JSH_BRANCH        Branch to install (default: main)

HELP
}

cmd_version() {
    echo "jsh ${VERSION}"
}

# Interactive setup wizard
_setup_interactive() {
    echo ""
    echo "${BOLD}Welcome to Jsh! Let's configure your shell.${RST}"
    echo ""

    # Editor selection
    local editor
    read -r -p "Select your preferred editor [vim/code/nano] (vim): " editor
    editor="${editor:-vim}"

    # Vi-mode
    local vi_mode
    read -r -p "Enable vi-mode keybindings? [Y/n]: " vi_mode
    vi_mode="${vi_mode:-y}"

    echo ""
    info "Saving configuration..."

    # Write configuration
    mkdir -p "${JSH_DIR}/local"
    cat > "${JSH_DIR}/local/.jshrc" << EOF
# Jsh Configuration (generated by setup --interactive)
export EDITOR="${editor}"
export JSH_VI_MODE=$([[ "${vi_mode,,}" =~ ^y ]] && echo 1 || echo 0)
EOF

    prefix_success "Configuration saved to local/.jshrc"
    echo ""

    info "Continuing with setup..."

    # Initialize submodules
    if [[ -d "${JSH_DIR}/.git" ]]; then
        info "Initializing submodules..."
        git -C "${JSH_DIR}" submodule update --init --depth 1 2>/dev/null || warn "Failed to init submodules"
    fi

    # Create symlinks
    cmd_link

    # Attempt to set zsh as default shell
    set_default_shell_zsh

    success "Jsh setup complete!"
    show_next_steps
}

# @jsh-cmd setup Setup jsh (link dotfiles)
# @jsh-opt -i,--interactive Run interactive setup wizard
# @jsh-opt --no-git Skip git operations (submodule init)
cmd_setup() {
    local interactive=false
    local skip_git=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive) interactive=true; shift ;;
            --no-git) skip_git=true; shift ;;
            *) shift ;;
        esac
    done

    show_banner

    if [[ "$interactive" == true ]]; then
        _setup_interactive
        return
    fi

    info "Setting up jsh..."

    # Initialize submodules (unless --no-git or git unavailable)
    if [[ "${skip_git}" == true ]]; then
        prefix_info "Skipping git operations (--no-git)"
    elif ! has git; then
        prefix_info "git not found, skipping submodule init"
    elif [[ -d "${JSH_DIR}/.git" ]]; then
        info "Initializing submodules..."
        if git -C "${JSH_DIR}" submodule update --init --depth 1 2>/dev/null; then
            # Show submodule status
            local gitmodules="${JSH_DIR}/.gitmodules"
            if [[ -f "${gitmodules}" ]]; then
                while IFS= read -r line; do
                    if [[ "${line}" =~ path\ =\ (.+) ]]; then
                        local submod_path="${BASH_REMATCH[1]}"
                        local full_path="${JSH_DIR}/${submod_path}"
                        if [[ -d "${full_path}" ]] && [[ -n "$(ls -A "${full_path}" 2>/dev/null)" ]]; then
                            local sub_commit
                            sub_commit=$(git -C "${full_path}" rev-parse --short HEAD 2>/dev/null || echo "?")
                            prefix_success "${submod_path} ${DIM}(${sub_commit})${RST}"
                        fi
                    fi
                done < "${gitmodules}"
            fi
        else
            warn "Failed to init submodules"
        fi
    fi

    # Create symlinks
    cmd_link

    # Create local config directory
    mkdir -p "${JSH_DIR}/local"

    # Attempt to set zsh as default shell
    set_default_shell_zsh

    success "Jsh setup complete!"
    show_next_steps
}

# @jsh-cmd teardown Remove jsh symlinks and optionally the entire installation
# @jsh-opt --full Remove entire Jsh directory
# @jsh-opt -r,--restore Restore backed up dotfiles
# @jsh-opt -y,--yes Skip confirmation prompt
cmd_teardown() {
    local full_teardown=false
    local restore_backup=false
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full|-f)
                full_teardown=true
                shift
                ;;
            --restore|-r)
                restore_backup=true
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

    if [[ "${skip_confirm}" != true ]]; then
        echo ""
        echo "${YLW}Are you sure you want to teardown jsh? T_T${RST}"
        if [[ "${full_teardown}" == true ]]; then
            echo "${RED}This will completely remove ${JSH_DIR}!${RST}"
        fi
        echo ""
        read -r -p "Type 'yes' to confirm: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            info "Teardown cancelled. Phew! :)"
            return 0
        fi
        echo ""
    fi

    info "Tearing down jsh..."

    if [[ "${restore_backup}" == true ]]; then
        cmd_unlink --restore
    else
        cmd_unlink
    fi

    if [[ "${full_teardown}" == true ]]; then
        if [[ -d "${JSH_DIR}" ]]; then
            warn "Removing ${JSH_DIR}..."
            if ! rm -rf "${JSH_DIR}" 2>/dev/null; then
                error "Could not remove ${JSH_DIR}"
                return 1
            fi
            success "Jsh completely removed from ${JSH_DIR}"
        fi
    else
        success "jsh teardown complete (dotfiles unlinked)."
    fi

    echo ""
    echo "Don't forget to remove the 'source ~/.jsh/src/init.sh' line"
    echo "from your .zshrc or .bashrc"
}

# @jsh-cmd link Create symlinks for managed dotfiles
cmd_link() {
    local backup_dir
    backup_dir="${HOME}/.jsh_backup/$(date +%Y%m%d_%H%M%S)"

    info "Creating symlinks..."
    _process_symlink_rules "${backup_dir}" "link"
    success "Symlinks created"
}

# @jsh-cmd unlink Remove symlinks (optionally restore backups)
# @jsh-opt --restore Restore from latest backup after unlinking
# @jsh-opt --restore=NAME Restore from a specific backup
cmd_unlink() {
    local restore_backup=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restore=*)
                restore_backup="${1#--restore=}"
                shift
                ;;
            --restore)
                restore_backup="latest"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    info "Removing symlinks..."
    _process_symlink_rules "" "unlink"
    success "Symlinks removed"

    # Restore from backup if requested
    if [[ -n "${restore_backup}" ]]; then
        echo ""
        _restore_backup "${restore_backup}"
    fi
}

_restore_backup() {
    local selected_backup="${1:-}"
    local backup_base="${HOME}/.jsh_backup"

    if [[ ! -d "${backup_base}" ]]; then
        warn "No backups found at ${backup_base}"
        return 1
    fi

    local backups=()
    while IFS= read -r dir; do
        [[ -d "${dir}" ]] && backups+=("$(basename "${dir}")")
    done < <(find "${backup_base}" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "No backups found in ${backup_base}"
        return 1
    fi

    # List backups if no selection
    if [[ -z "${selected_backup}" ]]; then
        echo "${BOLD}Available Backups${RST}"
        echo ""
        for i in "${!backups[@]}"; do
            local backup="${backups[${i}]}"
            local backup_path="${backup_base}/${backup}"
            local file_count
            file_count=$(find "${backup_path}" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [[ ${i} -eq 0 ]]; then
                echo "  ${CYN}${backup}${RST} (${file_count} files) ${GRN}[latest]${RST}"
            else
                echo "  ${backup} (${file_count} files)"
            fi
        done
        echo ""
        echo "Usage: ${CYN}jsh unlink --restore${RST} or ${CYN}jsh unlink --restore=NAME${RST}"
        return 0
    fi

    if [[ "${selected_backup}" == "latest" ]]; then
        selected_backup="${backups[0]}"
    fi

    local backup_path="${backup_base}/${selected_backup}"

    if [[ ! -d "${backup_path}" ]]; then
        error "Backup not found: ${selected_backup}"
        echo ""
        echo "Available backups:"
        printf '  %s\n' "${backups[@]}"
        return 1
    fi

    info "Restoring from backup: ${selected_backup}"

    local restored=0
    while IFS= read -r backup_file; do
        local filename
        filename=$(basename "${backup_file}")
        local relative_path="${backup_file#"${backup_path}"/}"
        local dest

        dest="${HOME}/${filename}"

        if [[ -L "${dest}" ]]; then
            local resolved
            resolved=$(readlink -f "${dest}" 2>/dev/null || readlink "${dest}")
            if [[ "${resolved}" == "${JSH_DIR}/"* ]] || [[ "${resolved}" == "${JSH_DIR}" ]]; then
                rm "${dest}"
                prefix_info "Removed symlink: ${dest}"
            else
                prefix_warn "Skipping ${filename}: symlink points to non-jsh location"
                continue
            fi
        elif [[ -e "${dest}" ]]; then
            prefix_warn "Skipping ${filename}: destination exists and is not a jsh symlink"
            continue
        fi

        if [[ -d "${backup_file}" ]]; then
            cp -R "${backup_file}" "${dest}"
        else
            cp "${backup_file}" "${dest}"
        fi
        prefix_success "Restored ${relative_path}"
        ((restored++))
    done < <(find "${backup_path}" -mindepth 1 -maxdepth 1)

    if [[ ${restored} -eq 0 ]]; then
        prefix_warn "No files were restored"
    else
        prefix_success "Restored ${restored} file(s) from ${selected_backup}"
    fi
}

cmd_reload() {
    info "Reloading shell..."
    exec "${SHELL}"
}

# =============================================================================
# Dependency Commands
# =============================================================================

# @jsh-cmd deps Manage dependencies (status, check, refresh, doctor)
# @jsh-sub status Show all dependencies and resolved strategies
# @jsh-sub check Re-run preflight checks
# @jsh-sub refresh Force re-download/rebuild dependencies
# @jsh-sub doctor Diagnose dependency issues
# @jsh-sub capabilities Show build capability profiles
# @jsh-sub fix-bash Install/configure bash 4+ (macOS)
cmd_deps() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    # Check if deps.sh is loaded
    if ! declare -f _jsh_deps_status >/dev/null 2>&1; then
        error "Dependency management not available"
        prefix_info "Ensure src/deps.sh exists and jq is installed"
        return 1
    fi

    case "${subcmd}" in
        status|s)
            _jsh_deps_status
            ;;
        check|c)
            cmd_deps_check "$@"
            ;;
        refresh|r)
            cmd_deps_refresh "$@"
            ;;
        doctor|d)
            cmd_deps_doctor "$@"
            ;;
        capabilities|cap)
            _jsh_capability_status
            ;;
        fix-bash)
            cmd_deps_fix_bash "$@"
            ;;
        *)
            echo "${BOLD}jsh deps${RST} - Dependency management"
            echo ""
            echo "${BOLD}USAGE:${RST}"
            echo "    jsh deps <command>"
            echo ""
            echo "${BOLD}COMMANDS:${RST}"
            echo "    ${CYN}status${RST}        Show all dependencies and resolved strategies"
            echo "    ${CYN}check${RST}         Re-run preflight checks"
            echo "    ${CYN}refresh${RST}       Force re-download/rebuild dependencies"
            echo "    ${CYN}doctor${RST}        Diagnose dependency issues"
            echo "    ${CYN}capabilities${RST}  Show build capability profiles"
            echo "    ${CYN}fix-bash${RST}      Install/configure bash 4+ (macOS)"
            ;;
    esac
}

cmd_deps_check() {
    info "Running dependency preflight..."
    echo ""

    if ! has jq; then
        error "jq is required for dependency management"
        prefix_info "Install with: brew install jq (macOS) or apt install jq (Linux)"
        return 1
    fi

    local state
    state=$(_jsh_preflight_full)

    if [[ $? -eq 0 ]]; then
        # Write state file
        mkdir -p "${JSH_DIR}/local"
        echo "${state}" > "${JSH_DIR}/local/dependency-state.json"
        success "Preflight complete. State saved to local/dependency-state.json"
    else
        error "Preflight failed"
        return 1
    fi
}

cmd_deps_refresh() {
    local dep_name="${1:-}"

    if [[ -z "${dep_name}" ]]; then
        info "Refreshing all dependencies..."
        prefix_info "This will re-run the setup script to download/update all binaries"
        echo ""

        local setup_script="${JSH_DIR}/src/deps.sh"
        if [[ -x "${setup_script}" ]]; then
            "${setup_script}"
        else
            warn "Setup script not found: ${setup_script}"
            prefix_info "Pull latest jsh or manually download binaries"
        fi
    else
        info "Refreshing dependency: ${dep_name}"
        warn "Individual dependency refresh not yet implemented"
        prefix_info "For now, use: jsh deps refresh (all)"
    fi
}

cmd_deps_doctor() {
    info "Dependency Doctor - Diagnosing issues..."
    echo ""

    local issues=0

    # Check jq
    if has jq; then
        prefix_success "jq is installed"
    else
        prefix_error "jq is not installed (required for dependency management)"
        ((issues++))
    fi

    # Check manifest
    local manifest="${JSH_DIR}/lib/dependencies.json"
    if [[ -f "${manifest}" ]]; then
        prefix_success "Manifest found: lib/dependencies.json"

        # Validate JSON
        if has jq && jq empty "${manifest}" 2>/dev/null; then
            prefix_success "Manifest is valid JSON"
        else
            prefix_error "Manifest has invalid JSON syntax"
            ((issues++))
        fi
    else
        prefix_warn "Manifest not found (using legacy versions.json)"
    fi

    # Check state file
    local state="${JSH_DIR}/local/dependency-state.json"
    if [[ -f "${state}" ]]; then
        prefix_success "State file found: local/dependency-state.json"

        local state_age
        if is_macos; then
            state_age=$(( ($(date +%s) - $(stat -f %m "${state}")) / 86400 ))
        else
            state_age=$(( ($(date +%s) - $(stat -c %Y "${state}")) / 86400 ))
        fi

        if [[ ${state_age} -gt 7 ]]; then
            prefix_warn "State file is ${state_age} days old (consider re-running: jsh deps check)"
        fi
    else
        prefix_warn "No state file (run: jsh deps check)"
    fi

    # Check system tools
    echo ""
    info "System Tools (install via package manager):"
    local tools=("jq" "fzf" "fd" "rg")
    for tool in "${tools[@]}"; do
        if has "${tool}"; then
            local version=""
            case "${tool}" in
                jq)  version=$("${tool}" --version 2>/dev/null) ;;
                fzf) version=$("${tool}" --version 2>/dev/null | head -1) ;;
                fd)  version=$("${tool}" --version 2>/dev/null | cut -d' ' -f2) ;;
                rg)  version=$("${tool}" --version 2>/dev/null | head -1 | cut -d' ' -f2) ;;
            esac
            prefix_success "${tool} ${DIM}(${version})${RST}"
        else
            if [[ "${tool}" == "jq" ]]; then
                prefix_error "${tool} (required - install with: brew install jq)"
                ((issues++))
            else
                prefix_info "${tool} ${DIM}(optional)${RST}"
            fi
        fi
    done

    # Summary
    echo ""
    if [[ ${issues} -eq 0 ]]; then
        prefix_success "No issues found"
    else
        prefix_warn "${issues} issue(s) found"
    fi
}

cmd_deps_fix_bash() {
    info "Bash Version Check and Fix"
    echo ""

    # Get current bash version
    local current_bash_ver current_bash_major
    current_bash_ver="${BASH_VERSION:-$(bash --version 2>/dev/null | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')}"
    current_bash_major="${current_bash_ver%%.*}"

    prefix_info "Current bash version: ${current_bash_ver}"

    # Check if we're running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        if [[ "${current_bash_major}" -ge 4 ]]; then
            prefix_success "Bash ${current_bash_ver} meets requirements (4.0+)"
        else
            prefix_warn "Bash is older than 4.0, but not on macOS"
            prefix_info "Install bash 4+ via your package manager (apt, dnf, pacman, etc.)"
        fi
        return 0
    fi

    echo ""
    info "macOS Bash Setup"

    # Check for Homebrew
    local brew_prefix=""
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        brew_prefix="/opt/homebrew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        brew_prefix="/usr/local"
    fi

    if [[ -z "${brew_prefix}" ]]; then
        error "Homebrew not found"
        echo ""
        prefix_info "Install Homebrew first:"
        echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi

    prefix_success "Homebrew found at ${brew_prefix}"

    # Check if modern bash is installed via brew
    local brew_bash="${brew_prefix}/bin/bash"
    if [[ -x "${brew_bash}" ]]; then
        local brew_bash_ver
        brew_bash_ver=$("${brew_bash}" --version 2>/dev/null | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')
        prefix_success "Homebrew bash installed: ${brew_bash_ver}"
    else
        prefix_warn "Homebrew bash not installed"
        echo ""
        info "Installing bash via Homebrew..."
        if brew install bash; then
            prefix_success "Bash installed successfully"
            brew_bash_ver=$("${brew_bash}" --version 2>/dev/null | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')
        else
            error "Failed to install bash"
            return 1
        fi
    fi

    # Check if brew paths are in shell config
    echo ""
    info "Checking PATH configuration..."

    local shell_rc=""
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL}" == *zsh ]]; then
        shell_rc="${HOME}/.zshrc"
    else
        shell_rc="${HOME}/.bashrc"
    fi

    # Check if brew bash comes before system bash
    local first_bash
    first_bash=$(which bash 2>/dev/null)

    if [[ "${first_bash}" == "${brew_bash}" ]]; then
        prefix_success "Homebrew bash is first in PATH"
    else
        prefix_warn "System bash (/bin/bash) comes before Homebrew bash"
        echo ""
        prefix_info "Your shell rc (${shell_rc}) should have Homebrew paths early."
        prefix_info "Jsh's managed .zshrc/.bashrc already handles this."

        if [[ -L "${HOME}/.zshrc" ]] && [[ "$(readlink "${HOME}/.zshrc")" == *jsh* ]]; then
            prefix_success "Using jsh-managed .zshrc"
            prefix_info "Start a new shell to pick up the correct PATH"
        else
            echo ""
            prefix_info "Add this to the TOP of ${shell_rc}:"
            echo ""
            echo "    # Homebrew (must be early in rc file)"
            echo "    eval \"\$(${brew_prefix}/bin/brew shellenv)\""
            echo ""
        fi
    fi

    # Final status
    echo ""
    info "Verification"
    local env_bash
    # shellcheck disable=SC2016  # Intentional: $BASH_VERSION is evaluated in subshell
    env_bash=$(/usr/bin/env bash -c 'echo $BASH_VERSION' 2>/dev/null)
    local env_bash_major="${env_bash%%.*}"

    if [[ "${env_bash_major}" -ge 4 ]]; then
        prefix_success "/usr/bin/env bash resolves to: bash ${env_bash}"
        echo ""
        success "Bash is properly configured!"
    else
        prefix_warn "/usr/bin/env bash still resolves to: bash ${env_bash}"
        echo ""
        warn "Start a new shell or source your rc file to apply PATH changes"
    fi
}

# @jsh-cmd bootstrap Clone/update repo and setup (for fresh installs)
# @jsh-opt -y,--non-interactive Skip prompts, use defaults
# @jsh-opt --tools Download jq and fzf for current platform
# @jsh-opt --all-platforms Download jq and fzf for all platforms (jssh)
# @jsh-opt --no-git Skip git clone/pull and submodule operations
cmd_bootstrap() {
    local interactive=true
    local with_tools=false
    local all_platforms=false
    local skip_git=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive|-y) interactive=false; shift ;;
            --tools) with_tools=true; shift ;;
            --all-platforms) all_platforms=true; with_tools=true; shift ;;
            --no-git) skip_git=true; shift ;;
            -h|--help)
                echo "Usage: jsh bootstrap [options]"
                echo ""
                echo "Options:"
                echo "  -y, --non-interactive   Skip prompts, use defaults"
                echo "  --tools                 Download jq and fzf for current platform"
                echo "  --all-platforms         Download jq and fzf for all platforms (jssh)"
                echo "  --no-git                Skip git clone/pull and submodule operations"
                echo "  -h, --help              Show this help"
                return 0
                ;;
            *) shift ;;
        esac
    done

    show_banner
    check_requirements "${skip_git}" "bootstrap"

    # Non-interactive mode: no TTY or explicit flag
    if [[ "${interactive}" == true ]] && [[ ! -t 0 || ! -t 1 ]]; then
        interactive=false
    fi

    # === Phase 1: Gather user selections ===
    if [[ "${interactive}" == true ]]; then
        _bootstrap_gather_selections
    else
        # Non-interactive mode: use flags or defaults
        BOOTSTRAP_SHELL_TOOLS="${with_tools}"
        BOOTSTRAP_ALL_PLATFORMS="${all_platforms}"
    fi

    # Set skip_git for use in summary display
    BOOTSTRAP_SKIP_GIT="${skip_git}"

    # === Phase 2: Show summary and get approval ===
    if ! _bootstrap_show_download_summary; then
        return 1
    fi

    # === Phase 3: Execute local operations ===
    echo ""

    # Clone or update repository (unless --no-git)
    if [[ "${skip_git}" == true ]]; then
        prefix_info "Skipping git operations (--no-git)"
        if [[ ! -d "${JSH_DIR}" ]]; then
            die "${JSH_DIR} does not exist. Cannot skip git operations on fresh install."
        fi
    else
        if [[ -d "${JSH_DIR}" ]]; then
            if [[ -d "${JSH_DIR}/.git" ]]; then
                info "Updating jsh repository..."
                git -C "${JSH_DIR}" pull --rebase || warn "Failed to pull updates"
            else
                die "${JSH_DIR} exists but is not a git repository"
            fi
        else
            info "Cloning jsh repository..."
            git clone --depth 1 --branch "${JSH_BRANCH}" "${JSH_REPO}" "${JSH_DIR}"
        fi

        info "Initializing submodules..."
        git -C "${JSH_DIR}" submodule update --init --depth 1 || warn "Failed to init submodules"
    fi

    # === Phase 4: Execute external downloads ===
    _bootstrap_download_shell_tools

    # === Phase 5: Local configuration ===
    info "Setting up dotfiles..."
    cmd_link
    mkdir -p "${JSH_DIR}/local"

    echo ""
    success "Jsh installed successfully!"
    show_next_steps
}

# =============================================================================
# Main
# =============================================================================

main() {
    local cmd="${1:-}"

    if [[ -z "${cmd}" ]]; then
        if [[ ! -t 0 ]] || [[ ! -d "${JSH_DIR}/.git" ]]; then
            cmd_bootstrap
            return
        fi
        cmd_help
        return
    fi

    shift || true

    case "${cmd}" in
        -h|--help|help)
            cmd_help
            ;;
        -v|--version|version)
            cmd_version
            ;;
        -r|--reload)
            cmd_reload
            ;;
        setup|init)
            cmd_setup "$@"
            ;;
        teardown|deinit)
            cmd_teardown "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        doctor|check)
            cmd_status --verbose "$@"
            ;;
        link)
            cmd_link "$@"
            ;;
        unlink)
            cmd_unlink "$@"
            ;;
        reload)
            cmd_reload "$@"
            ;;
        upgrade|update)
            cmd_upgrade "$@"
            ;;
        bootstrap)
            cmd_bootstrap "$@"
            ;;
        deps|dependencies)
            cmd_deps "$@"
            ;;
        host|hosts)
            cmd_host "$@"
            ;;
        # Package & Tools commands
        install)
            cmd_install "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        tools)
            cmd_tools "$@"
            ;;
        pkg|packages)
            cmd_pkg "$@"
            ;;
        # Configuration commands
        sync)
            cmd_sync "$@"
            ;;
        configure|config)
            cmd_configure "$@"
            ;;
        # CLI helper command
        cli)
            # shellcheck disable=SC1091
            source "${JSH_DIR}/src/cli.sh" && cmd_cli "$@"
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
