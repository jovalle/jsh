#!/usr/bin/env bash
# symlinks.sh - Dotfile symlink DSL and management
# Provides symlink rules definition and processing
#
# Dependencies: core.sh (colors, helpers, is_macos, is_linux)
# shellcheck disable=SC2034

# Load guard
[[ -n "${_JSH_SYMLINKS_LOADED:-}" ]] && return 0
_JSH_SYMLINKS_LOADED=1

# =============================================================================
# Symlink Rules DSL
# =============================================================================
# Defines which dotfiles to symlink and their destinations.
#
# Syntax:
#   TYPE SOURCE [-> DESTINATION] [@platform]
#
# Types:
#   file      - Single file symlink (default dest: $HOME/basename)
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
file .bash_profile
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

# Note: Neovim/LazyVim symlink is created during nvim installation (not here)

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
                    status) _status_single "${source}" "${dest}" ;;
                esac
                ;;

            dir)
                # Default destination: $HOME/source
                [[ -z "${dest}" ]] && dest="${HOME}/${source}"

                case "${action}" in
                    link)   _link_directory "${source}" "${dest}" "${backup_dir}" ;;
                    unlink) _unlink_single "${source}" "${dest}" ;;
                    status) _status_single "${source}" "${dest}" ;;
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
# Symlink Operation Helpers
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
        local link_target resolved jsh_dir_resolved
        link_target=$(readlink "${dest}")
        resolved=$(readlink -f "${dest}" 2>/dev/null || readlink "${dest}")
        # Canonicalize JSH_DIR for comparison (handles paths like /foo/tests/..)
        jsh_dir_resolved=$(cd "${JSH_DIR}" && pwd -P)
        if [[ "${resolved}" == "${jsh_dir_resolved}/"* ]] || [[ "${resolved}" == "${jsh_dir_resolved}" ]]; then
            echo "  ${GRN}✓${RST} ${display_name} -> ${link_target}"
        else
            echo "  ${YLW}~${RST} ${display_name} -> ${link_target}"
        fi
    elif [[ -e "${dest}" ]]; then
        echo "  ${YLW}~${RST} ${display_name} (exists, not linked)"
    else
        echo "  ${DIM}-${RST} ${display_name}"
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
        _status_single "${src_rel}/${child_name}" "${child_dest}"
    done
}
