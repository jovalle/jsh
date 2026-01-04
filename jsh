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

VERSION="1.1.0"
JSH_REPO="${JSH_REPO:-https://github.com/jovalle/jsh.git}"
JSH_BRANCH="${JSH_BRANCH:-main}"
JSH_DIR="${JSH_DIR:-${HOME}/.jsh}"

# Source core utilities for platform detection and helpers
# shellcheck disable=SC1091
if [[ -f "${JSH_DIR}/src/core.sh" ]]; then
    source "${JSH_DIR}/src/core.sh" 2>/dev/null || true
fi

# =============================================================================
# Colors
# =============================================================================

if [[ -t 1 ]]; then
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    BLUE=$'\e[34m'
    CYAN=$'\e[36m'
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    RST=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" RST=""
fi

# =============================================================================
# Helpers
# =============================================================================

info()    { echo "${BLUE}$*${RST}"; }
success() { echo "${GREEN}$*${RST}"; }
warn()    { echo "${YELLOW}$*${RST}" >&2; }
error()   { echo "${RED}$*${RST}" >&2; }
die()     { error "$@"; exit 1; }

prefix_info()    { echo "${BLUE}◆${RST} $*"; }
prefix_success() { echo "${GREEN}✔${RST} $*"; }
prefix_warn()    { echo "${YELLOW}⚠${RST} $*" >&2; }
prefix_error()   { echo "${RED}✘${RST} $*" >&2; }

has() { command -v "$1" >/dev/null 2>&1; }

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
# Symlink Configuration DSL
# =============================================================================
#
# Format: TYPE SOURCE [-> DESTINATION] [@PLATFORM]
#
# Types:
#   file      - Link single file (default dest: $HOME/filename)
#   dir       - Link entire directory (default dest: $HOME/dirname)
#   children  - Link each child of directory (default dest: $HOME/dirname/)
#
# Variables:
#   $HOME        - User home directory
#   $XDG_CONFIG  - XDG config dir ($XDG_CONFIG_HOME or ~/.config)
#   $VSCODE_USER - VSCode user settings dir (platform-aware)
#
# Platforms: @all (default), @macos, @linux
# =============================================================================

get_symlink_rules() {
    cat << 'RULES'
# Home Dotfiles
file .zshrc
file .bashrc
file .gitconfig
file .inputrc
file .tmux.conf
file .vimrc
file .editorconfig
file .shellcheckrc
file .markdownlint.jsonc
file .prettierrc.json
file .eslintrc.json
file .pylintrc
file .czrc
file .ripgreprc

# XDG Config (link each subdirectory)
children .config -> $XDG_CONFIG

# VSCode (platform-specific destination)
children .vscode/user -> $VSCODE_USER
RULES
}

# =============================================================================
# Symlink DSL Parser
# =============================================================================

# Expand path variables
_expand_path() {
    local path="$1"
    local xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"
    local vscode_user

    case "$(uname -s)" in
        Darwin) vscode_user="${HOME}/Library/Application Support/Code/User" ;;
        *)      vscode_user="${xdg_config}/Code/User" ;;
    esac

    # Replace variables (longer names first to avoid partial matches)
    path="${path//\$VSCODE_USER/${vscode_user}}"
    path="${path//\$XDG_CONFIG/${xdg_config}}"
    path="${path//\$HOME/${HOME}}"

    echo "${path}"
}

# Check if platform specifier matches current platform
_platform_matches() {
    local platform="$1"

    case "${platform}" in
        @all|"") return 0 ;;
        @macos)  is_macos && return 0 ;;
        @linux)  is_linux && return 0 ;;
    esac
    return 1
}

