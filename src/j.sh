#!/usr/bin/env bash
# j.sh - Zoxide-like smart directory jumping for jsh
# shellcheck disable=SC2119,SC2120,SC2296,SC1009,SC1035,SC1072,SC1073
#
# This file should be sourced, not executed, so that `j` can change
# the current directory of the calling shell.
#
# Features:
#   - Frecency-based ranking (frequency + recency)
#   - Integration with jsh projects (jgit)
#   - Fuzzy matching with multiple keywords
#   - FZF interactive selection (with fallback)
#   - Automatic tracking via cd hook
#
# Usage:
#   j              Interactive directory selection
#   j <query>      Jump to best matching directory
#   j <q1> <q2>    Multiple keywords (all must match)
#   j -           Jump to previous directory
#   j --add       Add current directory to database
#   j --remove    Remove current directory from database
#   j --list      List all directories with scores
#   j --clean     Remove non-existent directories
#
# Environment:
#   J_DATA        Path to data file (default: ~/.jsh/local/j.db)
#   J_EXCLUDE     Colon-separated paths to exclude from tracking
#   J_NO_HOOK     Set to disable automatic cd tracking

[[ -n "${_JSH_J_LOADED:-}" ]] && return 0
_JSH_J_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

# Data file location (in jsh local directory, not tracked by git)
J_DATA="${J_DATA:-${JSH_DIR:-${HOME}/.jsh}/local/j.db}"

# Remote projects config file
_J_REMOTE_CONFIG="${JSH_DIR:-${HOME}/.jsh}/local/projects.json"

# Directories to exclude from tracking (colon-separated)
J_EXCLUDE="${J_EXCLUDE:-${HOME}}"

# Decay factor for frecency (per hour)
# 0.99 means score decays by 1% per hour
_J_DECAY=0.99

# Minimum score before entry is removed
_J_MIN_SCORE=0.01

# Previous directory for `j -`
_J_PREV_DIR=""

# =============================================================================
# Shell Compatibility Layer
# =============================================================================

# Detect shell for compatibility
_J_SHELL="bash"
[[ -n "${ZSH_VERSION:-}" ]] && _J_SHELL="zsh"

# Lowercase using bash 4+ parameter expansion
_j_lowercase() {
    printf '%s' "${1,,}"
}

# =============================================================================
# Database Functions (file-based, no associative arrays for portability)
# =============================================================================

# Ensure data directory exists
_j_ensure_dir() {
    local dir
    dir="$(dirname "${J_DATA}")"
    [[ -d "${dir}" ]] || mkdir -p "${dir}"
}

# Get current timestamp in hours since epoch
_j_now() {
    printf '%s' "$(( $(command -p date +%s) / 3600 ))"
}

# Add/update a directory in the database
# Format: path|count|last_access_hours
_j_add() {
    local path="$1"

    # Resolve to absolute path
    path="$(cd "${path}" 2>/dev/null && pwd -P)" || return 1

    # Check exclusions
    local exclude IFS_OLD="${IFS}"
    IFS=':'
    for exclude in ${J_EXCLUDE}; do
        [[ "${path}" == "${exclude}" ]] && { IFS="${IFS_OLD}"; return 0; }
    done
    IFS="${IFS_OLD}"

    # Don't track very short paths (/, /tmp, etc.)
    [[ "${#path}" -lt 4 ]] && return 0

    _j_ensure_dir

    local now
    now="$(_j_now)"

    # Use awk to update or add entry atomically
    if [[ -f "${J_DATA}" ]]; then
        awk -F'|' -v path="${path}" -v now="${now}" '
            BEGIN { found=0; OFS="|" }
            $1 == path { print path, $2+1, now; found=1; next }
            { print }
            END { if (!found) print path, 1, now }
        ' "${J_DATA}" > "${J_DATA}.tmp" && mv "${J_DATA}.tmp" "${J_DATA}"
    else
        printf '%s|1|%s\n' "${path}" "${now}" > "${J_DATA}"
    fi
}

# Remove a directory from the database
_j_remove() {
    local path="$1"
    path="$(cd "${path}" 2>/dev/null && pwd -P)" || path="$1"

    [[ ! -f "${J_DATA}" ]] && return 1

    local count_before count_after
    count_before=$(wc -l < "${J_DATA}" | tr -d ' ')

    awk -F'|' -v path="${path}" '$1 != path' "${J_DATA}" > "${J_DATA}.tmp"
    mv "${J_DATA}.tmp" "${J_DATA}"

    count_after=$(wc -l < "${J_DATA}" | tr -d ' ')
    [[ "${count_after}" -lt "${count_before}" ]]
}

