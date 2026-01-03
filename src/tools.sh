# tools.sh - Shell-agnostic tool configuration
# FZF, fd, direnv, and other cross-shell integrations
# shellcheck disable=SC2034

[[ -n "${_JSH_TOOLS_LOADED:-}" ]] && return 0
_JSH_TOOLS_LOADED=1

# =============================================================================
# FZF Configuration
# =============================================================================

if has fzf; then
    # Base options
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --inline-info"

    # Use fd if available (faster than find, respects .gitignore)
    if has fd; then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="${FZF_DEFAULT_COMMAND}"
        export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
    fi
fi

# =============================================================================
# Direnv Integration
# =============================================================================

if has direnv; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        eval "$(direnv hook zsh)"
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        eval "$(direnv hook bash)"
    fi
fi
