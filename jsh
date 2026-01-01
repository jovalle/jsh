#!/usr/bin/env bash
# jsh - J Shell Management CLI
# Install, configure, and manage your shell environment
#
# Quick Install:
#   curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/jsh | bash

set -euo pipefail

VERSION="1.1.0"
JSH_REPO="${JSH_REPO:-https://github.com/jovalle/jsh.git}"
JSH_BRANCH="${JSH_BRANCH:-main}"
JSH_DIR="${JSH_DIR:-${HOME}/.jsh}"

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
file .p10k.zsh
file .gitconfig
file .inputrc
file .tmux.conf
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

    [[ -e "${src}" ]] || { prefix_warn "${display_name} source not found"; return 1; }

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
        mv "${dest}" "${backup_dir}/"
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

    [[ -d "${src_dir}" ]] || { prefix_warn "${src_rel}/ source directory not found"; return 1; }

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
            mv "${child_dest}" "${backup_dir}/"
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

    [[ -d "${src}" ]] || { prefix_warn "${display_name}/ source not found"; return 1; }

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
        mv "${dest}" "${backup_dir}/"
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
    echo "2. (Optional) Configure p10k:"
    echo ""
    echo "   ${CYAN}p10k configure${RST}"
    echo ""
    echo "${BOLD}Useful commands:${RST}"
    echo "  ${CYAN}jsh status${RST}   - Show installation status"
    echo ""
}

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

${BOLD}SYMLINK COMMANDS:${RST}
    ${CYAN}link${RST}        Create symlinks for managed dotfiles
    ${CYAN}unlink${RST}      Remove symlinks (optionally restore backups)

${BOLD}INFO COMMANDS:${RST}
    ${CYAN}status${RST}      Show installation status, symlinks, and check for issues

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
    JSH_DIR         Jsh installation directory (default: ~/.jsh)
    JSH_REPO        Git repository URL (default: github.com/jovalle/jsh)
    JSH_BRANCH      Branch to install (default: main)

HELP
}

cmd_version() {
    echo "jsh ${VERSION}"
}

cmd_setup() {
    show_banner
    check_requirements

    info "Setting up jsh..."

    # Initialize submodules
    if [[ -d "${JSH_DIR}/.git" ]]; then
        info "Initializing submodules..."
        git -C "${JSH_DIR}" submodule update --init --depth 1 || warn "Failed to init submodules"
    fi

    # Create symlinks
    cmd_link

    # Create local config directory
    mkdir -p "${JSH_DIR}/local"

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
    local recommended=("fzf" "fd" "rg" "bat" "eza" "nvim" "tmux")
    for tool in "${recommended[@]}"; do
        if has "${tool}"; then
            echo "  ${GREEN}✔${RST} ${tool}"
        else
            echo "  ${DIM}-${RST} ${tool}"
        fi
    done

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

        if [[ "${relative_path}" == "nvim" ]] || [[ "${relative_path}" == nvim/* ]]; then
            if [[ "${relative_path}" == "nvim" ]]; then
                dest="${XDG_CONFIG_HOME:-${HOME}/.config}/nvim"
            else
                continue
            fi
        else
            dest="${HOME}/${filename}"
        fi

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

    info "Initializing submodules (p10k)..."
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
        bootstrap)
            cmd_bootstrap "$@"
            ;;
        *)
            error "Unknown command: ${cmd}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
