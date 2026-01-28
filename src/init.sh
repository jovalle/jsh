# init.sh - J Shell Entrypoint
# Sourced by .bashrc/.zshrc to initialize the jsh shell environment
# shellcheck disable=SC1090,SC2034

# Detect current shell FIRST (before any guards)
# This is critical because running `bash` from zsh inherits exported variables
_jsh_current_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then echo "zsh"
    elif [[ -n "${BASH_VERSION:-}" ]]; then echo "bash"
    else echo "sh"; fi
}
_JSH_THIS_SHELL="$(_jsh_current_shell)"

# Shell-specific load guard (allows reloading when switching shells)
_JSH_GUARD_VAR="_JSH_INIT_LOADED_${_JSH_THIS_SHELL}"
eval "[[ -n \"\${${_JSH_GUARD_VAR}:-}\" ]]" && return 0
eval "${_JSH_GUARD_VAR}=1"

# =============================================================================
# PATH Safety Bootstrap (must be first!)
# =============================================================================
# Ensure minimal system PATH exists before any commands run
# This is critical because modules use commands like uname, mktemp, dirname, etc.
# Note: .zshrc and .zshenv also have bootstraps, but this is a final safety net
if [[ -z "${PATH:-}" ]] || [[ ":${PATH}:" != *":/usr/bin:"* ]]; then
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
fi

# =============================================================================
# Bootstrap
# =============================================================================

# Detect Jsh directory (where this script lives)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2296,SC2298
    JSH_DIR="${JSH_DIR:-${${(%):-%x}:A:h:h}}"
else
    JSH_DIR="${JSH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fi
export JSH_DIR

# Bail early if not interactive
[[ $- != *i* ]] && return 0

# =============================================================================
# Terminal Settings (must be early, before keybindings)
# =============================================================================

# Unbind Ctrl+R from terminal "reprint" so shells can use it for history search
# Without this, the terminal driver captures ^R before the shell sees it
[[ -t 0 ]] && stty rprnt undef 2>/dev/null

# =============================================================================
# Profiler (optional, zero overhead when disabled)
# =============================================================================

# Source profiler first for timing (defines no-op stubs when JSH_PROFILE!=1)
[[ -f "${JSH_DIR}/src/profiler.sh" ]] && source "${JSH_DIR}/src/profiler.sh"

# =============================================================================
# Homebrew Environment (cached for performance)
# =============================================================================

# Source brew.sh early to set up PATH before other modules
# This caches `brew shellenv` output for 20-40ms savings per shell
_profile_start "brew.sh"
[[ -f "${JSH_DIR}/src/brew.sh" ]] && source "${JSH_DIR}/src/brew.sh"
_profile_end "brew.sh"

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
# Module Loading Helper
# =============================================================================

# Source a module with error handling and profiling
_source_module() {
    local module="$1"
    # IMPORTANT: In zsh, many lowercase variable names are special arrays tied
    # to uppercase counterparts (path↔PATH, fpath↔FPATH, module_path↔MODULE_PATH).
    # Even 'local var=' corrupts the global binding within this function's scope.
    # Use underscore-prefixed names to avoid all zsh special variables.
    local _src_file="${JSH_DIR}/src/${module}"

    if [[ -f "${_src_file}" ]]; then
        [[ "${JSH_DEBUG:-0}" == "1" ]] && echo "Jsh: Loading module: ${module}" >&2
        _profile_start "${module}"
        source "${_src_file}"
        _profile_end "${module}"
    else
        echo "Jsh: Warning - module not found: ${module}" >&2
        return 1
    fi
}

# =============================================================================
# Load Order
# =============================================================================

# 1. Core utilities (colors, logging, platform detection)
_source_module "core.sh"

# 1b. Dependency management (optional, requires jq for full functionality)
source_if "${JSH_DIR}/src/deps.sh"

# =============================================================================
# PATH Setup (must be before zsh.sh/bash.sh for fzf detection)
# =============================================================================
# Note: Platform detection is handled in core.sh (already sourced above)
# JSH_PLATFORM is already set by core.sh

