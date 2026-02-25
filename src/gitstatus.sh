# gitstatus.sh - Git status functions for prompt (with async support)
# Pure shell, no external dependencies
# shellcheck disable=SC2034

[[ -n "${_JSH_GITSTATUS_LOADED:-}" ]] && return 0
_JSH_GITSTATUS_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

# Symbols (customizable)
GIT_SYMBOL_BRANCH="${GIT_SYMBOL_BRANCH:-}"
GIT_SYMBOL_DETACHED="${GIT_SYMBOL_DETACHED:-@}"
GIT_SYMBOL_MODIFIED="${GIT_SYMBOL_MODIFIED:-*}"
GIT_SYMBOL_STAGED="${GIT_SYMBOL_STAGED:-+}"
GIT_SYMBOL_UNTRACKED="${GIT_SYMBOL_UNTRACKED:-?}"
GIT_SYMBOL_STASH="${GIT_SYMBOL_STASH:-$}"
GIT_SYMBOL_AHEAD="${GIT_SYMBOL_AHEAD:-↑}"
GIT_SYMBOL_BEHIND="${GIT_SYMBOL_BEHIND:-↓}"
GIT_SYMBOL_DIVERGED="${GIT_SYMBOL_DIVERGED:-↕}"
GIT_SYMBOL_CLEAN="${GIT_SYMBOL_CLEAN:-✓}"
GIT_SYMBOL_CONFLICT="${GIT_SYMBOL_CONFLICT:-!}"

# Fallback symbols (no unicode)
GIT_SYMBOL_AHEAD_PLAIN="${GIT_SYMBOL_AHEAD_PLAIN:-^}"
GIT_SYMBOL_BEHIND_PLAIN="${GIT_SYMBOL_BEHIND_PLAIN:-v}"
GIT_SYMBOL_DIVERGED_PLAIN="${GIT_SYMBOL_DIVERGED_PLAIN:-*}"
GIT_SYMBOL_CLEAN_PLAIN="${GIT_SYMBOL_CLEAN_PLAIN:-ok}"

# Timeout for git operations (milliseconds)
GIT_PROMPT_TIMEOUT="${GIT_PROMPT_TIMEOUT:-2000}"

# Async update file (secure temp file creation)
# Guard to avoid re-creating on re-source; mktemp prevents TOCTOU race conditions
# Use absolute path for mktemp - PATH may not be fully set during early init
if [[ -z "${_GIT_ASYNC_FILE:-}" ]]; then
  _GIT_ASYNC_FILE=$(/usr/bin/mktemp "${JSH_CACHE_DIR:-${TMPDIR:-/tmp}}/.jsh_git_async.XXXXXX" 2>/dev/null || mktemp "${JSH_CACHE_DIR:-${TMPDIR:-/tmp}}/.jsh_git_async.XXXXXX")
fi

# =============================================================================
# Basic Git Functions
# =============================================================================

git_is_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

git_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

