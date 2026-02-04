# core.sh - Core utilities for jsh (colors, logging, platform detection)
# Pure shell, no external dependencies
# shellcheck disable=SC2034

# Shell detection (always run - shell can change between invocations)
_jsh_detect_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then echo "zsh"
    elif [[ -n "${BASH_VERSION:-}" ]]; then echo "bash"
    else echo "sh"; fi
}
JSH_SHELL="$(_jsh_detect_shell)"
export JSH_SHELL

# Shell-specific load guard
_JSH_CORE_GUARD="_JSH_CORE_LOADED_${JSH_SHELL}"
eval "[[ -n \"\${${_JSH_CORE_GUARD}:-}\" ]]" && return 0
eval "${_JSH_CORE_GUARD}=1"

# =============================================================================
# Platform Detection
# =============================================================================

_jsh_detect_os() {
    # Use absolute path for uname - PATH may not be set during early init
    case "$(/usr/bin/uname -s 2>/dev/null || uname -s)" in
        Darwin)  echo "macos" ;;
        Linux)   echo "linux" ;;
        FreeBSD) echo "freebsd" ;;
        *)       echo "unknown" ;;
    esac
}

_jsh_detect_arch() {
    # Use absolute path for uname - PATH may not be set during early init
    case "$(/usr/bin/uname -m 2>/dev/null || uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             echo "unknown" ;;
    esac
}

_jsh_detect_env() {
    # Detect environment type (ssh, local, container, etc.)
    if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
        echo "ssh"
    elif [[ -f "/.dockerenv" ]]; then
        echo "container"
    # Note: grep separated to avoid set -e triggering on grep exit code 1
    elif grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo "container"
    elif [[ -n "${JSH_EPHEMERAL:-}" ]]; then
        echo "ephemeral"  # SSH carry-through session
    else
        echo "local"
    fi
}

# Cache platform info (computed once, exported for subshells)
# Note: JSH_SHELL is detected before the load guard (see top of file)
JSH_OS="${JSH_OS:-$(_jsh_detect_os)}"
JSH_ARCH="${JSH_ARCH:-$(_jsh_detect_arch)}"
JSH_ENV="${JSH_ENV:-$(_jsh_detect_env)}"
export JSH_OS JSH_ARCH JSH_SHELL JSH_ENV

# Platform string for binary selection (e.g., "darwin-arm64", "linux-amd64")
_jsh_platform_string() {
    local os arch
    case "${JSH_OS}" in
        macos)  os="darwin" ;;
        linux)  os="linux" ;;
        *)      os="${JSH_OS}" ;;
    esac
    case "${JSH_ARCH}" in
        x64)    arch="amd64" ;;
        arm64)  arch="arm64" ;;
        *)      arch="${JSH_ARCH}" ;;
    esac
    echo "${os}-${arch}"
}
JSH_PLATFORM="${JSH_PLATFORM:-$(_jsh_platform_string)}"
export JSH_PLATFORM

# =============================================================================
# Terminal Capability Detection
# =============================================================================

_jsh_has_color() {
    # Respect common no-color and plain output toggles.
    [[ -n "${NO_COLOR:-}" ]] && return 1
    [[ "${JSH_PLAIN_OUTPUT:-0}" == "1" ]] && return 1
    # Check if terminal supports colors (don't require -t 1, as stdout may not
    # be a TTY during shell init, but we still want colors defined for later use)
    [[ -n "${TERM:-}" ]] && [[ "${TERM}" != "dumb" ]]
}

_jsh_color_count() {
    # Detect number of supported colors
    if [[ -n "${COLORTERM:-}" ]]; then
        case "${COLORTERM}" in
            truecolor|24bit) echo "16777216" ;;
            *)               echo "256" ;;
        esac
    elif command -v tput >/dev/null 2>&1; then
        tput colors 2>/dev/null || echo "8"
    else
        echo "8"
    fi
}

# Cache terminal capabilities
JSH_HAS_COLOR="$(_jsh_has_color && echo 1 || echo 0)"
JSH_COLOR_COUNT="$(_jsh_color_count)"

# =============================================================================
# Color Definitions
# =============================================================================

