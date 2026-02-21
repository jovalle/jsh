#!/usr/bin/env bash
# j.sh - Zoxide-like smart directory jumping for jsh
# shellcheck disable=SC2119,SC2120,SC2296,SC1009,SC1035,SC1072,SC1073
#
# This file should be sourced, not executed, so that `j` can change
# the current directory of the calling shell.
#
# Features:
#   - Frecency-based ranking (frequency + recency)
#   - Fallback to gitx projects for unvisited directories
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
#
# Database Management:
#   j --db         Show frecency database with scores
#   j -a|--add     Add current directory to frecency database
#   j --remove     Remove current directory from database
#   j --clean      Remove non-existent directories
#
# For git/project management, use gitx:
#   gitx clone <url>    Clone repository and cd into it
#   gitx create <name>  Create project and cd into it
#   gitx list           List all projects
#   gitx profile        Git profile management
#   gitx remote <name>  Open remote project in VS Code
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

# Directories to exclude from tracking (colon-separated)
J_EXCLUDE="${J_EXCLUDE:-${HOME}}"

# Decay factor for frecency (per hour)
# 0.99 means score decays by 1% per hour
_J_DECAY=0.99

# Minimum score before entry is removed
_J_MIN_SCORE=0.01

# Previous directory for `j -`
_J_PREV_DIR=""

# VS Code command (cached for performance)
_J_CODE_CMD=""

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