# Jsh binaries and tools
path_prepend "${JSH_DIR}/bin"                           # Bundled utilities
path_prepend "${JSH_DIR}/bin/${JSH_PLATFORM}"           # Platform binaries (fzf, jq)
path_prepend "${JSH_DIR}"                               # jsh CLI itself
path_prepend "${JSH_DIR}/local/bin"                     # Prototypes

# User local binaries
path_prepend "${HOME}/.local/bin"

# Language-specific paths
path_prepend "${HOME}/.cargo/bin"         # Rust
path_prepend "${HOME}/go/bin"             # Go
path_prepend "${HOME}/.npm-global/bin"    # Node global
path_prepend "${HOME}/.local/share/pnpm"  # pnpm global

# 2. Vi-mode configuration (before shell-specific, affects keybindings)
_source_module "vi-mode.sh"

# 3. Aliases (tiered system)
_source_module "aliases.sh"

# 4. Functions (shell utilities)
_source_module "functions.sh"

# 4b. Smart directory jumping (j command)
_source_module "j.sh"

# 4c. Git project management shell wrapper (gitx shell function)
_source_module "gitx.sh"

# 5. Git status functions (for prompt)
_source_module "gitstatus.sh"

# 6. Tool integrations (FZF, direnv - shell-agnostic)
_source_module "tools.sh"

# 6b. External tool completions (cross-shell, cached)
_source_module "completion.sh"

# 7. Shell-specific configuration (zsh.sh or bash.sh)
if [[ "${JSH_SHELL}" == "zsh" ]]; then
    _source_module "zsh.sh"
else
    _source_module "bash.sh"
fi

# 8. Initialize vi-mode
vimode_init

# 9. Prompt configuration (zsh.sh handles this for zsh, bash needs it here)
if [[ "${JSH_SHELL}" == "bash" ]]; then
    _source_module "prompt.sh"
    prompt_init
fi

# =============================================================================
# Tool Configuration
# =============================================================================

# pnpm home directory
export PNPM_HOME="${HOME}/.local/share/pnpm"

# Vim as default editor (portable across SSH sessions)
if has nvim; then
    export EDITOR="nvim"
    export VISUAL="nvim"

elif has vim; then
    export EDITOR="vim"
    export VISUAL="vim"
fi

# Less configuration
export LESS="-R -F -i -M -S"
export LESSHISTFILE="${XDG_CACHE_HOME:-$HOME/.cache}/less/history"
ensure_dir "$(dirname "${LESSHISTFILE}")"

# Man pages with color
export MANPAGER="less -R --use-color -Dd+r -Du+b"
if has bat; then
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
fi

# GPG TTY (for signing)
export GPG_TTY
GPG_TTY=$(tty)

# =============================================================================
# SSH Environment Detection
# =============================================================================

# Detect jssh session mode
if [[ "${JSH_ENV:-}" == "ssh" ]]; then
    debug "Jsh SSH mode: ${JSH_MODE:-unknown}"
    debug "  Payload: ${JSSH_PAYLOAD_DIR:-$JSH_DIR}"
    debug "  Session: ${JSH_SESSION:-none}"

    # In shared mode, session cleanup is handled by the parent shell script
    # In ephemeral mode (legacy), we still clean up on exit
    if [[ "${JSH_MODE:-}" == "ephemeral" && -n "${JSH_SESSION:-}" ]]; then
        _jsh_ephemeral_cleanup() {
            # Use command to bypass rm alias (rm -I would prompt)
            [[ -d "${JSH_SESSION}" ]] && command rm -rf "${JSH_SESSION}"
        }
        trap '_jsh_ephemeral_cleanup' EXIT
    fi
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
        _jsh_duration=$(awk "BEGIN {print ${EPOCHREALTIME} - ${_jsh_startup_start}}")
        debug "Jsh startup time: ${_jsh_duration}s"
        unset _jsh_duration
    fi
fi
unset _jsh_startup_start

# =============================================================================
# Local Overrides (machine-specific)
# =============================================================================

# Source local config if it exists (not tracked in git)
# Options (in reverse order of precedence):
source_if "${JSH_DIR}/local/.jshrc"
source_if "${HOME}/.jshrc.local"

# =============================================================================
# Profiler Report (when JSH_PROFILE=1)
# =============================================================================

# Show startup profile if requested
[[ "${JSH_PROFILE:-0}" == "1" ]] && _profile_report