if [[ "${JSH_HAS_COLOR}" == "1" ]]; then
    # Reset
    RST=$'\e[0m'

    # Basic colors (16-color safe)
    BLK=$'\e[30m'
    RED=$'\e[31m'
    GRN=$'\e[32m'
    YLW=$'\e[33m'
    BLU=$'\e[34m'
    MAG=$'\e[35m'
    CYN=$'\e[36m'
    WHT=$'\e[37m'

    # Bright colors
    BBLK=$'\e[90m'
    BRED=$'\e[91m'
    BGRN=$'\e[92m'
    BYLW=$'\e[93m'
    BBLU=$'\e[94m'
    BMAG=$'\e[95m'
    BCYN=$'\e[96m'
    BWHT=$'\e[97m'

    # Bold variants
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    ITAL=$'\e[3m'
    UNDR=$'\e[4m'

    # Background colors
    BG_BLK=$'\e[40m'
    BG_RED=$'\e[41m'
    BG_GRN=$'\e[42m'
    BG_YLW=$'\e[43m'
    BG_BLU=$'\e[44m'
    BG_MAG=$'\e[45m'
    BG_CYN=$'\e[46m'
    BG_WHT=$'\e[47m'

    # 256-color palette (if supported)
    if [[ "${JSH_COLOR_COUNT}" -ge 256 ]]; then
        # Extended palette - semantic colors
        C_DIR=$'\e[38;5;33m'      # Directories - blue
        C_FILE=$'\e[38;5;252m'    # Files - light gray
        C_EXEC=$'\e[38;5;82m'     # Executables - green
        C_LINK=$'\e[38;5;51m'     # Symlinks - cyan
        C_GIT=$'\e[38;5;208m'     # Git info - orange
        C_ERR=$'\e[38;5;196m'     # Errors - bright red
        C_WARN=$'\e[38;5;214m'    # Warnings - orange
        C_OK=$'\e[38;5;40m'       # Success - green
        C_INFO=$'\e[38;5;75m'     # Info - light blue
        C_MUTED=$'\e[38;5;245m'   # Muted/dimmed - gray
        C_ACCENT=$'\e[38;5;141m'  # Accent - purple
    else
        # Fallback to basic colors
        C_DIR="${BLU}"
        C_FILE="${WHT}"
        C_EXEC="${GRN}"
        C_LINK="${CYN}"
        C_GIT="${YLW}"
        C_ERR="${RED}"
        C_WARN="${YLW}"
        C_OK="${GRN}"
        C_INFO="${CYN}"
        C_MUTED="${BBLK}"
        C_ACCENT="${MAG}"
    fi

    # Semantic color aliases
    C_SUCCESS="${C_OK}"
    C_WARNING="${C_WARN}"
    C_ERROR="${C_ERR}"
    # C_INFO already defined above
    # C_MUTED already defined above
    C_GIT_CLEAN="${GRN}"
    C_GIT_DIRTY="${YLW}"
    C_GIT_STAGED="${CYN}"
    C_GIT_UNTRACKED="${RED}"
    C_GIT_CONFLICT="${RED}"
    C_GIT_STASH="${MAG}"
    C_GIT_AHEAD="${GRN}"
    C_GIT_BEHIND="${GRN}"

    # Prompt-specific semantic colors
    C_DURATION="${C_MUTED}"
    C_PYTHON="${YLW}"
    C_KUBE="${BLU}"
else
    # No colors
    RST="" BLK="" RED="" GRN="" YLW="" BLU="" MAG="" CYN="" WHT=""
    BBLK="" BRED="" BGRN="" BYLW="" BBLU="" BMAG="" BCYN="" BWHT=""
    BOLD="" DIM="" ITAL="" UNDR=""
    BG_BLK="" BG_RED="" BG_GRN="" BG_YLW="" BG_BLU="" BG_MAG="" BG_CYN="" BG_WHT=""
    C_DIR="" C_FILE="" C_EXEC="" C_LINK="" C_GIT="" C_ERR="" C_WARN=""
    C_OK="" C_INFO="" C_MUTED="" C_ACCENT=""
    C_SUCCESS="" C_WARNING="" C_ERROR="" C_GIT_CLEAN="" C_GIT_DIRTY="" C_GIT_STAGED="" C_GIT_UNTRACKED=""
    C_GIT_CONFLICT="" C_GIT_STASH="" C_GIT_AHEAD="" C_GIT_BEHIND=""
    C_DURATION="" C_PYTHON="" C_KUBE=""
fi

# =============================================================================
# Prompt-Safe Colors (for PS1)
# =============================================================================

# Wrap colors for prompt use (prevents readline length calculation issues)
if [[ "${JSH_SHELL}" == "zsh" ]]; then
    # Zsh uses %{ %} for zero-width sequences
    _p() { echo "%{$1%}"; }
else
    # Bash uses \[ \] for zero-width sequences
    _p() { echo "\\[$1\\]"; }
fi

