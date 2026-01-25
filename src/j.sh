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
#   j <query>      Jump to best matching directory/project
#   j <q1> <q2>    Multiple keywords (all must match)
#   j -            Jump to previous directory
#   j -v [query]   Verbose mode (show search steps)
#   j -c [query]   Jump and open in VS Code
#   j -r <name>    Open remote project in VS Code
#
# Project Management:
#   j add <url> [name]   Clone repository and cd into it
#   j create <name>      Create project directory and cd into it
#   j profile [cmd]      Git profile management
#   j update             Safe pull with stash and rebase
#   j -l|--list [-v]     List all projects (via jgit list)
#
# Database Management:
#   j --db         Show frecency database with scores
#   j -a|--add     Add current directory to frecency database
#   j --remove     Remove current directory from database
#   j --clean      Remove non-existent directories
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

# Lowercase: zsh uses ${(L)}, bash 4+ uses ${,,}
if [[ "${_J_SHELL}" == "zsh" ]]; then
    _j_lowercase() { printf '%s' "${(L)1}"; }
else
    _j_lowercase() { printf '%s' "${1,,}"; }
fi

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
        command -p awk -F'|' -v path="${path}" -v now="${now}" '
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

    command -p awk -F'|' -v path="${path}" '$1 != path' "${J_DATA}" > "${J_DATA}.tmp"
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
        (( total += 1 ))
        if [[ -d "${path}" ]]; then
            printf '%s|%s|%s\n' "${path}" "${count}" "${time}"
        else
            (( removed += 1 ))
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

    command -p awk -F'|' -v now="${now}" -v decay="${_J_DECAY}" -v min="${_J_MIN_SCORE}" '
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
        (( count += 1 ))
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
        (( count += 1 ))
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
        local -a display_paths=()
        for entry in "${entries[@]}"; do
            [[ -z "${entry}" ]] && continue
            [[ ${i} -gt 10 ]] && break
            display_paths+=("${entry#*|}")
            printf '  %s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" \
                "${CYN:-}" "$(_j_display_path "${entry#*|}")" "${RST:-}" >&2
            (( i += 1 ))
        done

        printf '%sEnter number (1-%d):%s ' "${DIM:-}" "$(( i - 1 ))" "${RST:-}" >&2
        local choice
        read -r choice

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -lt "${i}" ]]; then
            # Use loop to find nth entry (portable across bash/zsh indexing)
            local n=0 p
            for p in "${display_paths[@]}"; do
                [[ -z "${p}" ]] && continue
                (( n += 1 ))
                if [[ ${n} -eq ${choice} ]]; then
                    selected="${p}"
                    break
                fi
            done
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
            # bash: background inside subshell to suppress job notification
            ( PATH="$PATH" _j_add "${PWD}" & ) &>/dev/null
        fi
    fi
}

# =============================================================================
# Path Resolution Fallback
# =============================================================================

# Try to resolve a query as a directory path
# Checks: relative path, ~/query, ~/.$query
# Output: resolved absolute path, or empty
_j_resolve_path() {
    local query="$1"

    # Try as relative path from PWD
    if [[ -d "${PWD}/${query}" ]]; then
        (cd "${PWD}/${query}" && pwd -P)
        return 0
    fi

    # Try as path under HOME (e.g., "jsh" → ~/.jsh won't match, but ".jsh" → ~/.jsh will)
    if [[ -d "${HOME}/${query}" ]]; then
        (cd "${HOME}/${query}" && pwd -P)
        return 0
    fi

    # Try with dot prefix under HOME (e.g., "jsh" → ~/.jsh)
    if [[ "${query}" != .* ]] && [[ -d "${HOME}/.${query}" ]]; then
        (cd "${HOME}/.${query}" && pwd -P)
        return 0
    fi

    return 1
}

# =============================================================================
# Main j Function
# =============================================================================

j() {
    local open_code=false
    local open_remote=false
    local verbose=false

    # Parse flags first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                verbose=true
                shift
                ;;
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
                shift
                jgit list "$@"
                return $?
                ;;
            --db)
                _j_list
                return 0
                ;;
            --clean)
                _j_clean
                return 0
                ;;
            -h|--help)
                cat << 'EOF'
j - Smart directory jumping + project management

Usage:
  j              Interactive directory selection (fzf)
  j <query>      Jump to best matching directory/project
  j <q1> <q2>    Multiple keywords (all must match)
  j -            Jump to previous directory
  j -v [query]   Verbose mode (show search steps)
  j -c [query]   Jump and open in VS Code
  j -r <name>    Open remote project in VS Code (no cd)

Project Management:
  j add <url> [name]   Clone repository and cd into it
  j create <name>      Create project directory and cd into it
  j profile [cmd]      Git profile management
  j update             Safe pull with stash and rebase
  j -l|--list [-v]     List all projects (via jgit list)

Database Management:
  j --db         Show frecency database with scores
  j -a|--add     Add current directory to frecency database
  j --remove     Remove current directory from database
  j --clean      Remove non-existent directories
  j -h|--help    Show this help

Aliases:
  p              Same as j
  jj             Same as j profile

Environment:
  J_DATA         Path to data file (default: ~/.jsh/local/j.db)
  J_EXCLUDE      Colon-separated paths to exclude from tracking
  J_NO_HOOK      Set to disable automatic cd tracking

Remote projects are configured in ~/.jsh/local/projects.json

