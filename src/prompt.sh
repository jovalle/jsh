#!/usr/bin/env bash
# prompt.sh - High-performance cached prompt system
# Features: Git caching (~20x faster), command duration, Python/Kube context
# shellcheck disable=SC2034,SC2016,SC2153

[[ -n "${_JSH_PROMPT_LOADED:-}" ]] && return 0
_JSH_PROMPT_LOADED=1

# =============================================================================
# Icons - Unicode (UTF-8 assumed via LANG setup in core.sh)
# =============================================================================

_ICON_PROMPT="❯"
_ICON_FAIL="✘"
_ICON_BEHIND="⇣"
_ICON_AHEAD="⇡"
_ICON_ELLIPSIS="…"
_ICON_STASH="*"
_ICON_CONFLICT="~"
_ICON_STAGED="+"
_ICON_UNSTAGED="!"
_ICON_UNTRACKED="?"
_ICON_BRANCH=""   # nerd font git branch (fallback: no icon)
_ICON_TAG=""      # nerd font tag (fallback: no icon)
_ICON_DETACHED="➦"

# =============================================================================
# Git Status Cache - State Variables
# =============================================================================

# Note: Simple assignment works in all Bash versions (3.2+)
# We don't need 'typeset -g' since these are top-level declarations (already global)
_P_GIT_CACHE_PWD=""
_P_GIT_CACHE_VALID=0
_P_GIT_INVALIDATE=0

# Git status cached values
_P_GIT_BRANCH=""
_P_GIT_STAGED=0
_P_GIT_UNSTAGED=0
_P_GIT_UNTRACKED=0
_P_GIT_AHEAD=0
_P_GIT_BEHIND=0
_P_GIT_STASH=0
_P_GIT_CONFLICTS=0

# Command timing state
_P_CMD_START=0
_P_CMD_DURATION=0
_P_EXIT_CODE=0

# Context state
_P_USER=""
_P_HOST=""

# =============================================================================
# Colors - Use core.sh colors wrapped for prompt use
# =============================================================================

if [[ -n "${ZSH_VERSION:-}" ]]; then
    # Zsh uses %{ %} for zero-width sequences
    _C_PROMPT_OK="%{${C_GIT_CLEAN}%}"
    _C_PROMPT_ERR="%{${C_ERROR}%}"
    _C_DIR="%{${BOLD}${CYN}%}"
    _C_GIT_CLEAN="%{${C_GIT_CLEAN}%}"
    _C_GIT_DIRTY="%{${C_GIT_DIRTY}%}"
    _C_GIT_STAGED="%{${C_GIT_STAGED}%}"
    _C_GIT_UNTRACKED="%{${C_GIT_UNTRACKED}%}"
    _C_GIT_CONFLICT="%{${C_GIT_CONFLICT}%}"
    _C_GIT_STASH="%{${C_GIT_STASH}%}"
    _C_GIT_AHEAD="%{${C_GIT_AHEAD}%}"
    _C_GIT_BEHIND="%{${C_GIT_BEHIND}%}"
    _C_STATUS_ERR="%{${C_ERROR}%}"
    _C_TIME="%{${C_MUTED}%}"
    _C_JOBS="%{${C_GIT_CLEAN}%}"
    _C_CONTEXT="%{${YLW}%}"
    _C_CONTEXT_ROOT="%{${BOLD}${YLW}%}"
    _C_DURATION="%{${C_DURATION}%}"
    _C_PYTHON="%{${C_PYTHON}%}"
    _C_KUBE="%{${C_KUBE}%}"
    _C_RST="%{${RST}%}"