# Pre-compute prompt-safe color codes
P_RST="$(_p "${RST}")"
P_RED="$(_p "${RED}")"
P_GRN="$(_p "${GRN}")"
P_YLW="$(_p "${YLW}")"
P_BLU="$(_p "${BLU}")"
P_MAG="$(_p "${MAG}")"
P_CYN="$(_p "${CYN}")"
P_WHT="$(_p "${WHT}")"
P_BOLD="$(_p "${BOLD}")"
P_DIM="$(_p "${DIM}")"
P_BBLK="$(_p "${BBLK}")"

# =============================================================================
# Logging Functions
# =============================================================================

# Log levels
JSH_LOG_LEVEL="${JSH_LOG_LEVEL:-1}"  # 0=off, 1=normal, 2=verbose, 3=debug
JSH_PLAIN_OUTPUT="${JSH_PLAIN_OUTPUT:-0}"

# Output glyphs can be forced to ASCII for screen readers / plain logs.
if [[ "${JSH_PLAIN_OUTPUT}" == "1" ]]; then
    _JSH_SYM_INFO="i"
    _JSH_SYM_SUCCESS="OK"
    _JSH_SYM_WARN="WARN"
    _JSH_SYM_ERROR="ERR"
    _JSH_SYM_DEBUG="DBG"
else
    _JSH_SYM_INFO="·"
    _JSH_SYM_SUCCESS="✓"
    _JSH_SYM_WARN="!"
    _JSH_SYM_ERROR="✗"
    _JSH_SYM_DEBUG="?"
fi

_log() {
    local level="$1" prefix="$2" color="$3"
    shift 3
    [[ "${JSH_LOG_LEVEL}" -lt "${level}" ]] && return 0
    printf "%b%s%b %s\n" "${color}" "${prefix}" "${RST}" "$*" >&2
}

info()    { _log 1 "${_JSH_SYM_INFO}" "${C_INFO}" "$@"; }
success() { _log 1 "${_JSH_SYM_SUCCESS}" "${C_OK}" "$@"; }
warn()    { _log 1 "${_JSH_SYM_WARN}" "${C_WARN}" "$@"; }
error()   { _log 1 "${_JSH_SYM_ERROR}" "${C_ERR}" "$@"; }
debug()   { _log 3 "${_JSH_SYM_DEBUG}" "${C_MUTED}" "$@"; }

die() {
    error "$@"
    exit 1
}

# =============================================================================
# Spinner (braille animation for long-running operations)
# =============================================================================

_SPINNER_PID=""
_SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

_spinner_loop() {
    local msg="$1"
    local i=0
    local frame_count=${#_SPINNER_FRAMES[@]}

    # Hide cursor
    printf '\e[?25l'

    while true; do
        printf '\r%s %s' "${_SPINNER_FRAMES[$i]}" "${msg}"
        i=$(( (i + 1) % frame_count ))
        sleep 0.08
    done
}

_spinner_cleanup() {
    spinner_stop
}

spinner_start() {
    local msg="${1:-Loading...}"

    # Only show spinner if stdout is a terminal
    [[ ! -t 1 ]] && return 0

    # Set up cleanup trap
    trap '_spinner_cleanup' INT TERM

    _spinner_loop "${msg}" &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    [[ -z "${_SPINNER_PID}" ]] && return 0

    kill "$_SPINNER_PID" 2>/dev/null
    wait "$_SPINNER_PID" 2>/dev/null

    # Show cursor, clear line
    printf '\e[?25h\r\e[K'

    _SPINNER_PID=""

    # Remove our trap
    trap - INT TERM
}

# =============================================================================
# Print Functions (colored output for interactive/terminal use)
# =============================================================================

# Prefixed output (for status lists, validation results)
prefix_info() {
    local mark="◆"
    [[ "${JSH_PLAIN_OUTPUT}" == "1" ]] && mark="i"
    echo "${BLU}${mark}${RST} $*"
}
prefix_success() {
    local mark="✓"
    [[ "${JSH_PLAIN_OUTPUT}" == "1" ]] && mark="OK"
    echo "${GRN}${mark}${RST} $*"
}
prefix_warn() {
    local mark="⚠"
    [[ "${JSH_PLAIN_OUTPUT}" == "1" ]] && mark="WARN"
    echo "${YLW}${mark}${RST} $*" >&2
}
prefix_error() {
    local mark="✘"
    [[ "${JSH_PLAIN_OUTPUT}" == "1" ]] && mark="ERR"
    echo "${RED}${mark}${RST} $*" >&2
}

# =============================================================================
# Optional Gum UI Helpers (with shell fallbacks)
# =============================================================================

ui_has_gum() {
    [[ "${JSH_NO_GUM:-0}" != "1" ]] || return 1
    has gum || return 1
    [[ -t 0 ]] && [[ -t 1 ]]
}

# Prompt for free-form input.
# Usage: ui_input "<prompt>" [default]
# Output: input value on stdout
ui_input() {
    local prompt="$1"
    local default="${2:-}"
    local response=""

    if ui_has_gum; then
        if [[ -n "${default}" ]]; then
            response=$(gum input --prompt "${prompt}" --value "${default}") || return 1
        else
            response=$(gum input --prompt "${prompt}") || return 1
        fi
    else
        read -r -p "${prompt}" response || return 1
    fi

    if [[ -z "${response}" ]]; then
        response="${default}"
    fi

    printf '%s\n' "${response}"
}

# Prompt for yes/no confirmation.
# Usage: ui_confirm "<question>" [default: n]
# Returns: 0=yes, 1=no
ui_confirm() {
    local question="$1"
    local default="${2:-n}"
    local response=""

    if ui_has_gum; then
        gum confirm "${question}"
        return $?
    fi

    local yn_prompt
    if [[ "${default}" == "y" ]]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi

    read -r -p "${question} ${yn_prompt} " response || return 1

    case "${response}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        [nN]|[nN][oO]) return 1 ;;
        "")
            [[ "${default}" == "y" ]]
            return $?
            ;;
        *) return 1 ;;
    esac
}