The 'j' command learns from your navigation patterns. Directories you
visit frequently and recently will rank higher in search results.
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

    # Subcommand handling (project management)
    case "${1:-}" in
        add|create)
            # Clone/create project then cd into it via temp file
            local cd_file
            cd_file=$(mktemp "${TMPDIR:-/tmp}/jgit-cd.XXXXXX")

            JSH_WRAPPER=1 JSH_CD_FILE="${cd_file}" jgit "$@"
            local ret=$?

            if [[ $ret -eq 0 && -f "${cd_file}" ]]; then
                local target_dir
                target_dir=$(cat "${cd_file}")
                if [[ -n "${target_dir}" && -d "${target_dir}" ]]; then
                    _j_cd_hook "${target_dir}" || ret=1
                    [[ "${open_code}" == true ]] && code .
                fi
            fi

            rm -f "${cd_file}"
            return $ret
            ;;
        profile)
            shift
            jgit profile "$@"
            return $?
            ;;
        update)
            shift
            jgit update "$@"
            return $?
            ;;
    esac

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
    [[ "${verbose}" == true ]] && printf '%s[j]%s Searching frecency database (%s)...\n' "${DIM:-}" "${RST:-}" "${J_DATA}" >&2

    local best="" count=0 line

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ -z "${best}" ]] && best="${line}"
        (( count += 1 ))
    done < <(_j_query "$@")

    if [[ ${count} -gt 0 ]]; then
        local path="${best#*|}"
        [[ "${verbose}" == true ]] && printf '%s[j]%s Found %d match(es) in database, best: %s%s%s\n' \
            "${DIM:-}" "${RST:-}" "${count}" "${CYN:-}" "$(_j_display_path "${path}")" "${RST:-}" >&2
        _j_cd_hook "${path}"
        [[ "${open_code}" == true ]] && code .
        return 0
    fi

    # Fallbacks only apply for single-keyword queries
    if [[ $# -eq 1 ]]; then
        [[ "${verbose}" == true ]] && printf '%s[j]%s No match in database, trying path resolution...\n' "${DIM:-}" "${RST:-}" >&2

        # Fallback 1: Try resolving query as a directory path
        local resolved
        resolved="$(_j_resolve_path "$1")"
        if [[ -n "${resolved}" ]] && [[ -d "${resolved}" ]]; then
            [[ "${verbose}" == true ]] && printf '%s[j]%s Resolved path: %s%s%s\n' \
                "${DIM:-}" "${RST:-}" "${CYN:-}" "$(_j_display_path "${resolved}")" "${RST:-}" >&2
            _j_cd_hook "${resolved}"
            [[ "${open_code}" == true ]] && code .
            return 0
        fi

        # Fallback 2: Try as jgit project name (fast - single lookup)
        if command -v jgit &>/dev/null; then
            [[ "${verbose}" == true ]] && printf '%s[j]%s Trying jgit project lookup for "%s"...\n' "${DIM:-}" "${RST:-}" "$1" >&2
            local project_path
            project_path=$(jgit path "$1" 2>/dev/null)
            if [[ -n "${project_path}" ]] && [[ -d "${project_path}" ]]; then
                [[ "${verbose}" == true ]] && printf '%s[j]%s Found project: %s%s%s\n' \
                    "${DIM:-}" "${RST:-}" "${CYN:-}" "$(_j_display_path "${project_path}")" "${RST:-}" >&2
                _j_cd_hook "${project_path}"
                [[ "${open_code}" == true ]] && code .
                return 0
            fi
        fi
    fi

    [[ "${verbose}" == true ]] && printf '%s[j]%s No matching directory found for: %s%s%s\n' \
        "${DIM:-}" "${RST:-}" "${BOLD:-}" "$*" "${RST:-}" >&2
    printf '%s!%s No matching directory: %s%s%s\n' "${C_WARN:-}" "${RST:-}" "${BOLD:-}" "$*" "${RST:-}"
    return 1
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
                # bash: background inside subshell to suppress job notification
                ( PATH="$PATH" _j_add "${PWD}" & ) &>/dev/null
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
                # bash: background inside subshell to suppress job notification
                ( PATH="$PATH" _j_add "${PWD}" & ) &>/dev/null
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
        (( count += 1 ))
    done < "${marks_file}"

    if [[ ${count} -gt 0 ]]; then
        printf 'Migrated %d bookmarks. Original file preserved at ~/.marks\n' "${count}"
    fi
}

# Run migration on first load
_j_migrate_marks

# Bash completion for j command
if [[ -n "${BASH_VERSION:-}" ]]; then
    _j_completions() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local first="${COMP_WORDS[1]:-}"

        local completions=""

        if [[ ${COMP_CWORD} -eq 1 ]]; then
            # First arg: subcommands + project names + flags
            completions="add create profile update"
            completions+=" $(jgit list 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
        elif [[ "${first}" == "profile" ]]; then
            completions="list status check docs $(jgit profile list 2>/dev/null | awk 'NR>2 {print $1}' | tr '\n' ' ')"
        fi

        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "${completions}" -- "${cur}"))
    }
    complete -F _j_completions j
    complete -F _j_completions p

    # jj is 'j profile' - complete with profile args directly
    _jj_completions() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local completions="list status check docs"
        completions+=" $(jgit profile list 2>/dev/null | awk 'NR>2 {print $1}' | tr '\n' ' ')"
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "${completions}" -- "${cur}"))
    }
    complete -F _jj_completions jj
fi