# Clean non-existent directories from database
_j_clean() {
    [[ ! -f "${J_DATA}" ]] && { printf '%sDatabase is empty%s\n' "${C_MUTED:-}" "${RST:-}"; return 0; }

    local removed=0 total=0
    local tmpfile="${J_DATA}.tmp"

    while IFS='|' read -r path count time; do
        [[ -z "${path}" ]] && continue
        (( total++ ))
        if [[ -d "${path}" ]]; then
            printf '%s|%s|%s\n' "${path}" "${count}" "${time}"
        else
            (( removed++ ))
        fi
    done < "${J_DATA}" > "${tmpfile}"

    mv "${tmpfile}" "${J_DATA}"

    if [[ ${removed} -gt 0 ]]; then
        printf '%s✓%s Removed %s%d%s non-existent directories (kept %d)\n' \
            "${C_OK:-}" "${RST:-}" "${C_GIT:-}" "${removed}" "${RST:-}" "$(( total - removed ))"
    else
        printf '%s✓%s Database is clean (%s%d%s directories)\n' \
            "${C_OK:-}" "${RST:-}" "${C_GIT:-}" "${total}" "${RST:-}"
    fi
}

# =============================================================================
# Remote Project Functions
# =============================================================================

# Get remote project info from config
# Arguments:
#   $1 - Project name
# Output: JSON object with host, path, user, etc. or empty if not found
_j_get_remote() {
    local name="$1"

    if [[ ! -f "${_J_REMOTE_CONFIG}" ]]; then
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        printf 'jq is required for remote projects\n' >&2
        return 1
    fi

    jq -r --arg name "${name}" '.remotes[$name] // empty' "${_J_REMOTE_CONFIG}" 2>/dev/null || true
}

# List all remote project names
# Output: Project names, one per line
_j_list_remotes() {
    if [[ ! -f "${_J_REMOTE_CONFIG}" ]]; then
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        return 0
    fi

    jq -r '.remotes | keys[]' "${_J_REMOTE_CONFIG}" 2>/dev/null || true
}

# Open a remote project in VS Code Remote SSH
# Arguments:
#   $1 - Project name
# Returns: 0 on success, 1 on failure
_j_open_remote() {
    local name="$1"
    local remote_info host remote_path user ssh_key

    remote_info="$(_j_get_remote "${name}")"

    if [[ -z "${remote_info}" ]]; then
        printf '%s✗%s No remote project found: %s%s%s\n' "${C_ERR:-}" "${RST:-}" "${C_GIT:-}" "${name}" "${RST:-}" >&2
        printf '\n%sAvailable remote projects:%s\n' "${DIM:-}" "${RST:-}" >&2
        _j_list_remotes | while read -r proj; do
            printf '  %s%s%s\n' "${CYN:-}" "${proj}" "${RST:-}" >&2
        done
        return 1
    fi

    host=$(printf '%s' "${remote_info}" | jq -r '.host')
    remote_path=$(printf '%s' "${remote_info}" | jq -r '.path')
    user=$(printf '%s' "${remote_info}" | jq -r '.user // empty')
    ssh_key=$(printf '%s' "${remote_info}" | jq -r '.ssh_key // empty')

    if [[ -z "${host}" ]] || [[ -z "${remote_path}" ]]; then
        printf '%s✗%s Invalid remote project config for: %s%s%s\n' "${C_ERR:-}" "${RST:-}" "${C_GIT:-}" "${name}" "${RST:-}" >&2
        return 1
    fi

    # Build SSH target (user@host or just host)
    local ssh_target="${host}"
    [[ -n "${user}" ]] && ssh_target="${user}@${host}"

    # Open in VS Code Remote SSH
    printf '%sOpening remote:%s %s%s%s (%s%s%s:%s%s%s)\n' \
        "${C_INFO:-}" "${RST:-}" \
        "${C_GIT:-}" "${name}" "${RST:-}" \
        "${C_MUTED:-}" "${ssh_target}" "${RST:-}" \
        "${CYN:-}" "${remote_path}" "${RST:-}"
    [[ -n "${ssh_key}" ]] && printf '  %sKey:%s %s\n' "${DIM:-}" "${RST:-}" "${ssh_key}"

    code --remote "ssh-remote+${ssh_target}" "${remote_path}"
}

# =============================================================================
# Matching and Ranking
# =============================================================================