else
    # Bash uses \[ \] for zero-width sequences
    _C_PROMPT_OK="\\[${C_GIT_CLEAN}\\]"
    _C_PROMPT_ERR="\\[${C_ERROR}\\]"
    _C_DIR="\\[${BOLD}${CYN}\\]"
    _C_GIT_CLEAN="\\[${C_GIT_CLEAN}\\]"
    _C_GIT_DIRTY="\\[${C_GIT_DIRTY}\\]"
    _C_GIT_STAGED="\\[${C_GIT_STAGED}\\]"
    _C_GIT_UNTRACKED="\\[${C_GIT_UNTRACKED}\\]"
    _C_GIT_CONFLICT="\\[${C_GIT_CONFLICT}\\]"
    _C_GIT_STASH="\\[${C_GIT_STASH}\\]"
    _C_GIT_AHEAD="\\[${C_GIT_AHEAD}\\]"
    _C_GIT_BEHIND="\\[${C_GIT_BEHIND}\\]"
    _C_STATUS_ERR="\\[${C_ERROR}\\]"
    _C_TIME="\\[${C_MUTED}\\]"
    _C_JOBS="\\[${C_GIT_CLEAN}\\]"
    _C_CONTEXT="\\[${YLW}\\]"
    _C_CONTEXT_ROOT="\\[${BOLD}${YLW}\\]"
    _C_DURATION="\\[${C_DURATION}\\]"
    _C_PYTHON="\\[${C_PYTHON}\\]"
    _C_KUBE="\\[${C_KUBE}\\]"
    _C_RST="\\[${RST}\\]"
fi

# =============================================================================
# Git Cache Validation
# =============================================================================

_prompt_git_cache_valid() {
    # Cache is invalid if:
    # 1. Explicitly invalidated (command ran that might affect git)
    # 2. Cache marked as invalid
    # 3. Directory changed
    [[ ${_P_GIT_INVALIDATE} -eq 1 ]] && return 1
    [[ ${_P_GIT_CACHE_VALID} -eq 0 ]] && return 1
    [[ "${_P_GIT_CACHE_PWD}" != "${PWD}" ]] && return 1
    return 0
}

# =============================================================================
# Git Command Detection (for Cache Invalidation)
# =============================================================================

_prompt_is_git_command() {
    local cmd="$1"
    local first_word="${cmd%% *}"

    # Direct git commands
    [[ "${first_word}" == "git" ]] && return 0

    # Common git aliases: g, ga, gc, gco, gp, etc.
    case "${first_word}" in
        g|ga|gb|gc|gco|gd|gf|gl|gm|gp|gpl|gr|gs|gpush|gpull|tig|lazygit|gh|gitx)
            return 0 ;;
    esac

    # File-modifying commands that could affect git status
    case "${first_word}" in
        vim|vi|nano|emacs|code|subl)
            return 0 ;;
        rm|mv|cp|touch|mkdir|rmdir)
            return 0 ;;
        npm|yarn|pnpm|pip|pip3|cargo|go|make|cmake|gradle|mvn)
            return 0 ;;
        wget|curl)
            return 0 ;;
    esac

    return 1
}

# =============================================================================
# Git Status Collection (with Caching)
# =============================================================================

_prompt_git_status() {
    # Use cache if valid
    if _prompt_git_cache_valid; then
        return 0
    fi

    # Reset cache state
    _P_GIT_BRANCH=""
    _P_GIT_STAGED=0
    _P_GIT_UNSTAGED=0
    _P_GIT_UNTRACKED=0
    _P_GIT_AHEAD=0
    _P_GIT_BEHIND=0
    _P_GIT_STASH=0
    _P_GIT_CONFLICTS=0
    _P_GIT_INVALIDATE=0

    # Check if we're in a git repo
    command -v git >/dev/null 2>&1 || return
    git rev-parse --is-inside-work-tree &>/dev/null || return

    local info
    info="$(git_status_fast 2>/dev/null)" || return
    [[ -z "${info}" ]] && return

    local branch staged unstaged untracked ahead behind stash conflicts
    IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

    _P_GIT_BRANCH="${branch}"
    _P_GIT_STAGED="${staged:-0}"
    _P_GIT_UNSTAGED="${unstaged:-0}"
    _P_GIT_UNTRACKED="${untracked:-0}"
    _P_GIT_AHEAD="${ahead:-0}"
    _P_GIT_BEHIND="${behind:-0}"
    _P_GIT_STASH="${stash:-0}"
    _P_GIT_CONFLICTS="${conflicts:-0}"

    # Mark cache as valid
    _P_GIT_CACHE_PWD="${PWD}"
    _P_GIT_CACHE_VALID=1
}

# =============================================================================
# Left Prompt Components
# =============================================================================

_prompt_dir() {
    local dir="${PWD}"
    [[ "${dir}" == "${HOME}"* ]] && dir="~${dir#"${HOME}"}"
    printf '%s%s%s' "${_C_DIR}" "${dir}" "${_C_RST}"
}

