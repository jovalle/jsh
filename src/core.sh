# core.sh - Core utilities for jsh (colors, logging, platform detection)
# Pure shell, no external dependencies
# shellcheck disable=SC2034

[[ -n "${_JSH_CORE_LOADED:-}" ]] && return 0
_JSH_CORE_LOADED=1

# =============================================================================
# Platform Detection
# =============================================================================

_jsh_detect_os() {
    case "$(uname -s)" in
        Darwin)  echo "macos" ;;
        Linux)   echo "linux" ;;
        FreeBSD) echo "freebsd" ;;
        *)       echo "unknown" ;;
    esac
}

_jsh_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             echo "unknown" ;;
    esac
}

_jsh_detect_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        echo "zsh"
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        echo "bash"
    else
        echo "sh"
    fi
}

_jsh_detect_env() {
    # Detect environment type (ssh, local, container, etc.)
    if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
        echo "ssh"
    elif [[ -f "/.dockerenv" ]] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo "container"
    elif [[ -n "${JSH_EPHEMERAL:-}" ]]; then
        echo "ephemeral"  # SSH carry-through session
    else
        echo "local"
    fi
}

# Cache platform info (computed once)
JSH_OS="${JSH_OS:-$(_jsh_detect_os)}"
JSH_ARCH="${JSH_ARCH:-$(_jsh_detect_arch)}"
JSH_SHELL="${JSH_SHELL:-$(_jsh_detect_shell)}"
JSH_ENV="${JSH_ENV:-$(_jsh_detect_env)}"

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

# Add bundled binaries to PATH (platform-specific, takes precedence over system)
JSH_BIN_DIR="${JSH_DIR}/lib/bin/${JSH_PLATFORM}"
[[ -d "${JSH_BIN_DIR}" ]] && PATH="${JSH_BIN_DIR}:${PATH}"

# =============================================================================
# Terminal Capability Detection
# =============================================================================

_jsh_has_color() {
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

_jsh_has_unicode() {
    # Check if terminal supports unicode
    local lang="${LANG:-}${LC_ALL:-}${LC_CTYPE:-}"
    # Use tr for lowercase conversion (portable across bash/zsh)
    local lang_lower
    lang_lower="$(printf '%s' "${lang}" | tr '[:upper:]' '[:lower:]')"
    [[ "${lang_lower}" == *utf-8* ]] || [[ "${lang_lower}" == *utf8* ]]
}

# Cache terminal capabilities
JSH_HAS_COLOR="$(_jsh_has_color && echo 1 || echo 0)"
JSH_COLOR_COUNT="$(_jsh_color_count)"
JSH_HAS_UNICODE="$(_jsh_has_unicode && echo 1 || echo 0)"

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
else
    # No colors
    RST="" BLK="" RED="" GRN="" YLW="" BLU="" MAG="" CYN="" WHT=""
    BBLK="" BRED="" BGRN="" BYLW="" BBLU="" BMAG="" BCYN="" BWHT=""
    BOLD="" DIM="" ITAL="" UNDR=""
    BG_BLK="" BG_RED="" BG_GRN="" BG_YLW="" BG_BLU="" BG_MAG="" BG_CYN="" BG_WHT=""
    C_DIR="" C_FILE="" C_EXEC="" C_LINK="" C_GIT="" C_ERR="" C_WARN=""
    C_OK="" C_INFO="" C_MUTED="" C_ACCENT=""
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

_log() {
    local level="$1" prefix="$2" color="$3"
    shift 3
    [[ "${JSH_LOG_LEVEL}" -lt "${level}" ]] && return 0
    printf "%b%s%b %s\n" "${color}" "${prefix}" "${RST}" "$*" >&2
}

info()    { _log 1 "info:" "${C_INFO}" "$@"; }
success() { _log 1 "ok:" "${C_OK}" "$@"; }
warn()    { _log 1 "warn:" "${C_WARN}" "$@"; }
error()   { _log 1 "error:" "${C_ERR}" "$@"; }
debug()   { _log 3 "debug:" "${C_MUTED}" "$@"; }

die() {
    error "$@"
    exit 1
}

# =============================================================================
# Print Functions (colored output for interactive/terminal use)
# =============================================================================

# Plain colored output
print_info()    { echo "${C_INFO}$*${RST}"; }
print_success() { echo "${C_OK}$*${RST}"; }
print_warn()    { echo "${C_WARN}$*${RST}" >&2; }
print_error()   { echo "${C_ERR}$*${RST}" >&2; }

# Prefixed output (for status lists, validation results)
prefix_info()    { echo "${BLU}◆${RST} $*"; }
prefix_success() { echo "${GRN}✔${RST} $*"; }
prefix_warn()    { echo "${YLW}⚠${RST} $*" >&2; }
prefix_error()   { echo "${RED}✘${RST} $*" >&2; }

# =============================================================================
# Utility Functions
# =============================================================================

# Check if command exists
has() {
    command -v "$1" >/dev/null 2>&1
}

# Safe source (only if file exists and is readable)
source_if() {
    [[ -r "$1" ]] && source "$1"
}

# Execute only if command exists
try_eval() {
    local cmd="$1"
    shift
    has "${cmd}" && eval "$@"
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

path_append() {
    [[ -d "$1" ]] || return 0
    case ":${PATH}:" in
        *":$1:"*) ;;
        *) PATH="${PATH}:$1" ;;
    esac
}

path_remove() {
    PATH="${PATH//:$1:/:}"
    PATH="${PATH/#$1:/}"
    PATH="${PATH/%:$1/}"
}

# =============================================================================
# String Utilities
# =============================================================================

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

is_empty() {
    [[ -z "${1// /}" ]]
}

# =============================================================================
# Timing Utilities (for prompt performance)
# =============================================================================

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

# Track command execution time
_jsh_timer_start() {
    _JSH_CMD_START="${_JSH_CMD_START:-$(_jsh_now_ms)}"
}

_jsh_timer_stop() {
    local now end_time
    now="$(_jsh_now_ms)"
    _JSH_CMD_DURATION="$(( now - ${_JSH_CMD_START:-$now} ))"
    unset _JSH_CMD_START
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

# Editor preference
if [[ -z "${EDITOR:-}" ]]; then
    if has nvim; then
        export EDITOR="nvim"
    elif has vim; then
        export EDITOR="vim"
    elif has vi; then
        export EDITOR="vi"
    fi
fi
export VISUAL="${VISUAL:-$EDITOR}"

# Locale (UTF-8 preferred)
if [[ -z "${LANG:-}" ]] || [[ "${LANG}" == "C" ]] || [[ "${LANG}" == "POSIX" ]]; then
    if locale -a 2>/dev/null | grep -qi 'en_US.utf-\?8'; then
        export LANG="en_US.UTF-8"
    fi
fi
export LC_ALL="${LC_ALL:-$LANG}"

# =============================================================================
# Debug Mode
# =============================================================================

if [[ "${JSH_DEBUG:-0}" == "1" ]]; then
    JSH_LOG_LEVEL=3
    debug "JSH_OS=${JSH_OS} JSH_ARCH=${JSH_ARCH} JSH_SHELL=${JSH_SHELL} JSH_ENV=${JSH_ENV}"
    debug "JSH_HAS_COLOR=${JSH_HAS_COLOR} JSH_COLOR_COUNT=${JSH_COLOR_COUNT} JSH_HAS_UNICODE=${JSH_HAS_UNICODE}"
fi
