# init.sh - J Shell Entrypoint
# Sourced by .bashrc/.zshrc to initialize the jsh shell environment
# shellcheck disable=SC1090,SC2034

[[ -n "${_JSH_INIT_LOADED:-}" ]] && return 0
_JSH_INIT_LOADED=1

# =============================================================================
# Bootstrap
# =============================================================================

# Detect Jsh directory (where this script lives)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    JSH_DIR="${JSH_DIR:-${${(%):-%x}:A:h:h}}"
else
    JSH_DIR="${JSH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fi
export JSH_DIR

# Bail early if not interactive
[[ $- != *i* ]] && return 0

# =============================================================================
# Performance Timing (Debug Mode)
# =============================================================================

_jsh_startup_start=""
if [[ "${JSH_DEBUG:-0}" == "1" ]]; then
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        _jsh_startup_start="${EPOCHREALTIME}"
    fi
fi

# =============================================================================
# Load Order
# =============================================================================

# 1. Core utilities (colors, logging, platform detection)
source "${JSH_DIR}/src/core.sh"

# 2. Vi-mode configuration (before shell-specific, affects keybindings)
source "${JSH_DIR}/src/vi-mode.sh"

# 3. Aliases (tiered system)
source "${JSH_DIR}/src/aliases.sh"

# 4. Functions
source "${JSH_DIR}/src/functions.sh"

# 5. Git status functions (for prompt)
source "${JSH_DIR}/src/git.sh"

# 6. Shell-specific configuration (zsh.sh or bash.sh)
if [[ "${JSH_SHELL}" == "zsh" ]]; then
    source "${JSH_DIR}/src/zsh.sh"
else
    source "${JSH_DIR}/src/bash.sh"
fi

# 7. Initialize vi-mode
vimode_init

# 8. Prompt configuration
# Use lightweight prompt as fallback when p10k isn't available
# (p10k is loaded by zsh.sh if present; prompt.sh is fallback for bash/sh or missing p10k)
if [[ -z "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS:-}" ]]; then
    # P10k not loaded, use lightweight prompt
    source "${JSH_DIR}/src/prompt.sh"
    prompt_init
fi

# =============================================================================
# PATH Setup
# =============================================================================

# Jsh binaries and tools
path_prepend "${JSH_DIR}/bin"                           # Bundled utilities
path_prepend "${JSH_DIR}"                               # jsh CLI itself
path_prepend "${JSH_DIR}/ssh"                           # jssh

# User local binaries
path_prepend "${HOME}/.local/bin"

# Language-specific paths
path_prepend "${HOME}/.cargo/bin"     # Rust
path_prepend "${HOME}/go/bin"         # Go
path_prepend "${HOME}/.npm-global/bin"  # Node global

# =============================================================================
# Tool Configuration
# =============================================================================

# Neovim as default editor (if available)
if has nvim; then
    export EDITOR="nvim"
    export VISUAL="nvim"
elif has vim; then
    export EDITOR="vim"
    export VISUAL="vim"
fi

# Less configuration
export LESS="-R -F -X -i -M -S"
export LESSHISTFILE="${XDG_CACHE_HOME:-$HOME/.cache}/less/history"
ensure_dir "$(dirname "${LESSHISTFILE}")"

# Ripgrep config
export RIPGREP_CONFIG_PATH="${JSH_DIR}/core/ripgreprc"

# Man pages with color
export MANPAGER="less -R --use-color -Dd+r -Du+b"
if has bat; then
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
fi

# GPG TTY (for signing)
export GPG_TTY=$(tty)

# =============================================================================
# SSH Environment Detection
# =============================================================================

# Mark if this is an ephemeral SSH session (jssh)
if [[ -n "${JSH_EPHEMERAL:-}" ]]; then
    # Running in jssh portable mode
    debug "Jsh ephemeral mode: ${JSH_EPHEMERAL}"

    # Cleanup function for session end
    _jsh_ephemeral_cleanup() {
        # Use command to bypass rm alias (rm -I would prompt)
        [[ -d "${JSH_EPHEMERAL}" ]] && command rm -rf "${JSH_EPHEMERAL}"
    }
    trap '_jsh_ephemeral_cleanup' EXIT
fi

# =============================================================================
# Welcome Message (Optional)
# =============================================================================

_jsh_welcome() {
    [[ "${JSH_QUIET:-0}" == "1" ]] && return

    # Only show on first shell of session
    [[ -n "${JSH_WELCOMED:-}" ]] && return
    export JSH_WELCOMED=1

    # Simple, fast welcome
    if [[ "${JSH_ENV}" == "ssh" ]]; then
        printf '%s\n' "${C_MUTED:-}jsh @ $(hostname)${RST:-}"
    fi
}

# Uncomment to enable welcome message
# _jsh_welcome

# =============================================================================
# Startup Time (Debug)
# =============================================================================

if [[ "${JSH_DEBUG:-0}" == "1" ]] && [[ -n "${_jsh_startup_start}" ]]; then
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local duration
        duration=$(echo "${EPOCHREALTIME} - ${_jsh_startup_start}" | bc)
        debug "Jsh startup time: ${duration}s"
    fi
fi
unset _jsh_startup_start

# =============================================================================
# Local Overrides (Machine-Specific)
# =============================================================================

# Source local config if it exists (not tracked in git)
# Options (in order of complexity):
#   1. local/.jshrc   - Simple env vars and exports (within jsh)
#   2. ~/.jshrc.local - Simple overrides (outside jsh)
#   3. local/init.sh  - Complex multi-file setups (within jsh)
source_if "${JSH_DIR}/local/.jshrc"
source_if "${HOME}/.jshrc.local"
source_if "${JSH_DIR}/local/init.sh"