# Abbreviate git branch - keeps END of branch name (more meaningful)
# p10k truncates middle: first 12...last 12 for branches > 32 chars
_prompt_abbreviate_branch() {
    local branch="${1}"
    local max_len="${2:-32}"

    [[ -z "${max_len}" ]] || [[ ${max_len} -le 0 ]] && { printf '%s' "${branch}"; return; }
    [[ ${#branch} -le ${max_len} ]] && { printf '%s' "${branch}"; return; }

    # p10k style: show first 12 ... last 12 for long branches
    if [[ ${max_len} -ge 25 ]]; then
        printf '%s%s%s' "${branch:0:12}" "${_ICON_ELLIPSIS}" "${branch: -12}"
    else
        # For shorter limits, keep the end
        local keep=$((max_len - 1))
        printf '%s%s' "${_ICON_ELLIPSIS}" "${branch: -${keep}}"
    fi
}

# Build git portion with optional branch length limit
# Full format: branch ⇣behind⇡ahead *stash ~conflicts +staged !unstaged ?untracked
_prompt_git_formatted() {
    local max_branch_len="${1:-32}"

    [[ -z "${_P_GIT_BRANCH}" ]] && return

    local branch="${_P_GIT_BRANCH}"

    # Abbreviate branch if needed
    if [[ ${max_branch_len} -gt 0 ]]; then
        branch=$(_prompt_abbreviate_branch "${branch}" "${max_branch_len}")
    fi

    # Build output: branch in green
    local output=" ${_C_GIT_CLEAN}${branch}${_C_RST}"

    # Behind/ahead - p10k format: ⇣N⇡N (no space between if both present)
    if [[ "${_P_GIT_BEHIND:-0}" -gt 0 ]] || [[ "${_P_GIT_AHEAD:-0}" -gt 0 ]]; then
        output+=" "
        [[ "${_P_GIT_BEHIND:-0}" -gt 0 ]] && output+="${_C_GIT_BEHIND}${_ICON_BEHIND}${_P_GIT_BEHIND}${_C_RST}"
        [[ "${_P_GIT_AHEAD:-0}" -gt 0 ]] && output+="${_C_GIT_AHEAD}${_ICON_AHEAD}${_P_GIT_AHEAD}${_C_RST}"
    fi

    # Stash: *N (magenta)
    [[ "${_P_GIT_STASH:-0}" -gt 0 ]] && output+=" ${_C_GIT_STASH}${_ICON_STASH}${_P_GIT_STASH}${_C_RST}"

    # Conflicts: ~N (red)
    [[ "${_P_GIT_CONFLICTS:-0}" -gt 0 ]] && output+=" ${_C_GIT_CONFLICT}${_ICON_CONFLICT}${_P_GIT_CONFLICTS}${_C_RST}"

    # Staged: +N (cyan)
    [[ "${_P_GIT_STAGED:-0}" -gt 0 ]] && output+=" ${_C_GIT_STAGED}${_ICON_STAGED}${_P_GIT_STAGED}${_C_RST}"

    # Unstaged: !N (yellow)
    [[ "${_P_GIT_UNSTAGED:-0}" -gt 0 ]] && output+=" ${_C_GIT_DIRTY}${_ICON_UNSTAGED}${_P_GIT_UNSTAGED}${_C_RST}"

    # Untracked: ?N (red)
    [[ "${_P_GIT_UNTRACKED:-0}" -gt 0 ]] && output+=" ${_C_GIT_UNTRACKED}${_ICON_UNTRACKED}${_P_GIT_UNTRACKED}${_C_RST}"

    printf '%s' "${output}"
}

_prompt_char() {
    local exit_code="${1}"
    # p10k uses ❯ for normal mode
    if [[ "${exit_code}" -eq 0 ]]; then
        printf '%s%s%s ' "${_C_PROMPT_OK}" "${_ICON_PROMPT}" "${_C_RST}"
    else
        printf '%s%s%s ' "${_C_PROMPT_ERR}" "${_ICON_PROMPT}" "${_C_RST}"
    fi
}

# =============================================================================
# Right Prompt Components
# =============================================================================

_prompt_status() {
    local exit_code="${1}"
    [[ "${exit_code}" -eq 0 ]] && return

    # Show signal name for signals (128+), otherwise just the exit code
    local status_text
    if [[ ${exit_code} -gt 128 ]]; then
        local sig=$((exit_code - 128))
        case ${sig} in
            1)  status_text="HUP" ;;
            2)  status_text="INT" ;;
            3)  status_text="QUIT" ;;
            9)  status_text="KILL" ;;
            15) status_text="TERM" ;;
            *)  status_text="${exit_code}" ;;
        esac
    else
        status_text="${exit_code}"
    fi
    printf '%s%s %s%s' "${_C_STATUS_ERR}" "${_ICON_FAIL}" "${status_text}" "${_C_RST}"
}

