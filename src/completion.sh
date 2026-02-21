# completion.sh - Cross-shell completion loaders for external tools
# Caches and sources completions for tools like kubectl, helm, etc.
# shellcheck disable=SC1090

[[ -n "${_JSH_COMPLETION_LOADED:-}" ]] && return 0
_JSH_COMPLETION_LOADED=1

# =============================================================================
# Helper: Deferred completion loader for zsh
# =============================================================================
# When compdef isn't available yet (before compinit), queue for later.
# The _JSH_DEFERRED_COMPLETIONS array is processed in zsh.sh after compinit.

_jsh_defer_completion_if_needed() {
    local cache="$1"

    # Bash: always source directly (no compdef dependency)
    if [[ -z "${ZSH_VERSION:-}" ]]; then
        source "$cache"
        return
    fi

    # Zsh: check if compdef is available (means compinit already ran)
    # shellcheck disable=SC2296
    if (( ${+functions[compdef]} )); then
        source "$cache"
        return
    fi

    # Zsh but compdef not ready - defer until after compinit
    # Create closure function to source this specific cache file
    # shellcheck disable=SC2016
    local defer_fn="_jsh_deferred_comp_${cache//[^a-zA-Z0-9]/_}"
    eval "${defer_fn}() { source '$cache'; }"
    _JSH_DEFERRED_COMPLETIONS+=("$defer_fn")
}

# =============================================================================
# Helper: Generic cached completion loader
# =============================================================================
# Usage: _jsh_cached_completion <tool> [max_age_days]
#   tool: Command name (must support `<tool> completion <shell>`)
#   max_age_days: Cache expiry in days (default: 7)

_jsh_cached_completion() {
    local tool="${1:?tool required}"
    local max_age="${2:-7}"

    command -v "$tool" &>/dev/null || return 0

    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/jsh/${tool}-completion.${JSH_SHELL}"
    local bin
    bin="$(command -v "$tool")"

    # Ensure cache directory exists (portable dirname: ${var%/*})
    [[ -d "${cache%/*}" ]] || mkdir -p "${cache%/*}"

    # Regenerate if: missing, binary newer, or cache expired
    if [[ ! -f "$cache" || "$bin" -nt "$cache" ]] || \
       [[ -n "$(find "$cache" -mtime +"${max_age}" 2>/dev/null)" ]]; then
        "$tool" completion "${JSH_SHELL}" > "$cache" 2>/dev/null
    fi

    [[ -f "$cache" ]] && _jsh_defer_completion_if_needed "$cache"
}

# =============================================================================
# Dynamic completion: just (loads on first tab press)
# =============================================================================
# Registers a stub that loads `just --completions zsh` on first tab-complete.
# This avoids any startup cost - completion is fetched only when needed.

_jsh_setup_just_completion() {
    command -v just &>/dev/null || return 0

    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # Zsh: register stub that loads real completion on first use
        _jsh_just_stub() {
            unfunction _jsh_just_stub 2>/dev/null
            local _just_completions
            _just_completions="$(just --completions zsh 2>/dev/null)"
            # Patch: replace showing full recipe body with completing other commands
            # The upstream script shows `just --show $recipe` which dumps the whole recipe
            _just_completions="${_just_completions//_message \"\`just --show \$recipe\`\"/_arguments -s -S \$common \'*:: :_just_commands\'}"
            eval "${_just_completions}"
            _just "$@"
        }
        compdef _jsh_just_stub just
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        # Bash: use complete -F with lazy loader
        _jsh_just_stub() {
            eval "$(just --completions bash 2>/dev/null)"
            _just
        }
        complete -F _jsh_just_stub just
    fi
}

# Defer just completion setup until compdef is available (after compinit)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    _JSH_DEFERRED_COMPLETIONS+=("_jsh_setup_just_completion")
else
    _jsh_setup_just_completion
fi

# =============================================================================
# Load completions for installed tools
# =============================================================================

_jsh_cached_completion kubectl
# Future: _jsh_cached_completion helm
# Future: _jsh_cached_completion terraform