# Process all symlink rules for a given action
# Args: $1 = backup_dir (for link action), $2 = action (link|unlink|status)
_process_symlink_rules() {
    local backup_dir="$1"
    local action="${2:-link}"

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Extract platform specifier if present
        local platform="@all"
        if [[ "${line}" =~ [[:space:]]@(macos|linux|all)[[:space:]]*$ ]]; then
            platform="@${BASH_REMATCH[1]}"
            line="${line% @*}"
            line="${line%"${line##*[![:space:]]}"}"
        fi

        # Skip if platform doesn't match
        _platform_matches "${platform}" || continue

        # Parse: TYPE SOURCE [-> DESTINATION]
        local rule_type source dest

        if [[ "${line}" =~ ^([a-z]+)[[:space:]]+(.+)[[:space:]]*-\>[[:space:]]*(.+)$ ]]; then
            # Explicit destination: "type source -> dest"
            rule_type="${BASH_REMATCH[1]}"
            source="${BASH_REMATCH[2]}"
            dest="${BASH_REMATCH[3]}"
        elif [[ "${line}" =~ ^([a-z]+)[[:space:]]+(.+)$ ]]; then
            # Implicit destination: "type source"
            rule_type="${BASH_REMATCH[1]}"
            source="${BASH_REMATCH[2]}"
            dest=""
        else
            warn "Invalid rule: ${line}"
            continue
        fi

        # Trim whitespace from parsed values
        source="${source%"${source##*[![:space:]]}"}"
        dest="${dest#"${dest%%[![:space:]]*}"}"

        # Expand variables in destination
        [[ -n "${dest}" ]] && dest=$(_expand_path "${dest}")

        # Execute based on rule type and action
        case "${rule_type}" in
            file)
                # Default destination: $HOME/$(basename source)
                [[ -z "${dest}" ]] && dest="${HOME}/$(basename "${source}")"

                case "${action}" in
                    link)   _link_file "${source}" "${dest}" "${backup_dir}" ;;
                    unlink) _unlink_single "${source}" "${dest}" ;;
                    status) _status_single "  ${source}" "${dest}" ;;
                esac
                ;;

            dir)
                # Default destination: $HOME/source
                [[ -z "${dest}" ]] && dest="${HOME}/${source}"

                case "${action}" in
                    link)   _link_directory "${source}" "${dest}" "${backup_dir}" ;;
                    unlink) _unlink_single "${source}" "${dest}" ;;
                    status) _status_single "  ${source}" "${dest}" ;;
                esac
                ;;

            children)
                # Default destination: $HOME/source
                [[ -z "${dest}" ]] && dest="${HOME}/${source}"

                case "${action}" in
                    link)   _link_directory_children "${source}" "${dest}" "${backup_dir}" ;;
                    unlink) _unlink_directory_children "${source}" "${dest}" ;;
                    status) _status_directory_children "${source}" "${dest}" ;;
                esac
                ;;

            *)
                warn "Unknown rule type: ${rule_type}"
                ;;
        esac

    done < <(get_symlink_rules)
}

# =============================================================================
# Dotfile Symlink Helpers
# =============================================================================

# Link a single file
# Args: $1 = source (relative to JSH_DIR), $2 = destination (absolute), $3 = backup_dir
_link_file() {
    local src_rel="$1"
    local dest="$2"
    local backup_dir="$3"
    local src="${JSH_DIR}/${src_rel}"
    local display_name="${src_rel}"

    [[ -e "${src}" ]] || { prefix_warn "${display_name} source not found, skipping"; return 0; }

    if [[ -L "${dest}" ]]; then
        local current
        current=$(readlink "${dest}")
        if [[ "${current}" == "${src}" ]]; then
            prefix_info "${display_name} already linked"
            return 0
        fi
        rm "${dest}"
    elif [[ -e "${dest}" ]]; then
        mkdir -p "${backup_dir}"
        if ! mv "${dest}" "${backup_dir}/" 2>/dev/null; then
            prefix_warn "${display_name} cannot be moved (immutable or permission denied), skipping"
            return 0
        fi
        prefix_info "Backed up ${display_name} to ${backup_dir}/"
    fi

    mkdir -p "$(dirname "${dest}")"
    ln -s "${src}" "${dest}"
    prefix_success "Linked ${display_name}"
}