git_is_bare() {
    [[ "$(git rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]
}

# =============================================================================
# Branch / Reference Functions
# =============================================================================

git_branch() {
    # Returns branch name, or :SHA if detached
    local branch
    branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
    if [[ -n "${branch}" ]]; then
        echo "${branch}"
    else
        # Detached HEAD - show short SHA
        local sha
        sha="$(git rev-parse --short HEAD 2>/dev/null)"
        echo ":${sha:-unknown}"
    fi
}

git_branch_or_tag() {
    # Returns branch, @tag, or :SHA
    local branch tag sha
    branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
    if [[ -n "${branch}" ]]; then
        echo "${branch}"
        return
    fi
    # Check for tag
    tag="$(git describe --tags --exact-match HEAD 2>/dev/null)"
    if [[ -n "${tag}" ]]; then
        echo "@${tag}"
        return
    fi
    # Fallback to SHA
    sha="$(git rev-parse --short HEAD 2>/dev/null)"
    echo ":${sha:-unknown}"
}

# =============================================================================
# Status Detection Functions
# =============================================================================

git_is_dirty() {
    # Quick check - any uncommitted changes?
    ! git diff --quiet HEAD 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]
}

git_has_staged() {
    ! git diff --cached --quiet 2>/dev/null
}

git_has_unstaged() {
    ! git diff --quiet 2>/dev/null
}

git_has_untracked() {
    [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]
}

git_has_conflicts() {
    [[ -n "$(git ls-files --unmerged 2>/dev/null | head -1)" ]]
}

git_has_stash() {
    git rev-parse --verify --quiet refs/stash >/dev/null 2>&1
}

git_stash_count() {
    git stash list 2>/dev/null | wc -l | tr -d ' '
}

# =============================================================================
# Upstream Tracking Functions
# =============================================================================

git_upstream() {
    git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null
}

git_commits_ahead() {
    git rev-list --count '@{upstream}'..HEAD 2>/dev/null || echo 0
}

git_commits_behind() {
    git rev-list --count HEAD..'@{upstream}' 2>/dev/null || echo 0
}

git_ahead_behind() {
    # Returns "ahead:behind" counts
    local ahead behind
    ahead="$(git_commits_ahead)"
    behind="$(git_commits_behind)"
    echo "${ahead}:${behind}"
}

# =============================================================================
# Combined Status (Single Git Call - Fast)
# =============================================================================

git_status_fast() {
    # Get all status info in one git call
    # Returns: branch|staged|unstaged|untracked|ahead|behind|stash|conflicts

    git_is_repo || return 1

    local branch staged=0 unstaged=0 untracked=0 conflicts=0
    local ahead=0 behind=0 stash=0

    # Get branch
    branch="$(git_branch_or_tag)"

    # Parse porcelain status (fast, machine-readable)
    # NOTE: Avoid process substitution here.
    # Some zsh builds on appliance distros can crash in hook contexts when
    # evaluating '< <(...)' during prompt/precmd execution.
    local status_line status_output
    status_output="$(git status --porcelain=v1 -b 2>/dev/null)"
    while IFS= read -r status_line; do
        case "${status_line:0:2}" in
            "##")
                # Parse ahead/behind from branch line
                # Works in both bash (BASH_REMATCH) and zsh (match)
                if [[ -n "${ZSH_VERSION:-}" ]]; then
                    # Zsh: use $match array (quotes required for zsh regex)
                    # shellcheck disable=SC2076
                    if [[ "${status_line}" =~ '\[ahead ([0-9]+), behind ([0-9]+)\]' ]]; then
                        ahead="${match[1]}"
                        behind="${match[2]}"
                    elif [[ "${status_line}" =~ '\[ahead ([0-9]+)\]' ]]; then
                        ahead="${match[1]}"
                    elif [[ "${status_line}" =~ '\[behind ([0-9]+)\]' ]]; then
                        behind="${match[1]}"
                    fi
                else
                    # Bash: use BASH_REMATCH
                    if [[ "${status_line}" =~ \[ahead\ ([0-9]+),\ behind\ ([0-9]+)\] ]]; then
                        ahead="${BASH_REMATCH[1]}"
                        behind="${BASH_REMATCH[2]}"
                    elif [[ "${status_line}" =~ \[ahead\ ([0-9]+)\] ]]; then
                        ahead="${BASH_REMATCH[1]}"
                    elif [[ "${status_line}" =~ \[behind\ ([0-9]+)\] ]]; then
                        behind="${BASH_REMATCH[1]}"
                    fi
                fi
                ;;
            "??") ((untracked++)) ;;
            "UU"|"AA"|"DD"|"AU"|"UA"|"DU"|"UD") ((conflicts++)) ;;
            *)
                # First char = staged, second = unstaged
                [[ "${status_line:0:1}" != " " && "${status_line:0:1}" != "?" ]] && ((staged++))
                [[ "${status_line:1:1}" != " " && "${status_line:1:1}" != "?" ]] && ((unstaged++))
                ;;
        esac
    done <<< "${status_output}"

    # Check stash
    if git_has_stash; then
        stash="$(git_stash_count)"
    fi

    echo "${branch}|${staged}|${unstaged}|${untracked}|${ahead}|${behind}|${stash}|${conflicts}"
}

