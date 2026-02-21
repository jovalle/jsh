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
_BREW_DELEGATE_WARNED=0
_BREW_PERMS_REPAIRED_KEY=""

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
    elif [[ -x "${HOME}/.linuxbrew/bin/brew" ]]; then
        echo "${HOME}/.linuxbrew"
    else
        if _brew_is_linux_root; then
            local delegate_user delegate_home
            delegate_user=$(_brew_delegate_user 2>/dev/null || true)
            if [[ -n "${delegate_user}" ]]; then
                delegate_home=$(_brew_user_home "${delegate_user}")
                if [[ -n "${delegate_home}" ]] && [[ -x "${delegate_home}/.linuxbrew/bin/brew" ]]; then
                    echo "${delegate_home}/.linuxbrew"
                    return 0
                fi
            fi
        fi
        return 1
    fi
}

# =============================================================================
# Root Delegation (Linux)
# =============================================================================

_brew_is_linux_root() {
    [[ "$(uname -s)" == "Linux" ]] && [[ "${EUID:-$(id -u)}" == "0" ]]
}

_brew_user_home() {
    local username="$1"
    [[ -z "${username}" ]] && return 1

    if command -v getent >/dev/null 2>&1; then
        getent passwd "${username}" 2>/dev/null | cut -d: -f6
    else
        awk -F: -v user="${username}" '$1 == user {print $6; exit}' /etc/passwd 2>/dev/null
    fi
}

_brew_uid1000_user() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd 1000 2>/dev/null | cut -d: -f1
    else
        awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd 2>/dev/null
    fi
}

_brew_delegate_user() {
    local delegate_user="${JSH_BREW_DELEGATE_USER:-}"

    if [[ -z "${delegate_user}" ]]; then
        delegate_user=$(_brew_uid1000_user)
    fi

    [[ -z "${delegate_user}" ]] && return 1
    id -u "${delegate_user}" >/dev/null 2>&1 || return 1
    echo "${delegate_user}"
}

_brew_warn_once() {
    local message="$1"
    [[ "${_BREW_DELEGATE_WARNED}" == "1" ]] && return 0
    _BREW_DELEGATE_WARNED=1
    echo "jsh: ${message}" >&2
}

_brew_repair_delegate_permissions() {
    local delegate_user="$1"
    local delegate_home="$2"
    local brew_cmd="$3"

    [[ "${EUID:-$(id -u)}" == "0" ]] || return 0
    [[ -n "${delegate_user}" ]] || return 0
    [[ -n "${delegate_home}" ]] || return 0

    local brew_prefix=""
    if [[ "${brew_cmd}" == */bin/brew ]]; then
        brew_prefix="${brew_cmd%/bin/brew}"
    fi

    local repair_key="${delegate_user}:${brew_prefix}"
    [[ "${_BREW_PERMS_REPAIRED_KEY}" == "${repair_key}" ]] && return 0

    local -a targets=()
    [[ -n "${brew_prefix}" ]] && [[ -d "${brew_prefix}" ]] && targets+=("${brew_prefix}")
    targets+=("${delegate_home}/.cache/Homebrew")

    local target
    for target in "${targets[@]}"; do
        [[ -e "${target}" ]] || continue

        if find "${target}" -xdev -uid 0 -print -quit 2>/dev/null | grep -q .; then
            find "${target}" -xdev -uid 0 -type l -exec chown -h "${delegate_user}:${delegate_user}" {} + 2>/dev/null || true
            find "${target}" -xdev -uid 0 ! -type l -exec chown "${delegate_user}:${delegate_user}" {} + 2>/dev/null || true
        fi
    done

    _BREW_PERMS_REPAIRED_KEY="${repair_key}"
}