# Link all children of a directory
# Args: $1 = source dir (relative to JSH_DIR), $2 = dest dir (absolute), $3 = backup_dir
_link_directory_children() {
    local src_rel="${1%/}"
    local dest_dir="${2%/}"
    local backup_dir="$3"
    local src_dir="${JSH_DIR}/${src_rel}"

    [[ -d "${src_dir}" ]] || { prefix_warn "${src_rel}/ source directory not found, skipping"; return 0; }

    mkdir -p "${dest_dir}"

    for child in "${src_dir}"/*; do
        [[ -e "${child}" ]] || continue
        local child_name
        child_name=$(basename "${child}")
        local child_dest="${dest_dir}/${child_name}"
        local child_src_rel="${src_rel}/${child_name}"

        if [[ -L "${child_dest}" ]]; then
            local current
            current=$(readlink "${child_dest}")
            if [[ "${current}" == "${child}" ]]; then
                prefix_info "${child_src_rel} already linked"
                continue
            fi
            rm "${child_dest}"
        elif [[ -e "${child_dest}" ]]; then
            mkdir -p "${backup_dir}"
            if ! mv "${child_dest}" "${backup_dir}/" 2>/dev/null; then
                prefix_warn "${child_src_rel} cannot be moved (immutable or permission denied), skipping"
                continue
            fi
            prefix_info "Backed up ${child_src_rel} to ${backup_dir}/"
        fi

        ln -s "${child}" "${child_dest}"
        prefix_success "Linked ${child_src_rel}"
    done
}

# Show status of a single symlink
_status_single() {
    local display_name="$1"
    local dest="$2"

    if [[ -L "${dest}" ]]; then
        local link_target resolved
        link_target=$(readlink "${dest}")
        resolved=$(readlink -f "${dest}" 2>/dev/null || readlink "${dest}")
        if [[ "${resolved}" == "${JSH_DIR}/"* ]] || [[ "${resolved}" == "${JSH_DIR}" ]]; then
            echo "${GREEN}✔${RST} ${display_name} -> ${link_target}"
        else
            echo "${YELLOW}~${RST} ${display_name} -> ${link_target}"
        fi
    elif [[ -e "${dest}" ]]; then
        echo "${YELLOW}~${RST} ${display_name} (exists, not linked)"
    else
        echo "${DIM}-${RST} ${display_name}"
    fi
}

# Link an entire directory
# Args: $1 = source (relative to JSH_DIR), $2 = destination (absolute), $3 = backup_dir
_link_directory() {
    local src_rel="$1"
    local dest="$2"
    local backup_dir="$3"
    local src="${JSH_DIR}/${src_rel}"
    local display_name="${src_rel}"

    [[ -d "${src}" ]] || { prefix_warn "${display_name}/ source not found, skipping"; return 0; }

    if [[ -L "${dest}" ]]; then
        local current
        current=$(readlink "${dest}")
        if [[ "${current}" == "${src}" ]]; then
            prefix_info "${display_name}/ already linked"
            return 0
        fi
        rm "${dest}"
    elif [[ -e "${dest}" ]]; then
        mkdir -p "${backup_dir}"
        if ! mv "${dest}" "${backup_dir}/" 2>/dev/null; then
            prefix_warn "${display_name}/ cannot be moved (immutable or permission denied), skipping"
            return 0
        fi
        prefix_info "Backed up ${display_name}/ to ${backup_dir}/"
    fi

    mkdir -p "$(dirname "${dest}")"
    ln -s "${src}" "${dest}"
    prefix_success "Linked ${display_name}/"
}

# Unlink a single file or directory
# Args: $1 = source (relative to JSH_DIR), $2 = destination (absolute)
_unlink_single() {
    local src_rel="$1"
    local dest="$2"

    if [[ -L "${dest}" ]]; then
        local resolved
        resolved=$(readlink -f "${dest}" 2>/dev/null || readlink "${dest}")
        if [[ "${resolved}" == "${JSH_DIR}/"* ]] || [[ "${resolved}" == "${JSH_DIR}" ]]; then
            rm "${dest}"
            prefix_success "Unlinked ${src_rel}"
        fi
    fi
}

# Unlink all children of a directory
# Args: $1 = source dir (relative to JSH_DIR), $2 = dest dir (absolute)
_unlink_directory_children() {
    local src_rel="${1%/}"
    local dest_dir="${2%/}"
    local src_dir="${JSH_DIR}/${src_rel}"

    [[ -d "${src_dir}" ]] || return 0

    for child in "${src_dir}"/*; do
        [[ -e "${child}" ]] || continue
        local child_name
        child_name=$(basename "${child}")
        local child_dest="${dest_dir}/${child_name}"
        local child_src_rel="${src_rel}/${child_name}"

        if [[ -L "${child_dest}" ]]; then
            local resolved
            resolved=$(readlink -f "${child_dest}" 2>/dev/null || readlink "${child_dest}")
            if [[ "${resolved}" == "${JSH_DIR}/"* ]] || [[ "${resolved}" == "${JSH_DIR}" ]]; then
                rm "${child_dest}"
                prefix_success "Unlinked ${child_src_rel}"
            fi
        fi
    done
}

# Show status of directory children
# Args: $1 = source dir (relative to JSH_DIR), $2 = dest dir (absolute)
_status_directory_children() {
    local src_rel="${1%/}"
    local dest_dir="${2%/}"
    local src_dir="${JSH_DIR}/${src_rel}"

    [[ -d "${src_dir}" ]] || return 0

    for child in "${src_dir}"/*; do
        [[ -e "${child}" ]] || continue
        local child_name
        child_name=$(basename "${child}")
        local child_dest="${dest_dir}/${child_name}"
        _status_single "  ${src_rel}/${child_name}" "${child_dest}"
    done
}

# =============================================================================
# Banner and Requirements
# =============================================================================

show_banner() {
    echo ""
    echo "${BOLD}${CYAN}"
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
    info "Checking requirements..."

    has git || die "git is required but not installed"

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
    echo "   ${CYAN}exec \$SHELL${RST}"
    echo ""
    echo "${BOLD}Useful commands:${RST}"
    echo "  ${CYAN}jsh status${RST}   - Show installation status"
    echo ""
}

# =============================================================================
# Load Project Management
# =============================================================================

# Source project management functions
# shellcheck disable=SC1091
source "${JSH_DIR}/src/projects.sh"

# =============================================================================
# Load Dependency Management
# =============================================================================

# Source dependency management functions (if available)
# shellcheck disable=SC1091
if [[ -f "${JSH_DIR}/src/deps.sh" ]]; then
    # Load core first for platform detection
    source "${JSH_DIR}/src/core.sh"
    source "${JSH_DIR}/src/deps.sh"
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
    ${CYAN}bootstrap${RST}   Clone/update repo and setup (for fresh installs)
    ${CYAN}setup${RST}       Setup jsh (link dotfiles)
    ${CYAN}teardown${RST}    Remove jsh symlinks and optionally the entire installation
    ${CYAN}upgrade${RST}     Check for plugin/binary updates and manage versions

${BOLD}SYMLINK COMMANDS:${RST}
    ${CYAN}link${RST}        Create symlinks for managed dotfiles
    ${CYAN}unlink${RST}      Remove symlinks (optionally restore backups)

${BOLD}INFO COMMANDS:${RST}
    ${CYAN}status${RST}      Show installation status, symlinks, and check for issues
    ${CYAN}doctor${RST}      Comprehensive health check with diagnostics and fixes

${BOLD}PROJECT COMMANDS:${RST}
    ${CYAN}project${RST}     Manage projects (sync, status, navigate, profiles)
    ${CYAN}profiles${RST}    Manage git profiles (shortcut for 'projects profile')

${BOLD}DEPENDENCY COMMANDS:${RST}
    ${CYAN}deps${RST}        Manage dependencies (status, check, refresh, doctor)
    ${CYAN}host${RST}        Manage remote host configurations for jssh

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
    PROJECTS          Space/newline separated list of git repos to sync
    PROJECTS_DIR      Directory for git projects (default: ~/projects)

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

    # Project directory
    local projects_dir
    read -r -p "Project directory location [~/projects]: " projects_dir
    projects_dir="${projects_dir:-$HOME/projects}"

    echo ""
    info "Saving configuration..."

    # Write configuration
    mkdir -p "${JSH_DIR}/local"
    cat > "${JSH_DIR}/local/.jshrc" << EOF
# Jsh Configuration (generated by setup --interactive)
export EDITOR="${editor}"
export JSH_VI_MODE=$([[ "${vi_mode,,}" =~ ^y ]] && echo 1 || echo 0)
export PROJECTS_DIR="${projects_dir}"
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

cmd_setup() {
    local interactive=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive) interactive=true; shift ;;
            *) shift ;;
        esac
    done

    show_banner
    check_requirements

    if [[ "$interactive" == true ]]; then
        _setup_interactive
        return
    fi

    info "Setting up jsh..."

    # Initialize submodules
    if [[ -d "${JSH_DIR}/.git" ]]; then
        info "Initializing submodules..."
        git -C "${JSH_DIR}" submodule update --init --depth 1 2>/dev/null || warn "Failed to init submodules"
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
        echo "${YELLOW}Are you sure you want to teardown jsh? T_T${RST}"
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

# Find broken symlinks in a directory
_find_broken_symlinks() {
    local search_dir="$1"
    local depth="${2:-1}"

    [[ -d "${search_dir}" ]] || return

    find "${search_dir}" -maxdepth "${depth}" -type l 2>/dev/null | while read -r link; do
        if [[ ! -e "${link}" ]]; then
            echo "${link}"
        fi
    done
}

# =============================================================================
# Key Dependencies Health Check
# =============================================================================
# Note: Platform detection is in core.sh, use $JSH_PLATFORM variable

# Check a bundled binary's health
# Returns: 0=healthy, 1=not bundled, 2=not in PATH, 3=wrong version in PATH, 4=runtime error
# Output: status message suitable for display
_check_bundled_binary() {
    local name="$1"
    local bin_dir="$2"
    local bundled="${bin_dir}/${name}"
    local resolved version_output exit_code

    # Check if bundled binary exists
    if [[ ! -x "${bundled}" ]]; then
        echo "not_bundled"
        return 1
    fi

    # Check what's being resolved via PATH
    resolved=$(command -v "${name}" 2>/dev/null)
    if [[ -z "${resolved}" ]]; then
        echo "not_in_path"
        return 2
    fi

    # Check if resolved binary is our bundled version
    if [[ "${resolved}" != "${bundled}" ]]; then
        echo "wrong_path:${resolved}"
        return 3
    fi

    # Run version check to verify runtime health
    # Capture both stdout and stderr, and the exit code
    case "${name}" in
        fzf)
            version_output=$("${bundled}" --version 2>&1)
            exit_code=$?
            if [[ ${exit_code} -eq 0 ]]; then
                echo "healthy:fzf ${version_output}"
                return 0
            fi
            ;;
        jq)
            version_output=$("${bundled}" --version 2>&1)
            exit_code=$?
            if [[ ${exit_code} -eq 0 ]]; then
                echo "healthy:jq ${version_output}"
                return 0
            fi
            ;;
        *)
            # Generic check for other binaries
            version_output=$("${bundled}" --version 2>&1 || "${bundled}" -v 2>&1 || true)
            exit_code=$?
            if [[ ${exit_code} -eq 0 ]]; then
                local ver_line
                ver_line=$(echo "${version_output}" | head -1)
                echo "healthy:${ver_line}"
                return 0
            fi
            ;;
    esac

    # Runtime error - try to identify the cause
    if [[ "${version_output}" == *"GLIBC"* ]]; then
        echo "runtime_error:glibc version mismatch"
    elif [[ "${version_output}" == *"cannot open shared object"* ]]; then
        local missing_lib
        missing_lib=$(echo "${version_output}" | grep -o 'lib[^:]*\.so[^ ]*' | head -1)
        echo "runtime_error:missing ${missing_lib:-shared library}"
    elif [[ "${version_output}" == *"Illegal instruction"* ]]; then
        echo "runtime_error:CPU instruction incompatibility"
    else
        echo "runtime_error:${version_output%%$'\n'*}"
    fi
    return 4
}

cmd_status() {
    local fix_issues=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix|-f)
                fix_issues=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    show_banner

    # Installation info
    echo "${CYAN}Installation:${RST}"
    echo "  Directory: ${JSH_DIR}"
    echo "  Version:   ${VERSION}"

    if [[ -d "${JSH_DIR}/.git" ]]; then
        local branch commit
        branch=$(git -C "${JSH_DIR}" branch --show-current 2>/dev/null || echo "unknown")
        commit=$(git -C "${JSH_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "  Branch:    ${branch}"
        echo "  Commit:    ${commit}"
    fi

    # Detailed symlink status
    echo ""
    echo "${CYAN}Symlinks:${RST}"
    _process_symlink_rules "" "status"

    # Shell info
    echo ""
    echo "${CYAN}Shell:${RST}"
    echo "  Current:   ${SHELL}"
    echo "  EDITOR:    ${EDITOR:-not set}"

    # Tool checks
    echo ""
    echo "${CYAN}Required tools:${RST}"
    local issues=0
    local required=("git" "curl")
    for tool in "${required[@]}"; do
        if has "${tool}"; then
            echo "  ${GREEN}✔${RST} ${tool}"
        else
            echo "  ${RED}✘${RST} ${tool} (required)"
            ((issues++))
        fi
    done

    if has zsh; then
        echo "  ${GREEN}✔${RST} zsh"
    else
        echo "  ${YELLOW}⚠${RST} zsh (recommended)"
    fi

    echo ""
    echo "${CYAN}Optional tools:${RST}"
    local recommended=("fzf" "fd" "rg" "bat" "eza" "tmux")
    for tool in "${recommended[@]}"; do
        if has "${tool}"; then
            echo "  ${GREEN}✔${RST} ${tool}"
        else
            echo "  ${DIM}-${RST} ${tool}"
        fi
    done

    # Key dependencies health check (bundled binaries)
    echo ""
    echo "${CYAN}Key dependencies:${RST}"
    local platform bin_dir
    platform="${JSH_PLATFORM:-unknown}"
    bin_dir="${JSH_DIR}/lib/bin/${platform}"

    if [[ "${platform}" == "unknown" ]]; then
        echo "  ${YELLOW}⚠${RST} Unknown platform, cannot check bundled binaries"
    elif [[ ! -d "${bin_dir}" ]]; then
        echo "  ${YELLOW}⚠${RST} No bundled binaries for ${platform}"
        prefix_info "Run: ${CYAN}${JSH_DIR}/src/deps.sh${RST} to download"
    else
        local key_deps=("fzf" "jq")
        for dep in "${key_deps[@]}"; do
            local result status_type status_detail
            result=$(_check_bundled_binary "${dep}" "${bin_dir}")
            status_type="${result%%:*}"
            status_detail="${result#*:}"

            case "${status_type}" in
                healthy)
                    echo "  ${GREEN}✔${RST} ${dep}: ${status_detail}"
                    ;;
                not_bundled)
                    echo "  ${DIM}-${RST} ${dep} (not bundled for ${platform})"
                    ;;
                not_in_path)
                    echo "  ${RED}✘${RST} ${dep}: bundled but not in PATH"
                    echo "      ${DIM}Expected: ${bin_dir}/${dep}${RST}"
                    ((issues++))
                    ;;
                wrong_path)
                    echo "  ${YELLOW}⚠${RST} ${dep}: using system version"
                    echo "      ${DIM}Active:   ${status_detail}${RST}"
                    echo "      ${DIM}Bundled:  ${bin_dir}/${dep}${RST}"
                    ;;
                runtime_error)
                    echo "  ${RED}✘${RST} ${dep}: ${status_detail}"
                    echo "      ${DIM}Binary: ${bin_dir}/${dep}${RST}"
                    ((issues++))
                    ;;
            esac
        done
    fi

    # Broken symlinks check
    echo ""
    echo "${CYAN}Broken symlinks:${RST}"
    local xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"
    local broken_links=()

    while IFS= read -r link; do
        [[ -n "${link}" ]] && broken_links+=("${link}")
    done < <(_find_broken_symlinks "${JSH_DIR}" 3)

    while IFS= read -r link; do
        [[ -n "${link}" ]] && broken_links+=("${link}")
    done < <(_find_broken_symlinks "${HOME}" 1)

    while IFS= read -r link; do
        [[ -n "${link}" ]] && broken_links+=("${link}")
    done < <(_find_broken_symlinks "${xdg_config}" 2)

    if [[ ${#broken_links[@]} -eq 0 ]]; then
        echo "  ${GREEN}✔${RST} None found"
    else
        for link in "${broken_links[@]}"; do
            local target
            target=$(readlink "${link}" 2>/dev/null || echo "unknown")
            if [[ "${fix_issues}" == true ]]; then
                rm -f "${link}"
                echo "  ${GREEN}✔${RST} Fixed: ${link}"
            else
                echo "  ${RED}✘${RST} ${link} -> ${target}"
                ((issues++))
            fi
        done

        if [[ "${fix_issues}" != true ]] && [[ ${#broken_links[@]} -gt 0 ]]; then
            echo ""
            info "Run ${CYAN}jsh status --fix${RST} to remove broken symlinks"
        fi
    fi

    # Summary
    echo ""
    if [[ "${issues}" -eq 0 ]]; then
        prefix_success "No issues found"
    else
        prefix_warn "${issues} issue(s) found"
    fi
}

cmd_link() {
    local backup_dir
    backup_dir="${HOME}/.jsh_backup/$(date +%Y%m%d_%H%M%S)"

    info "Creating symlinks..."
    _process_symlink_rules "${backup_dir}" "link"
    success "Symlinks created"
}

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
                echo "  ${CYAN}${backup}${RST} (${file_count} files) ${GREEN}[latest]${RST}"
            else
                echo "  ${backup} (${file_count} files)"
            fi
        done
        echo ""
        echo "Usage: ${CYAN}jsh unlink --restore${RST} or ${CYAN}jsh unlink --restore=NAME${RST}"
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
# Upgrade Command
# =============================================================================

cmd_upgrade() {
    info "Jsh Upgrade - Check for upstream updates"
    echo ""

    local check_only=false
    local component=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|-c) check_only=true; shift ;;
            plugins|binaries|all) component="$1"; shift ;;
            *) shift ;;
        esac
    done

    [[ -z "${component}" ]] && component="all"

    # Plugin upstream repos for reference
    declare -A PLUGIN_REPOS=(
        ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions"
        ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting"
        ["zsh-history-substring-search"]="https://github.com/zsh-users/zsh-history-substring-search"
        ["zsh-completions"]="https://github.com/zsh-users/zsh-completions"
    )

    if [[ "${component}" == "plugins" ]] || [[ "${component}" == "all" ]]; then
        info "Plugin Update Status"
        echo ""
        prefix_info "Embedded plugins are static snapshots. To check for upstream changes:"
        echo ""
        for plugin in "${!PLUGIN_REPOS[@]}"; do
            echo "  ${CYAN}${plugin}${RST}: ${PLUGIN_REPOS[$plugin]}"
        done
        echo ""
        prefix_info "To absorb updates manually:"
        echo "  1. Clone the upstream repo to a temp directory"
        echo "  2. Copy relevant .zsh files to lib/zsh-plugins/"
        echo "  3. Test and commit the changes"
        echo ""
    fi

    if [[ "${component}" == "binaries" ]] || [[ "${component}" == "all" ]]; then
        info "Binary Update Status"
        echo ""

        local versions_file="${JSH_DIR}/lib/bin/versions.json"
        if [[ -f "${versions_file}" ]]; then
            prefix_info "Current versions (from ${versions_file}):"
            echo ""
            if has jq; then
                jq -r 'to_entries[] | "  \(.key): v\(.value)"' "${versions_file}"
            else
                cat "${versions_file}"
            fi
            echo ""
        fi

        prefix_info "Binaries are managed via Renovate + GitHub Actions"
        echo "  - Renovate creates PRs when new versions are available"
        echo "  - GitHub Actions downloads binaries for all platforms on merge"
        echo ""
        prefix_info "To manually update binaries:"
        echo "  1. Edit lib/bin/versions.json with new versions"
        echo "  2. Run: ${JSH_DIR}/src/deps.sh"
        echo ""

        if [[ "${check_only}" == false ]]; then
            prefix_info "Checking for missing binaries..."
            local platform="${JSH_PLATFORM:-unknown}"

            local binaries=("fzf" "jq")
            local missing=()
            for bin in "${binaries[@]}"; do
                if [[ ! -x "${JSH_DIR}/lib/bin/${platform}/${bin}" ]]; then
                    missing+=("${bin}")
                fi
            done

            if [[ ${#missing[@]} -gt 0 ]]; then
                prefix_warn "Missing binaries for ${platform}: ${missing[*]}"
                echo ""
                prefix_info "Run to download: ${JSH_DIR}/src/deps.sh"
            else
                prefix_success "All binaries present for ${platform}"
            fi
        fi
    fi
}

# =============================================================================
# Dependency Commands
# =============================================================================

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
        *)
            echo "${BOLD}jsh deps${RST} - Dependency management"
            echo ""
            echo "${BOLD}USAGE:${RST}"
            echo "    jsh deps <command>"
            echo ""
            echo "${BOLD}COMMANDS:${RST}"
            echo "    ${CYAN}status${RST}        Show all dependencies and resolved strategies"
            echo "    ${CYAN}check${RST}         Re-run preflight checks"
            echo "    ${CYAN}refresh${RST}       Force re-download/rebuild dependencies"
            echo "    ${CYAN}doctor${RST}        Diagnose dependency issues"
            echo "    ${CYAN}capabilities${RST}  Show build capability profiles"
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

    # Check platform binaries
    echo ""
    info "Platform: ${JSH_PLATFORM:-unknown}"
    local platform="${JSH_PLATFORM:-unknown}"
    local bin_dir="${JSH_DIR}/lib/bin/${platform}"

    if [[ -d "${bin_dir}" ]]; then
        prefix_success "Binary directory exists: lib/bin/${platform}"

        local binaries=("fzf" "jq")
        for bin in "${binaries[@]}"; do
            if [[ -x "${bin_dir}/${bin}" ]]; then
                # Test if it runs
                if "${bin_dir}/${bin}" --version >/dev/null 2>&1; then
                    prefix_success "${bin} is executable and runs"
                else
                    prefix_error "${bin} exists but fails to run (likely glibc/library issue)"
                    ((issues++))

                    # Try to diagnose
                    local err_output
                    err_output=$("${bin_dir}/${bin}" --version 2>&1 || true)
                    if [[ "${err_output}" == *"GLIBC"* ]]; then
                        echo "      ${DIM}Cause: glibc version mismatch${RST}"
                        echo "      ${DIM}Solution: Use 'build' strategy or upgrade system${RST}"
                    fi
                fi
            else
                prefix_warn "${bin} not found in lib/bin/${platform}"
            fi
        done
    else
        prefix_warn "Binary directory not found for ${platform}"
        prefix_info "Run: jsh deps refresh"
    fi

    # Summary
    echo ""
    if [[ ${issues} -eq 0 ]]; then
        prefix_success "No issues found"
    else
        prefix_warn "${issues} issue(s) found"
    fi
}

# =============================================================================
# Host Commands
# =============================================================================

cmd_host() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "${subcmd}" in
        list|ls|l)
            cmd_host_list "$@"
            ;;
        status|s)
            cmd_host_status "$@"
            ;;
        refresh|r)
            cmd_host_refresh "$@"
            ;;
        reset)
            cmd_host_reset "$@"
            ;;
        *)
            echo "${BOLD}jsh host${RST} - Remote host management"
            echo ""
            echo "${BOLD}USAGE:${RST}"
            echo "    jsh host <command> [hostname]"
            echo ""
            echo "${BOLD}COMMANDS:${RST}"
            echo "    ${CYAN}list${RST}          List known remote hosts"
            echo "    ${CYAN}status${RST}        Show host capabilities and decisions"
            echo "    ${CYAN}refresh${RST}       Re-run remote preflight for a host"
            echo "    ${CYAN}reset${RST}         Clear cached decisions for a host"
            ;;
    esac
}

cmd_host_list() {
    local hosts_dir="${JSH_DIR}/local/hosts"

    echo ""
    echo "${BOLD}Known Remote Hosts${RST}"
    echo ""

    if [[ ! -d "${hosts_dir}" ]] || [[ -z "$(ls -A "${hosts_dir}" 2>/dev/null)" ]]; then
        prefix_info "No remote hosts configured yet"
        echo ""
        echo "Remote hosts are tracked when you use ${CYAN}jssh${RST} to connect."
        return 0
    fi

    for host_file in "${hosts_dir}"/*.json; do
        [[ -f "${host_file}" ]] || continue

        local hostname platform last_check
        if has jq; then
            hostname=$(jq -r '.hostname // "unknown"' "${host_file}")
            platform=$(jq -r '.platform // "unknown"' "${host_file}")
            last_check=$(jq -r '.last_check // "never"' "${host_file}")
        else
            hostname=$(basename "${host_file}" .json)
            platform="unknown"
            last_check="unknown"
        fi

        printf "  ${CYAN}%-30s${RST}  ${DIM}%s${RST}  %s\n" \
            "${hostname}" "${platform}" "${last_check}"
    done

    echo ""
}

cmd_host_status() {
    local hostname="${1:-}"

    if [[ -z "${hostname}" ]]; then
        error "Usage: jsh host status <hostname>"
        return 1
    fi

    local hosts_dir="${JSH_DIR}/local/hosts"
    local host_file

    # Try exact match first, then glob
    if [[ -f "${hosts_dir}/${hostname}.json" ]]; then
        host_file="${hosts_dir}/${hostname}.json"
    else
        # Try to find a match
        local matches=("${hosts_dir}"/*"${hostname}"*.json)
        if [[ ${#matches[@]} -eq 1 ]] && [[ -f "${matches[0]}" ]]; then
            host_file="${matches[0]}"
        elif [[ ${#matches[@]} -gt 1 ]]; then
            error "Multiple matches found. Be more specific:"
            for m in "${matches[@]}"; do
                echo "  $(basename "${m}" .json)"
            done
            return 1
        else
            error "Host not found: ${hostname}"
            prefix_info "Available hosts: jsh host list"
            return 1
        fi
    fi

    if ! has jq; then
        cat "${host_file}"
        return 0
    fi

    echo ""
    echo "${BOLD}Host: $(jq -r '.hostname' "${host_file}")${RST}"
    echo ""

    echo "${CYAN}System:${RST}"
    echo "  Platform:    $(jq -r '.platform // "unknown"' "${host_file}")"
    echo "  glibc:       $(jq -r '.glibc // "N/A"' "${host_file}")"
    echo "  Last check:  $(jq -r '.last_check // "never"' "${host_file}")"
    echo ""

    echo "${CYAN}Capabilities:${RST}"
    jq -r '.capabilities // {} | to_entries[] | "  \(if .value then "✔" else "✘" end) \(.key)"' "${host_file}"
    echo ""

    echo "${CYAN}Dependency Decisions:${RST}"
    jq -r '.decisions // {} | to_entries[] | "  \(.key): \(.value.strategy) (\(.value.reason // ""))"' "${host_file}"
    echo ""
}

cmd_host_refresh() {
    local hostname="${1:-}"

    if [[ -z "${hostname}" ]]; then
        error "Usage: jsh host refresh <hostname>"
        return 1
    fi

    info "Refreshing host: ${hostname}"
    warn "Remote host refresh requires jssh connection"
    prefix_info "Connect with: jssh ${hostname}"
    prefix_info "The preflight will run automatically on connection"
}

cmd_host_reset() {
    local hostname="${1:-}"

    if [[ -z "${hostname}" ]]; then
        error "Usage: jsh host reset <hostname>"
        return 1
    fi

    local hosts_dir="${JSH_DIR}/local/hosts"
    local host_file="${hosts_dir}/${hostname}.json"

    if [[ ! -f "${host_file}" ]]; then
        # Try glob match
        local matches=("${hosts_dir}"/*"${hostname}"*.json)
        if [[ ${#matches[@]} -eq 1 ]] && [[ -f "${matches[0]}" ]]; then
            host_file="${matches[0]}"
        else
            error "Host not found: ${hostname}"
            return 1
        fi
    fi

    local actual_hostname
    actual_hostname=$(basename "${host_file}" .json)

    read -r -p "Reset all decisions for ${actual_hostname}? [y/N] " confirm
    if [[ "${confirm}" =~ ^[Yy] ]]; then
        rm -f "${host_file}"
        success "Reset ${actual_hostname} - will re-prompt on next jssh connection"
    else
        info "Cancelled"
    fi
}

cmd_bootstrap() {
    show_banner
    check_requirements

    if [[ -d "${JSH_DIR}" ]]; then
        if [[ -d "${JSH_DIR}/.git" ]]; then
            info "Jsh already installed, updating..."
            git -C "${JSH_DIR}" pull --rebase || warn "Failed to pull updates"
        else
            die "${JSH_DIR} exists but is not a git repository"
        fi
    else
        info "Cloning Jsh..."
        git clone --depth 1 --branch "${JSH_BRANCH}" "${JSH_REPO}" "${JSH_DIR}"
    fi

    info "Initializing submodules..."
    git -C "${JSH_DIR}" submodule update --init --depth 1 || warn "Failed to init submodules"

    info "Setting up dotfiles..."
    cmd_link
    mkdir -p "${JSH_DIR}/local"

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
        project|proj|p)
            project "$@"
            ;;
        profile)
            project profile "$@"
            ;;
        projects)
            project -l -v
            ;;
        profiles)
            project profile list
            ;;
        deps|dependencies)
            cmd_deps "$@"
            ;;
        host|hosts)
            cmd_host "$@"
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