# =============================================================================
# Prompt String Generators
# =============================================================================

_git_use_unicode() {
    # Unicode is always available (LANG=en_US.UTF-8 set in .zshrc)
    # This only checks if user explicitly requested ASCII mode
    [[ "${GIT_PROMPT_ASCII:-0}" != "1" ]]
}

git_prompt_info() {
    # Plain text git status for prompt
    git_is_repo || return 0

    local info
    info="$(git_status_fast)"
    [[ -z "${info}" ]] && return 0

    local branch staged unstaged untracked ahead behind stash conflicts
    IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

    local result="${branch}"
    local dirty=""

    # Status indicators
    [[ "${staged}" -gt 0 ]] && dirty+="${GIT_SYMBOL_STAGED}"
    [[ "${unstaged}" -gt 0 ]] && dirty+="${GIT_SYMBOL_MODIFIED}"
    [[ "${untracked}" -gt 0 ]] && dirty+="${GIT_SYMBOL_UNTRACKED}"
    [[ "${conflicts}" -gt 0 ]] && dirty+="${GIT_SYMBOL_CONFLICT}"

    [[ -n "${dirty}" ]] && result+="${dirty}"

    # Ahead/behind
    if _git_use_unicode; then
        [[ "${ahead}" -gt 0 && "${behind}" -gt 0 ]] && result+=" ${GIT_SYMBOL_DIVERGED}${ahead}/${behind}"
        [[ "${ahead}" -gt 0 && "${behind}" -eq 0 ]] && result+=" ${GIT_SYMBOL_AHEAD}${ahead}"
        [[ "${behind}" -gt 0 && "${ahead}" -eq 0 ]] && result+=" ${GIT_SYMBOL_BEHIND}${behind}"
    else
        [[ "${ahead}" -gt 0 && "${behind}" -gt 0 ]] && result+=" ${GIT_SYMBOL_DIVERGED_PLAIN}${ahead}/${behind}"
        [[ "${ahead}" -gt 0 && "${behind}" -eq 0 ]] && result+=" ${GIT_SYMBOL_AHEAD_PLAIN}${ahead}"
        [[ "${behind}" -gt 0 && "${ahead}" -eq 0 ]] && result+=" ${GIT_SYMBOL_BEHIND_PLAIN}${behind}"
    fi

    # Stash
    [[ "${stash}" -gt 0 ]] && result+=" ${GIT_SYMBOL_STASH}${stash}"

    echo "${result}"
}

git_prompt_info_colored() {
    # Colored git status for prompt
    # Uses raw escape codes - caller must wrap for prompt safety
    git_is_repo || return 0

    local info
    info="$(git_status_fast)"
    [[ -z "${info}" ]] && return 0

    local branch staged unstaged untracked ahead behind stash conflicts
    IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

    # Branch color (clean=green, dirty=yellow, conflicts=red)
    local branch_color="${C_OK:-}"
    if [[ "${conflicts}" -gt 0 ]]; then
        branch_color="${C_ERR:-}"
    elif [[ "${staged}" -gt 0 || "${unstaged}" -gt 0 || "${untracked}" -gt 0 ]]; then
        branch_color="${C_WARN:-}"
    fi

    local result="${branch_color}${branch}${RST:-}"

    # Status indicators (each with own color)
    [[ "${staged}" -gt 0 ]] && result+="${C_OK:-}${GIT_SYMBOL_STAGED}${RST:-}"
    [[ "${unstaged}" -gt 0 ]] && result+="${C_WARN:-}${GIT_SYMBOL_MODIFIED}${RST:-}"
    [[ "${untracked}" -gt 0 ]] && result+="${C_MUTED:-}${GIT_SYMBOL_UNTRACKED}${RST:-}"
    [[ "${conflicts}" -gt 0 ]] && result+="${C_ERR:-}${GIT_SYMBOL_CONFLICT}${RST:-}"

    # Ahead/behind (cyan)
    local ab_sym_ahead ab_sym_behind ab_sym_div
    if _git_use_unicode; then
        ab_sym_ahead="${GIT_SYMBOL_AHEAD}"
        ab_sym_behind="${GIT_SYMBOL_BEHIND}"
        ab_sym_div="${GIT_SYMBOL_DIVERGED}"
    else
        ab_sym_ahead="${GIT_SYMBOL_AHEAD_PLAIN}"
        ab_sym_behind="${GIT_SYMBOL_BEHIND_PLAIN}"
        ab_sym_div="${GIT_SYMBOL_DIVERGED_PLAIN}"
    fi

    if [[ "${ahead}" -gt 0 && "${behind}" -gt 0 ]]; then
        result+=" ${C_INFO:-}${ab_sym_div}${ahead}/${behind}${RST:-}"
    elif [[ "${ahead}" -gt 0 ]]; then
        result+=" ${C_INFO:-}${ab_sym_ahead}${ahead}${RST:-}"
    elif [[ "${behind}" -gt 0 ]]; then
        result+=" ${C_INFO:-}${ab_sym_behind}${behind}${RST:-}"
    fi

    # Stash (purple/accent)
    [[ "${stash}" -gt 0 ]] && result+=" ${C_ACCENT:-}${GIT_SYMBOL_STASH}${stash}${RST:-}"

    echo "${result}"
}