_brew_run() {
    local brew_cmd="$1"
    shift

    if _brew_is_linux_root; then
        local delegate_user
        delegate_user=$(_brew_delegate_user) || {
            _brew_warn_once "brew cannot run as root on Linux. Set JSH_BREW_DELEGATE_USER or run 'jsh setup'."
            return 1
        }

        local original_pwd="${PWD:-}"
        local changed_dir=0
        local delegate_home=""
        local delegate_cache_home=""
        local delegate_config_home=""
        local delegate_data_home=""
        local delegate_hb_cache=""
        local delegate_hb_logs=""
        local fallback_dir=""
        local cwd_ok=0

        delegate_home=$(_brew_user_home "${delegate_user}" 2>/dev/null || true)
        [[ -z "${delegate_home}" ]] && delegate_home="/home/${delegate_user}"
        delegate_cache_home="${delegate_home}/.cache"
        delegate_config_home="${delegate_home}/.config"
        delegate_data_home="${delegate_home}/.local/share"
        delegate_hb_cache="${delegate_cache_home}/Homebrew"
        delegate_hb_logs="${delegate_hb_cache}/Logs"

        mkdir -p "${delegate_hb_cache}" "${delegate_hb_logs}" 2>/dev/null || true
        chown -R "${delegate_user}:${delegate_user}" "${delegate_hb_cache}" 2>/dev/null || true

        _brew_repair_delegate_permissions "${delegate_user}" "${delegate_home}" "${brew_cmd}"

        fallback_dir="${delegate_home:-/tmp}"

        if command -v runuser >/dev/null 2>&1; then
            runuser -u "${delegate_user}" -- test -x "${original_pwd}" >/dev/null 2>&1 && cwd_ok=1
        elif command -v sudo >/dev/null 2>&1; then
            sudo -H -u "${delegate_user}" test -x "${original_pwd}" >/dev/null 2>&1 && cwd_ok=1
        fi

        if [[ "${cwd_ok}" != "1" ]] && [[ -n "${fallback_dir}" ]] && [[ -d "${fallback_dir}" ]]; then
            cd "${fallback_dir}" 2>/dev/null && changed_dir=1
        fi

        local exit_code

        if command -v runuser >/dev/null 2>&1; then
            runuser -u "${delegate_user}" -- env \
                HOME="${delegate_home}" \
                USER="${delegate_user}" \
                LOGNAME="${delegate_user}" \
                XDG_CACHE_HOME="${delegate_cache_home}" \
                XDG_CONFIG_HOME="${delegate_config_home}" \
                XDG_DATA_HOME="${delegate_data_home}" \
                HOMEBREW_CACHE="${delegate_hb_cache}" \
                HOMEBREW_LOGS="${delegate_hb_logs}" \
                "${brew_cmd}" "$@"
            exit_code=$?
        elif command -v sudo >/dev/null 2>&1; then
            sudo -H -u "${delegate_user}" env \
                HOME="${delegate_home}" \
                USER="${delegate_user}" \
                LOGNAME="${delegate_user}" \
                XDG_CACHE_HOME="${delegate_cache_home}" \
                XDG_CONFIG_HOME="${delegate_config_home}" \
                XDG_DATA_HOME="${delegate_data_home}" \
                HOMEBREW_CACHE="${delegate_hb_cache}" \
                HOMEBREW_LOGS="${delegate_hb_logs}" \
                "${brew_cmd}" "$@"
            exit_code=$?
        else
            _brew_warn_once "cannot delegate brew to '${delegate_user}' (missing runuser/sudo)."
            return 1
        fi

        if [[ "${changed_dir}" == "1" ]] && [[ -n "${original_pwd}" ]]; then
            cd "${original_pwd}" 2>/dev/null || true
        fi

        return "${exit_code}"
    else
        "${brew_cmd}" "$@"
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
    shellenv_output=$(_brew_run "${brew_cmd}" shellenv 2>/dev/null) || return 1

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
            eval "$(_brew_run "${brew_prefix}/bin/brew" shellenv 2>/dev/null)"
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
if [[ "${JSH_BREW_SKIP_SETUP:-0}" != "1" ]]; then
    _brew_setup
fi