# Prompt for typed token confirmation (e.g. "yes" or "force").
# Usage: ui_confirm_token "<prompt>" "<token>"
# Returns: 0 if typed token matches exactly.
ui_confirm_token() {
    local prompt="$1"
    local token="$2"
    local response=""

    if ui_has_gum; then
        response=$(gum input --prompt "${prompt} ") || return 1
    else
        read -r -p "${prompt} " response || return 1
    fi

    [[ "${response}" == "${token}" ]]
}

# =============================================================================
# Utility Functions
# =============================================================================

# Canonical package config path.
jsh_packages_dir() {
    local base="${JSH_DIR:-${HOME}/.jsh}"
    echo "${base}/config"
}

# Check if command exists
has() {
    command -v "$1" >/dev/null 2>&1
}

# Safe source (only if file exists and is readable)
source_if() {
    [[ -r "$1" ]] && source "$1"
    return 0
}

# Ensure directory exists
ensure_dir() {
    [[ -d "$1" ]] || mkdir -p "$1"
}

# =============================================================================
# Path Utilities
# =============================================================================

path_prepend() {
    [[ -d "$1" ]] || return 0
    case ":${PATH}:" in
        *":$1:"*) ;;
        *) PATH="$1:${PATH}" ;;
    esac
}

_jsh_now_ms() {
    if has gdate; then
        gdate +%s%3N
    elif [[ "${JSH_OS}" == "macos" ]]; then
        # macOS date doesn't support %N, use perl
        perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000' 2>/dev/null || date +%s000
    else
        date +%s%3N 2>/dev/null || date +%s000
    fi
}

# =============================================================================
# Environment Setup
# =============================================================================

# XDG Base Directory spec
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Jsh directories
export JSH_DIR="${JSH_DIR:-$HOME/.jsh}"
export JSH_CACHE_DIR="${XDG_CACHE_HOME}/jsh"
ensure_dir "${JSH_CACHE_DIR}"

# Editor preference (vim preferred, portable across SSH sessions)
if [[ -z "${EDITOR:-}" ]]; then
    if has vim; then
        export EDITOR="vim"
    elif has vi; then
        export EDITOR="vi"
    fi
fi
export VISUAL="${VISUAL:-${EDITOR:-}}"

# Locale (UTF-8 preferred)
if [[ -z "${LANG:-}" ]] || [[ "${LANG}" == "C" ]] || [[ "${LANG}" == "POSIX" ]]; then
    if locale -a 2>/dev/null | grep -qi 'en_US.utf-\?8'; then
        export LANG="en_US.UTF-8"
    fi
fi
export LC_ALL="${LC_ALL:-${LANG:-}}"

# =============================================================================
# Debug Mode
# =============================================================================

if [[ "${JSH_DEBUG:-0}" == "1" ]]; then
    JSH_LOG_LEVEL=3
    debug "JSH_OS=${JSH_OS} JSH_ARCH=${JSH_ARCH} JSH_SHELL=${JSH_SHELL} JSH_ENV=${JSH_ENV}"
    debug "JSH_HAS_COLOR=${JSH_HAS_COLOR} JSH_COLOR_COUNT=${JSH_COLOR_COUNT}"
fi