# =============================================================================
# Async Git Status (for instant prompt)
# =============================================================================

_git_async_worker() {
    # Background worker that computes git status
    local output_file="$1"
    local status
    status="$(git_prompt_info_colored 2>/dev/null)"
    echo "${status}" > "${output_file}"
}

git_async_start() {
    # Start async git status computation
    git_is_repo || return 1

    # Clean up old file
    rm -f "${_GIT_ASYNC_FILE}" 2>/dev/null

    # Run in background
    _git_async_worker "${_GIT_ASYNC_FILE}" &
    _GIT_ASYNC_PID=$!
}

git_async_result() {
    # Get async result (returns immediately, may be empty)
    if [[ -f "${_GIT_ASYNC_FILE}" ]]; then
        cat "${_GIT_ASYNC_FILE}"
        rm -f "${_GIT_ASYNC_FILE}" 2>/dev/null
        unset _GIT_ASYNC_PID
    fi
}

git_async_wait() {
    # Wait for async result with timeout
    local timeout="${1:-${GIT_PROMPT_TIMEOUT}}"
    local elapsed=0
    local interval=10  # ms

    while [[ ! -f "${_GIT_ASYNC_FILE}" ]] && [[ "${elapsed}" -lt "${timeout}" ]]; do
        sleep 0.01 2>/dev/null || sleep 1
        ((elapsed += interval))
    done

    git_async_result
}

git_async_cleanup() {
    # Clean up async resources
    [[ -n "${_GIT_ASYNC_PID:-}" ]] && kill "${_GIT_ASYNC_PID}" 2>/dev/null
    rm -f "${_GIT_ASYNC_FILE}" 2>/dev/null
    unset _GIT_ASYNC_PID
}

# Cleanup on shell exit
trap 'git_async_cleanup' EXIT

# =============================================================================
# Repo Size Heuristics (for skipping slow repos)
# =============================================================================

_git_is_large_repo() {
    # Heuristic: check if repo might be slow
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1

    # Check if index is large (>50MB suggests large repo)
    local index_file="${git_dir}/index"
    if [[ -f "${index_file}" ]]; then
        local size
        if [[ "${JSH_OS}" == "macos" ]]; then
            size=$(stat -f%z "${index_file}" 2>/dev/null || echo 0)
        else
            size=$(stat -c%s "${index_file}" 2>/dev/null || echo 0)
        fi
        [[ "${size}" -gt 52428800 ]] && return 0
    fi

    return 1
}

git_prompt_smart() {
    # Smart prompt: async for large repos, sync for small
    if _git_is_large_repo; then
        # Use cached result or empty for large repos
        git_async_start
        echo ""  # Prompt will update async
    else
        # Sync for small repos (fast)
        git_prompt_info_colored
    fi
}