# Calculate frecency score using awk
# Score = count * decay^(hours_since_access)
_j_calculate_scores() {
    local now
    now="$(_j_now)"

    [[ ! -f "${J_DATA}" ]] && return

    awk -F'|' -v now="${now}" -v decay="${_J_DECAY}" -v min="${_J_MIN_SCORE}" '
        {
            path = $1
            count = $2
            last = $3
            hours = now - last
            if (hours < 0) hours = 0
            score = count * (decay ^ hours)
            if (score >= min) {
                printf "%.4f|%s\n", score, path
            }
        }
    ' "${J_DATA}"
}

# Check if path matches all query terms (case-insensitive)
_j_matches() {
    local path="$1"
    shift

    local path_lower query
    path_lower="$(_j_lowercase "${path}")"

    for query in "$@"; do
        local query_lower
        query_lower="$(_j_lowercase "${query}")"
        # Check if query is a substring
        case "${path_lower}" in
            *"${query_lower}"*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Get all matching directories with scores, sorted by score
# Output: score|path (one per line)
_j_query() {
    local results="" line score path

    # Add entries from j database
    while IFS='|' read -r score path; do
        [[ -z "${path}" ]] && continue
        [[ ! -d "${path}" ]] && continue
        [[ "${path}" == "${PWD}" ]] && continue

        # Check if matches query
        if [[ $# -eq 0 ]] || _j_matches "${path}" "$@"; then
            results="${results}${score}|${path}"$'\n'
        fi
    done < <(_j_calculate_scores)

    # Also include jsh projects that match
    if command -v jgit &>/dev/null; then
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            path=$(jgit path "${name}" 2>/dev/null) || continue
            [[ -z "${path}" ]] && continue
            [[ ! -d "${path}" ]] && continue
            [[ "${path}" == "${PWD}" ]] && continue

            # Check if already in database (grep for exact path match)
            if [[ ! -f "${J_DATA}" ]] || ! grep -q "^${path}|" "${J_DATA}" 2>/dev/null; then
                if [[ $# -eq 0 ]] || _j_matches "${path}" "$@"; then
                    results="${results}1.0000|${path}"$'\n'
                fi
            fi
        done < <(jgit list 2>/dev/null | awk '{print $1}')
    fi

    # Sort by score descending
    printf '%s' "${results}" | command -p sort -t'|' -k1 -rn
}

# =============================================================================
# Display Helpers
# =============================================================================

# Display path with ~ for home
_j_display_path() {
    local path="$1"
    if [[ "${path}" == "${HOME}"* ]]; then
        printf '~%s' "${path#"${HOME}"}"
    else
        printf '%s' "${path}"
    fi
}

# List all directories with scores
_j_list() {
    local entries=() count=0

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        entries+=("${line}")
        (( count++ ))
    done < <(_j_query)

    if [[ ${count} -eq 0 ]]; then
        printf '%sNo directories tracked yet.%s\n' "${C_MUTED:-}" "${RST:-}"
        printf '%sUse cd to navigate and directories will be automatically added.%s\n' "${DIM:-}" "${RST:-}"
        return 0
    fi

    printf '%s%-8s  %s%s\n' "${DIM:-}" "SCORE" "PATH" "${RST:-}"
    printf '%s%s%s\n' "${DIM:-}" "$(printf '%60s' '' | tr ' ' '-')" "${RST:-}"

    local entry score path
    for entry in "${entries[@]}"; do
        score="${entry%%|*}"
        path="${entry#*|}"
        printf '%s%-8s%s  %s%s%s\n' \
            "${C_GIT:-}" "${score}" "${RST:-}" \
            "${CYN:-}" "$(_j_display_path "${path}")" "${RST:-}"
    done
}

# =============================================================================
# Interactive Selection
# =============================================================================

# Interactive directory selection with fzf
_j_interactive() {
    local entries=() paths=() count=0

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        entries+=("${line}")
        paths+=("${line#*|}")
        (( count++ ))
    done < <(_j_query "$@")

    if [[ ${count} -eq 0 ]]; then
        printf '%s!%s No matching directories found.\n' "${C_WARN:-}" "${RST:-}" >&2
        return 1
    fi

    local selected
    if command -v fzf &>/dev/null; then
        # FZF with preview
        selected=$(printf '%s\n' "${paths[@]}" | while read -r p; do
            _j_display_path "$p"
        done | fzf --height=40% --reverse --no-sort \
            --preview='ls -la {}' \
            --preview-window='right:50%:wrap' \
            --prompt='j> ')

        # Convert back to absolute path if we displayed with ~
        if [[ "${selected}" == "~"* ]]; then
            selected="${HOME}${selected#\~}"
        fi
    else
        # Fallback: numbered list selection
        printf '%sSelect directory:%s\n' "${DIM:-}" "${RST:-}" >&2
        local i=1 entry
        for entry in "${entries[@]:0:10}"; do
            printf '  %s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" \
                "${CYN:-}" "$(_j_display_path "${entry#*|}")" "${RST:-}" >&2
            (( i++ ))
        done

        printf '%sEnter number (1-%d):%s ' "${DIM:-}" "$(( i - 1 ))" "${RST:-}" >&2
        local choice
        read -r choice

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -lt "${i}" ]]; then
            selected="${paths[$(( choice - 1 ))]}"
        else
            return 1
        fi
    fi

    [[ -n "${selected}" ]] && printf '%s' "${selected}"
}

# =============================================================================
# CD Hook
# =============================================================================

# Hook to track directory changes
_j_cd_hook() {
    _J_PREV_DIR="${PWD}"
    builtin cd "$@" || return $?

    # Track the new directory (unless disabled)
    # Note: Explicitly pass PATH to background job - zsh subshells during init
    # may not inherit PATH correctly
    if [[ -z "${J_NO_HOOK:-}" ]]; then
        if [[ "${_J_SHELL}" == "zsh" ]]; then
            # zsh: &! backgrounds and disowns silently (no job control output)
            ( PATH="$PATH" _j_add "${PWD}" ) &>/dev/null &!
        else
            # bash: background and disown separately
            ( PATH="$PATH" _j_add "${PWD}" ) &>/dev/null &
            disown 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# Main j Function
# =============================================================================

j() {
    local open_code=false
    local open_remote=false

    # Parse flags first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--code)
                open_code=true
                shift
                ;;
            -r|--remote)
                open_remote=true
                shift
                ;;
            -a|--add)
                _j_add "${PWD}"
                printf '%s✓%s Added: %s%s%s\n' "${C_OK:-}" "${RST:-}" "${CYN:-}" "$(_j_display_path "${PWD}")" "${RST:-}"
                return 0
                ;;
            --remove)
                if _j_remove "${PWD}"; then
                    printf '%s✓%s Removed: %s%s%s\n' "${C_OK:-}" "${RST:-}" "${CYN:-}" "$(_j_display_path "${PWD}")" "${RST:-}"
                else
                    printf '%s!%s Not in database: %s%s%s\n' "${C_WARN:-}" "${RST:-}" "${CYN:-}" "$(_j_display_path "${PWD}")" "${RST:-}" >&2
                    return 1
                fi
                return 0
                ;;
            -l|--list)
                _j_list
                return 0
                ;;
            --clean)
                _j_clean
                return 0
                ;;
            -h|--help)
                cat << 'EOF'
