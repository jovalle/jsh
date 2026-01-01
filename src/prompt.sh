#!/usr/bin/env bash
# prompt.sh - Lightweight prompt matching p10k style
# For SSH/ephemeral sessions where p10k isn't available
# shellcheck disable=SC2034,SC2016

[[ -n "${_JSH_PROMPT_LOADED:-}" ]] && return 0
_JSH_PROMPT_LOADED=1

# =============================================================================
# Colors (matching p10k.zsh exactly)
# =============================================================================

_C_PROMPT_OK=$'\e[38;5;76m'       # prompt_char OK (green)
_C_PROMPT_ERR=$'\e[38;5;196m'     # prompt_char ERROR (red)
_C_DIR=$'\e[38;5;31m'             # directory (blue)
_C_VCS_CLEAN=$'\e[38;5;76m'       # git clean (green)
_C_VCS_MODIFIED=$'\e[38;5;178m'   # git modified (yellow)
_C_STATUS_ERR=$'\e[38;5;160m'     # status error (red)
_C_TIME=$'\e[38;5;66m'            # time (blue-gray)
_C_CONTEXT=$'\e[38;5;180m'        # user@host SSH
_C_CONTEXT_ROOT=$'\e[38;5;178m'   # user@host root
_C_RST=$'\e[0m'                   # reset

# =============================================================================
# Left Prompt Components
# =============================================================================

_prompt_dir() {
    local dir="${PWD}"
    [[ "${dir}" == "${HOME}"* ]] && dir="~${dir#"${HOME}"}"
    echo "${_C_DIR}${dir}${_C_RST}"
}

_prompt_git() {
    command -v git >/dev/null 2>&1 || return
    git rev-parse --is-inside-work-tree &>/dev/null || return

    local info
    info="$(git_status_fast 2>/dev/null)" || return
    [[ -z "${info}" ]] && return

    local branch staged unstaged untracked ahead behind stash conflicts
    IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

    # Determine color (clean=green, dirty=yellow)
    local color="${_C_VCS_CLEAN}"
    if [[ "${staged}" -gt 0 || "${unstaged}" -gt 0 || "${untracked}" -gt 0 ]]; then
        color="${_C_VCS_MODIFIED}"
    fi

    # Build output with ahead/behind indicators
    local output=" ${branch}"
    [[ "${ahead}" -gt 0 ]] && output+=" ↑${ahead}"
    [[ "${behind}" -gt 0 ]] && output+=" ↓${behind}"

    echo "${color}${output}${_C_RST}"
}

_prompt_char() {
    local exit_code="$1"
    if [[ "${exit_code}" -eq 0 ]]; then
        echo "${_C_PROMPT_OK}❯${_C_RST} "
    else
        echo "${_C_PROMPT_ERR}❯${_C_RST} "
    fi
}

# =============================================================================
# Right Prompt Components (matching p10k RIGHT_PROMPT_ELEMENTS)
# =============================================================================

_prompt_status() {
    local exit_code="$1"
    [[ "${exit_code}" -eq 0 ]] && return
    echo "${_C_STATUS_ERR}✘ ${exit_code}${_C_RST}"
}

_prompt_time() {
    # Clock icon + time + trailing space (matching p10k)
    echo "${_C_TIME} $(date +%H:%M:%S) ${_C_RST}"
}

_prompt_context() {
    # Only show in SSH or as root
    [[ -z "${SSH_CONNECTION:-}" ]] && [[ -z "${JSH_ENV:-}" ]] && [[ "${EUID:-$(id -u)}" != "0" ]] && return

    local user host color
    user="${USER:-$(whoami)}"
    host="${HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"

    if [[ "${EUID:-$(id -u)}" == "0" ]]; then
        color="${_C_CONTEXT_ROOT}"
    else
        color="${_C_CONTEXT}"
    fi

    echo "${color}${user}@${host}${_C_RST}"
}

# =============================================================================
# Prompt Builder
# =============================================================================

_prompt_build_left() {
    local left
    left="$(_prompt_dir)"

    local git_info
    git_info="$(_prompt_git)"
    [[ -n "${git_info}" ]] && left+="${git_info}"

    echo "${left}"
}

_prompt_build_right() {
    local exit_code="$1"
    local parts=()

    # Status (only on error)
    local exit_status
    exit_status="$(_prompt_status ${exit_code})"
    [[ -n "${exit_status}" ]] && parts+=("${exit_status}")

    # Context (user@host) - only for SSH
    local ctx
    ctx="$(_prompt_context)"
    [[ -n "${ctx}" ]] && parts+=("${ctx}")

    # Time
    parts+=("$(_prompt_time)")

    # Join with spaces
    local IFS=' '
    echo "${parts[*]}"
}

_prompt_build() {
    local exit_code="$1"
    local left right

    left="$(_prompt_build_left)"
    right="$(_prompt_build_right ${exit_code})"

    # Calculate padding for right-align
    local left_plain right_plain
    left_plain=$(printf '%s' "${left}" | sed 's/\x1b\[[0-9;]*m//g')
    right_plain=$(printf '%s' "${right}" | sed 's/\x1b\[[0-9;]*m//g')

    local term_width="${COLUMNS:-80}"
    local spaces=$((term_width - ${#left_plain} - ${#right_plain}))
    [[ ${spaces} -lt 1 ]] && spaces=1
    local padding
    padding=$(printf '%*s' "${spaces}" '')

    # Line 1: left + padding + right
    echo "${left}${padding}${right}"
    # Line 2: prompt char
    echo -n "$(_prompt_char ${exit_code})"
}

# =============================================================================
# Shell Setup
# =============================================================================

_prompt_setup_bash() {
    _prompt_precmd_bash() {
        local exit_code=$?
        PS1="$(_prompt_build ${exit_code})"
    }
    PROMPT_COMMAND="_prompt_precmd_bash"
}

_prompt_setup_zsh() {
    autoload -Uz add-zsh-hook 2>/dev/null || return
    setopt PROMPT_SUBST

    _prompt_precmd_zsh() {
        local exit_code=$?
        PROMPT="$(_prompt_build ${exit_code})"
    }

    add-zsh-hook precmd _prompt_precmd_zsh
}

prompt_init() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        _prompt_setup_zsh
    else
        _prompt_setup_bash
    fi
}