# Find code command (cached to avoid repeated lookups)
# Checks common paths to avoid shell hash table issues
_j_find_code() {
    # Return cached value if available
    if [[ -n "${_J_CODE_CMD}" ]]; then
        printf '%s' "${_J_CODE_CMD}"
        return 0
    fi

    local cmd

    # Check common local code locations FIRST (most common case)
    local code_paths=(
        "/opt/homebrew/bin/code" # macOS Homebrew (Apple Silicon)
        "/usr/local/bin/code"    # macOS Homebrew (Intel)
        "/usr/bin/code"          # Linux system
    )

    for cmd in "${code_paths[@]}"; do
        if [[ -x "${cmd}" ]]; then
            _J_CODE_CMD="${cmd}"
            printf '%s' "${cmd}"
            return 0
        fi
    done

    # Fallback to PATH lookup
    if command -v code &>/dev/null; then
        cmd="$(command -v code)"
        _J_CODE_CMD="${cmd}"
        printf '%s' "${cmd}"
        return 0
    fi

    # Last resort: Check VS Code Server (remote SSH sessions)
    # Use explicit directory check to avoid glob issues with zsh configs
    local vscode_server_dir="$HOME/.vscode-server/bin"
    if [[ -d "${vscode_server_dir}" ]]; then
        # Find most recent code binary without glob-in-subshell
        cmd=""
        for dir in "${vscode_server_dir}"/*/; do
            if [[ -x "${dir}bin/code" ]]; then
                cmd="${dir}bin/code"
            fi
        done
        if [[ -n "${cmd}" ]] && [[ -x "${cmd}" ]]; then
            _J_CODE_CMD="${cmd}"
            printf '%s' "${cmd}"
            return 0
        fi
    fi

    return 1
}

# Open code in current directory
_j_open_code() {
    local code_cmd
    code_cmd="$(_j_find_code)"
    if [[ -n "${code_cmd}" ]]; then
        # The code command is a bash script - ensure bash is found
        # Temporarily add /bin to PATH if bash isn't available (macOS edge case)
        if ! command -v bash &>/dev/null; then
            PATH="/bin:/usr/bin:$PATH" "${code_cmd}" .
        else
            "${code_cmd}" .
        fi
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS fallback: use open command directly
        open -a "Visual Studio Code" .
    else
        printf '%s!%s VS Code command not found.\n' "${C_WARN:-}" "${RST:-}" >&2
        return 1
    fi
}

# Check if current directory is a registered gitx project
_j_is_gitx_project() {
    command -v gitx &>/dev/null || return 1
    gitx is-project 2>/dev/null
}

# Get all gitx project paths (one per line, with ~ notation)
# Used as fallback when frecency database is empty
_j_get_gitx_projects() {
    command -v gitx &>/dev/null || return 1
    # Skip header lines, extract just the path column
    gitx list 2>/dev/null | awk 'NR>2 && /^~/ {print $1}'
}

# Interactive selection of remote projects
_j_select_remote() {
    local remotes=()

    while IFS= read -r name; do
        [[ -n "${name}" ]] && remotes+=("${name}")
    done < <(_gitx_list_remotes)

    if [[ ${#remotes[@]} -eq 0 ]]; then
        printf '%s!%s No remote projects configured.\n' "${C_WARN:-}" "${RST:-}" >&2
        printf '%sAdd remotes to:%s %s\n' "${DIM:-}" "${RST:-}" "${_GITX_REMOTE_CONFIG:-~/.jsh/local/projects.json}" >&2
        return 1
    fi

    local selected
    if command -v fzf &>/dev/null; then
        selected=$(printf '%s\n' "${remotes[@]}" | fzf --height=40% --reverse --prompt='remote> ')
    else
        # Fallback: numbered list
        printf '%sSelect remote project:%s\n' "${DIM:-}" "${RST:-}" >&2
        local i=1
        for name in "${remotes[@]}"; do
            printf '%s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" "${CYN:-}" "${name}" "${RST:-}" >&2
            (( i += 1 ))
        done
        printf '%sEnter number (1-%d):%s ' "${DIM:-}" "$(( i - 1 ))" "${RST:-}" >&2
        local choice
        read -r choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -lt "${i}" ]]; then
            selected="${remotes[$(( choice - 1 ))]}"
        fi
    fi

    [[ -n "${selected}" ]] && printf '%s' "${selected}"
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
# Parameters:
#   $@ - optional query terms to filter
#   _J_INTERACTIVE_INCLUDE_CURRENT - set to path to prepend "(current)" option
_j_interactive() {
    local entries=() paths=() count=0
    local include_current="${_J_INTERACTIVE_INCLUDE_CURRENT:-}"

    # Collect frecency entries (already sorted by score, highest first)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        entries+=("${line}")
        paths+=("${line#*|}")
        (( count += 1 ))
    done < <(_j_query "$@")

    # Collect gitx projects not already in frecency list
    local -A frecency_set=()
    local p
    for p in "${paths[@]}"; do
        frecency_set["${p}"]=1
    done

    local extra_paths=()
    while IFS= read -r gpath; do
        [[ -z "${gpath}" ]] && continue
        # Expand ~ to absolute path for internal use
        local abs_path="${gpath/#\~/$HOME}"
        [[ ! -d "${abs_path}" ]] && continue
        [[ "${abs_path}" == "${PWD}" ]] && continue
        # Skip if already in frecency list
        [[ -n "${frecency_set["${abs_path}"]:-}" ]] && continue
        # Filter by query if provided
        if [[ $# -eq 0 ]] || _j_matches "${abs_path}" "$@"; then
            extra_paths+=("${abs_path}")
        fi
    done < <(_j_get_gitx_projects)

    # Sort extra paths alphabetically and append to paths
    if [[ ${#extra_paths[@]} -gt 0 ]]; then
        while IFS= read -r sorted_path; do
            paths+=("${sorted_path}")
            (( count += 1 ))
        done < <(printf '%s\n' "${extra_paths[@]}" | sort)
    fi

    # No entries from either source
    if [[ ${count} -eq 0 ]]; then
        printf '%s!%s No directories found.\n' "${C_WARN:-}" "${RST:-}" >&2
        printf '%sStart navigating with cd to build your frecency database,%s\n' "${DIM:-}" "${RST:-}" >&2
        printf '%sor add projects with: gitx clone <url>%s\n' "${DIM:-}" "${RST:-}" >&2
        return 1
    fi

    # Prepend "(current)" option if requested and we have a path
    local current_marker=""
    if [[ -n "${include_current}" ]]; then
        current_marker="(current) $(_j_display_path "${include_current}")"
    fi

    local selected
    if command -v fzf &>/dev/null; then
        # Build display list
        local display_list=""
        [[ -n "${current_marker}" ]] && display_list="${current_marker}"$'\n'

        display_list+="$(printf '%s\n' "${paths[@]}" | while read -r p; do
            _j_display_path "$p"
            printf '\n'
        done)"

        # FZF selection
        local prompt="j> "

        selected=$(printf '%s' "${display_list}" | fzf --height=40% --reverse --no-sort \
            --prompt="${prompt}")

        # Handle "(current)" selection
        if [[ "${selected}" == "(current)"* ]]; then
            printf 'CURRENT:%s' "${include_current}"
            return 0
        fi

        # Convert back to absolute path if we displayed with ~
        if [[ "${selected}" == "~"* ]]; then
            selected="${HOME}${selected#\~}"
        fi
    else
        # Fallback: numbered list selection
        printf '%s%sSelect directory:%s\n' "${DIM:-}" "" "${RST:-}" >&2

        local i=1
        local -a display_paths=()

        # Show "(current)" option first if requested
        if [[ -n "${current_marker}" ]]; then
            display_paths+=("CURRENT:${include_current}")
            printf '%s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" \
                "${CYN:-}" "${current_marker}" "${RST:-}" >&2
            (( i += 1 ))
        fi

        local p
        for p in "${paths[@]}"; do
            [[ -z "${p}" ]] && continue
            [[ ${i} -gt 10 ]] && break
            display_paths+=("${p}")
            printf '%s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" \
                "${CYN:-}" "$(_j_display_path "${p}")" "${RST:-}" >&2
            (( i += 1 ))
        done

        printf '%sEnter number (1-%d):%s ' "${DIM:-}" "$(( i - 1 ))" "${RST:-}" >&2
        local choice
        read -r choice

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -lt "${i}" ]]; then
            # Use loop to find nth entry (portable across bash/zsh indexing)
            local n=0
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
            --db)
                _j_list
                return 0
                ;;
            --clean)
                _j_clean
                return 0
                ;;
            -l|--list)
                # Migration: -l moved to gitx list
                printf '%s!%s "j -l" has moved to "gitx list"\n' "${C_WARN:-}" "${RST:-}" >&2
                shift
                printf '%sRun:%s gitx list %s\n' "${DIM:-}" "${RST:-}" "$*" >&2
                return 1
                ;;
            -r|--remote)
                open_remote=true
                shift
                ;;
            -h|--help)
                cat << 'EOF'
j - Smart frecency-based directory jumping

Usage:
  j              Interactive directory selection (fzf)
  j <query>      Jump to best matching directory/project
  j <q1> <q2>    Multiple keywords (all must match)
  j -            Jump to previous directory
  j -v [query]   Verbose mode (show search steps)
  j -c [query]   Jump and open in VS Code (skip cd if already in project)
  j -r [query]   Open remote project in VS Code via SSH

Database Management:
  j --db         Show frecency database with scores
  j -a|--add     Add current directory to frecency database
  j --remove     Remove current directory from database
  j --clean      Remove non-existent directories
  j -h|--help    Show this help

For git/project management, use gitx:
  gitx clone <url>    Clone repository and cd into it
  gitx create <name>  Create project and cd into it
  gitx list           List all projects
  gitx profile        Git profile management

Aliases:
  p              Same as j

Environment:
  J_DATA         Path to data file (default: ~/.jsh/local/j.db)
  J_EXCLUDE      Colon-separated paths to exclude from tracking
  J_NO_HOOK      Set to disable automatic cd tracking

Remote projects are configured in ~/.jsh/local/projects.json under "remotes".

The 'j' command learns from your navigation patterns. Directories you
visit frequently and recently will rank higher in search results.
EOF
                return 0
                ;;
            -)
                # Jump to previous directory
                if [[ -n "${_J_PREV_DIR}" ]] && [[ -d "${_J_PREV_DIR}" ]]; then
                    _j_cd_hook "${_J_PREV_DIR}"
                    [[ "${open_code}" == true ]] && _j_open_code
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

    # Handle -r (remote) - always uses remote picker, never cd
    if [[ "${open_remote}" == true ]]; then
        local remote_name
        if [[ $# -gt 0 ]]; then
            remote_name="$1"
        else
            remote_name="$(_j_select_remote)"
        fi
        if [[ -n "${remote_name}" ]]; then
            _gitx_open_remote "${remote_name}"
        fi
        return $?
    fi

    # No arguments - interactive selection
    if [[ $# -eq 0 ]]; then
        local selected

        # Include "(current)" option when using -c and already in a gitx project
        if [[ "${open_code}" == true ]] && _j_is_gitx_project; then
            _J_INTERACTIVE_INCLUDE_CURRENT="${PWD}"
        else
            _J_INTERACTIVE_INCLUDE_CURRENT=""
        fi

        selected="$(_j_interactive)"
        unset _J_INTERACTIVE_INCLUDE_CURRENT

        if [[ -n "${selected}" ]]; then
            # Handle "(current)" selection - open VS Code in current dir
            if [[ "${selected}" == "CURRENT:"* ]]; then
                _j_open_code
            elif [[ "${open_code}" == true ]] && _j_is_gitx_project; then
                # Already in project - open selected in VS Code without cd
                local code_cmd
                code_cmd="$(_j_find_code)"
                [[ -n "${code_cmd}" ]] && "${code_cmd}" "${selected}"
            else
                _j_cd_hook "${selected}"
                [[ "${open_code}" == true ]] && _j_open_code
            fi
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
        if [[ "${open_code}" == true ]] && _j_is_gitx_project; then
            # Already in project - open target in VS Code without cd
            local code_cmd
            code_cmd="$(_j_find_code)"
            [[ -n "${code_cmd}" ]] && "${code_cmd}" "${path}"
        else
            _j_cd_hook "${path}"
            [[ "${open_code}" == true ]] && _j_open_code
        fi
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
            if [[ "${open_code}" == true ]] && _j_is_gitx_project; then
                local code_cmd
                code_cmd="$(_j_find_code)"
                [[ -n "${code_cmd}" ]] && "${code_cmd}" "${resolved}"
            else
                _j_cd_hook "${resolved}"
                [[ "${open_code}" == true ]] && _j_open_code
            fi
            return 0
        fi

        # Fallback 2: Try as gitx project name (fast - single lookup)
        if command -v gitx &>/dev/null; then
            [[ "${verbose}" == true ]] && printf '%s[j]%s Trying gitx project lookup for "%s"...\n' "${DIM:-}" "${RST:-}" "$1" >&2
            local project_path
            project_path=$(gitx path "$1" 2>/dev/null)
            if [[ -n "${project_path}" ]] && [[ -d "${project_path}" ]]; then
                [[ "${verbose}" == true ]] && printf '%s[j]%s Found project: %s%s%s\n' \
                    "${DIM:-}" "${RST:-}" "${CYN:-}" "$(_j_display_path "${project_path}")" "${RST:-}" >&2
                if [[ "${open_code}" == true ]] && _j_is_gitx_project; then
                    local code_cmd
                    code_cmd="$(_j_find_code)"
                    [[ -n "${code_cmd}" ]] && "${code_cmd}" "${project_path}"
                else
                    _j_cd_hook "${project_path}"
                    [[ "${open_code}" == true ]] && _j_open_code
                fi
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

        local completions=""

        if [[ ${COMP_CWORD} -eq 1 ]]; then
            # First arg: flags + project names from gitx for fallback
            completions="--db --clean"
            completions+=" $(gitx list 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
        fi

        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "${completions}" -- "${cur}"))
    }
    complete -F _j_completions j
    complete -F _j_completions p
fi