j - Smart directory jumping (zoxide-like)

Usage:
  j              Interactive directory selection
  j <query>      Jump to best matching directory
  j <q1> <q2>    Multiple keywords (all must match)
  j -            Jump to previous directory
  j -c <query>   Jump to directory and open in VS Code
  j -r <name>    Open remote project in VS Code (no cd)

Commands:
  j --add        Add current directory to database
  j --remove     Remove current directory from database
  j --list       List all directories with scores
  j --clean      Remove non-existent directories
  j --help       Show this help

Environment:
  J_DATA         Path to data file (default: ~/.jsh/local/j.db)
  J_EXCLUDE      Colon-separated paths to exclude from tracking
  J_NO_HOOK      Set to disable automatic cd tracking

Remote projects are configured in ~/.jsh/local/projects.json

The 'j' command learns from your navigation patterns. Directories you
visit frequently and recently will rank higher in search results.

Integration:
  - jsh projects are automatically included in search results
  - Use 'jgit' for explicit project navigation
EOF
                return 0
                ;;
            -)
                # Jump to previous directory
                if [[ -n "${_J_PREV_DIR}" ]] && [[ -d "${_J_PREV_DIR}" ]]; then
                    _j_cd_hook "${_J_PREV_DIR}"
                    [[ "${open_code}" == true ]] && code .
                else
                    printf '%s!%s No previous directory\n' "${C_WARN:-}" "${RST:-}" >&2
                    return 1
                fi
                return 0
                ;;
            -*)
                printf '%s✗%s Unknown option: %s%s%s\n' "${C_ERR:-}" "${RST:-}" "${BOLD:-}" "$1" "${RST:-}" >&2
                return 1
                ;;
            *)
                break
                ;;
        esac
    done

    # Handle remote project mode (-r flag with name)
    if [[ "${open_remote}" == true ]]; then
        if [[ $# -eq 0 ]]; then
            printf '%sUsage:%s j -r <project-name>\n' "${DIM:-}" "${RST:-}" >&2
            printf '\n%sAvailable remote projects:%s\n' "${DIM:-}" "${RST:-}" >&2
            _j_list_remotes | while read -r proj; do
                printf '  %s%s%s\n' "${CYN:-}" "${proj}" "${RST:-}" >&2
            done
            return 1
        fi
        _j_open_remote "$1"
        return $?
    fi

    # No arguments - interactive selection
    if [[ $# -eq 0 ]]; then
        local selected
        selected="$(_j_interactive)"
        if [[ -n "${selected}" ]]; then
            _j_cd_hook "${selected}"
            [[ "${open_code}" == true ]] && code .
        fi
        return 0
    fi

    # Query mode - find best match
    local entries=() count=0

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        entries+=("${line}")
        (( count++ ))
    done < <(_j_query "$@")

    if [[ ${count} -eq 0 ]]; then
        # No match in j database - try as project name
        if command -v jgit &>/dev/null; then
            local project_path
            project_path=$(jgit path "$1" 2>/dev/null)
            if [[ -n "${project_path}" ]] && [[ -d "${project_path}" ]]; then
                _j_cd_hook "${project_path}"
                [[ "${open_code}" == true ]] && code .
                return 0
            fi
        fi

        printf '%s!%s No matching directory: %s%s%s\n' "${C_WARN:-}" "${RST:-}" "${BOLD:-}" "$*" "${RST:-}" >&2
        return 1
    fi

    # Jump to highest scoring match
    local best="${entries[0]}"
    local path="${best#*|}"

    _j_cd_hook "${path}"
    [[ "${open_code}" == true ]] && code .
    return 0
}

# =============================================================================
# Initialization
# =============================================================================

# Override cd to track directories
# Preserve existing cd wrapper functionality (create dirs if needed)
_j_has_original_cd=false

if declare -f cd &>/dev/null; then
    # There's an existing cd function - wrap it using shell-specific methods
    if [[ "${_J_SHELL}" == "zsh" ]]; then
        # zsh: save function body and recreate with new name
        _j_cd_body="$(functions -c cd 2>/dev/null)"
        if [[ -n "${_j_cd_body}" ]]; then
            eval "_j_original_cd ${_j_cd_body#cd }" 2>/dev/null && _j_has_original_cd=true
        fi
        unset _j_cd_body
    else
        # bash: use eval with sed to rename the function
        if eval "$(declare -f cd | sed '1s/^cd /_j_original_cd /')" 2>/dev/null; then
            _j_has_original_cd=true
        fi
    fi
fi

if [[ "${_j_has_original_cd}" == true ]]; then
    cd() {
        _J_PREV_DIR="${PWD}"
        _j_original_cd "$@" || return $?

        if [[ -z "${J_NO_HOOK:-}" ]]; then
            if [[ "${_J_SHELL}" == "zsh" ]]; then
                ( PATH="$PATH" _j_add "${PWD}" ) &>/dev/null &!
            else
                ( PATH="$PATH" _j_add "${PWD}" ) &>/dev/null &
                disown 2>/dev/null || true
            fi
        fi
    }
else
    # No existing wrapper or copy failed - use builtin
    cd() {
        _J_PREV_DIR="${PWD}"
        builtin cd "$@" || return $?

        if [[ -z "${J_NO_HOOK:-}" ]]; then
            if [[ "${_J_SHELL}" == "zsh" ]]; then
                ( PATH="$PATH" _j_add "${PWD}" ) &>/dev/null &!
            else
                ( PATH="$PATH" _j_add "${PWD}" ) &>/dev/null &
                disown 2>/dev/null || true
            fi
        fi
    }
fi

unset _j_has_original_cd

# Migrate from old ~/.marks file if it exists
_j_migrate_marks() {
    local marks_file="${HOME}/.marks"
    [[ -f "${marks_file}" ]] || return 0
    [[ -f "${J_DATA}" ]] && return 0  # Don't migrate if j.db exists

    printf 'Migrating bookmarks from ~/.marks to j database...\n'

    _j_ensure_dir

    local now count=0
    now="$(_j_now)"

    while IFS=':' read -r name path; do
        [[ -z "${path}" ]] && continue
        [[ ! -d "${path}" ]] && continue

        # Give migrated bookmarks a base count of 10
        printf '%s|10|%s\n' "${path}" "${now}" >> "${J_DATA}"
        (( count++ ))
    done < "${marks_file}"

    if [[ ${count} -gt 0 ]]; then
        printf 'Migrated %d bookmarks. Original file preserved at ~/.marks\n' "${count}"
    fi
}

# Run migration on first load
_j_migrate_marks
