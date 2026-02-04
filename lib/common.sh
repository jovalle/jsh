# lib/common.sh - Shared output helpers for bin scripts
# Source this at the top of scripts: source "${0%/*}/../lib/common.sh"
# shellcheck shell=bash

# =============================================================================
# Colors (auto-detect terminal support)
# =============================================================================

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_CYAN='' C_BOLD='' C_DIM=''
fi

# Export for subshells
export C_RESET C_RED C_GREEN C_YELLOW C_BLUE C_CYAN C_BOLD C_DIM

# =============================================================================
# Output Helpers
# =============================================================================

# Fatal error - print message and exit
die() {
    printf "%s%s×%s %s\n" "${C_RED}" "${C_BOLD}" "${C_RESET}" "$*" >&2
    exit 1
}

# Warning message
warn() {
    printf "%s%s!%s %s\n" "${C_YELLOW}" "${C_BOLD}" "${C_RESET}" "$*" >&2
}

# Success message
success() {
    printf "%s%s✓%s %s\n" "${C_GREEN}" "${C_BOLD}" "${C_RESET}" "$*"
}

# Info message
info() {
    printf "%s•%s %s\n" "${C_BLUE}" "${C_RESET}" "$*"
}

# Error message (no exit)
error() {
    printf "%s%s×%s %s\n" "${C_RED}" "${C_BOLD}" "${C_RESET}" "$*" >&2
}

# Debug message (internal, override with script-specific env var)
_debug() {
    printf "%s• %s%s\n" "${C_DIM}" "$*" "${C_RESET}" >&2
}

# =============================================================================
# User Interaction
# =============================================================================

# Prompt for confirmation
# Usage: confirm "Are you sure?" [default: n]
# Returns: 0 for yes, 1 for no
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local yn_prompt response

    if [[ "${JSH_NO_GUM:-0}" != "1" ]] && command -v gum >/dev/null 2>&1 && [[ -t 0 ]] && [[ -t 1 ]]; then
        gum confirm "${prompt}"
        return $?
    fi

    if [[ "${default}" == "y" ]]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi

    printf '%s%s%s %s ' "${C_YELLOW}" "${prompt}" "${C_RESET}" "${yn_prompt}"
    read -r response

    case "${response}" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        [nN]|[nN][oO])
            return 1
            ;;
        "")
            [[ "${default}" == "y" ]] && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if command exists
has() {
    command -v "$1" >/dev/null 2>&1
}
