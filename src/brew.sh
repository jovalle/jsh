# brew.sh - Homebrew/Linuxbrew shellenv caching for faster shell startup
# Caches `brew shellenv` output to avoid 20-40ms overhead per shell
# Works on both macOS (Homebrew) and Linux (Linuxbrew)
# shellcheck disable=SC2034

# Load guard
[[ -n "${_JSH_BREW_LOADED:-}" ]] && return 0
_JSH_BREW_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

_BREW_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/jsh/brew"
_BREW_CACHE_FILE="${_BREW_CACHE_DIR}/shellenv"
_BREW_CACHE_HEAD="${_BREW_CACHE_DIR}/head"
_BREW_CACHE_TTL=86400  # 24 hours in seconds

# =============================================================================
# Homebrew/Linuxbrew Path Detection
# =============================================================================

# Find Homebrew/Linuxbrew installation
# macOS: /opt/homebrew (Apple Silicon) or /usr/local (Intel)
# Linux: /home/linuxbrew/.linuxbrew
_brew_find_prefix() {
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        echo "/opt/homebrew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        echo "/usr/local"
    elif [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
        echo "/home/linuxbrew/.linuxbrew"
    else
        return 1
    fi
}

# =============================================================================
# Cache Management
# =============================================================================

# Check if cache is valid
# Returns 0 if cache is valid, 1 if stale or missing
_brew_cache_valid() {
    local cache_file="$1"
    local head_file="$2"
    local brew_prefix="$3"

    # Cache file must exist
    [[ -f "${cache_file}" ]] || return 1

    # Check age (24-hour TTL)
    local cache_age
    if [[ "$(uname -s)" == "Darwin" ]]; then
        cache_age=$(( $(date +%s) - $(stat -f %m "${cache_file}" 2>/dev/null || echo 0) ))
    else
        cache_age=$(( $(date +%s) - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0) ))
    fi
    [[ ${cache_age} -gt ${_BREW_CACHE_TTL} ]] && return 1

    # Check if Homebrew/Linuxbrew HEAD changed (indicates brew update)
    if [[ -f "${head_file}" ]]; then
        local cached_head current_head homebrew_repo
        cached_head=$(cat "${head_file}" 2>/dev/null)
        # Homebrew repo location (same structure on macOS and Linux)
        homebrew_repo="${brew_prefix}/Homebrew"
        current_head=$(git -C "${homebrew_repo}" rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "${current_head}" ]] && [[ "${cached_head}" != "${current_head}" ]]; then
            return 1
        fi
    fi

    return 0
}

# Generate and cache brew shellenv output
_brew_update_cache() {
    local brew_prefix="$1"
    local brew_cmd="${brew_prefix}/bin/brew"

    # Create cache directory
    mkdir -p "${_BREW_CACHE_DIR}"

    # Generate shellenv output
    local shellenv_output
    shellenv_output=$("${brew_cmd}" shellenv 2>/dev/null) || return 1

    # Write cache
    echo "${shellenv_output}" > "${_BREW_CACHE_FILE}"

    # Store Homebrew/Linuxbrew HEAD for invalidation detection
    local head_commit homebrew_repo
    homebrew_repo="${brew_prefix}/Homebrew"
    head_commit=$(git -C "${homebrew_repo}" rev-parse HEAD 2>/dev/null || echo "")
    if [[ -n "${head_commit}" ]]; then
        echo "${head_commit}" > "${_BREW_CACHE_HEAD}"
    fi

    return 0
}

# =============================================================================
# Main: Load Homebrew/Linuxbrew Environment
# =============================================================================

_brew_setup() {
    local brew_prefix
    brew_prefix=$(_brew_find_prefix) || return 0

    # Check cache validity
    if _brew_cache_valid "${_BREW_CACHE_FILE}" "${_BREW_CACHE_HEAD}" "${brew_prefix}"; then
        # Use cached shellenv
        # shellcheck disable=SC1090
        source "${_BREW_CACHE_FILE}"
        [[ "${JSH_DEBUG:-0}" == "1" ]] && debug "brew.sh: Using cached shellenv"
    else
        # Generate fresh cache and source it
        if _brew_update_cache "${brew_prefix}"; then
            # shellcheck disable=SC1090
            source "${_BREW_CACHE_FILE}"
            [[ "${JSH_DEBUG:-0}" == "1" ]] && debug "brew.sh: Regenerated shellenv cache"
        else
            # Fallback: direct eval (no caching)
            eval "$("${brew_prefix}/bin/brew" shellenv 2>/dev/null)"
            [[ "${JSH_DEBUG:-0}" == "1" ]] && debug "brew.sh: Fallback to direct eval"
        fi
    fi
}

# =============================================================================
# CLI Commands (for jsh integration)
# =============================================================================

# Clear the shellenv cache (useful after manual brew changes)
brew_cache_clear() {
    rm -f "${_BREW_CACHE_FILE}" "${_BREW_CACHE_HEAD}"
    echo "Brew shellenv cache cleared"
}

# Show cache status
brew_cache_status() {
    local brew_prefix
    brew_prefix=$(_brew_find_prefix) || {
        echo "Homebrew/Linuxbrew not found"
        return 1
    }

    echo "Brew prefix: ${brew_prefix}"
    echo "Cache directory: ${_BREW_CACHE_DIR}"

    if [[ -f "${_BREW_CACHE_FILE}" ]]; then
        local cache_age
        if [[ "$(uname -s)" == "Darwin" ]]; then
            cache_age=$(( $(date +%s) - $(stat -f %m "${_BREW_CACHE_FILE}") ))
        else
            cache_age=$(( $(date +%s) - $(stat -c %Y "${_BREW_CACHE_FILE}") ))
        fi
        local cache_age_human=$(( cache_age / 60 ))
        echo "Cache age: ${cache_age_human} minutes (TTL: $(( _BREW_CACHE_TTL / 3600 )) hours)"

        if _brew_cache_valid "${_BREW_CACHE_FILE}" "${_BREW_CACHE_HEAD}" "${brew_prefix}"; then
            echo "Cache status: VALID"
        else
            echo "Cache status: STALE"
        fi
    else
        echo "Cache status: NOT CACHED"
    fi
}

# =============================================================================
# Initialize
# =============================================================================

# Run setup automatically when sourced
_brew_setup