# Command duration display - shows for commands > 3 seconds
_prompt_duration() {
    [[ ${_P_CMD_DURATION} -lt 3 ]] && return

    local d=${_P_CMD_DURATION}
    local out=""

    # Format: Nd Nh Nm Ns
    [[ ${d} -ge 86400 ]] && { out+="$((d/86400))d"; d=$((d%86400)); }
    [[ ${d} -ge 3600 ]]  && { out+="$((d/3600))h"; d=$((d%3600)); }
    [[ ${d} -ge 60 ]]    && { out+="$((d/60))m"; d=$((d%60)); }
    [[ ${d} -gt 0 || -z "${out}" ]] && out+="${d}s"

    printf '%s%s%s' "${_C_DURATION}" "${out}" "${_C_RST}"
}

# Python virtualenv/conda display
_prompt_python() {
    [[ -z "${VIRTUAL_ENV:-}" && -z "${CONDA_DEFAULT_ENV:-}" ]] && return

    local env="${VIRTUAL_ENV:-${CONDA_DEFAULT_ENV}}"
    env="${env##*/}"  # basename
    printf '%s(%s)%s' "${_C_PYTHON}" "${env}" "${_C_RST}"
}

# Kubernetes context display (opt-in via JSH_PROMPT_KUBE=1)
_prompt_kube() {
    [[ "${JSH_PROMPT_KUBE:-0}" != "1" ]] && return
    command -v kubectl >/dev/null 2>&1 || return

    local ctx
    ctx="$(kubectl config current-context 2>/dev/null)" || return
    [[ -z "${ctx}" ]] && return

    # Truncate long context names
    [[ ${#ctx} -gt 20 ]] && ctx="${ctx:0:8}${_ICON_ELLIPSIS}${ctx: -8}"

    printf '%s⎈ %s%s' "${_C_KUBE}" "${ctx}" "${_C_RST}"
}

_prompt_time() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # Use zsh strftime builtin if available
        if zmodload -e zsh/datetime 2>/dev/null || zmodload zsh/datetime 2>/dev/null; then
            printf '%s%s%s' "${_C_TIME}" "$(strftime '%H:%M:%S' "${EPOCHSECONDS}")" "${_C_RST}"
            return
        fi
    fi
    printf '%s%s%s' "${_C_TIME}" "$(date +%H:%M:%S)" "${_C_RST}"
}

_prompt_jobs() {
    local job_count
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # Zsh: use jobstates array (no subshell)
        job_count=${#jobstates}
    else
        # Bash: count background jobs
        job_count=$(jobs -p 2>/dev/null | wc -l | tr -d ' ')
    fi
    [[ "${job_count}" -eq 0 ]] && return
    printf '%s[%s]%s' "${_C_JOBS}" "${job_count}" "${_C_RST}"
}

# =============================================================================
# Context (user@host)
# =============================================================================

_prompt_collect_context() {
    _P_USER=""
    _P_HOST=""

    # Only show in SSH, remote sessions, or as root
    [[ -z "${SSH_CONNECTION:-}" ]] && [[ -z "${JSH_ENV:-}" ]] && [[ "${EUID:-$(id -u)}" != "0" ]] && return

    _P_USER="${USER:-$(whoami)}"
    _P_HOST="${HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"

    # Strip domain from user if present
    [[ "${_P_USER}" == *"@"* ]] && _P_USER="${_P_USER%%@*}"

    # Strip FQDN from host
    [[ "${_P_HOST}" == *"."* ]] && _P_HOST="${_P_HOST%%.*}"
}

_prompt_abbreviate_host() {
    local host="${1}"
    local max_len="${2:-0}"

    [[ "${host}" == *"."* ]] && host="${host%%.*}"

    if [[ ${max_len} -gt 0 ]] && [[ ${#host} -gt ${max_len} ]]; then
        host="${host:0:$((max_len-1))}${_ICON_ELLIPSIS}"
    fi

    printf '%s' "${host}"
}

_prompt_abbreviate_user() {
    local user="${1}"
    local max_len="${2:-0}"

    [[ "${user}" == *"@"* ]] && user="${user%%@*}"

    if [[ ${max_len} -gt 0 ]] && [[ ${#user} -gt ${max_len} ]]; then
        user="${user:0:$((max_len-1))}${_ICON_ELLIPSIS}"
    fi

    printf '%s' "${user}"
}

_prompt_context_formatted() {
    local max_user="${1:-0}"
    local max_host="${2:-0}"

    [[ -z "${_P_USER}" ]] && return

    local user="${_P_USER}"
    local host="${_P_HOST}"

    [[ ${max_user} -gt 0 ]] && user=$(_prompt_abbreviate_user "${user}" "${max_user}")
    [[ ${max_host} -gt 0 ]] && host=$(_prompt_abbreviate_host "${host}" "${max_host}")

    if [[ "${EUID:-$(id -u)}" == "0" ]]; then
        printf '%s%s@%s%s' "${_C_CONTEXT_ROOT}" "${user}" "${host}" "${_C_RST}"
    else
        printf '%s%s@%s%s' "${_C_CONTEXT}" "${user}" "${host}" "${_C_RST}"
    fi
}

# =============================================================================
# Pure Shell Length Calculation (avoids sed)
# =============================================================================

_prompt_visible_len() {
    local s="$1"
    local len=0
    local in_escape=0
    local i=0
    local char

    # Strip Zsh %{...%} blocks
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        s="${s//\%\{/}"
        s="${s//\%\}/}"
    else
        # Strip Bash \[...\] blocks
        s="${s//\\[/}"
        s="${s//\\]/}"
    fi

    # Count non-escape characters
    while [[ $i -lt ${#s} ]]; do
        char="${s:$i:1}"
        if [[ $in_escape -eq 1 ]]; then
            [[ "$char" == "m" ]] && in_escape=0
        elif [[ "$char" == $'\e' ]]; then
            in_escape=1
        else
            ((len++))
        fi
        ((i++))
    done

    printf '%d' "$len"
}

# =============================================================================
# Preexec/Precmd Hooks
# =============================================================================

_prompt_preexec() {
    local cmd="$1"

    # Record command start time
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        _P_CMD_START="${EPOCHSECONDS:-$(date +%s)}"
    else
        _P_CMD_START="${EPOCHSECONDS:-$(date +%s)}"
    fi

    # Check if command might affect git state
    if _prompt_is_git_command "${cmd}"; then
        _P_GIT_INVALIDATE=1
    fi
}

_prompt_precmd() {
    # Capture exit code FIRST
    _P_EXIT_CODE=$?

    # Calculate command duration
    if [[ ${_P_CMD_START} -gt 0 ]]; then
        local now="${EPOCHSECONDS:-$(date +%s)}"
        _P_CMD_DURATION=$((now - _P_CMD_START))
    else
        _P_CMD_DURATION=0
    fi
    _P_CMD_START=0

    # Collect git status (uses cache if valid)
    _prompt_git_status

    # Collect context
    _prompt_collect_context
}

# =============================================================================
# User-Callable Functions
# =============================================================================

# Manually refresh git cache (after external changes)
prompt_refresh() {
    _P_GIT_INVALIDATE=1
    _P_GIT_CACHE_VALID=0
}

# =============================================================================
# Prompt Builder
# =============================================================================

_prompt_build() {
    local exit_code="${_P_EXIT_CODE}"

    # Build left side: dir + git
    local dir_part="$(_prompt_dir)"

    # Build right side components
    local right_parts=()
    local status_part="$(_prompt_status "${exit_code}")"
    [[ -n "${status_part}" ]] && right_parts+=("${status_part}")

    local duration_part="$(_prompt_duration)"
    [[ -n "${duration_part}" ]] && right_parts+=("${duration_part}")

    local python_part="$(_prompt_python)"
    [[ -n "${python_part}" ]] && right_parts+=("${python_part}")

    local kube_part="$(_prompt_kube)"
    [[ -n "${kube_part}" ]] && right_parts+=("${kube_part}")

    local jobs_part="$(_prompt_jobs)"
    [[ -n "${jobs_part}" ]] && right_parts+=("${jobs_part}")

    # Context added later based on space
    local time_part="$(_prompt_time)"
    right_parts+=("${time_part}")

    # Join right parts with double space
    local right_base=""
    local first=1
    for part in "${right_parts[@]}"; do
        if [[ $first -eq 1 ]]; then
            right_base="${part}"
            first=0
        else
            right_base+="  ${part}"
        fi
    done

    # Calculate base lengths
    local dir_len=$(_prompt_visible_len "${dir_part}")
    local right_len=$(_prompt_visible_len "${right_base}")

    local term_width="${COLUMNS:-80}"

    # Reserve space
    local base_used=$((dir_len + right_len + 2))
    local available=$((term_width - base_used))

    # Calculate git portion
    local git_part=""

    if [[ -n "${_P_GIT_BRANCH}" ]]; then
        local git_indicators_len=2
        [[ "${_P_GIT_UNSTAGED:-0}" -gt 0 ]] && git_indicators_len=$((git_indicators_len + 4))
        [[ "${_P_GIT_UNTRACKED:-0}" -gt 0 ]] && git_indicators_len=$((git_indicators_len + 4))

        local branch_len=${#_P_GIT_BRANCH}
        local git_available=$((available - git_indicators_len))

        if [[ ${git_available} -ge ${branch_len} ]]; then
            git_part=$(_prompt_git_formatted 0)
        elif [[ ${git_available} -ge 25 ]]; then
            git_part=$(_prompt_git_formatted 32)
        elif [[ ${git_available} -ge 8 ]]; then
            git_part=$(_prompt_git_formatted "${git_available}")
        elif [[ ${git_available} -ge 4 ]]; then
            git_part=$(_prompt_git_formatted 4)
        fi
    fi

    # Context portion
    local context_part=""
    if [[ -n "${_P_USER}" ]]; then
        local git_len=$(_prompt_visible_len "${git_part}")
        local remaining=$((available - git_len))

        local user_len=${#_P_USER}
        local host_len=${#_P_HOST}
        local context_full_len=$((user_len + 1 + host_len))

        if [[ ${remaining} -ge $((context_full_len + 2)) ]]; then
            context_part="$(_prompt_context_formatted 0 0)"
        elif [[ ${remaining} -ge 12 ]]; then
            local ctx_available=$((remaining - 2))
            local max_user=$((ctx_available * 4 / 10))
            local max_host=$((ctx_available - max_user - 1))
            [[ ${max_user} -lt 3 ]] && max_user=3
            [[ ${max_host} -lt 4 ]] && max_host=4
            context_part="$(_prompt_context_formatted "${max_user}" "${max_host}")"
        fi
    fi

    # Final assembly
    local left="${dir_part}${git_part}"

    # Rebuild right with context
    local right=""
    [[ -n "${status_part}" ]] && right+="${status_part}  "
    [[ -n "${duration_part}" ]] && right+="${duration_part}  "
    [[ -n "${python_part}" ]] && right+="${python_part}  "
    [[ -n "${kube_part}" ]] && right+="${kube_part}  "
    [[ -n "${jobs_part}" ]] && right+="${jobs_part}  "
    [[ -n "${context_part}" ]] && right+="${context_part}  "
    right+="${time_part}"

    # Calculate padding
    local left_len=$(_prompt_visible_len "${left}")
    local right_final_len=$(_prompt_visible_len "${right}")
    local spaces=$((term_width - left_len - right_final_len))
    [[ ${spaces} -lt 1 ]] && spaces=1
    local padding
    padding=$(printf '%*s' "${spaces}" '')

    # Line 1: left + padding + right
    printf '%s%s%s\n' "${left}" "${padding}" "${right}"
    # Line 2: prompt char
    printf '%s' "$(_prompt_char "${exit_code}")"
}

# =============================================================================
# Shell Setup
# =============================================================================

_prompt_setup_bash() {
    # Bash preexec emulation via DEBUG trap
    # shellcheck disable=SC2329  # Invoked via trap DEBUG
    _prompt_bash_preexec_invoke() {
        [[ -n "${COMP_LINE:-}" ]] && return  # Ignore during completion
        [[ "${BASH_COMMAND}" == "${PROMPT_COMMAND}" ]] && return  # Ignore precmd
        _prompt_preexec "${BASH_COMMAND}"
    }

    trap '_prompt_bash_preexec_invoke' DEBUG

    # shellcheck disable=SC2329  # Used in PROMPT_COMMAND
    _prompt_precmd_bash() {
        _prompt_precmd
        PS1="$(_prompt_build)"
    }
    PROMPT_COMMAND="_prompt_precmd_bash"
}

_prompt_setup_zsh() {
    autoload -Uz add-zsh-hook 2>/dev/null || return
    setopt PROMPT_SUBST

    # Load zsh/datetime for EPOCHSECONDS
    zmodload zsh/datetime 2>/dev/null

    # shellcheck disable=SC2329  # Registered via add-zsh-hook
    _prompt_preexec_zsh() {
        _prompt_preexec "$1"
    }

    # shellcheck disable=SC2329  # Registered via add-zsh-hook
    _prompt_precmd_zsh() {
        _prompt_precmd
        PROMPT="$(_prompt_build)"
    }

    add-zsh-hook preexec _prompt_preexec_zsh
    add-zsh-hook precmd _prompt_precmd_zsh
}

_prompt_zsh_probe_advanced() {
    # Probe zsh features used by the advanced prompt path in a clean child zsh.
    # Using `zsh -f` avoids user startup files and keeps probe deterministic.
    command zsh -f -c '
        emulate -L zsh
        setopt prompt_subst
        autoload -Uz add-zsh-hook || exit 1

        typeset -gi _p_ahead=0 _p_behind=0 _p_untracked=0
        typeset _p_line _p_status

        _p_status="## main...origin/main [ahead 2, behind 3]\n M tracked\n?? new"
        while IFS= read -r _p_line; do
            case "${_p_line:0:2}" in
                "##")
                    if [[ "${_p_line}" =~ "\\[ahead ([0-9]+), behind ([0-9]+)\\]" ]]; then
                        _p_ahead="${match[1]}"
                        _p_behind="${match[2]}"
                    fi
                    ;;
                "??") (( _p_untracked++ )) ;;
            esac
        done <<< "${_p_status}"

        (( _p_ahead == 2 && _p_behind == 3 && _p_untracked == 1 ))
    ' >/dev/null 2>&1
}

_prompt_should_use_safe_zsh() {
    [[ -z "${ZSH_VERSION:-}" ]] && return 1

    # Explicit overrides always win.
    [[ "${JSH_PROMPT_FORCE_ADVANCED_ZSH:-0}" == "1" ]] && return 1
    [[ "${JSH_PROMPT_FORCE_SAFE_ZSH:-0}" == "1" ]] && return 0

    # Cache probe result per zsh version to avoid startup overhead.
    local cache_dir cache_file cache_key cached_key cached_mode
    cache_dir="${JSH_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/jsh}"
    cache_file="${cache_dir}/prompt-zsh-mode.cache"
    cache_key="${ZSH_VERSION}"

    command mkdir -p "${cache_dir}" 2>/dev/null || true

    if [[ -r "${cache_file}" ]]; then
        IFS='|' read -r cached_key cached_mode < "${cache_file}" 2>/dev/null || true
        if [[ "${cached_key}" == "${cache_key}" ]]; then
            [[ "${cached_mode}" == "safe" ]] && return 0
            return 1
        fi
    fi

    if _prompt_zsh_probe_advanced; then
        printf '%s|%s\n' "${cache_key}" "advanced" > "${cache_file}" 2>/dev/null || true
        return 1
    fi

    printf '%s|%s\n' "${cache_key}" "safe" > "${cache_file}" 2>/dev/null || true
    return 0
}

_prompt_setup_zsh_safe() {
    setopt PROMPT_SUBST

    # Keep this path intentionally simple for stability on affected zsh builds.
    if [[ "${EUID:-$(id -u)}" == "0" ]]; then
        PROMPT=$'%F{yellow}%n@%m%f %F{cyan}%~%f\n%F{green}❯%f '
    else
        PROMPT=$'%F{cyan}%~%f\n%F{green}❯%f '
    fi

    if [[ -z "${RPROMPT:-}" ]]; then
        RPROMPT='%F{8}%*%f'
    fi
}

prompt_init() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        if _prompt_should_use_safe_zsh; then
            _prompt_setup_zsh_safe
        else
            _prompt_setup_zsh
        fi
    else
        _prompt_setup_bash
    fi
}
