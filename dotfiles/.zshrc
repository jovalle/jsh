# Self-contained Zsh configuration managed by this repository.
if [[ -z "${_JSH_DOTFILES_ZSH_LOADED:-}" ]]; then
_JSH_DOTFILES_ZSH_LOADED=1

if [[ -z "${PATH:-}" ]] || [[ ":${PATH}:" != *":/usr/bin:"* ]]; then
  export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
fi
if [[ -z "${JSH_DIR:-}" ]]; then
  _jsh_zshrc="${${(%):-%N}:A}"
  export JSH_DIR="${_jsh_zshrc:h:h}"
  unset _jsh_zshrc
fi
export LANG="${JSH_LANG:-en_US.UTF-8}"

# =============================================================================
# Core
# =============================================================================
# core.sh - Core utilities for jsh (colors, logging, platform detection)
# Pure shell, no external dependencies
# shellcheck disable=SC2034

# Shell detection (always run - shell can change between invocations)
_jsh_detect_shell() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then REPLY="zsh"
  elif [[ -n "${BASH_VERSION:-}" ]]; then REPLY="bash"
  else REPLY="sh"; fi
}
_jsh_detect_shell
JSH_SHELL="$REPLY"
export JSH_SHELL

# =============================================================================
# Platform Detection
# =============================================================================

_jsh_detect_os() {
  case "${OSTYPE:-}" in
    darwin*)  REPLY="macos" ;;
    linux*)   REPLY="linux" ;;
    *)
      # Rare fallback for shells that do not expose OSTYPE.
      case "$(/usr/bin/uname -s 2>/dev/null || uname -s)" in
        Darwin) REPLY="macos" ;;
        Linux) REPLY="linux" ;;
        *) REPLY="unknown" ;;
      esac
      ;;
  esac
}

_jsh_detect_arch() {
  # MACHTYPE may itself be inherited from an earlier Rosetta session; prefer
  # the kernel's current machine value for executable selection.
  case "$(/usr/bin/uname -m 2>/dev/null || uname -m)" in
    x86_64|amd64) REPLY="x64" ;;
    arm64|aarch64) REPLY="arm64" ;;
    armv7l) REPLY="armv7" ;;
    *)
      case "${MACHTYPE:-${HOSTTYPE:-}}" in
        x86_64*|amd64*) REPLY="x64" ;;
        arm64*|aarch64*) REPLY="arm64" ;;
        armv7*) REPLY="armv7" ;;
        *) REPLY="unknown" ;;
      esac
      ;;
  esac
}

_jsh_detect_env() {
  # Detect environment type (ssh, local, container, etc.)
  if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
    REPLY="ssh"
  elif [[ -f "/.dockerenv" ]]; then
    REPLY="container"
  elif [[ -n "${JSH_EPHEMERAL:-}" ]]; then
    REPLY="ephemeral"  # SSH carry-through session
  else
    REPLY="local"
    if [[ -r /proc/1/cgroup ]]; then
      while IFS= read -r _jsh_cgroup_line; do
        case "${_jsh_cgroup_line}" in
          *docker*|*containerd*|*kubepods*) REPLY="container"; break ;;
        esac
      done </proc/1/cgroup
      unset _jsh_cgroup_line
    fi
  fi
}

# Cache platform info (computed once, exported for subshells)
# Note: JSH_SHELL is detected before the load guard (see top of file)
if [[ -z "${JSH_OS:-}" ]]; then _jsh_detect_os; JSH_OS="$REPLY"; fi
# Architecture describes the current host. Do not inherit it: login/session
# state may have been created under Rosetta or before a hardware migration,
# leaving an x64 value on an Apple Silicon shell.
_jsh_detect_arch; JSH_ARCH="$REPLY"
if [[ -z "${JSH_ENV:-}" ]]; then _jsh_detect_env; JSH_ENV="$REPLY"; fi
export JSH_OS JSH_ARCH JSH_SHELL JSH_ENV

# Stable host descriptor (e.g., "darwin-arm64", "linux-amd64")
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
  REPLY="${os}-${arch}"
}
# The runtime platform must describe this host. Inherited values can be stale
# after a Rosetta shell or a hardware migration.
_jsh_platform_string
JSH_PLATFORM="$REPLY"
export JSH_PLATFORM

# Platform predicates (use cached JSH_OS; no extra uname calls)
is_macos() { [[ "${JSH_OS}" == "macos" ]]; }
is_linux() { [[ "${JSH_OS}" == "linux" ]]; }

# =============================================================================
# Terminal Capability Detection
# =============================================================================

_jsh_has_color() {
  # Respect common no-color and plain output toggles.
  [[ "${JSH_PLAIN_OUTPUT:-0}" == "1" ]] && return 1
  [[ "${JSH_COLOR:-auto}" != never ]] || return 1
  [[ "${JSH_COLOR:-auto}" == always ]] && return 0
  [[ -n "${NO_COLOR:-}" ]] && return 1
  # Check if terminal supports colors (don't require -t 1, as stdout may not
  # be a TTY during shell init, but we still want colors defined for later use)
  [[ -n "${TERM:-}" ]] && [[ "${TERM}" != "dumb" ]]
}

_jsh_color_count() {
  case "${COLORTERM:-}" in
    truecolor|24bit) REPLY="16777216"; return ;;
    ?*) REPLY="256"; return ;;
  esac
  case "${TERM:-}" in
    *direct*|*truecolor*) REPLY="16777216" ;;
    *256color*) REPLY="256" ;;
    *) REPLY="8" ;;
  esac
}

# Cache terminal capabilities
if _jsh_has_color; then JSH_HAS_COLOR=1; else JSH_HAS_COLOR=0; fi
_jsh_color_count
JSH_COLOR_COUNT="$REPLY"

# One canonical palette feeds the prompt, commands, and standalone tools.
_jsh_palette_tier="basic"
case "${COLORTERM:-}:${TERM:-}" in
  *truecolor*|*24bit*|*direct*) _jsh_palette_tier="truecolor" ;;
  *256color*) _jsh_palette_tier="256" ;;
  *) [[ "${JSH_COLOR_COUNT:-8}" -ge 256 ]] 2>/dev/null && _jsh_palette_tier="256" ;;
esac

case "${_jsh_palette_tier}" in
  truecolor)
    JSH_PALETTE_TEXT=$'\033[38;2;215;218;224m'
    JSH_PALETTE_MUTED=$'\033[38;2;139;148;158m'
    JSH_PALETTE_ACCENT=$'\033[38;2;0;168;232m'
    JSH_PALETTE_OK=$'\033[38;2;0;208;132m'
    JSH_PALETTE_INFO=$'\033[38;2;0;183;255m'
    JSH_PALETTE_WARN=$'\033[38;2;255;233;0m'
    JSH_PALETTE_YELLOW=$'\033[38;2;255;233;0m'
    JSH_PALETTE_ERROR=$'\033[38;2;255;82;99m'
    JSH_PALETTE_GIT=$'\033[38;2;240;80;50m'
    JSH_PALETTE_PYTHON=$'\033[38;2;55;118;171m'
    JSH_PALETTE_KUBE=$'\033[38;2;50;108;229m'
    JSH_PALETTE_AI=$'\033[38;2;189;147;249m'
    JSH_PALETTE_VIOLET=$'\033[38;2;168;85;247m'
    JSH_PALETTE_CYAN=$'\033[38;2;0;183;255m'
    JSH_PALETTE_BG_ACCENT=$'\033[48;2;0;119;182m'
    JSH_PALETTE_BG_MUTED=$'\033[48;2;40;44;52m'
    JSH_PALETTE_BG_OK=$'\033[48;2;0;120;75m'
    JSH_PALETTE_BG_WARN=$'\033[48;2;140;120;0m'
    JSH_PALETTE_BG_ERROR=$'\033[48;2;160;30;45m'
    JSH_STYLE_TEXT='#D7DAE0'
    JSH_STYLE_MUTED='#8B949E'
    JSH_STYLE_ACCENT='#00A8E8'
    JSH_STYLE_OK='#00D084'
    JSH_STYLE_INFO='#00B7FF'
    JSH_STYLE_WARN='#FFE900'
    JSH_STYLE_ERROR='#FF5263'
    JSH_STYLE_AI='#BD93F9'
    JSH_STYLE_ERROR_SGR='38;2;255;82;99'
    ;;
  256)
    JSH_PALETTE_TEXT=$'\033[38;5;252m'
    JSH_PALETTE_MUTED=$'\033[38;5;247m'
    JSH_PALETTE_ACCENT=$'\033[38;5;38m'
    JSH_PALETTE_OK=$'\033[38;5;42m'
    JSH_PALETTE_INFO=$'\033[38;5;39m'
    JSH_PALETTE_WARN=$'\033[38;5;226m'
    JSH_PALETTE_YELLOW=$'\033[38;5;226m'
    JSH_PALETTE_ERROR=$'\033[38;5;203m'
    JSH_PALETTE_GIT=$'\033[38;5;202m'
    JSH_PALETTE_PYTHON=$'\033[38;5;67m'
    JSH_PALETTE_KUBE=$'\033[38;5;33m'
    JSH_PALETTE_AI=$'\033[38;5;141m'
    JSH_PALETTE_VIOLET=$'\033[38;5;135m'
    JSH_PALETTE_CYAN=$'\033[38;5;39m'
    JSH_PALETTE_BG_ACCENT=$'\033[48;5;24m'
    JSH_PALETTE_BG_MUTED=$'\033[48;5;236m'
    JSH_PALETTE_BG_OK=$'\033[48;5;22m'
    JSH_PALETTE_BG_WARN=$'\033[48;5;58m'
    JSH_PALETTE_BG_ERROR=$'\033[48;5;52m'
    JSH_STYLE_TEXT=252
    JSH_STYLE_MUTED=247
    JSH_STYLE_ACCENT=38
    JSH_STYLE_OK=42
    JSH_STYLE_INFO=39
    JSH_STYLE_WARN=226
    JSH_STYLE_ERROR=203
    JSH_STYLE_AI=141
    JSH_STYLE_ERROR_SGR='38;5;203'
    ;;
  *)
    JSH_PALETTE_TEXT=$'\033[37m'
    JSH_PALETTE_MUTED=$'\033[90m'
    JSH_PALETTE_ACCENT=$'\033[36m'
    JSH_PALETTE_OK=$'\033[32m'
    JSH_PALETTE_INFO=$'\033[34m'
    JSH_PALETTE_WARN=$'\033[33m'
    JSH_PALETTE_YELLOW=$'\033[33m'
    JSH_PALETTE_ERROR=$'\033[31m'
    JSH_PALETTE_GIT=$'\033[31m'
    JSH_PALETTE_PYTHON=$'\033[34m'
    JSH_PALETTE_KUBE=$'\033[94m'
    JSH_PALETTE_AI=$'\033[35m'
    JSH_PALETTE_VIOLET=$'\033[35m'
    JSH_PALETTE_CYAN=$'\033[36m'
    JSH_PALETTE_BG_ACCENT=$'\033[46m'
    JSH_PALETTE_BG_MUTED=$'\033[40m'
    JSH_PALETTE_BG_OK=$'\033[42m'
    JSH_PALETTE_BG_WARN=$'\033[43m'
    JSH_PALETTE_BG_ERROR=$'\033[41m'
    JSH_STYLE_TEXT=white
    JSH_STYLE_MUTED=default
    JSH_STYLE_ACCENT=cyan
    JSH_STYLE_OK=green
    JSH_STYLE_INFO=blue
    JSH_STYLE_WARN=yellow
    JSH_STYLE_ERROR=red
    JSH_STYLE_AI=magenta
    JSH_STYLE_ERROR_SGR=31
    ;;
esac

if [[ "${JSH_HAS_COLOR:-1}" == 0 ]]; then
  JSH_STYLE_TEXT=default
  JSH_STYLE_MUTED=default
  JSH_STYLE_ACCENT=default
  JSH_STYLE_OK=default
  JSH_STYLE_INFO=default
  JSH_STYLE_WARN=default
  JSH_STYLE_ERROR=default
  JSH_STYLE_ERROR_SGR=39
fi

unset _jsh_palette_tier

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
    C_DIR=$'\e[38;5;75m'      # Directories - blue
    C_FILE=$'\e[38;5;252m'    # Files - light gray
    C_EXEC=$'\e[38;5;35m'     # Executables - green
    C_LINK=$'\e[38;5;75m'     # Symlinks - blue
    C_GIT=$'\e[38;5;180m'     # Git info - amber
    C_ERR=$'\e[38;5;203m'     # Errors - red
    C_WARN=$'\e[38;5;180m'    # Warnings - amber
    C_OK=$'\e[38;5;35m'       # Success - green
    C_INFO=$'\e[38;5;75m'     # Info - blue
    C_MUTED=$'\e[38;5;247m'   # Muted/dimmed - gray
    C_ACCENT=$'\e[38;5;32m'   # Accent - blue
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
    C_ACCENT="${CYN}"
  fi

  # Canonical high-chroma Dark Modern semantics. These aliases intentionally replace the
  # terminal defaults above so prompt and command output cannot drift.
  RED="${JSH_PALETTE_ERROR}"
  GRN="${JSH_PALETTE_OK}"
  YLW="${JSH_PALETTE_WARN}"
  BLU="${JSH_PALETTE_INFO}"
  MAG="${JSH_PALETTE_ACCENT}"
  CYN="${JSH_PALETTE_INFO}"
  WHT="${JSH_PALETTE_TEXT}"
  BBLK="${JSH_PALETTE_MUTED}"
  C_TEXT="${JSH_PALETTE_TEXT}"
  C_DIR="${JSH_PALETTE_INFO}"
  C_FILE="${JSH_PALETTE_TEXT}"
  C_EXEC="${JSH_PALETTE_OK}"
  C_LINK="${JSH_PALETTE_INFO}"
  C_GIT="${JSH_PALETTE_GIT}"
  C_ERR="${JSH_PALETTE_ERROR}"
  C_WARN="${JSH_PALETTE_WARN}"
  C_OK="${JSH_PALETTE_OK}"
  C_INFO="${JSH_PALETTE_INFO}"
  C_MUTED="${JSH_PALETTE_MUTED}"
  C_ACCENT="${JSH_PALETTE_ACCENT}"

  # Semantic color aliases
  C_SUCCESS="${C_OK}"
  C_WARNING="${C_WARN}"
  C_ERROR="${C_ERR}"
  # C_INFO already defined above
  # C_MUTED already defined above
  C_GIT_CLEAN="${C_OK}"
  C_GIT_DIRTY="${C_WARN}"
  # Match Git's own status colors: staged changes are green, unstaged
  # changes are yellow, and untracked files are blue.
  C_GIT_STAGED="${C_OK}"
  C_GIT_UNTRACKED="${C_INFO}"
  C_GIT_CONFLICT="${C_ERR}"
  C_GIT_STASH="${C_ACCENT}"
  C_GIT_AHEAD="${C_OK}"
  C_GIT_BEHIND="${C_OK}"

  # Prompt-specific semantic colors
  C_DURATION="${C_MUTED}"
  C_PYTHON="${JSH_PALETTE_PYTHON}"
  C_KUBE="${JSH_PALETTE_KUBE}"
  C_CONTEXT="${C_OK}"
  C_JOBS="${C_ACCENT}"
else
  # No colors
  RST="" BLK="" RED="" GRN="" YLW="" BLU="" MAG="" CYN="" WHT=""
  BBLK="" BRED="" BGRN="" BYLW="" BBLU="" BMAG="" BCYN="" BWHT=""
  BOLD="" DIM="" ITAL="" UNDR=""
  BG_BLK="" BG_RED="" BG_GRN="" BG_YLW="" BG_BLU="" BG_MAG="" BG_CYN="" BG_WHT=""
  C_TEXT="" C_DIR="" C_FILE="" C_EXEC="" C_LINK="" C_GIT="" C_ERR="" C_WARN=""
  C_OK="" C_INFO="" C_MUTED="" C_ACCENT=""
  C_SUCCESS="" C_WARNING="" C_ERROR="" C_GIT_CLEAN="" C_GIT_DIRTY="" C_GIT_STAGED="" C_GIT_UNTRACKED=""
  C_GIT_CONFLICT="" C_GIT_STASH="" C_GIT_AHEAD="" C_GIT_BEHIND=""
  C_DURATION="" C_PYTHON="" C_KUBE="" C_CONTEXT="" C_JOBS=""
fi

# The high-chroma Dark Modern semantic palette is shared by prompts,
# command output, interactive selectors, and legacy scripts.
C_PRIMARY="${C_ACCENT}"

# =============================================================================
# Prompt-Safe Colors (for PS1)
# =============================================================================

# Wrap colors for prompt use (prevents readline length calculation issues)
if [[ "${JSH_SHELL}" == "zsh" ]]; then
  # Zsh uses %{ %} for zero-width sequences
  _p() { REPLY="%{$1%}"; }
else
  # Bash uses \[ \] for zero-width sequences
  _p() { REPLY="\\[$1\\]"; }
fi

# Pre-compute prompt-safe color codes
_p "${RST}"; P_RST="$REPLY"
_p "${RED}"; P_RED="$REPLY"
_p "${GRN}"; P_GRN="$REPLY"
_p "${YLW}"; P_YLW="$REPLY"
_p "${BLU}"; P_BLU="$REPLY"
_p "${MAG}"; P_MAG="$REPLY"
_p "${CYN}"; P_CYN="$REPLY"
_p "${WHT}"; P_WHT="$REPLY"
_p "${BOLD}"; P_BOLD="$REPLY"
_p "${DIM}"; P_DIM="$REPLY"
_p "${BBLK}"; P_BBLK="$REPLY"

# =============================================================================
# Logging Functions
# =============================================================================

# Log levels
JSH_LOG_LEVEL="${JSH_LOG_LEVEL:-1}"  # 0=off, 1=normal, 2=verbose, 3=debug
JSH_PLAIN_OUTPUT="${JSH_PLAIN_OUTPUT:-0}"

_log() {
  local level="$1" color="$2"
  shift 2
  [[ "${JSH_LOG_LEVEL}" -lt "${level}" ]] && return 0
  printf "%b%s%b\n" "${color}" "$*" "${RST}" >&2
}

info()    { _log 1 "${C_INFO}" "$@"; }
success() { _log 1 "${C_OK}" "$@"; }
warn()    { command -v jsh_boot_stage_warn >/dev/null 2>&1 && jsh_boot_stage_warn "$*" && return 0; _log 1 "${C_WARN}" "$@"; }
error()   { command -v jsh_boot_stage_fail >/dev/null 2>&1 && jsh_boot_stage_fail "$*" && return 0; _log 1 "${C_ERR}" "$@"; }
debug()   { _log 3 "${C_MUTED}" "$@"; }

die() {
  error "$@"
  exit 1
}

# Start a worker without exposing it through interactive job notifications.
# Bash process substitution launches the worker without adding it to the
# interactive shell's job table, while still making its PID available through
# `$!`. Zsh has a native `&!` equivalent.
_JSH_DETACHED_PID=""
jsh_run_detached() {
  local _jsh_output="silent" _jsh_pid
  [[ $# -gt 0 ]] || return 2

  if [[ "$1" == "--terminal" ]]; then
    _jsh_output="terminal"
    shift
  elif [[ "$1" == "--silent" ]]; then
    shift
  fi
  [[ $# -gt 0 ]] || return 2

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt localoptions no_bg_nice
    if [[ "${_jsh_output}" == "terminal" ]]; then
      # Bash cannot parse zsh's `&!` token even in an unreachable branch,
      # so defer parsing until zsh executes this path.
      eval '"$@" &!'
    else
      eval '( "$@" >/dev/null 2>&1 ) &!'
    fi
    _jsh_pid=$!
  elif [[ -n "${BASH_VERSION:-}" ]]; then
    if [[ "${_jsh_output}" == "terminal" ]]; then
      : < <( "$@" >/dev/tty 2>/dev/tty )
    else
      : < <( "$@" >/dev/null 2>&1 )
    fi
    _jsh_pid=$!
  else
    "$@" &
    _jsh_pid=$!
  fi

  _JSH_DETACHED_PID="${_jsh_pid}"
}

# =============================================================================
# Spinner (terminal-only animation for long-running operations)
# =============================================================================

_SPINNER_PID=""
_SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

_spinner_loop() {
  local msg="$1"
  local i=0
  local frame_count=${#_SPINNER_FRAMES[@]}
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays

  # Hide cursor
  printf '\e[?25l'

  while true; do
    printf '\r\e[K%s%s%s %s' "${C_ACCENT}" "${_SPINNER_FRAMES[$i]}" "${RST}" "${msg}"
    i=$(( (i + 1) % frame_count ))
    sleep "${JSH_SPINNER_INTERVAL:-0.09}"
  done
}

_spinner_cleanup() {
  spinner_stop
}

spinner_start() {
  local msg="${1:-Loading...}"

  # Only animate interactive terminal output. Logs remain stable text.
  [[ "${JSH_SPINNER:-auto}" != never ]] || return 0
  [[ "${JSH_OUTPUT:-terminal}" == terminal ]] || return 0
  [[ "${TERM:-}" != dumb ]] || return 0
  [[ ! -t 1 ]] && return 0

  # Set up cleanup trap
  trap '_spinner_cleanup' INT TERM

  jsh_run_detached --terminal _spinner_loop "${msg}"
  _SPINNER_PID="${_JSH_DETACHED_PID}"
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
  printf '%s%s%s\n' "${C_INFO}" "$*" "${RST}"
}
prefix_success() {
  printf '%s%s%s\n' "${C_OK}" "$*" "${RST}"
}
prefix_warn() {
  printf '%s%s%s\n' "${C_WARN}" "$*" "${RST}" >&2
}
prefix_error() {
  printf '%s%s%s\n' "${C_ERR}" "$*" "${RST}" >&2
}

# Compact compatibility renderers for interactive help and shell wrappers.
jsh_banner() {
  printf '\n%s%s%s%s\n' "${C_ACCENT}" "${BOLD}" "${1:-jsh}" "${RST}"
  [[ -z "${2:-}" ]] || printf '%s%s%s\n' "${C_MUTED}" "$2" "${RST}"
}

jsh_section() {
  printf '\n%s%s%s%s\n' "${C_ACCENT}" "${BOLD}" "${1:-}" "${RST}"
}

jsh_field() {
  local width="${3:-20}"
  printf '  %s%-*s%s %s\n' "${BOLD}" "${width}" "${1:-}" "${RST}" "${2:-}"
}

jsh_note() {
  printf '  %s%s%s\n' "${C_MUTED}" "$*" "${RST}"
}

jsh_detail() {
  printf '  %s%s%s\n' "${C_MUTED}" "$*" "${RST}"
}

jsh_command_preview() {
  printf '  %s$%s %s\n' "${C_ACCENT}" "${RST}" "$*"
}

# =============================================================================
# Interactive prompts
# =============================================================================

# Present a multi-choice prompt. Append `|off` for an unselected default.
# Usage: ui_checklist "Header" "id|Label[|off]" ...
# Result: REPLY contains selected IDs, one per line. Returns JSH_EXIT_CANCELLED
# on cancel and JSH_EXIT_NO_TERMINAL when no interactive terminal is available.
ui_checklist() {
  local header="$1" option id label default_state answer token row
  local index=1 choices="" defaults="" selected=""
  shift

  [[ -r /dev/tty && -w /dev/tty ]] || return "${JSH_EXIT_NO_TERMINAL:-2}"
  printf '%s\n' "${header}" >/dev/tty
  for option in "$@"; do
    id="${option%%|*}"
    label="${option#*|}"
    default_state=""
    if [[ "${label}" == *'|'* ]]; then
      default_state="${label##*|}"
      label="${label%%|*}"
    fi
    choices="${choices}${choices:+$'\n'}${index}|${id}"
    [[ "${default_state}" == off ]] || defaults="${defaults}${defaults:+$'\n'}${id}"
    printf '  [%d] %s%s\n' "${index}" "${label}" "$([[ "${default_state}" == off ]] || printf ' *')" >/dev/tty
    index=$((index + 1))
  done
  printf 'Select numbers separated by spaces (Enter keeps defaults): ' >/dev/tty
  IFS= read -r answer </dev/tty || return "${JSH_EXIT_CANCELLED:-130}"
  if [[ -z "${answer}" ]]; then
    REPLY="${defaults}"
    [[ -n "${REPLY}" ]] || return "${JSH_EXIT_NOTHING_SELECTED:-75}"
    return 0
  fi

  answer="${answer//,/ }"
  for token in ${=answer}; do
    row="${${(M)${(f)choices}:#${token}|*}[1]-}"
    [[ -n "${row}" ]] || return 2
    id="${row#*|}"
    selected="${selected}${selected:+$'\n'}${id}"
  done
  REPLY="${selected}"
  [[ -n "${REPLY}" ]] || return "${JSH_EXIT_NOTHING_SELECTED:-75}"
}

# Prompt for free-form input.
# Usage: ui_input "<prompt>" [default]
# Output: input value on stdout
ui_input() {
  local prompt="$1"
  local default="${2:-}"
  local response=""

  [[ -r /dev/tty && -w /dev/tty ]] || return "${JSH_EXIT_NO_TERMINAL:-2}"
  printf '%s' "${prompt}" >/dev/tty
  IFS= read -r response </dev/tty || return "${JSH_EXIT_CANCELLED:-130}"

  if [[ -z "${response}" ]]; then
    response="${default}"
  fi

  printf '%s\n' "${response}"
}

# Prompt for a password while showing one asterisk per entered character.
# The password is written to stdout so callers can capture it; all interaction
# is written to stderr so it remains visible during command substitution.
ui_password() {
  local prompt="${1:-Password: }"
  local password=""
  local char=""

  printf '%s' "${prompt}" >&2

  while IFS= read -r -s -n 1 char; do
    # With read -n, Enter is returned as an empty character.
    if [[ -z "${char}" ]]; then
      printf '\n' >&2
      printf '%s\n' "${password}"
      return 0
    fi

    case "${char}" in
      $'\177' | $'\b')
        if [[ -n "${password}" ]]; then
          password="${password%?}"
          printf '\b \b' >&2
        fi
        ;;
      *)
        password="${password}${char}"
        printf '*' >&2
        ;;
    esac
  done

  printf '\n' >&2
  return 1
}

# Prompt for yes/no confirmation.
# Usage: ui_confirm "<question>" [default: n]
# Returns: 0=yes, 1=no
ui_confirm() {
  local question="$1"
  local default="${2:-n}"
  local response="" default_yes=0

  [[ "${default}" != "y" ]] || default_yes=1

  local yn_prompt
  if [[ "${default}" == "y" ]]; then
    yn_prompt="[Y/n]"
  else
    yn_prompt="[y/N]"
  fi

  [[ -r /dev/tty && -w /dev/tty ]] || return "${JSH_EXIT_NO_TERMINAL:-2}"
  printf '%s %s ' "${question}" "${yn_prompt}" >/dev/tty
  IFS= read -r response </dev/tty || return "${JSH_EXIT_CANCELLED:-130}"

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

  [[ -r /dev/tty && -w /dev/tty ]] || return "${JSH_EXIT_NO_TERMINAL:-2}"
  printf '%s ' "${prompt}" >/dev/tty
  IFS= read -r response </dev/tty || return "${JSH_EXIT_CANCELLED:-130}"

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
  local entry
  local -a updated_path

  [[ -d "$1" ]] || return 0
  updated_path=("$1")
  for entry in "${path[@]}"; do
    [[ "$entry" == "$1" ]] || updated_path+=("$entry")
  done
  path=("${updated_path[@]}")
  export PATH
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
export JSH_CACHE_DIR="${JSH_CACHE_DIR:-${XDG_CACHE_HOME}/jsh}"
ensure_dir "${JSH_CACHE_DIR}"

if [[ "${JSH_MODE:-}" == lite && -r "${JSH_DIR}/dotfiles/.config/shell/runtime.sh" ]]; then
  source "${JSH_DIR}/dotfiles/.config/shell/runtime.sh"
fi

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
  _jsh_locale_list="$(locale -a 2>/dev/null || true)"
  _jsh_utf8_locale="$(printf '%s\n' "${_jsh_locale_list}" | grep -im1 '^en_US\.utf-\?8$' || true)"
  [[ -n "${_jsh_utf8_locale}" ]] || \
    _jsh_utf8_locale="$(printf '%s\n' "${_jsh_locale_list}" | grep -im1 '^C\.utf-\?8$' || true)"
  [[ -n "${_jsh_utf8_locale}" ]] || \
    _jsh_utf8_locale="$(printf '%s\n' "${_jsh_locale_list}" | grep -im1 'utf-\?8$' || true)"
  if [[ -n "${_jsh_utf8_locale}" ]]; then
    export LANG="${_jsh_utf8_locale}"
  elif [[ "${JSH_OS}" == "linux" ]]; then
    warn "UTF-8 locale not found — run: sudo locale-gen en_US.UTF-8"
  fi
  unset _jsh_locale_list _jsh_utf8_locale
fi

# =============================================================================
# Debug Mode
# =============================================================================

if [[ "${JSH_DEBUG:-0}" == "1" ]]; then
  JSH_LOG_LEVEL=3
  debug "JSH_OS=${JSH_OS} JSH_ARCH=${JSH_ARCH} JSH_SHELL=${JSH_SHELL} JSH_ENV=${JSH_ENV}"
  debug "JSH_HAS_COLOR=${JSH_HAS_COLOR} JSH_COLOR_COUNT=${JSH_COLOR_COUNT}"
fi

# =============================================================================
# Runtime
# =============================================================================
# runtime.sh - Profiles, capabilities, hooks, plugins, and bounded async jobs
# Pure Bash 3.2/zsh compatible shell.

# Runtime profiles select cost, not appearance. Users can override individual
# features with JSH_FEATURE_<UPPER_NAME>=0|1.
if [[ -z "${JSH_RUNTIME_PROFILE:-}" ]]; then
  if [[ "${JSH_SAFE_MODE:-0}" == "1" ]]; then JSH_RUNTIME_PROFILE=safe
  elif [[ "${JSH_ENV:-local}" == "ssh" ]]; then JSH_RUNTIME_PROFILE=ssh
  elif [[ "${JSH_ENV:-local}" == "container" ]]; then JSH_RUNTIME_PROFILE=container
  else JSH_RUNTIME_PROFILE=standard
  fi
fi
export JSH_RUNTIME_PROFILE

jsh_feature_enabled() {
  local feature="$1" override_name override=""
  case "$feature" in
    async) override_name=JSH_FEATURE_ASYNC ;;
    brew) override_name=JSH_FEATURE_BREW ;;
    completions) override_name=JSH_FEATURE_COMPLETIONS ;;
    git) override_name=JSH_FEATURE_GIT ;;
    navigation) override_name=JSH_FEATURE_NAVIGATION ;;
    plugins) override_name=JSH_FEATURE_PLUGINS ;;
    project-env) override_name=JSH_FEATURE_PROJECT_ENV ;;
    prompt) override_name=JSH_FEATURE_PROMPT ;;
    *)
      case "$feature" in ""|[0-9]*|*[!A-Za-z0-9_]*) return 2 ;; esac
      override_name="JSH_FEATURE_${feature}"
      ;;
  esac
  eval "override=\${${override_name}:-}"
  [[ "$override" == 1 ]] && return 0
  [[ "$override" == 0 ]] && return 1

  case "${JSH_RUNTIME_PROFILE}:${feature}" in
    safe:prompt|safe:navigation) return 0 ;;
    minimal:prompt|minimal:navigation|minimal:git|minimal:async) return 0 ;;
    ssh:prompt|ssh:navigation|ssh:git|ssh:async|ssh:project-env) return 0 ;;
    container:prompt|container:navigation|container:git|container:async|container:completions|container:project-env) return 0 ;;
    standard:prompt|standard:navigation|standard:git|standard:async|standard:brew|standard:completions|standard:plugins|standard:project-env) return 0 ;;
    full:*) return 0 ;;
  esac
  return 1
}

# Capability queries give modules one stable portability boundary.
jsh_has_capability() {
  case "$1" in
    async) jsh_feature_enabled async ;;
    color) [[ "${JSH_HAS_COLOR:-0}" == 1 ]] ;;
    clipboard) command -v pbcopy >/dev/null 2>&1 || command -v wl-copy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1 ;;
    notifications) command -v osascript >/dev/null 2>&1 || command -v notify-send >/dev/null 2>&1 ;;
    open) command -v open >/dev/null 2>&1 || command -v xdg-open >/dev/null 2>&1 ;;
    truecolor) [[ "${JSH_COLOR_COUNT:-0}" -ge 16777216 ]] ;;
    unicode) [[ "${LANG:-${LC_ALL:-}}" == *UTF-8* || "${LANG:-${LC_ALL:-}}" == *utf8* ]] ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}

jsh_platform_open() {
  case "${JSH_OS:-unknown}" in
    macos) command open "$@" ;;
    linux) command xdg-open "$@" ;;
    *) return 127 ;;
  esac
}

jsh_clipboard_copy() {
  case "${JSH_OS:-unknown}" in
    macos) command pbcopy ;;
    *)
      if command -v wl-copy >/dev/null 2>&1; then command wl-copy
      elif command -v xclip >/dev/null 2>&1; then command xclip -selection clipboard
      else return 127; fi
      ;;
  esac
}

jsh_clipboard_paste() {
  case "${JSH_OS:-unknown}" in
    macos) command pbpaste ;;
    *)
      if command -v wl-paste >/dev/null 2>&1; then command wl-paste --no-newline
      elif command -v xclip >/dev/null 2>&1; then command xclip -selection clipboard -out
      else return 127; fi
      ;;
  esac
}

jsh_notify() {
  local title="${1:-jsh}" message="${2:-Done}"
  case "${JSH_OS:-unknown}" in
    macos)
      command osascript \
        -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' -- "$title" "$message" >/dev/null
      ;;
    linux) command notify-send "$title" "$message" ;;
    *) return 127 ;;
  esac
}

# Long-running Task recipes advertise their activity in the terminal tab even
# when their ordinary output is streaming and cannot host an inline spinner.
_JSH_OPERATION_TITLE_PID=''
_JSH_OPERATION_TITLE_ACTIVE=0

_jsh_operation_title_enabled() {
  [[ "${JSH_TITLE:-auto}" != never ]] || return 1
  [[ "${TERM:-}" != dumb ]] || return 1
  [[ "${JSH_TITLE:-auto}" == always || -t 2 ]]
}

_jsh_operation_title_frame() {
  local frame="${1:-⠋}" label="${2:-operation}"
  _jsh_operation_title_enabled || return 0
  label="${label//$'\n'/ }"
  label="${label//$'\r'/ }"
  printf '\033]2;%s jsh · %s\007' "${frame}" "${label}" >&2
}

_jsh_operation_title_loop() {
  local parent="$1" operation="$2" frame=0
  while kill -0 "${parent}" 2>/dev/null; do
    case $((frame % 10)) in
      0) _jsh_operation_title_frame '⠋' "${operation}" ;;
      1) _jsh_operation_title_frame '⠙' "${operation}" ;;
      2) _jsh_operation_title_frame '⠹' "${operation}" ;;
      3) _jsh_operation_title_frame '⠸' "${operation}" ;;
      4) _jsh_operation_title_frame '⠼' "${operation}" ;;
      5) _jsh_operation_title_frame '⠴' "${operation}" ;;
      6) _jsh_operation_title_frame '⠦' "${operation}" ;;
      7) _jsh_operation_title_frame '⠧' "${operation}" ;;
      8) _jsh_operation_title_frame '⠇' "${operation}" ;;
      *) _jsh_operation_title_frame '⠏' "${operation}" ;;
    esac
    frame=$((frame + 1))
    sleep "${JSH_TITLE_INTERVAL:-0.12}"
  done
}

_jsh_operation_title_start() {
  local command_line="${1:-}" executable remainder operation parent
  [[ "${_JSH_OPERATION_TITLE_ACTIVE:-0}" != 1 ]] || return 0
  _jsh_operation_title_enabled || return 0
  command_line="${command_line#"${command_line%%[![:space:]]*}"}"
  executable="${command_line%%[[:space:]]*}"
  [[ "${executable##*/}" == task ]] || return 0
  remainder="${command_line#"${executable}"}"
  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  operation="${remainder%%[[:space:]]*}"
  case "${operation}" in ''|reload|-r|--reload|-*) return 0 ;; esac

  _JSH_OPERATION_TITLE_ACTIVE=1
  export JSH_OPERATION_TITLE_ACTIVE=1
  parent="$$"
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    # zsh's &! launches and disowns atomically, preventing job-start and
    # terminated notifications. Keep the zsh-only token behind eval so
    # this shared runtime still parses in Bash 3.2.
    # shellcheck disable=SC2294
    eval '_jsh_operation_title_loop "${parent}" "${operation}" &!'
    _JSH_OPERATION_TITLE_PID=$!
  else
    _jsh_operation_title_loop "${parent}" "${operation}" &
    _JSH_OPERATION_TITLE_PID=$!
    disown "${_JSH_OPERATION_TITLE_PID}" 2>/dev/null || true
  fi
}

_jsh_operation_title_stop() {
  if [[ -n "${_JSH_OPERATION_TITLE_PID:-}" ]]; then
    kill "${_JSH_OPERATION_TITLE_PID}" 2>/dev/null || true
    wait "${_JSH_OPERATION_TITLE_PID}" 2>/dev/null || true
    _JSH_OPERATION_TITLE_PID=''
  fi
  _JSH_OPERATION_TITLE_ACTIVE=0
  unset JSH_OPERATION_TITLE_ACTIVE
}

_jsh_operation_title_preexec() { _jsh_operation_title_start "${1:-}"; }
_jsh_operation_title_precmd() { _jsh_operation_title_stop; }

_jsh_terminal_cwd() {
  local url_path='' remaining="${PWD}" ch hexch
  local host="${HOSTNAME:-${HOST:-localhost}}"
  local LC_CTYPE=C LC_COLLATE=C LC_ALL='' LANG=''

  while [[ -n "${remaining}" ]]; do
    ch="${remaining%"${remaining#?}"}"
    remaining="${remaining#?}"
    case "${ch}" in
      [/.~_A-Za-z0-9-]) url_path="${url_path}${ch}" ;;
      *)
        printf -v hexch '%02X' "'${ch}"
        hexch="${hexch#"${hexch%??}"}"
        url_path="${url_path}%${hexch}"
        ;;
    esac
  done

  printf '\033]7;file://%s%s\007' "${host}" "${url_path}" >&2
}

# Central hook registry. Priority <= 10 runs before ordinary hooks, which lets
# the prompt capture the previous exit status before title/plugin hooks.
jsh_hook_add() {
  local event="$1" fn="$2" priority="${3:-50}" array_name
  case "$event" in precmd|preexec|chpwd|zshexit) ;; *) return 2 ;; esac
  case "$fn" in ""|[0-9]*|*[!A-Za-z0-9_]*) return 2 ;; esac
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    autoload -Uz add-zsh-hook
    add-zsh-hook "$event" "$fn"
    array_name="${event}_functions"
    if [[ "$priority" -le 10 ]]; then
      eval "$array_name=(\"$fn\" \${$array_name:#$fn})"
    fi
  else
    local current new_list
    array_name="_JSH_HOOK_${event}"
    eval "current=\${${array_name}:-}"
    case " ${current} " in *" ${fn} "*) return 0 ;; esac
    if [[ "$priority" -le 10 ]]; then
      new_list="${fn}${current:+ ${current}}"
    else
      new_list="${current}${current:+ }${fn}"
    fi
    eval "$array_name=\"\$new_list\""
    case "$event" in
      precmd)
        if [[ "${_JSH_BASH_PRECMD_INSTALLED:-0}" != 1 ]]; then
          _JSH_BASH_PRECMD_INSTALLED=1
          _JSH_BASH_LEGACY_PROMPT_COMMAND="${PROMPT_COMMAND:-}"
          PROMPT_COMMAND=_jsh_hook_bash_precmd
        fi
        ;;
      preexec)
        if [[ "${_JSH_BASH_PREEXEC_INSTALLED:-0}" != 1 ]]; then
          _JSH_BASH_PREEXEC_INSTALLED=1
          trap '_jsh_hook_bash_debug' DEBUG
        fi
        ;;
    esac
  fi
}

_jsh_hook_dispatch() {
  local event="$1" hook_status="${2:-0}" list fn
  eval "list=\${_JSH_HOOK_${event}:-}"
  while [[ -n "$list" ]]; do
    fn="${list%% *}"
    if [[ "$list" == *" "* ]]; then list="${list#* }"; else list=""; fi
    [[ -n "$fn" ]] && "$fn" "$hook_status"
  done
}

_jsh_hook_bash_precmd() {
  local previous_status=$?
  _jsh_hook_dispatch precmd "$previous_status"
  [[ -n "${_JSH_BASH_LEGACY_PROMPT_COMMAND:-}" ]] && eval "${_JSH_BASH_LEGACY_PROMPT_COMMAND}"
}

_jsh_hook_bash_debug() {
  [[ "${_JSH_BASH_DEBUG_ACTIVE:-0}" == 1 ]] && return 0
  case "${BASH_COMMAND:-}" in _jsh_hook_*|trap\ *) return 0 ;; esac
  _JSH_BASH_DEBUG_ACTIVE=1
  _jsh_hook_dispatch preexec "${BASH_COMMAND:-}"
  _JSH_BASH_DEBUG_ACTIVE=0
}

# Trap registry prevents unrelated modules from replacing one another.
jsh_trap_add() {
  local signal="$1" fn="$2" name current new_list
  case "$signal" in ""|*[!A-Za-z0-9]*) return 2 ;; esac
  case "$fn" in ""|[0-9]*|*[!A-Za-z0-9_]*) return 2 ;; esac
  name="_JSH_TRAP_${signal}"
  eval "current=\${${name}:-}"
  case " ${current} " in *" ${fn} "*) return 0 ;; esac
  new_list="${current}${current:+ }${fn}"
  eval "$name=\"\$new_list\""
  trap "_jsh_trap_dispatch $signal" "$signal"
}

_jsh_trap_dispatch() {
  local signal="$1" list fn
  eval "list=\${_JSH_TRAP_${signal}:-}"
  while [[ -n "$list" ]]; do
    fn="${list%% *}"
    if [[ "$list" == *" "* ]]; then list="${list#* }"; else list=""; fi
    [[ -n "$fn" ]] && "$fn"
  done
}

# Public plugin API. A plugin is a readable plugin.sh in either plugin root.
JSH_PLUGIN_PATH="${JSH_PLUGIN_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/jsh/plugins:${JSH_DIR}/plugins}"
JSH_PLUGIN_LOCK_FILE="${JSH_PLUGIN_LOCK_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/jsh/plugins.lock}"
_JSH_PLUGIN_NAMES=()
_JSH_PLUGIN_FILES=()

jsh_plugin_register() {
  local name="$1" file="$2" existing
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays
  for existing in "${_JSH_PLUGIN_NAMES[@]}"; do [[ "$existing" == "$name" ]] && return 0; done
  _JSH_PLUGIN_NAMES[${#_JSH_PLUGIN_NAMES[@]}]="$name"
  _JSH_PLUGIN_FILES[${#_JSH_PLUGIN_FILES[@]}]="$file"
}

jsh_plugins_discover() {
  local root dir name roots="${JSH_PLUGIN_PATH}:"
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions nonomatch
  while [[ -n "$roots" ]]; do
    root="${roots%%:*}"
    roots="${roots#*:}"
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] || continue
    for dir in "$root"/*; do
      [[ -d "$dir" && -r "$dir/plugin.sh" ]] || continue
      name="${dir##*/}"
      jsh_plugin_register "$name" "$dir/plugin.sh"
    done
    [[ -r "$root/plugin.sh" ]] && jsh_plugin_register "${root##*/}" "$root/plugin.sh"
  done
  return 0
}

jsh_plugin_hash() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    REPLY="$(shasum -a 256 "$file" 2>/dev/null)"; REPLY="${REPLY%% *}"
  elif command -v sha256sum >/dev/null 2>&1; then
    REPLY="$(sha256sum "$file" 2>/dev/null)"; REPLY="${REPLY%% *}"
  else REPLY=""; return 1
  fi
  [[ -n "$REPLY" ]]
}

jsh_plugin_verify() {
  local name="$1" file="$2" locked_name locked_file locked_hash actual
  if [[ ! -r "$JSH_PLUGIN_LOCK_FILE" ]]; then
    [[ "${JSH_PLUGIN_REQUIRE_LOCK:-0}" != 1 ]]
    return
  fi
  while IFS='|' read -r locked_name locked_file locked_hash; do
    [[ "$locked_name" == "$name" && "$locked_file" == "$file" ]] || continue
    jsh_plugin_hash "$file" || return 1; actual="$REPLY"
    [[ "$actual" == "$locked_hash" ]]
    return
  done <"$JSH_PLUGIN_LOCK_FILE"
  return 1
}

jsh_plugins_load() {
  local i=0 plugin
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays
  jsh_plugins_discover
  while [[ $i -lt ${#_JSH_PLUGIN_FILES[@]} ]]; do
    plugin="${_JSH_PLUGIN_FILES[$i]}"
    if jsh_plugin_verify "${_JSH_PLUGIN_NAMES[$i]}" "$plugin"; then
      # shellcheck disable=SC1090
      source "$plugin"
    else
      warn "Plugin failed lock verification: ${_JSH_PLUGIN_NAMES[$i]}"
    fi
    i=$((i + 1))
  done
}

# Bounded, coalescing async manager. Workers write one result record and are
# polled from precmd; this avoids one bespoke process manager per feature.
JSH_ASYNC_MAX_JOBS="${JSH_ASYNC_MAX_JOBS:-2}"
_JSH_ASYNC_KEYS=()
_JSH_ASYNC_PIDS=()
_JSH_ASYNC_FILES=()
_JSH_ASYNC_STATUS_FILES=()
_JSH_ASYNC_CALLBACKS=()
_JSH_ASYNC_SERIAL=0

_jsh_async_worker_wrapper() {
  local _jsh_worker="$1" _jsh_file="$2" _jsh_status_file="$3" _jsh_worker_status=0
  shift 3
  "${_jsh_worker}" "$@" >"${_jsh_file}" 2>/dev/null || _jsh_worker_status=$?
  printf '%s\n' "${_jsh_worker_status}" >"${_jsh_status_file}"
}

jsh_async_submit() {
  local key="$1" worker="$2" callback="$3" i=0 active=0 file status_file pid
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt localoptions ksharrays
    unsetopt bg_nice
  fi
  shift 3
  jsh_feature_enabled async || return 1
  while [[ $i -lt ${#_JSH_ASYNC_KEYS[@]} ]]; do
    [[ "${_JSH_ASYNC_KEYS[$i]}" == "$key" ]] && return 0
    [[ ! -s "${_JSH_ASYNC_STATUS_FILES[$i]}" ]] && active=$((active + 1))
    i=$((i + 1))
  done
  [[ "$active" -lt "$JSH_ASYNC_MAX_JOBS" ]] || return 1
  ensure_dir "${JSH_CACHE_DIR}/async"
  _JSH_ASYNC_SERIAL=$((_JSH_ASYNC_SERIAL + 1))
  file="${JSH_CACHE_DIR}/async/${key//[^a-zA-Z0-9_.-]/_}.$$.${_JSH_ASYNC_SERIAL}"
  status_file="${file}.status"
  command rm -f -- "$file" "$status_file"
  # The wrapper preserves the worker's output/status contract while the
  # shared launcher suppresses interactive job-start notifications.
  jsh_run_detached --silent _jsh_async_worker_wrapper "$worker" "$file" "$status_file" "$@"
  pid="${_JSH_DETACHED_PID}"
  i=${#_JSH_ASYNC_KEYS[@]}
  _JSH_ASYNC_KEYS[i]="$key"; _JSH_ASYNC_PIDS[i]="$pid"
  _JSH_ASYNC_FILES[i]="$file"; _JSH_ASYNC_STATUS_FILES[i]="$status_file"
  _JSH_ASYNC_CALLBACKS[i]="$callback"
}

jsh_async_poll() {
  local i=0 new_count=0 key pid file status_file callback data job_status
  local -a new_keys=() new_pids=() new_files=() new_status_files=() new_callbacks=()
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays
  while [[ $i -lt ${#_JSH_ASYNC_KEYS[@]} ]]; do
    key="${_JSH_ASYNC_KEYS[$i]}"; pid="${_JSH_ASYNC_PIDS[$i]}"
    file="${_JSH_ASYNC_FILES[$i]}"; status_file="${_JSH_ASYNC_STATUS_FILES[$i]}"
    callback="${_JSH_ASYNC_CALLBACKS[$i]}"
    if [[ ! -s "$status_file" ]]; then
      new_keys[new_count]="$key"; new_pids[new_count]="$pid"
      new_files[new_count]="$file"; new_status_files[new_count]="$status_file"
      new_callbacks[new_count]="$callback"
      new_count=$((new_count + 1)); i=$((i + 1)); continue
    fi
    job_status="$(<"$status_file")"
    case "$job_status" in ''|*[!0-9]*) job_status=1 ;; esac
    data=""; [[ -r "$file" ]] && data="$(<"$file")"
    "$callback" "$key" "$job_status" "$data"
    command rm -f -- "$file" "$status_file"
    i=$((i + 1))
  done
  if [[ "$new_count" -eq 0 ]]; then
    _JSH_ASYNC_KEYS=(); _JSH_ASYNC_PIDS=(); _JSH_ASYNC_FILES=()
    _JSH_ASYNC_STATUS_FILES=(); _JSH_ASYNC_CALLBACKS=()
  else
    _JSH_ASYNC_KEYS=("${new_keys[@]}"); _JSH_ASYNC_PIDS=("${new_pids[@]}")
    _JSH_ASYNC_FILES=("${new_files[@]}")
    _JSH_ASYNC_STATUS_FILES=("${new_status_files[@]}")
    _JSH_ASYNC_CALLBACKS=("${new_callbacks[@]}")
  fi
}

jsh_async_stop_all() {
  local pid file
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays
  for pid in "${_JSH_ASYNC_PIDS[@]-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  for file in "${_JSH_ASYNC_FILES[@]-}" "${_JSH_ASYNC_STATUS_FILES[@]-}"; do
    [[ -n "$file" ]] && command rm -f -- "$file" 2>/dev/null || true
  done
  _JSH_ASYNC_KEYS=(); _JSH_ASYNC_PIDS=(); _JSH_ASYNC_FILES=()
  _JSH_ASYNC_STATUS_FILES=(); _JSH_ASYNC_CALLBACKS=()
}

if [[ $- == *i* ]]; then
  jsh_trap_add EXIT jsh_async_stop_all
  jsh_hook_add precmd jsh_async_poll 90
fi

# Paths
path_prepend "${JSH_DIR}/local/bin"
path_prepend "${HOME}/.local/bin"
path_prepend "${HOME}/.cargo/bin"
path_prepend "${HOME}/go/bin"
path_prepend "${HOME}/.npm-global/bin"
path_prepend "${HOME}/.local/share/pnpm/bin"
path_prepend "${HOME}/.cache/.bun/bin"
path_prepend "${JSH_DIR}/bin"

# =============================================================================
# Homebrew
# =============================================================================
# brew.sh - Homebrew/Linuxbrew shellenv caching for faster shell startup
# Caches `brew shellenv` output to avoid 20-40ms overhead per shell
# Works on both macOS (Homebrew) and Linux (Linuxbrew)
# shellcheck disable=SC2034

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
    REPLY="/opt/homebrew"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    REPLY="/usr/local"
  elif [[ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
    REPLY="/home/linuxbrew/.linuxbrew"
  elif [[ -x "${HOME}/.linuxbrew/bin/brew" ]]; then
    REPLY="${HOME}/.linuxbrew"
  else
    if _brew_is_linux_root; then
      local delegate_user delegate_home
      delegate_user=$(_brew_delegate_user 2>/dev/null || true)
      if [[ -n "${delegate_user}" ]]; then
        delegate_home=$(_brew_user_home "${delegate_user}")
        if [[ -n "${delegate_home}" ]] && [[ -x "${delegate_home}/.linuxbrew/bin/brew" ]]; then
          REPLY="${delegate_home}/.linuxbrew"
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
  [[ "${OSTYPE:-}" == linux* ]] && [[ "${EUID:-1}" == "0" ]]
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
      _brew_warn_once "brew cannot run as root on Linux. Set JSH_BREW_DELEGATE_USER or run 'task install'."
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
  [[ -n "${shellenv_output}" ]] && [[ "${shellenv_output}" == *HOMEBREW_PREFIX* ]] || return 1

  # Publish only a complete cache so an interrupted worker cannot make future
  # shells source an empty environment.
  local cache_tmp
  cache_tmp="$(mktemp "${_BREW_CACHE_DIR}/shellenv.XXXXXX")" || return 1
  printf '%s\n' "${shellenv_output}" >"${cache_tmp}"
  mv "${cache_tmp}" "${_BREW_CACHE_FILE}"

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
  local brew_prefix _brew_worker_pid
  _brew_find_prefix || return 0
  brew_prefix="$REPLY"

  # shellenv is effectively static for an installed prefix. Trust the cache
  # on the startup path; expensive TTL and git-HEAD validation belongs in the
  # background and in explicit maintenance commands.
  if [[ -r "${_BREW_CACHE_FILE}" ]] && grep -q 'HOMEBREW_PREFIX' "${_BREW_CACHE_FILE}"; then
    # shellcheck disable=SC1090
    source "${_BREW_CACHE_FILE}"
    [[ "${JSH_DEBUG:-0}" == "1" ]] && debug "brew.sh: Using cached shellenv"
  else
    rm -f "${_BREW_CACHE_FILE}"
    # A deterministic prefix is enough for this shell. Populate the richer
    # cache asynchronously for the next one.
    PATH="${brew_prefix}/bin:${brew_prefix}/sbin:${PATH}"
    export PATH
    jsh_run_detached --silent _brew_update_cache "${brew_prefix}"
    _brew_worker_pid="${_JSH_DETACHED_PID}"
  fi

  # Do not leak the status of the optional debug expression above. Reaching
  # this point means the environment was either loaded or was not needed.
  return 0
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
  _brew_find_prefix || {
    echo "Homebrew/Linuxbrew not found"
    return 1
  }
  brew_prefix="$REPLY"

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
path_prepend "${JSH_DIR}/bin"

# =============================================================================
# Aliases
# =============================================================================
# aliases.sh - Tiered alias system
# Core aliases always load, extended aliases load if tools detected
# shellcheck disable=SC2139,SC2034,SC2142,SC2262,SC2263
# SC2262/SC2263: Defining and checking aliases in same file is standard for shell configs

# =============================================================================
# Core Aliases (Always Loaded)
# =============================================================================

alias p='j'
alias jj='gitx profile'
alias projects='gitx list -v'

# -----------------------------------------------------------------------------
# Navigation
# -----------------------------------------------------------------------------
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'

alias ~='cd ~'

# -----------------------------------------------------------------------------
# Directory Listing
# -----------------------------------------------------------------------------
# Smart ls: use eza if available, else ls with colors
if has eza; then
  unalias ls 2>/dev/null || true
  ls() {
  local -a eza_args=("--group-directories-first")
  local arg cluster flag

  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift

    case "${arg}" in
    --)
      eza_args+=("--" "$@")
      break
      ;;
    --*|-)
      eza_args+=("${arg}")
      ;;
    -?*)
      cluster="${arg#-}"
      while [[ -n "${cluster}" ]]; do
      flag="${cluster%"${cluster#?}"}"
      cluster="${cluster#?}"
      case "${flag}" in
        t) eza_args+=("--sort=modified") ;;
        S) eza_args+=("--sort=size") ;;
        h) ;; # eza is human-readable by default; do not enable its header.
        *) eza_args+=("-${flag}") ;;
      esac
      done
      ;;
    *)
      eza_args+=("${arg}")
      ;;
    esac
  done

  command eza "${eza_args[@]}"
  }
  alias l='eza -la --group-directories-first --git'
  alias ll='eza -l --group-directories-first'
  alias la='eza -la --group-directories-first'
  alias lt='eza -la --sort=modified'
  alias lS='eza -la --sort=size'
  alias tree='eza --tree'
elif has exa; then
  alias ls='exa --group-directories-first'
  alias l='exa -la --group-directories-first --git'
  alias ll='exa -l --group-directories-first'
  alias la='exa -la --group-directories-first'
  alias lt='exa -la --sort=modified'
  alias lS='exa -la --sort=size'
  alias tree='exa --tree'
else
  # BSD ls can accept an unknown long option as a pathname and still exit 0.
  # Test the complete GNU option set before selecting the GNU-specific alias.
  if command ls --color=auto --group-directories-first &>/dev/null; then
  alias ls='ls --color=auto --group-directories-first'
  else
  alias ls='ls -G' # macOS/BSD
  fi
  alias l='ls -lAh'
  alias ll='ls -lh'
  alias la='ls -lAh'
  alias lt='ls -lAht'
  alias lS='ls -lAhS'
fi

# -----------------------------------------------------------------------------
# File Operations (Safe Defaults)
# -----------------------------------------------------------------------------
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -I' # Prompt before removing more than 3 files
alias mkdir='mkdir -pv'
alias ln='ln -iv'

# -----------------------------------------------------------------------------
# Search and Find
# -----------------------------------------------------------------------------
source "${JSH_DIR}/dotfiles/.config/shell/grep.sh"

# -----------------------------------------------------------------------------
# File Viewing
# -----------------------------------------------------------------------------
# Use bat if available
if has bat; then
  alias cat='bat --paging=never'
  alias less='bat'
elif has batcat; then
  alias cat='batcat --paging=never'
  alias less='batcat'
fi

# -----------------------------------------------------------------------------
# Quick Commands
# -----------------------------------------------------------------------------
alias c='clear'
alias e='exit'
alias q='exit'
alias cls='clear'
alias clr='clear'

alias path='echo "$PATH" | tr ":" "\n"'
alias now='date "+%Y-%m-%d %H:%M:%S"'
alias ts='date +%s'
alias week='date +%V'

# -----------------------------------------------------------------------------
# Editors
# -----------------------------------------------------------------------------
if has nvim; then
  alias vim='nvim'
  alias vi='nvim'
elif has vim; then
  alias vi='vim'
  alias v='vim'
fi

alias e='"${EDITOR:-vi}"'

# -----------------------------------------------------------------------------
# Disk and System
# -----------------------------------------------------------------------------
alias df='df -h'
alias du='du -h'
alias free='free -h 2>/dev/null || vm_stat' # Linux vs macOS

# -----------------------------------------------------------------------------
# Process Management
# -----------------------------------------------------------------------------
alias psg='ps aux | grep -v grep | grep'
alias psa='ps aux'
alias top='htop 2>/dev/null || top'

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
alias ports='netstat -tulanp 2>/dev/null || lsof -i -P -n'
alias myip='curl -s https://api.ipify.org && echo'
alias localip='ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk "{print \$1}"'

# -----------------------------------------------------------------------------
# History
# -----------------------------------------------------------------------------
alias hist='history'
alias hg='history | grep'

# =============================================================================
# Git Aliases
# =============================================================================

if has git; then
  alias g='git'
  alias gs='git status -sb'
  alias gst='git status'
  alias ga='git add'
  alias gaa='git add --all'
  alias gap='git add -p'
  alias gc='git commit'
  alias gcm='git commit -m'
  alias gca='git commit --amend'
  alias gcan='git commit --amend --no-edit'
  alias gco='git checkout'
  alias gcb='git checkout -b'
  alias gb='git branch'
  alias gba='git branch -a'
  alias gbd='git branch -d'
  alias gd='git diff'
  alias gds='git diff --staged'
  alias gdw='git diff --word-diff'
  alias gl='git log --oneline -20'
  alias gla='git log --oneline --all --graph --decorate'
  alias glg='git log --graph --pretty=format:"%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset" --abbrev-commit'
  alias gp='git push'
  alias gpf='git push --force-with-lease'
  alias gpu='git push -u origin HEAD'
  alias gpl='git pull'
  alias gpr='git pull --rebase'
  alias gf='git fetch'
  alias gfa='git fetch --all --prune'
  alias gm='git merge'
  alias grb='git rebase'
  alias grbi='git rebase -i'
  alias grbc='git rebase --continue'
  alias grba='git rebase --abort'
  alias grs='git reset'
  alias grsh='git reset --hard'
  alias grss='git reset --soft'
  alias gss='git stash'
  alias gsp='git stash pop'
  alias gsl='git stash list'
  alias gsd='git stash drop'
  alias gcp='git cherry-pick'
  alias gcpc='git cherry-pick --continue'
  alias gcpa='git cherry-pick --abort'
  alias gwip='git add -A && git commit -m "WIP"'
  alias gunwip='git log -1 --format="%s" | grep -q "WIP" && git reset HEAD~1'
  alias gundo='git reset --soft HEAD~1'
  alias gclean='git clean -fd'
  alias gremote='git remote -v'
  alias gtag='git tag'
  alias gcount='git rev-list --count HEAD'
fi

# =============================================================================
# Extended Aliases (Tool Detection)
# =============================================================================

# -----------------------------------------------------------------------------
# Claude
# -----------------------------------------------------------------------------
if has claude; then
  alias claude-mem='bun "$HOME/.claude/plugins/marketplaces/thedotmack/plugin/scripts/worker-service.cjs"'
  alias claudia='claude --permission-mode plan --allow-dangerously-skip-permissions'
fi

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------
if has docker; then
  alias d='docker'
  alias dc='docker compose'
  alias dps='docker ps'
  alias dpsa='docker ps -a'
  alias di='docker images'
  alias dex='docker exec -it'
  alias drun='docker run -it --rm'
  alias dlogs='docker logs -f'
  alias dstop='docker stop $(docker ps -q) 2>/dev/null'
  alias drm='docker rm $(docker ps -aq) 2>/dev/null'
  alias drmi='docker rmi $(docker images -q) 2>/dev/null'
  alias dprune='docker system prune -af'
  alias dvol='docker volume ls'
  alias dnet='docker network ls'
fi

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------
if has kubectl; then
  alias k='kubectl'
  alias kx='kubectx 2>/dev/null || kubectl config get-contexts'
  alias kn='kubens 2>/dev/null || kubectl config set-context --current --namespace'
  alias kg='kubectl get'
  alias kgp='kubectl get pods'
  alias kgpa='kubectl get pods --all-namespaces'
  alias kgd='kubectl get deployments'
  alias kgs='kubectl get services'
  alias kgn='kubectl get nodes'
  alias kgns='kubectl get namespaces'
  alias kgi='kubectl get ingress'
  alias kgcm='kubectl get configmaps'
  alias kgsec='kubectl get secrets'
  alias kd='kubectl describe'
  alias kdp='kubectl describe pod'
  alias kdd='kubectl describe deployment'
  alias kds='kubectl describe service'
  alias kl='kubectl logs -f'
  alias klp='kubectl logs -f --previous'
  alias kex='kubectl exec -it'
  alias kaf='kubectl apply -f'
  alias kdf='kubectl delete -f'
  alias kctx='kubectl config current-context'
  alias kns='kubectl config view --minify -o jsonpath="{..namespace}"'
  alias ktop='kubectl top'
  alias ktopp='kubectl top pods'
  alias ktopn='kubectl top nodes'
  alias kpf='kubectl port-forward'
  alias kroll='kubectl rollout'
  alias krollr='kubectl rollout restart'
  alias krolls='kubectl rollout status'
fi

# Helm
if has helm; then
  alias h='helm'
  alias hl='helm list'
  alias hla='helm list -A'
  alias hi='helm install'
  alias hu='helm upgrade'
  alias hd='helm delete'
  alias hs='helm search repo'
  alias hr='helm repo'
  alias hra='helm repo add'
  alias hru='helm repo update'
fi

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------
if has terraform; then
  alias tf='terraform'
  alias tfi='terraform init'
  alias tfp='terraform plan'
  alias tfa='terraform apply'
  alias tfaa='terraform apply -auto-approve'
  alias tfd='terraform destroy'
  alias tff='terraform fmt'
  alias tfv='terraform validate'
  alias tfo='terraform output'
  alias tfs='terraform state'
  alias tfsl='terraform state list'
  alias tfw='terraform workspace'
  alias tfwl='terraform workspace list'
  alias tfws='terraform workspace select'
fi

if has terragrunt; then
  alias tg='terragrunt'
  alias tgi='terragrunt init'
  alias tgp='terragrunt plan'
  alias tga='terragrunt apply'
  alias tgaa='terragrunt apply -auto-approve'
  alias tgd='terragrunt destroy'
  alias tgra='terragrunt run-all'
fi

# -----------------------------------------------------------------------------
# Tmux
# -----------------------------------------------------------------------------
if has tmux; then
  alias t='tmux'
  alias ta='tmux attach -t'
  alias tn='tmux new -s'
  alias tl='tmux ls'
  alias tk='tmux kill-session -t'
  alias tka='tmux kill-server'
fi

# -----------------------------------------------------------------------------
# Python
# -----------------------------------------------------------------------------
if has python3 || has python; then
  alias py='python3 2>/dev/null || python'
  alias py3='python3'
  alias pip='pip3 2>/dev/null || pip'
  alias venv='python3 -m venv'
  alias activate='source venv/bin/activate 2>/dev/null || source .venv/bin/activate'
  alias deact='deactivate'
fi

# -----------------------------------------------------------------------------
# Node.js
# -----------------------------------------------------------------------------
if has npm; then
  alias ni='npm install'
  alias nid='npm install --save-dev'
  alias nig='npm install -g'
  alias nr='npm run'
  alias ns='npm start'
  alias nt='npm test'
  alias nb='npm run build'
  alias nci='npm ci'
  alias nu='npm update'
  alias nout='npm outdated'
fi

if has yarn; then
  alias y='yarn'
  alias ya='yarn add'
  alias yad='yarn add -D'
  alias yr='yarn run'
  alias ys='yarn start'
  alias yt='yarn test'
  alias yb='yarn build'
fi

if has pnpm; then
  alias pn='pnpm'
  alias pni='pnpm install'
  alias pna='pnpm add'
  alias pnad='pnpm add -D'
  alias pnr='pnpm run'
fi

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
if has go; then
  alias gor='go run'
  alias gob='go build'
  alias got='go test'
  alias gotv='go test -v'
  alias gom='go mod'
  alias gomt='go mod tidy'
  alias gof='go fmt ./...'
  alias gol='golangci-lint run 2>/dev/null || go vet ./...'
fi

# -----------------------------------------------------------------------------
# Rust
# -----------------------------------------------------------------------------
if has cargo; then
  alias cb='cargo build'
  alias cr='cargo run'
  alias ct='cargo test'
  alias cc='cargo check'
  alias cf='cargo fmt'
  alias ccl='cargo clippy'
fi

# -----------------------------------------------------------------------------
# AWS
# -----------------------------------------------------------------------------
if has aws; then
  alias awsw='aws sts get-caller-identity'
  alias awsp='export AWS_PROFILE=$(aws configure list-profiles | fzf)'
fi

# -----------------------------------------------------------------------------
# Misc Tools
# -----------------------------------------------------------------------------
if has lazygit; then
  alias lg='lazygit'
fi

if has lazydocker; then
  alias lzd='lazydocker'
fi

if has k9s; then
  alias k9='k9s'
fi

# -----------------------------------------------------------------------------
# macOS Specific
# -----------------------------------------------------------------------------
if [[ "${JSH_OS}" == "macos" ]]; then
  alias o='open'
  alias oo='open .'
  alias finder='open -a Finder'
  alias flushdns='sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder'
  alias showfiles='defaults write com.apple.finder AppleShowAllFiles YES; killall Finder'
  alias hidefiles='defaults write com.apple.finder AppleShowAllFiles NO; killall Finder'
  alias cpwd='pwd | pbcopy'

  # Use GNU tools if available
  has gawk && alias awk='gawk'
  has gsed && alias sed='gsed'
  has gtar && alias tar='gtar'
fi

# -----------------------------------------------------------------------------
# Linux Specific
# -----------------------------------------------------------------------------
if [[ "${JSH_OS}" == "linux" ]]; then
  alias pbcopy='xclip -selection clipboard 2>/dev/null || xsel --clipboard'
  alias pbpaste='xclip -selection clipboard -o 2>/dev/null || xsel --clipboard -o'
  alias open='xdg-open 2>/dev/null || sensible-browser'
  alias cpwd='pwd | xclip -selection clipboard'
fi

# =============================================================================
# Functions
# =============================================================================
# functions.sh - Utility functions
# Pure shell, portable across bash/zsh
# shellcheck disable=SC2034,SC2001,SC2004,SC2016
# SC2001: sed preferred for complex patterns; SC2004/SC2016: Style preferences

# =============================================================================
# Directory Navigation
# =============================================================================

# Enhanced cd: creates directory if it doesn't exist, auto-cleans empty dirs on leave
# shellcheck disable=SC2164  # cd failures are intentional for error propagation
#
# Auto-cleanup behavior:
#   When cd auto-creates a directory and you later cd out of it,
#   the empty directory is automatically removed (via rmdir, which is safe).
#   If you create any files/subdirs, the directory is kept.
#
# Variable: _JSH_AUTOCREATED_DIR - tracks the last auto-created directory

cd() {
  local prev_dir="${PWD}"

  # Helper: attempt cleanup of auto-created dir if we're leaving it
  _jsh_cleanup_autocreated() {
    if [[ -n "${_JSH_AUTOCREATED_DIR:-}" ]]; then
      # Only cleanup if we're leaving the auto-created dir
      if [[ "${prev_dir}" == "${_JSH_AUTOCREATED_DIR}" ]]; then
        # rmdir only removes empty dirs - safe to always try
        if rmdir "${_JSH_AUTOCREATED_DIR}" 2>/dev/null; then
          echo "Removed empty directory: ${_JSH_AUTOCREATED_DIR}"
        fi
        # Clear tracking regardless (we're done with this dir)
        unset _JSH_AUTOCREATED_DIR
      fi
    fi
  }

  # Handle no args (go home) and special cases like cd -
  if [[ $# -eq 0 ]] || [[ "$1" == "-" ]]; then
    _jsh_cleanup_autocreated
    builtin cd "$@" || return
    return
  fi

  # Try normal cd first
  if builtin cd "$@" 2>/dev/null; then
    _jsh_cleanup_autocreated
    return 0
  fi

  # If target doesn't exist and isn't a special arg, create and cd
  if [[ ! -e "$1" ]]; then
    # Cleanup before creating new auto-dir (in case nested typos)
    _jsh_cleanup_autocreated

    echo "Creating directory: $1"
    if mkdir -p "$1" && builtin cd "$1"; then
      # Track this as auto-created for potential cleanup
      _JSH_AUTOCREATED_DIR="${PWD}"
    else
      return 1
    fi
  else
    # Exists but cd failed (permission denied, not a directory, etc.)
    _jsh_cleanup_autocreated
    builtin cd "$@" || return
  fi
}

# Go up N directories
up() {
  local count="${1:-1}"
  local _dir=""
  for ((i = 0; i < count; i++)); do
    _dir="../${_dir}"
  done
  cd "${_dir:-.}" || return 1
}

# Make a directory (with parents) and cd into it
take() {
  [[ -z "${1:-}" ]] && { echo "Usage: take <dir>" >&2; return 1; }
  mkdir -p "$1" && builtin cd "$1" || return 1
}

# Quick cd to parent with matching name
# Usage: bd foo -> cd to nearest parent containing "foo"
bd() {
  local target="$1"
  local _dir="${PWD}"

  while [[ "${_dir}" != "/" ]]; do
    if [[ "$(basename "${_dir}")" == *"${target}"* ]]; then
      cd "${_dir}" || return 1
      return 0
    fi
    _dir="$(dirname "${_dir}")"
  done

  echo "No parent directory matching '${target}'" >&2
  return 1
}

# =============================================================================
# File Operations
# =============================================================================

# Create backup with timestamp
bak() {
  local file="$1"
  [[ -z "${file}" ]] && { echo "Usage: bak <file>" >&2; return 1; }
  [[ -e "${file}" ]] || { echo "File not found: ${file}" >&2; return 1; }

  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  cp -a "${file}" "${file}.${timestamp}.bak"
  echo "Backed up: ${file}.${timestamp}.bak"
}

# Batch backup multiple files
backup() {
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"

  for file in "$@"; do
    if [[ -e "${file}" ]]; then
      cp -a "${file}" "${file}.${timestamp}.bak"
      echo "Backed up: ${file}.${timestamp}.bak"
    else
      echo "Skipped (not found): ${file}" >&2
    fi
  done
}

# Extract any archive format
extract() {
  local file="$1"
  [[ -z "${file}" ]] && { echo "Usage: extract <file>" >&2; return 1; }
  [[ -f "${file}" ]] || { echo "File not found: ${file}" >&2; return 1; }

  case "${file:l}" in
    *.tar.bz2|*.tbz2)   tar xjf "${file}" ;;
    *.tar.gz|*.tgz)     tar xzf "${file}" ;;
    *.tar.xz|*.txz)     tar xJf "${file}" ;;
    *.tar.zst)          tar --zstd -xf "${file}" ;;
    *.tar)              tar xf "${file}" ;;
    *.bz2)              bunzip2 "${file}" ;;
    *.gz)               gunzip "${file}" ;;
    *.xz)               unxz "${file}" ;;
    *.zst)              unzstd "${file}" ;;
    *.zip)              unzip "${file}" ;;
    *.rar)              unrar x "${file}" ;;
    *.7z)               7z x "${file}" ;;
    *.z)                uncompress "${file}" ;;
    *.deb)              ar x "${file}" ;;
    *.rpm)              rpm2cpio "${file}" | cpio -idmv ;;
    *)
      echo "Unknown archive format: ${file}" >&2
      return 1
      ;;
  esac
}

# Create archive (auto-detect format from name)
compress() {
  local archive="$1"
  shift
  [[ -z "${archive}" ]] && { echo "Usage: compress <archive> <files...>" >&2; return 1; }
  [[ $# -eq 0 ]] && { echo "No files specified" >&2; return 1; }

  case "${archive:l}" in
    *.tar.bz2|*.tbz2)   tar cjf "${archive}" "$@" ;;
    *.tar.gz|*.tgz)     tar czf "${archive}" "$@" ;;
    *.tar.xz|*.txz)     tar cJf "${archive}" "$@" ;;
    *.tar.zst)          tar --zstd -cf "${archive}" "$@" ;;
    *.tar)              tar cf "${archive}" "$@" ;;
    *.zip)              zip -r "${archive}" "$@" ;;
    *.7z)               7z a "${archive}" "$@" ;;
    *)
      echo "Unknown archive format: ${archive}" >&2
      return 1
      ;;
  esac
}

# =============================================================================
# Search Functions
# =============================================================================

# Find files by name
ff() {
  local pattern="$1"
  local dir="${2:-.}"

  if has fd; then
    fd "${pattern}" "${dir}"
  elif has find; then
    find "${dir}" -type f -iname "*${pattern}*" 2>/dev/null
  fi
}

# Find directories by name
ffd() {
  local pattern="$1"
  local dir="${2:-.}"

  if has fd; then
    fd -t d "${pattern}" "${dir}"
  elif has find; then
    find "${dir}" -type d -iname "*${pattern}*" 2>/dev/null
  fi
}

# Grep recursively (uses rg if available)
gr() {
  local pattern="$1"
  local dir="${2:-.}"

  if has rg; then
    rg "${pattern}" "${dir}"
  else
    grep -r --color=auto "${pattern}" "${dir}"
  fi
}

# =============================================================================
# System Information
# =============================================================================

# Disk usage summary, sorted
duh() {
  du -cksh "${1:-.}"/* 2>/dev/null | sort -rh | head -20
}

# What's listening on ports
listening() {
  if [[ "${JSH_OS}" == "macos" ]]; then
    lsof -iTCP -sTCP:LISTEN -P -n
  else
    ss -tuln 2>/dev/null || netstat -tuln
  fi
}

# Kill process on specific port
killport() {
  local port="$1"
  [[ -z "${port}" ]] && { echo "Usage: killport <port>" >&2; return 1; }

  local pid
  if [[ "${JSH_OS}" == "macos" ]]; then
    pid=$(lsof -ti ":${port}" 2>/dev/null)
  else
    pid=$(fuser "${port}/tcp" 2>/dev/null)
  fi

  if [[ -n "${pid}" ]]; then
    echo "Killing PID ${pid} on port ${port}"
    kill -9 "${pid}"
  else
    echo "No process found on port ${port}"
  fi
}

# Show external IP
whatsmyip() {
  curl -s https://api.ipify.org && echo
}

# =============================================================================
# Development Utilities
# =============================================================================

# Git stage specific lines in a file
git-stage-range() { git diff -U0 "$1" | awk -v s="$2" -v e="$3" '/^@@/{match($0,/\+([0-9]+)/,a);in_range=(a[1]>=s&&a[1]<=e)}in_range||/^(diff|index|---|\+\+\+)/' | git apply --cached; }
git-stage-pattern() { git diff -U0 "$1" | grep -B999 -A999 "$2" | git apply --cached --recount 2>/dev/null || git diff -U0 "$1" | git apply --cached; }

# Quick HTTP server
serve() {
  local port="${1:-8000}"
  local dir="${2:-.}"

  echo "Serving ${dir} on http://localhost:${port}"

  if has python3; then
    python3 -m http.server "${port}" --directory "${dir}"
  elif has python; then
    (cd "${dir}" && python -m SimpleHTTPServer "${port}")
  elif has ruby; then
    ruby -run -ehttpd "${dir}" -p"${port}"
  elif has php; then
    php -S "localhost:${port}" -t "${dir}"
  else
    echo "No suitable HTTP server found (python, ruby, php)" >&2
    return 1
  fi
}

# JSON pretty print
jsonpp() {
  if has jq; then
    jq '.' "$@"
  elif has python3; then
    python3 -m json.tool "$@"
  elif has python; then
    python -m json.tool "$@"
  else
    echo "No JSON parser available (jq, python)" >&2
    return 1
  fi
}

# Generate random password
genpass() {
  local length="${1:-32}"

  if has openssl; then
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${length}"
    echo
  else
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${length}"
    echo
  fi
}

# URL encode
urlencode() {
  local string="$1"
  if has python3; then
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$string"
  else
    echo "${string}" | sed 's/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g'
  fi
}

# URL decode
urldecode() {
  local string="$1"
  if has python3; then
    python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$string"
  else
    echo "${string}" | sed 's/%20/ /g; s/%21/!/g; s/%22/"/g; s/%23/#/g; s/%24/$/g; s/%26/\&/g'
  fi
}

# =============================================================================
# Git Utilities
# =============================================================================

# Shared confirmation prompt for git+ helpers
_git_confirm() {
  local action="$1"
  local reply

  printf '%s [y/N] ' "${action}"
  read -r reply || return 1

  case "${reply}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      echo "Cancelled"
      return 1
      ;;
  esac
}

# Push to origin on the current branch
function git+ {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    echo "Detached HEAD: checkout a branch first" >&2
    return 1
  }

  _git_confirm "Push '${branch}' to origin?" || return 1
  git push origin "${branch}"
}

function git+++ {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    echo "Detached HEAD: checkout a branch first" >&2
    return 1
  }

  _git_confirm "Force-push '${branch}' to origin with --force-with-lease?" || return 1
  git push --force-with-lease origin "${branch}"
}

# Backward-compat convenience alias
function git++ { git+++ "$@"; }

# Reset HEAD to undo last commit (soft reset, keeps changes in working directory)
function git- {
  _git_confirm "Reset HEAD to undo last commit ($(git log -1 --pretty=format:'%s'))?" || return 1
  git reset HEAD~1
}

# Rebase current branch onto latest remote default branch (origin/main, origin/master, etc.)
# Usage: git-+ [git rebase args...]
function git-+ {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not a git repository" >&2
    return 1
  fi

  local current_branch remote upstream_ref default_ref default_branch candidate
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    echo "Detached HEAD: checkout a branch first" >&2
    return 1
  }

  upstream_ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || true
  if [[ -n "${upstream_ref}" ]]; then
    remote="${upstream_ref%%/*}"
  else
    remote=$(git config --get "branch.${current_branch}.remote" 2>/dev/null) || true
  fi

  if [[ -z "${remote}" ]]; then
    if git remote get-url origin >/dev/null 2>&1; then
      remote="origin"
    else
      remote=$(git remote | head -n 1)
    fi
  fi

  if [[ -z "${remote}" ]]; then
    echo "No git remote configured" >&2
    return 1
  fi

  default_ref=$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null) || true
  default_branch="${default_ref#"${remote}"/}"

  if [[ -z "${default_branch}" || "${default_branch}" == "${default_ref}" ]]; then
    default_branch=$(git remote show "${remote}" 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p' | head -n 1)
  fi

  if [[ -z "${default_branch}" ]]; then
    for candidate in main master trunk develop; do
      if git show-ref --verify --quiet "refs/remotes/${remote}/${candidate}"; then
        default_branch="${candidate}"
        break
      fi
    done
  fi

  if [[ -z "${default_branch}" ]]; then
    echo "Could not determine default branch for remote '${remote}'" >&2
    return 1
  fi

  _git_confirm "Fetch '${remote}' and rebase '${current_branch}' onto '${remote}/${default_branch}'?" || return 1

  git fetch "${remote}" --prune || return 1

  echo "Rebasing ${current_branch} onto ${remote}/${default_branch}"
  git rebase --autostash "$@" "${remote}/${default_branch}"
}

# Commit with optional inline message
# Usage: git_ "message" or just git_ to open editor
git_() {
  if [[ $# -eq 0 ]]; then
    git commit
  else
    git commit -m "$*"
  fi
}

# Clone and cd into repo
gclone() {
  local repo="$1"
  [[ -z "${repo}" ]] && { echo "Usage: gclone <repo-url>" >&2; return 1; }

  local dir
  dir="$(basename "${repo}" .git)"

  git clone "${repo}" && cd "${dir}" || return 1
}

# Convert HTTPS git URL to SSH
http2ssh() {
  local url="$1"
  echo "${url}" | sed -e 's|https://github.com/|git@github.com:|' \
            -e 's|https://gitlab.com/|git@gitlab.com:|' \
            -e 's|https://bitbucket.org/|git@bitbucket.org:|'
}

# =============================================================================
# Fun / Misc
# =============================================================================

# Weather
weather() {
  local location="${1:-}"
  curl -s "wttr.in/${location}?F"
}

# Cheat sheet lookup
cheat() {
  local topic="$1"
  [[ -z "${topic}" ]] && { echo "Usage: cheat <topic>" >&2; return 1; }
  curl -s "cheat.sh/${topic}"
}

# Countdown timer
timer() {
  local seconds="${1:-60}"
  local msg="${2:-Timer done!}"

  echo "Timer: ${seconds} seconds"
  while [[ "${seconds}" -gt 0 ]]; do
    printf "\r%02d:%02d " $((seconds / 60)) $((seconds % 60))
    sleep 1
    ((seconds--))
  done
  printf "\r%s\n" "${msg}"

  # Notification
  if has osascript; then
    osascript -e "display notification \"${msg}\" with title \"Timer\""
  elif has notify-send; then
    notify-send "Timer" "${msg}"
  fi
}

# Simple calculator
# Uses bc for floating-point, falls back to bash arithmetic (integers only)
calc() {
  local expr="$*"
  # Validate input: only allow numbers, operators, parentheses, decimal points, spaces
  if [[ ! "$expr" =~ ^[0-9+\-*/\(\)\.\ %^]+$ ]]; then
    echo "calc: invalid characters in expression" >&2
    return 1
  fi
  if has bc; then
    echo "scale=4; ${expr}" | bc -l
  else
    # Bash arithmetic (integers only)
    echo $(($expr))
  fi
}

# Quick notes
note() {
  local notes_file="${HOME}/.notes"

  if [[ $# -eq 0 ]]; then
    [[ -f "${notes_file}" ]] && cat "${notes_file}"
  else
    echo "$(date '+%Y-%m-%d %H:%M') $*" >> "${notes_file}"
    echo "Note added."
  fi
}

# =============================================================================
# FZF Integration (if available)
# =============================================================================

if has fzf; then
  # Interactive cd
  fcd() {
    local dir
    dir=$(find "${1:-.}" -type d 2>/dev/null | fzf --preview 'ls -la {}')
    [[ -n "${dir}" ]] && cd "${dir}" || return 1
  }

  # Interactive file edit
  fe() {
    local file
    file=$(fzf --preview 'head -100 {}')
    [[ -n "${file}" ]] && "${EDITOR:-vim}" "${file}"
  }

  # Interactive history search
  fh() {
    local cmd
    cmd=$(history | fzf --tac | sed 's/^[ ]*[0-9]*[ ]*//')
    [[ -n "${cmd}" ]] && eval "${cmd}"
  }

  # Interactive process kill
  fkill() {
    local pid
    pid=$(ps aux | fzf --header-lines=1 | awk '{print $2}')
    [[ -n "${pid}" ]] && kill -9 "${pid}"
  }

  # Git branch checkout
  fco() {
    local branch
    branch=$(git branch -a | fzf | sed 's/^[ *]*//' | sed 's|remotes/origin/||')
    [[ -n "${branch}" ]] && git checkout "${branch}"
  }

  # Git log browser
  fgl() {
    git log --oneline --graph --color=always | \
      fzf --ansi --preview 'git show --color=always {1}' | \
      awk '{print $1}'
  }
else
  # ==========================================================================
  # Pure Shell Fallbacks (when fzf is not available)
  # Uses select menus and numbered lists for interactive selection
  # ==========================================================================

  _jsh_pick_array_item() {
    local wanted="$1" item n=1
    shift
    REPLY=""
    for item in "$@"; do
      if [[ $n -eq $wanted ]]; then REPLY="$item"; return 0; fi
      n=$((n + 1))
    done
    return 1
  }

  # Interactive cd (pure shell)
  fcd() {
    local dir="${1:-.}"
    local dirs=()
    local i=1

    echo "Directories in ${dir}:"
    while IFS= read -r d; do
      dirs+=("$d")
      printf "%d) %s\n" "$i" "$d"
      ((i++))
      [[ $i -gt 50 ]] && { echo "... (limited to 50)"; break; }
    done < <(find "${dir}" -maxdepth 3 -type d 2>/dev/null | head -50)

    [[ ${#dirs[@]} -eq 0 ]] && { echo "No directories found"; return 1; }

    printf "\nEnter number (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#dirs[@]} ]]; then
      _jsh_pick_array_item "$choice" "${dirs[@]}" && cd "$REPLY" || return 1
    else
      echo "Invalid selection" >&2
      return 1
    fi
  }

  # Interactive file edit (pure shell)
  fe() {
    local files=()
    local i=1

    echo "Files in current directory:"
    while IFS= read -r f; do
      files+=("$f")
      printf "%d) %s\n" "$i" "$f"
      ((i++))
      [[ $i -gt 50 ]] && { echo "... (limited to 50)"; break; }
    done < <(find . -maxdepth 2 -type f 2>/dev/null | head -50)

    [[ ${#files[@]} -eq 0 ]] && { echo "No files found"; return 1; }

    printf "\nEnter number (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#files[@]} ]]; then
      _jsh_pick_array_item "$choice" "${files[@]}" && "${EDITOR:-vim}" "$REPLY"
    else
      echo "Invalid selection" >&2
      return 1
    fi
  }

  # Interactive history search (pure shell)
  fh() {
    local pattern="${1:-}"
    local cmds=()
    local i=1

    echo "Recent commands${pattern:+ matching '$pattern'}:"
    while IFS= read -r line; do
      # Strip leading spaces and history number
      local cmd
      cmd=$(echo "$line" | sed 's/^[ ]*[0-9]*[ ]*//')
      [[ -z "$cmd" ]] && continue
      [[ -n "$pattern" ]] && [[ "$cmd" != *"$pattern"* ]] && continue
      cmds+=("$cmd")
      printf "%d) %s\n" "$i" "${cmd:0:80}"
      ((i++))
      [[ $i -gt 30 ]] && break
    done < <(history | tail -100)

    [[ ${#cmds[@]} -eq 0 ]] && { echo "No matching commands"; return 1; }

    printf "\nEnter number to execute (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#cmds[@]} ]]; then
      _jsh_pick_array_item "$choice" "${cmds[@]}" || return 1
      echo "Executing: ${REPLY}"
      eval "${REPLY}"
    else
      echo "Invalid selection" >&2
      return 1
    fi
  }

  # Interactive process kill (pure shell)
  fkill() {
    local pattern="${1:-}"
    local pids=()
    local i=1

    echo "Running processes${pattern:+ matching '$pattern'}:"
    echo "PID USER COMMAND"
    echo "--- ---- -------"

    while IFS= read -r line; do
      [[ $i -eq 1 ]] && { ((i++)); continue; }  # Skip header
      local pid user cmd
      pid=$(echo "$line" | awk '{print $2}')
      user=$(echo "$line" | awk '{print $1}')
      cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')

      [[ -n "$pattern" ]] && [[ "$cmd" != *"$pattern"* ]] && continue
      pids+=("$pid")
      printf "%d) %-6s %-8s %s\n" "${#pids[@]}" "$pid" "$user" "${cmd:0:60}"
      [[ ${#pids[@]} -ge 30 ]] && break
    done < <(ps aux)

    [[ ${#pids[@]} -eq 0 ]] && { echo "No matching processes"; return 1; }

    printf "\nEnter number to kill (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#pids[@]} ]]; then
      _jsh_pick_array_item "$choice" "${pids[@]}" || return 1
      local target_pid="${REPLY}"
      echo "Killing PID ${target_pid}..."
      kill -9 "${target_pid}"
    else
      echo "Invalid selection" >&2
      return 1
    fi
  }

  # Git branch checkout (pure shell)
  fco() {
    local branches=()
    local i=1

    echo "Git branches:"
    while IFS= read -r branch; do
      branch=$(echo "$branch" | sed 's/^[ *]*//' | sed 's|remotes/origin/||')
      [[ -z "$branch" ]] && continue
      [[ "$branch" == "HEAD"* ]] && continue
      branches+=("$branch")
      printf "%d) %s\n" "$i" "$branch"
      ((i++))
      [[ $i -gt 30 ]] && { echo "... (limited to 30)"; break; }
    done < <(git branch -a 2>/dev/null)

    [[ ${#branches[@]} -eq 0 ]] && { echo "No branches found (not a git repo?)"; return 1; }

    printf "\nEnter number to checkout (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#branches[@]} ]]; then
      _jsh_pick_array_item "$choice" "${branches[@]}" && git checkout "$REPLY"
    else
      echo "Invalid selection" >&2
      return 1
    fi
  }

  # Git log browser (pure shell)
  fgl() {
    local commits=()
    local i=1

    echo "Recent commits:"
    while IFS= read -r line; do
      local sha msg
      sha=$(echo "$line" | awk '{print $1}')
      msg=$(echo "$line" | cut -d' ' -f2-)
      commits+=("$sha")
      printf "%d) %s %s\n" "$i" "${sha:0:7}" "${msg:0:65}"
      ((i++))
      [[ $i -gt 30 ]] && break
    done < <(git log --oneline -30 2>/dev/null)

    [[ ${#commits[@]} -eq 0 ]] && { echo "No commits found (not a git repo?)"; return 1; }

    printf "\nEnter number to show (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#commits[@]} ]]; then
      _jsh_pick_array_item "$choice" "${commits[@]}" && git show "$REPLY"
    else
      echo "Invalid selection" >&2
      return 1
    fi
  }
fi


# =============================================================================
# Directory jumping
# =============================================================================
#!/usr/bin/env bash
# j.sh - Zoxide-like smart directory jumping for jsh
# shellcheck disable=SC2016,SC2119,SC2120,SC2296,SC1009,SC1035,SC1072,SC1073
#
# This file should be sourced, not executed, so that `j` can change
# the current directory of the calling shell.
#
# Features:
#   - Frecency-based ranking (frequency + recency)
#   - Fallback to gitx projects for unvisited directories
#   - Fuzzy matching with multiple keywords
#   - FZF interactive selection (with fallback)
#   - Automatic tracking via cd hook
#
# Usage:
#   j              Interactive directory selection
#   j <query>      Jump to best matching directory/project
#   j <q1> <q2>    Multiple keywords (all must match)
#   j -            Jump to previous directory
#   j -v [query]   Verbose mode (show search steps)
#   j -c [query]   Open in VS Code without changing directory
#
# Database Management:
#   j --db         Show frecency database with scores
#   j -a|--add     Add current directory to frecency database
#   j --remove     Remove current directory from database
#   j --clean      Remove non-existent directories
#
# For git/project management, use gitx:
#   gitx clone <url>    Clone repository and cd into it
#   gitx create <name>  Create project and cd into it
#   gitx list           List all projects
#   gitx profile        Git profile management
#   gitx remote <name>  Open remote project in VS Code
#
# Environment:
#   J_DATA        Path to data file (default: ~/.jsh/local/j.db)
#   J_EXCLUDE     Colon-separated paths to exclude from tracking
#   J_NO_HOOK     Set to disable automatic cd tracking

# =============================================================================
# Configuration
# =============================================================================

# Data file location (in jsh local directory, not tracked by git)
J_DATA="${J_DATA:-${JSH_DIR:-${HOME}/.jsh}/local/j.db}"

# Directories to exclude from tracking (colon-separated)
J_EXCLUDE="${J_EXCLUDE:-${HOME}}"

# Decay factor for frecency (per hour)
# 0.99 means score decays by 1% per hour
_J_DECAY=0.99

# Minimum score before entry is removed
_J_MIN_SCORE=0.01

# Previous directory for `j -`
_J_PREV_DIR=""

# VS Code command (cached for performance)
_J_CODE_CMD=""

# =============================================================================
# Shell Compatibility Layer
# =============================================================================

# Detect shell for compatibility
_J_SHELL="bash"
[[ -n "${ZSH_VERSION:-}" ]] && _J_SHELL="zsh"

# Lowercase: zsh and Bash 4+ have native operators; Bash 3.2 uses tr.
if [[ "${_J_SHELL}" == "zsh" ]]; then
  _j_lowercase() { printf '%s' "${(L)1}"; }
elif [[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]; then
  eval '_j_lowercase() { printf '\''%s'\'' "${1,,}"; }'
else
  _j_lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fi

# Find code command (cached to avoid repeated lookups)
# Checks common paths to avoid shell hash table issues
_j_find_code() {
  # Return cached value if available
  if [[ -n "${_J_CODE_CMD}" ]]; then
    printf '%s' "${_J_CODE_CMD}"
    return 0
  fi

  local cmd

  # Check common local code locations FIRST (most common case)
  local code_paths=(
    "/opt/homebrew/bin/code" # macOS Homebrew (Apple Silicon)
    "/usr/local/bin/code"    # macOS Homebrew (Intel)
    "/usr/bin/code"          # Linux system
  )

  for cmd in "${code_paths[@]}"; do
    if [[ -x "${cmd}" ]]; then
      _J_CODE_CMD="${cmd}"
      printf '%s' "${cmd}"
      return 0
    fi
  done

  # Fallback to PATH lookup
  if command -v code &>/dev/null; then
    cmd="$(command -v code)"
    _J_CODE_CMD="${cmd}"
    printf '%s' "${cmd}"
    return 0
  fi

  # Last resort: Check VS Code Server (remote SSH sessions)
  # Use explicit directory check to avoid glob issues with zsh configs
  local vscode_server_dir="$HOME/.vscode-server/bin"
  if [[ -d "${vscode_server_dir}" ]]; then
    # Find most recent code binary without glob-in-subshell
    cmd=""
    for dir in "${vscode_server_dir}"/*/; do
      if [[ -x "${dir}bin/code" ]]; then
        cmd="${dir}bin/code"
      fi
    done
    if [[ -n "${cmd}" ]] && [[ -x "${cmd}" ]]; then
      _J_CODE_CMD="${cmd}"
      printf '%s' "${cmd}"
      return 0
    fi
  fi

  return 1
}

# Open a path in VS Code
_j_open_code_path() {
  local _j_target_path="${1:-.}"
  local code_cmd
  code_cmd="$(_j_find_code)"
  if [[ -n "${code_cmd}" ]]; then
    # The code command is a bash script - ensure bash is found
    # Temporarily add /bin to PATH if bash isn't available (macOS edge case)
    if ! command -v bash &>/dev/null; then
      PATH="/bin:/usr/bin:$PATH" "${code_cmd}" "${_j_target_path}"
    else
      "${code_cmd}" "${_j_target_path}"
    fi
  elif [[ "$(uname)" == "Darwin" ]]; then
    # macOS fallback: use open command directly
    open -a "Visual Studio Code" "${_j_target_path}"
  else
    _j_ui_message error "VS Code command not found."
    return 1
  fi
}

# Open code in current directory
_j_open_code() {
  _j_open_code_path .
}

# Check if current directory is a registered gitx project
_j_is_gitx_project() {
  command -v gitx &>/dev/null || return 1
  gitx is-project 2>/dev/null
}

# Get all gitx project paths (one per line, with ~ notation)
# Used as fallback when frecency database is empty
_j_get_gitx_projects() {
  command -v gitx &>/dev/null || return 1
  # Skip header lines, extract just the path column
  gitx list 2>/dev/null | awk 'NR>2 && /^~/ {print $1}'
}

# Interactive selection of remote projects
_j_select_remote() {
  local remotes=()

  while IFS= read -r name; do
    [[ -n "${name}" ]] && remotes+=("${name}")
  done < <(_gitx_list_remotes)

  if [[ ${#remotes[@]} -eq 0 ]]; then
    _j_ui_message warn "No remote projects configured."
    declare -f jsh_detail >/dev/null 2>&1 && jsh_detail "Add remotes in ${_GITX_REMOTE_CONFIG:-~/.jsh/local/projects.json}" >&2
    return 1
  fi

  local selected
  if command -v fzf &>/dev/null; then
    selected=$(printf '%s\n' "${remotes[@]}" | fzf --height=40% --reverse --prompt='remote> ')
  else
    # Fallback: numbered list
    printf '%sSelect remote project:%s\n' "${DIM:-}" "${RST:-}" >&2
    local i=1
    for name in "${remotes[@]}"; do
      printf '%s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" "${CYN:-}" "${name}" "${RST:-}" >&2
      (( i += 1 ))
    done
    printf '%sEnter number (1-%d):%s ' "${DIM:-}" "$(( i - 1 ))" "${RST:-}" >&2
    local choice
    read -r choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -lt "${i}" ]]; then
      local n=1 remote
      for remote in "${remotes[@]}"; do
        if [[ ${n} -eq ${choice} ]]; then selected="${remote}"; break; fi
        (( n += 1 ))
      done
    fi
  fi

  [[ -n "${selected}" ]] && printf '%s' "${selected}"
}

# =============================================================================
# Database Functions (file-based, no associative arrays for portability)
# =============================================================================

# Ensure data directory exists
_j_ensure_dir() {
  local dir
  dir="$(dirname "${J_DATA}")"
  [[ -d "${dir}" ]] || mkdir -p "${dir}"
}

_j_array_contains() {
  local wanted="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

_j_ui_message() {
  local _j_level="$1"
  shift
  if declare -f jsh_ui_message >/dev/null 2>&1; then
    case "${_j_level}" in
      warn|warning|error|fail) jsh_ui_message "${_j_level}" "$*" >&2 ;;
      *) jsh_ui_message "${_j_level}" "$*" ;;
    esac
    return
  fi
  case "${_j_level}" in
    success|ok) printf '  ✓ %s\n' "$*" ;;
    warn|warning) printf '  ! %s\n' "$*" >&2 ;;
    error|fail) printf '  ✕ %s\n' "$*" >&2 ;;
    *) printf '  %s\n' "$*" ;;
  esac
}

_j_lock_acquire() {
  local lock_dir="${J_DATA}.lock" tries=0
  while ! command mkdir "${lock_dir}" 2>/dev/null; do
    tries=$((tries + 1))
    [[ ${tries} -lt 100 ]] || return 1
    sleep 0.01
  done
}

_j_lock_release() {
  command rmdir "${J_DATA}.lock" 2>/dev/null || true
}

# Get current timestamp in hours since epoch
_j_now() {
  printf '%s' "$(( $(command -p date +%s) / 3600 ))"
}

# Add/update a directory in the database
# Format: path|count|last_access_hours
_j_add() {
  local _j_entry_path="$1"

  # Resolve to absolute path
  _j_entry_path="$(builtin cd "${_j_entry_path}" 2>/dev/null && pwd -P)" || return 1

  # Check exclusions
  local exclude exclusions="${J_EXCLUDE}:"
  while [[ -n "${exclusions}" ]]; do
    exclude="${exclusions%%:*}"
    exclusions="${exclusions#*:}"
    if [[ -d "${exclude}" ]]; then
      exclude="$(builtin cd "${exclude}" 2>/dev/null && pwd -P)" || true
    fi
    [[ -n "${exclude}" && "${_j_entry_path}" == "${exclude}" ]] && return 0
  done

  # Don't track very short paths (/, /tmp, etc.)
  [[ "${#_j_entry_path}" -lt 4 ]] && return 0
  case "${_j_entry_path}" in *'|'*|*$'\n'*) return 1 ;; esac

  _j_ensure_dir
  _j_lock_acquire || return 0

  local now tmp_file result=0
  now="$(_j_now)"
  tmp_file="$(mktemp "${J_DATA}.tmp.XXXXXX")" || {
    _j_lock_release
    return 1
  }

  # Each worker gets a unique temporary file so rapid directory changes cannot
  # collide on one shared `${J_DATA}.tmp` path.
  if [[ -f "${J_DATA}" ]]; then
    command -p awk -F'|' -v path="${_j_entry_path}" -v now="${now}" '
      BEGIN { found=0; OFS="|" }
      $1 == path { print path, $2+1, now; found=1; next }
      { print }
      END { if (!found) print path, 1, now }
    ' "${J_DATA}" > "${tmp_file}" && command mv -f "${tmp_file}" "${J_DATA}" || result=$?
  else
    printf '%s|1|%s\n' "${_j_entry_path}" "${now}" > "${tmp_file}" &&
      command mv -f "${tmp_file}" "${J_DATA}" || result=$?
  fi
  command rm -f "${tmp_file}" 2>/dev/null || true
  _j_lock_release
  return "${result}"
}

# Remove a directory from the database
_j_remove() {
  local _j_entry_path="$1"
  _j_entry_path="$(builtin cd "${_j_entry_path}" 2>/dev/null && pwd -P)" || _j_entry_path="$1"

  [[ ! -f "${J_DATA}" ]] && return 1
  _j_lock_acquire || return 1

  local count_before count_after tmp_file
  count_before=$(wc -l < "${J_DATA}" | tr -d ' ')

  tmp_file="$(mktemp "${J_DATA}.tmp.XXXXXX")" || {
    _j_lock_release
    return 1
  }
  if ! command -p awk -F'|' -v path="${_j_entry_path}" '$1 != path' "${J_DATA}" > "${tmp_file}" ||
    ! command mv -f "${tmp_file}" "${J_DATA}"; then
    command rm -f "${tmp_file}" 2>/dev/null || true
    _j_lock_release
    return 1
  fi
  _j_lock_release

  count_after=$(wc -l < "${J_DATA}" | tr -d ' ')
  [[ "${count_after}" -lt "${count_before}" ]]
}

# Clean non-existent directories from database
_j_clean() {
  [[ ! -f "${J_DATA}" ]] && { _j_ui_message info "Database is empty"; return 0; }
  _j_lock_acquire || return 1

  local removed=0 total=0
  local tmpfile
  tmpfile="$(mktemp "${J_DATA}.tmp.XXXXXX")" || {
    _j_lock_release
    return 1
  }

  while IFS='|' read -r _j_entry_path count time; do
    [[ -z "${_j_entry_path}" ]] && continue
    (( total += 1 ))
    if [[ -d "${_j_entry_path}" ]]; then
      printf '%s|%s|%s\n' "${_j_entry_path}" "${count}" "${time}"
    else
      (( removed += 1 ))
    fi
  done < "${J_DATA}" > "${tmpfile}"

  command mv -f "${tmpfile}" "${J_DATA}" || {
    command rm -f "${tmpfile}" 2>/dev/null || true
    _j_lock_release
    return 1
  }
  _j_lock_release

  if [[ ${removed} -gt 0 ]]; then
    _j_ui_message success "Removed ${removed} non-existent directories · kept $((total - removed))"
  else
    _j_ui_message success "Database is clean · ${total} directories"
  fi
}

# =============================================================================
# Matching and Ranking
# =============================================================================

# Calculate frecency score using awk
# Score = count * decay^(hours_since_access)
_j_calculate_scores() {
  local now
  now="$(_j_now)"

  [[ ! -f "${J_DATA}" ]] && return

  command -p awk -F'|' -v now="${now}" -v decay="${_J_DECAY}" -v min="${_J_MIN_SCORE}" '
    {
      path = $1
      count = $2
      last = $3
      hours = now - last
      if (hours < 0) hours = 0
      score = count * (decay ^ hours)
      if (score >= min) {
        printf "%.4f|%s\n", score, path
      }
    }
  ' "${J_DATA}"
}

# Check if path matches all query terms (case-insensitive)
_j_matches() {
  local _j_candidate_path="$1"
  shift

  local path_lower query
  path_lower="$(_j_lowercase "${_j_candidate_path}")"

  for query in "$@"; do
    local query_lower
    query_lower="$(_j_lowercase "${query}")"
    # Check if query is a substring
    case "${path_lower}" in
      *"${query_lower}"*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Get all matching directories with scores, sorted by score
# Output: score|path (one per line)
_j_query() {
  local results="" line score _j_candidate_path

  # Add entries from j database
  while IFS='|' read -r score _j_candidate_path; do
    [[ -z "${_j_candidate_path}" ]] && continue
    [[ ! -d "${_j_candidate_path}" ]] && continue
    [[ "${_j_candidate_path}" == "${PWD}" ]] && continue

    # Check if matches query
    if [[ $# -eq 0 ]] || _j_matches "${_j_candidate_path}" "$@"; then
      results="${results}${score}|${_j_candidate_path}"$'\n'
    fi
  done < <(_j_calculate_scores)

  # Sort by score descending
  printf '%s' "${results}" | command -p sort -t'|' -k1 -rn
}

# =============================================================================
# Display Helpers
# =============================================================================

# Display path with ~ for home
_j_display_path() {
  local _j_display="$1"
  if [[ "${_j_display}" == "${HOME}" ]]; then
    printf '~'
  elif [[ "${_j_display}" == "${HOME}/"* ]]; then
    printf '~%s' "${_j_display#"${HOME}"}"
  else
    printf '%s' "${_j_display}"
  fi
}

# List all directories with scores
_j_list() {
  local entries=() count=0

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    entries+=("${line}")
    (( count += 1 ))
  done < <(_j_query)

  if [[ ${count} -eq 0 ]]; then
    _j_ui_message info "No directories tracked yet."
    declare -f jsh_detail >/dev/null 2>&1 && jsh_detail "Use cd to navigate; directories are added automatically."
    return 0
  fi

  printf '%s%-8s  %s%s\n' "${DIM:-}" "SCORE" "PATH" "${RST:-}"
  printf '%s%s%s\n' "${DIM:-}" "$(printf '%60s' '' | tr ' ' '-')" "${RST:-}"

  local entry score _j_entry_path
  for entry in "${entries[@]}"; do
    score="${entry%%|*}"
    _j_entry_path="${entry#*|}"
    printf '%s%-8s%s  %s%s%s\n' \
      "${C_GIT:-}" "${score}" "${RST:-}" \
      "${CYN:-}" "$(_j_display_path "${_j_entry_path}")" "${RST:-}"
  done
}

# =============================================================================
# Interactive Selection
# =============================================================================

# Interactive directory selection with fzf
# Parameters:
#   $@ - optional query terms to filter
#   _J_INTERACTIVE_INCLUDE_CURRENT - set to path to prepend "(current)" option
_j_interactive() {
  local entries=() paths=() count=0
  local include_current="${_J_INTERACTIVE_INCLUDE_CURRENT:-}"

  # Collect frecency entries (already sorted by score, highest first)
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    entries+=("${line}")
    paths+=("${line#*|}")
    (( count += 1 ))
  done < <(_j_query "$@")

  # Keep duplicate detection compatible with macOS Bash 3.2, which has no
  # associative arrays.
  local p
  local extra_paths=()
  while IFS= read -r gpath; do
    [[ -z "${gpath}" ]] && continue
    # Expand ~ to absolute path for internal use
    local abs_path="${gpath/#\~/$HOME}"
    [[ ! -d "${abs_path}" ]] && continue
    [[ "${abs_path}" == "${PWD}" ]] && continue
    # Skip if already in frecency list
    _j_array_contains "${abs_path}" "${paths[@]}" && continue
    # Filter by query if provided
    if [[ $# -eq 0 ]] || _j_matches "${abs_path}" "$@"; then
      extra_paths+=("${abs_path}")
    fi
  done < <(_j_get_gitx_projects)

  # Sort extra paths alphabetically and append to paths
  if [[ ${#extra_paths[@]} -gt 0 ]]; then
    while IFS= read -r sorted_path; do
      paths+=("${sorted_path}")
      (( count += 1 ))
    done < <(printf '%s\n' "${extra_paths[@]}" | sort)
  fi

  # No entries from either source
  if [[ ${count} -eq 0 ]]; then
    _j_ui_message warn "No directories found."
    if declare -f jsh_detail >/dev/null 2>&1; then
      jsh_detail "Use cd to build the frecency database." >&2
      jsh_command_preview "gitx clone <url>" >&2
    fi
    return 1
  fi

  # Prepend "(current)" option if requested and we have a path
  local current_marker=""
  if [[ -n "${include_current}" ]]; then
    current_marker="(current) $(_j_display_path "${include_current}")"
  fi

  local selected
  if command -v fzf &>/dev/null; then
    # Build display list
    local display_list=""
    [[ -n "${current_marker}" ]] && display_list="${current_marker}"$'\n'

    display_list+="$(printf '%s\n' "${paths[@]}" | while read -r p; do
      _j_display_path "$p"
      printf '\n'
    done)"

    # FZF selection
    local prompt="j> "

    selected=$(printf '%s' "${display_list}" | fzf --height=40% --reverse --no-sort \
      --prompt="${prompt}")

    # Handle "(current)" selection
    if [[ "${selected}" == "(current)"* ]]; then
      printf 'CURRENT:%s' "${include_current}"
      return 0
    fi

    # Convert back to absolute path if we displayed with ~
    if [[ "${selected}" == "~"* ]]; then
      selected="${HOME}${selected#\~}"
    fi
  else
    # Fallback: numbered list selection
    printf '%s%sSelect directory:%s\n' "${DIM:-}" "" "${RST:-}" >&2

    local i=1
    local -a display_paths=()

    # Show "(current)" option first if requested
    if [[ -n "${current_marker}" ]]; then
      display_paths+=("CURRENT:${include_current}")
      printf '%s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" \
        "${CYN:-}" "${current_marker}" "${RST:-}" >&2
      (( i += 1 ))
    fi

    local p
    for p in "${paths[@]}"; do
      [[ -z "${p}" ]] && continue
      [[ ${i} -gt 10 ]] && break
      display_paths+=("${p}")
      printf '%s[%d]%s %s%s%s\n' "${C_GIT:-}" "${i}" "${RST:-}" \
        "${CYN:-}" "$(_j_display_path "${p}")" "${RST:-}" >&2
      (( i += 1 ))
    done

    printf '%sEnter number (1-%d):%s ' "${DIM:-}" "$(( i - 1 ))" "${RST:-}" >&2
    local choice
    read -r choice

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -lt "${i}" ]]; then
      # Use loop to find nth entry (portable across bash/zsh indexing)
      local n=0
      for p in "${display_paths[@]}"; do
        [[ -z "${p}" ]] && continue
        (( n += 1 ))
        if [[ ${n} -eq ${choice} ]]; then
          selected="${p}"
          break
        fi
      done
    else
      return 1
    fi
  fi

  [[ -n "${selected}" ]] && printf '%s' "${selected}"
}

# =============================================================================
# CD Hook
# =============================================================================

_j_track_directory() {
  local track_path="$1" worker_pid
  [[ -z "${J_NO_HOOK:-}" ]] || return 0

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    # zsh's &! detaches at creation time. `disown $pid` leaves the process
    # in zsh's job table and leaks both start and completion notifications.
    setopt localoptions no_bg_nice
    eval '( PATH="$PATH" _j_add "$track_path" ) >/dev/null 2>&1 &!'
  else
    ( PATH="$PATH" _j_add "${track_path}" ) >/dev/null 2>&1 &
    worker_pid=$!
    disown "${worker_pid}" 2>/dev/null || true
  fi
}

_j_after_cd() {
  _j_track_directory "${PWD}"
  # zsh invokes native chpwd hooks itself. Bash needs the shared dispatcher
  # for project environments and plugin hooks.
  if [[ -z "${ZSH_VERSION:-}" ]] && declare -f _jsh_hook_dispatch >/dev/null 2>&1; then
    _jsh_hook_dispatch chpwd 0
  fi
}

# Hook to track directory changes
_j_cd_hook() {
  _J_PREV_DIR="${PWD}"
  builtin cd "$@" || return $?
  _j_after_cd
}

# =============================================================================
# Path Resolution Fallback
# =============================================================================

# Try to resolve a query as a directory path
# Checks: relative path, ~/query, ~/.$query
# Output: resolved absolute path, or empty
_j_resolve_path() {
  local query="$1"

  # Accept explicit absolute paths before trying query-oriented fallbacks.
  if [[ -d "${query}" ]]; then
    (builtin cd "${query}" && pwd -P)
    return 0
  fi

  # Try as relative path from PWD
  if [[ -d "${PWD}/${query}" ]]; then
    (builtin cd "${PWD}/${query}" && pwd -P)
    return 0
  fi

  # Try as path under HOME (e.g., "jsh" → ~/.jsh won't match, but ".jsh" → ~/.jsh will)
  if [[ -d "${HOME}/${query}" ]]; then
    (builtin cd "${HOME}/${query}" && pwd -P)
    return 0
  fi

  # Try with dot prefix under HOME (e.g., "jsh" → ~/.jsh)
  if [[ "${query}" != .* ]] && [[ -d "${HOME}/.${query}" ]]; then
    (builtin cd "${HOME}/.${query}" && pwd -P)
    return 0
  fi

  return 1
}

# =============================================================================
# Main j Function
# =============================================================================

j() {
  local open_code=false
  local open_remote=false
  local verbose=false

  # Parse flags first
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        verbose=true
        shift
        ;;
      -c|--code)
        open_code=true
        shift
        ;;
      -a|--add)
        _j_add "${PWD}"
        _j_ui_message success "Added · $(_j_display_path "${PWD}")"
        return 0
        ;;
      --remove)
        if _j_remove "${PWD}"; then
          _j_ui_message success "Removed · $(_j_display_path "${PWD}")"
        else
          _j_ui_message warn "Not in database · $(_j_display_path "${PWD}")"
          return 1
        fi
        return 0
        ;;
      --db)
        _j_list
        return 0
        ;;
      --clean)
        _j_clean
        return 0
        ;;
      -l|--list)
        # Migration: -l moved to gitx list
        _j_ui_message warn '"j -l" has moved to "gitx list"'
        shift
        declare -f jsh_command_preview >/dev/null 2>&1 && jsh_command_preview "gitx list $*" >&2
        return 1
        ;;
      -r|--remote)
        open_remote=true
        shift
        ;;
      -h|--help)
        jsh_banner "j" "Smart frecency-based directory jumping"
        jsh_section "Usage"
        jsh_field "j" "Interactive directory selection (fzf)"
        jsh_field "j <query>" "Jump to the best matching directory or project"
        jsh_field "j <q1> <q2>" "Match multiple keywords"
        jsh_field "j -" "Jump to the previous directory"
        jsh_field "j -v [query]" "Show search steps"
        jsh_field "j -c [query]" "Open in VS Code without changing directory"
        jsh_field "j -r [query]" "Open a remote project in VS Code over SSH"
        jsh_section "Database"
        jsh_field "j --db" "Show tracked directories and scores"
        jsh_field "j -a, --add" "Add the current directory"
        jsh_field "j --remove" "Remove the current directory"
        jsh_field "j --clean" "Remove directories that no longer exist"
        jsh_section "Git Projects"
        jsh_command_preview "gitx clone <url>"
        jsh_command_preview "gitx create <name>"
        jsh_command_preview "gitx list"
        jsh_command_preview "gitx profile"
        jsh_section "Environment"
        jsh_field "J_DATA" "Database path (default: ~/.jsh/local/j.db)"
        jsh_field "J_EXCLUDE" "Colon-separated tracking exclusions"
        jsh_field "J_NO_HOOK" "Disable automatic directory tracking"
        jsh_note "Alias: p | remote projects: ~/.jsh/local/projects.json"
        return 0
        ;;
      -)
        # Jump to previous directory, or only open it with -c
        if [[ -n "${_J_PREV_DIR}" ]] && [[ -d "${_J_PREV_DIR}" ]]; then
          if [[ "${open_code}" == true ]]; then
            _j_open_code_path "${_J_PREV_DIR}"
          else
            _j_cd_hook "${_J_PREV_DIR}"
          fi
        else
          _j_ui_message warn "No previous directory"
          return 1
        fi
        return 0
        ;;
      -*)
        _j_ui_message error "Unknown option: $1"
        return 1
        ;;
      *)
        break
        ;;
    esac
  done

  # Handle -r (remote) - always uses remote picker, never cd
  if [[ "${open_remote}" == true ]]; then
    local remote_name
    if [[ $# -gt 0 ]]; then
      remote_name="$1"
    else
      remote_name="$(_j_select_remote)"
    fi
    if [[ -n "${remote_name}" ]]; then
      _gitx_open_remote "${remote_name}"
    fi
    return $?
  fi

  # A literal dot names the working directory, not a frecency query.
  if [[ $# -eq 1 ]] && [[ "$1" == "." ]]; then
    if [[ "${open_code}" == true ]]; then
      _j_open_code_path "${PWD}"
    else
      _j_cd_hook "${PWD}"
    fi
    return $?
  fi

  # No arguments - interactive selection
  if [[ $# -eq 0 ]]; then
    local selected

    # Include "(current)" option when using -c and already in a gitx project
    if [[ "${open_code}" == true ]] && _j_is_gitx_project; then
      _J_INTERACTIVE_INCLUDE_CURRENT="${PWD}"
    else
      _J_INTERACTIVE_INCLUDE_CURRENT=""
    fi

    selected="$(_j_interactive)"
    unset _J_INTERACTIVE_INCLUDE_CURRENT

    if [[ -n "${selected}" ]]; then
      # Handle "(current)" selection - open VS Code in current dir
      if [[ "${selected}" == "CURRENT:"* ]]; then
        _j_open_code
      elif [[ "${open_code}" == true ]]; then
        _j_open_code_path "${selected}"
      else
        _j_cd_hook "${selected}"
      fi
    fi
    return 0
  fi

  # Query mode - find best match
  [[ "${verbose}" == true ]] && _j_ui_message info "Searching frecency database · ${J_DATA}"

  local best="" count=0 line

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ -z "${best}" ]] && best="${line}"
    (( count += 1 ))
  done < <(_j_query "$@")

  if [[ ${count} -gt 0 ]]; then
    local _j_best_path="${best#*|}"
    [[ "${verbose}" == true ]] && _j_ui_message success "${count} database match(es) · best $(_j_display_path "${_j_best_path}")"
    if [[ "${open_code}" == true ]]; then
      _j_open_code_path "${_j_best_path}"
    else
      _j_cd_hook "${_j_best_path}"
    fi
    return 0
  fi

  # Fallbacks only apply for single-keyword queries
  if [[ $# -eq 1 ]]; then
    [[ "${verbose}" == true ]] && _j_ui_message info "No database match · trying path resolution"

    # Fallback 1: Try resolving query as a directory path
    local resolved
    resolved="$(_j_resolve_path "$1")"
    if [[ -n "${resolved}" ]] && [[ -d "${resolved}" ]]; then
      [[ "${verbose}" == true ]] && _j_ui_message success "Resolved path · $(_j_display_path "${resolved}")"
      if [[ "${open_code}" == true ]]; then
        _j_open_code_path "${resolved}"
      else
        _j_cd_hook "${resolved}"
      fi
      return 0
    fi

    # Fallback 2: Try as gitx project name (fast - single lookup)
    if command -v gitx &>/dev/null; then
      [[ "${verbose}" == true ]] && _j_ui_message info "Trying gitx project lookup · $1"
      local project_path
      project_path=$(gitx path "$1" 2>/dev/null)
      if [[ -n "${project_path}" ]] && [[ -d "${project_path}" ]]; then
        [[ "${verbose}" == true ]] && _j_ui_message success "Found project · $(_j_display_path "${project_path}")"
        if [[ "${open_code}" == true ]]; then
          _j_open_code_path "${project_path}"
        else
          _j_cd_hook "${project_path}"
        fi
        return 0
      fi
    fi
  fi

  [[ "${verbose}" == true ]] && _j_ui_message warn "No matching directory · $*"
  _j_ui_message error "No matching directory · $*"
  return 1
}

# =============================================================================
# Initialization
# =============================================================================

# Override cd to track directories
# Preserve existing cd wrapper functionality (create dirs if needed)
_j_has_original_cd=false

if declare -f cd &>/dev/null; then
  # There's an existing cd function - wrap it using shell-specific methods
  if [[ "${_J_SHELL}" == "zsh" ]]; then
    # zsh: save function body and recreate with new name
    _j_cd_body="$(functions -c cd 2>/dev/null)"
    if [[ -n "${_j_cd_body}" ]]; then
      eval "_j_original_cd ${_j_cd_body#cd }" 2>/dev/null && _j_has_original_cd=true
    fi
    unset _j_cd_body
  else
    # bash: use eval with sed to rename the function
    if eval "$(declare -f cd | sed '1s/^cd /_j_original_cd /')" 2>/dev/null; then
      _j_has_original_cd=true
    fi
  fi
fi

if [[ "${_j_has_original_cd}" == true ]]; then
  cd() {
    _J_PREV_DIR="${PWD}"
    _j_original_cd "$@" || return $?
    _j_after_cd
  }
else
  # No existing wrapper or copy failed - use builtin
  cd() {
    _J_PREV_DIR="${PWD}"
    builtin cd "$@" || return $?
    _j_after_cd
  }
fi

unset _j_has_original_cd

# Migrate from old ~/.marks file if it exists
_j_migrate_marks() {
  local marks_file="${HOME}/.marks"
  [[ -f "${marks_file}" ]] || return 0
  [[ -f "${J_DATA}" ]] && return 0  # Don't migrate if j.db exists

  _j_ui_message info "Migrating bookmarks from ~/.marks to the j database..."

  _j_ensure_dir

  local now count=0 name _j_mark_path
  now="$(_j_now)"

  while IFS=':' read -r name _j_mark_path; do
    [[ -z "${_j_mark_path}" ]] && continue
    [[ ! -d "${_j_mark_path}" ]] && continue

    # Give migrated bookmarks a base count of 10
    printf '%s|10|%s\n' "${_j_mark_path}" "${now}" >> "${J_DATA}"
    (( count += 1 ))
  done < "${marks_file}"

  if [[ ${count} -gt 0 ]]; then
    _j_ui_message success "Migrated ${count} bookmarks · original preserved at ~/.marks"
  fi
}

# Run migration on first load
_j_migrate_marks

# Bash completion for j command
if [[ -n "${BASH_VERSION:-}" ]]; then
  _j_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"

    local completions=""

    if [[ ${COMP_CWORD} -eq 1 ]]; then
      # First arg: flags + project names from gitx for fallback
      completions="--db --clean"
      completions+=" $(gitx list 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    fi

    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "${completions}" -- "${cur}"))
  }
  complete -F _j_completions j
  complete -F _j_completions p
fi

# =============================================================================
# Gitx shell integration
# =============================================================================
# gitx.sh - Shell wrapper for gitx commands that need parent shell integration
# shellcheck disable=SC2119,SC2120,SC2207,SC2296
#
# This file should be sourced, not executed, so that `gitx` shell function
# can change the current directory of the calling shell after clone/create.
#
# Commands handled by this wrapper:
#   gitx clone <url> [name]   Clone repository and cd into it
#   gitx create <name>        Create project directory and cd into it
#   gitx remote <name>        Open remote project in VS Code
#
# All other commands pass through to bin/gitx.

# =============================================================================
# Configuration
# =============================================================================

# Remote projects config file
_GITX_REMOTE_CONFIG="${JSH_DIR:-${HOME}/.jsh}/local/projects.json"

# =============================================================================
# Remote Project Functions
# =============================================================================

# Get remote project info from config
# Arguments:
#   $1 - Project name
# Output: JSON object with host, path, user, etc. or empty if not found
_gitx_get_remote() {
  local name="$1"

  if [[ ! -f "${_GITX_REMOTE_CONFIG}" ]]; then
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    printf 'jq is required for remote projects\n' >&2
    return 1
  fi

  jq -r --arg name "${name}" '.remotes[$name] // empty' "${_GITX_REMOTE_CONFIG}" 2>/dev/null || true
}

# List all remote project names
# Output: Project names, one per line
_gitx_list_remotes() {
  if [[ ! -f "${_GITX_REMOTE_CONFIG}" ]]; then
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    return 0
  fi

  jq -r '.remotes | keys[]' "${_GITX_REMOTE_CONFIG}" 2>/dev/null || true
}

# Open a remote project in VS Code Remote SSH
# Arguments:
#   $1 - Project name
# Returns: 0 on success, 1 on failure
_gitx_open_remote() {
  local name="$1"
  local remote_info host remote_path user ssh_key

  remote_info="$(_gitx_get_remote "${name}")"

  if [[ -z "${remote_info}" ]]; then
    error "No remote project found: ${name}"
    jsh_section "Available Remote Projects" >&2
    _gitx_list_remotes | while read -r proj; do
      jsh_detail "${proj}" >&2
    done
    return 1
  fi

  host=$(printf '%s' "${remote_info}" | jq -r '.host')
  remote_path=$(printf '%s' "${remote_info}" | jq -r '.path')
  user=$(printf '%s' "${remote_info}" | jq -r '.user // empty')
  ssh_key=$(printf '%s' "${remote_info}" | jq -r '.ssh_key // empty')

  if [[ -z "${host}" ]] || [[ -z "${remote_path}" ]]; then
    error "Invalid remote project configuration: ${name}"
    return 1
  fi

  # Build SSH target (user@host or just host)
  local ssh_target="${host}"
  [[ -n "${user}" ]] && ssh_target="${user}@${host}"

  # Open in VS Code Remote SSH
  jsh_status "${name}" "opening ${ssh_target}:${remote_path}" plan
  [[ -n "${ssh_key}" ]] && jsh_field "SSH key" "${ssh_key}"

  code --remote "ssh-remote+${ssh_target}" "${remote_path}"
}

# =============================================================================
# Main gitx Function
# =============================================================================

gitx() {
  local open_code=false

  # Parse global flags first
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--code)
        open_code=true
        shift
        ;;
      -h|--help)
        # Pass through to binary for help
        command gitx --help
        return $?
        ;;
      -*)
        # Unknown flag - let the binary handle it
        break
        ;;
      *)
        break
        ;;
    esac
  done

  # Handle commands that need shell integration
  case "${1:-}" in
    clone|create)
      # Clone/create project then cd into it via temp file
      local cd_file
      cd_file=$(mktemp "${TMPDIR:-/tmp}/gitx-cd.XXXXXX")

      JSH_WRAPPER=1 JSH_CD_FILE="${cd_file}" command gitx "$@"
      local ret=$?

      if [[ $ret -eq 0 && -f "${cd_file}" ]]; then
        local target_dir
        target_dir=$(cat "${cd_file}")
        if [[ -n "${target_dir}" && -d "${target_dir}" ]]; then
          cd "${target_dir}" || ret=1
          [[ "${open_code}" == true ]] && code .
        fi
      fi

      rm -f "${cd_file}"
      return $ret
      ;;

    remote)
      # Open remote project in VS Code (no cd - it's on a different machine)
      shift
      if [[ $# -eq 0 ]]; then
        printf '%sUsage:%s gitx remote <project-name>\n' "${DIM:-}" "${RST:-}" >&2
        printf '\n%sAvailable remote projects:%s\n' "${DIM:-}" "${RST:-}" >&2
        _gitx_list_remotes | while read -r proj; do
          printf '%s%s%s\n' "${CYN:-}" "${proj}" "${RST:-}" >&2
        done
        return 1
      fi
      _gitx_open_remote "$1"
      return $?
      ;;

    *)
      # Pass through to binary for all other commands
      command gitx "$@"
      return $?
      ;;
  esac
}

# =============================================================================
# Git status
# =============================================================================
# gitstatus.sh - Git status functions for prompt (with async support)
# Pure shell, no external dependencies
# shellcheck disable=SC2034

# =============================================================================
# Configuration
# =============================================================================

# Symbols (customizable)
GIT_SYMBOL_BRANCH="${GIT_SYMBOL_BRANCH:-}"
GIT_SYMBOL_DETACHED="${GIT_SYMBOL_DETACHED:-@}"
GIT_SYMBOL_MODIFIED="${GIT_SYMBOL_MODIFIED:-~}"
GIT_SYMBOL_STAGED="${GIT_SYMBOL_STAGED:-+}"
GIT_SYMBOL_UNTRACKED="${GIT_SYMBOL_UNTRACKED:-?}"
GIT_SYMBOL_STASH="${GIT_SYMBOL_STASH:-$}"
GIT_SYMBOL_AHEAD="${GIT_SYMBOL_AHEAD:-+}"
GIT_SYMBOL_BEHIND="${GIT_SYMBOL_BEHIND:--}"
GIT_SYMBOL_DIVERGED="${GIT_SYMBOL_DIVERGED:-+/-}"
GIT_SYMBOL_CLEAN="${GIT_SYMBOL_CLEAN:-}"
GIT_SYMBOL_CONFLICT="${GIT_SYMBOL_CONFLICT:-!}"

# Fallback symbols (no unicode)
GIT_SYMBOL_AHEAD_PLAIN="${GIT_SYMBOL_AHEAD_PLAIN:-^}"
GIT_SYMBOL_BEHIND_PLAIN="${GIT_SYMBOL_BEHIND_PLAIN:-v}"
GIT_SYMBOL_DIVERGED_PLAIN="${GIT_SYMBOL_DIVERGED_PLAIN:-*}"
GIT_SYMBOL_CLEAN_PLAIN="${GIT_SYMBOL_CLEAN_PLAIN:-ok}"

# Timeout for git operations (milliseconds)
GIT_PROMPT_TIMEOUT="${GIT_PROMPT_TIMEOUT:-2000}"

# Async state is allocated lazily. This keeps startup fork-free while retaining
# a private directory when the legacy file-based async helpers are used.
_GIT_ASYNC_DIR="${_GIT_ASYNC_DIR:-}"
_GIT_ASYNC_FILE="${_GIT_ASYNC_FILE:-}"

# =============================================================================
# Basic Git Functions
# =============================================================================

git_is_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

git_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

git_is_bare() {
  [[ "$(git rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]
}

# =============================================================================
# Branch / Reference Functions
# =============================================================================

git_branch() {
  # Returns branch name, or :SHA if detached
  local branch
  branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
  if [[ -n "${branch}" ]]; then
    echo "${branch}"
  else
    # Detached HEAD - show short SHA
    local sha
    sha="$(git rev-parse --short HEAD 2>/dev/null)"
    echo ":${sha:-unknown}"
  fi
}

git_branch_or_tag() {
  # Returns branch, @tag, or :SHA
  local branch tag sha
  branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
  if [[ -n "${branch}" ]]; then
    echo "${branch}"
    return
  fi
  # Check for tag
  tag="$(git describe --tags --exact-match HEAD 2>/dev/null)"
  if [[ -n "${tag}" ]]; then
    echo "@${tag}"
    return
  fi
  # Fallback to SHA
  sha="$(git rev-parse --short HEAD 2>/dev/null)"
  echo ":${sha:-unknown}"
}

# =============================================================================
# Status Detection Functions
# =============================================================================

git_is_dirty() {
  # Quick check - any uncommitted changes?
  ! git diff --quiet HEAD 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]
}

git_has_staged() {
  ! git diff --cached --quiet 2>/dev/null
}

git_has_unstaged() {
  ! git diff --quiet 2>/dev/null
}

git_has_untracked() {
  [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]
}

git_has_conflicts() {
  [[ -n "$(git ls-files --unmerged 2>/dev/null | head -1)" ]]
}

git_has_stash() {
  git rev-parse --verify --quiet refs/stash >/dev/null 2>&1
}

git_stash_count() {
  git stash list 2>/dev/null | wc -l | tr -d ' '
}

# =============================================================================
# Upstream Tracking Functions
# =============================================================================

git_upstream() {
  git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null
}

git_commits_ahead() {
  git rev-list --count '@{upstream}'..HEAD 2>/dev/null || echo 0
}

git_commits_behind() {
  git rev-list --count HEAD..'@{upstream}' 2>/dev/null || echo 0
}

git_ahead_behind() {
  # Returns "ahead:behind" counts
  local ahead behind
  ahead="$(git_commits_ahead)"
  behind="$(git_commits_behind)"
  echo "${ahead}:${behind}"
}

# =============================================================================
# Combined Status (Single Git Call - Fast)
# =============================================================================

git_status_fast() {
  # Get all status info in one git call
  # Returns: branch|staged|unstaged|untracked|ahead|behind|stash|conflicts

  git_is_repo || return 1

  local branch staged=0 unstaged=0 untracked=0 conflicts=0
  local ahead=0 behind=0 stash=0

  # Get branch
  branch="$(git_branch_or_tag)"

  # Parse porcelain status (fast, machine-readable)
  # NOTE: Avoid process substitution here.
  # Some zsh builds on appliance distros can crash in hook contexts when
  # evaluating '< <(...)' during prompt/precmd execution.
  local status_line status_output
  status_output="$(git status --porcelain=v1 -b 2>/dev/null)"
  while IFS= read -r status_line; do
    case "${status_line:0:2}" in
      "##")
        # Parse ahead/behind from branch line
        # Works in both bash (BASH_REMATCH) and zsh (match)
        if [[ -n "${ZSH_VERSION:-}" ]]; then
          # Zsh: use $match array (quotes required for zsh regex)
          # shellcheck disable=SC2076
          if [[ "${status_line}" =~ '\[ahead ([0-9]+), behind ([0-9]+)\]' ]]; then
            ahead="${match[1]}"
            behind="${match[2]}"
          elif [[ "${status_line}" =~ '\[ahead ([0-9]+)\]' ]]; then
            ahead="${match[1]}"
          elif [[ "${status_line}" =~ '\[behind ([0-9]+)\]' ]]; then
            behind="${match[1]}"
          fi
        else
          # Bash: use BASH_REMATCH
          if [[ "${status_line}" =~ \[ahead\ ([0-9]+),\ behind\ ([0-9]+)\] ]]; then
            ahead="${BASH_REMATCH[1]}"
            behind="${BASH_REMATCH[2]}"
          elif [[ "${status_line}" =~ \[ahead\ ([0-9]+)\] ]]; then
            ahead="${BASH_REMATCH[1]}"
          elif [[ "${status_line}" =~ \[behind\ ([0-9]+)\] ]]; then
            behind="${BASH_REMATCH[1]}"
          fi
        fi
        ;;
      "??") ((untracked++)) ;;
      "UU"|"AA"|"DD"|"AU"|"UA"|"DU"|"UD") ((conflicts++)) ;;
      *)
        # First char = staged, second = unstaged
        [[ "${status_line:0:1}" != " " && "${status_line:0:1}" != "?" ]] && ((staged++))
        [[ "${status_line:1:1}" != " " && "${status_line:1:1}" != "?" ]] && ((unstaged++))
        ;;
    esac
  done <<< "${status_output}"

  # Check stash
  # Single call: counts stash reflog entries; errors (no stash) collapse to 0.
  stash="$(git rev-list --walk-reflogs --count refs/stash 2>/dev/null || printf '0')"
  [[ -z "${stash}" ]] && stash=0

  echo "${branch}|${staged}|${unstaged}|${untracked}|${ahead}|${behind}|${stash}|${conflicts}"
}

# =============================================================================
# Prompt String Generators
# =============================================================================

_git_use_unicode() {
  # Unicode is always available (LANG=en_US.UTF-8 set in .zshrc)
  # This only checks if user explicitly requested ASCII mode
  [[ "${GIT_PROMPT_ASCII:-0}" != "1" ]]
}

git_prompt_info() {
  # Plain text git status for prompt
  git_is_repo || return 0

  local info
  info="$(git_status_fast)"
  [[ -z "${info}" ]] && return 0

  local branch staged unstaged untracked ahead behind stash conflicts
  IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

  local result="${branch}"
  local dirty=""

  # Status indicators
  [[ "${staged}" -gt 0 ]] && dirty+="${GIT_SYMBOL_STAGED}"
  [[ "${unstaged}" -gt 0 ]] && dirty+="${GIT_SYMBOL_MODIFIED}"
  [[ "${untracked}" -gt 0 ]] && dirty+="${GIT_SYMBOL_UNTRACKED}"
  [[ "${conflicts}" -gt 0 ]] && dirty+="${GIT_SYMBOL_CONFLICT}"

  [[ -n "${dirty}" ]] && result+="${dirty}"

  # Ahead/behind
  if _git_use_unicode; then
    [[ "${ahead}" -gt 0 && "${behind}" -gt 0 ]] && result+=" ${GIT_SYMBOL_DIVERGED}${ahead}/${behind}"
    [[ "${ahead}" -gt 0 && "${behind}" -eq 0 ]] && result+=" ${GIT_SYMBOL_AHEAD}${ahead}"
    [[ "${behind}" -gt 0 && "${ahead}" -eq 0 ]] && result+=" ${GIT_SYMBOL_BEHIND}${behind}"
  else
    [[ "${ahead}" -gt 0 && "${behind}" -gt 0 ]] && result+=" ${GIT_SYMBOL_DIVERGED_PLAIN}${ahead}/${behind}"
    [[ "${ahead}" -gt 0 && "${behind}" -eq 0 ]] && result+=" ${GIT_SYMBOL_AHEAD_PLAIN}${ahead}"
    [[ "${behind}" -gt 0 && "${ahead}" -eq 0 ]] && result+=" ${GIT_SYMBOL_BEHIND_PLAIN}${behind}"
  fi

  # Stash
  [[ "${stash}" -gt 0 ]] && result+=" ${GIT_SYMBOL_STASH}${stash}"

  echo "${result}"
}

git_prompt_info_colored() {
  # Colored git status for prompt
  # Uses raw escape codes - caller must wrap for prompt safety
  git_is_repo || return 0

  local info
  info="$(git_status_fast)"
  [[ -z "${info}" ]] && return 0

  local branch staged unstaged untracked ahead behind stash conflicts
  IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

  # Branch color (clean=green, dirty=yellow, conflicts=red)
  local branch_color="${C_OK:-}"
  if [[ "${conflicts}" -gt 0 ]]; then
    branch_color="${C_ERR:-}"
  elif [[ "${staged}" -gt 0 || "${unstaged}" -gt 0 || "${untracked}" -gt 0 ]]; then
    branch_color="${C_WARN:-}"
  fi

  local result="${branch_color}${branch}${RST:-}"

  # Status indicators (each with own color)
  [[ "${staged}" -gt 0 ]] && result+="${C_OK:-}${GIT_SYMBOL_STAGED}${RST:-}"
  [[ "${unstaged}" -gt 0 ]] && result+="${C_WARN:-}${GIT_SYMBOL_MODIFIED}${RST:-}"
  [[ "${untracked}" -gt 0 ]] && result+="${C_INFO:-}${GIT_SYMBOL_UNTRACKED}${RST:-}"
  [[ "${conflicts}" -gt 0 ]] && result+="${C_ERR:-}${GIT_SYMBOL_CONFLICT}${RST:-}"

  # Ahead/behind (cyan)
  local ab_sym_ahead ab_sym_behind ab_sym_div
  if _git_use_unicode; then
    ab_sym_ahead="${GIT_SYMBOL_AHEAD}"
    ab_sym_behind="${GIT_SYMBOL_BEHIND}"
    ab_sym_div="${GIT_SYMBOL_DIVERGED}"
  else
    ab_sym_ahead="${GIT_SYMBOL_AHEAD_PLAIN}"
    ab_sym_behind="${GIT_SYMBOL_BEHIND_PLAIN}"
    ab_sym_div="${GIT_SYMBOL_DIVERGED_PLAIN}"
  fi

  if [[ "${ahead}" -gt 0 && "${behind}" -gt 0 ]]; then
    result+=" ${C_INFO:-}${ab_sym_div}${ahead}/${behind}${RST:-}"
  elif [[ "${ahead}" -gt 0 ]]; then
    result+=" ${C_INFO:-}${ab_sym_ahead}${ahead}${RST:-}"
  elif [[ "${behind}" -gt 0 ]]; then
    result+=" ${C_INFO:-}${ab_sym_behind}${behind}${RST:-}"
  fi

  # Stash (cyan/accent)
  [[ "${stash}" -gt 0 ]] && result+=" ${C_ACCENT:-}${GIT_SYMBOL_STASH}${stash}${RST:-}"

  echo "${result}"
}

# =============================================================================
# Async Git Status (for instant prompt)
# =============================================================================

_git_async_worker() {
  # Background worker that computes git status
  local output_file="$1"
  # `status` is a read-only special parameter in zsh.
  local _git_status_result
  _git_status_result="$(git_prompt_info_colored 2>/dev/null)"
  printf '%s\n' "${_git_status_result}" > "${output_file}"
}

git_async_start() {
  # Start async git status computation
  git_is_repo || return 1

  if [[ -z "${_GIT_ASYNC_DIR}" ]]; then
    _GIT_ASYNC_DIR="$(
      /usr/bin/mktemp -d "${TMPDIR:-/tmp}/.jsh_git_async.XXXXXX" 2>/dev/null ||
        mktemp -d "${TMPDIR:-/tmp}/.jsh_git_async.XXXXXX"
    )" || return 1
    _GIT_ASYNC_FILE="${_GIT_ASYNC_DIR}/result"
  fi

  # Clean up old file
  rm -f "${_GIT_ASYNC_FILE}" 2>/dev/null

  # Run detached so prompt refreshes never leak shell job notifications.
  jsh_run_detached --silent _git_async_worker "${_GIT_ASYNC_FILE}"
  _GIT_ASYNC_PID="${_JSH_DETACHED_PID}"
}

git_async_result() {
  # Get async result (returns immediately, may be empty)
  if [[ -f "${_GIT_ASYNC_FILE}" ]]; then
    cat "${_GIT_ASYNC_FILE}"
    rm -f "${_GIT_ASYNC_FILE}" 2>/dev/null
    unset _GIT_ASYNC_PID
  fi
}

git_async_wait() {
  # Wait for async result with timeout
  local timeout="${1:-${GIT_PROMPT_TIMEOUT}}"
  local elapsed=0
  local interval=10  # ms

  while [[ ! -f "${_GIT_ASYNC_FILE}" ]] && [[ "${elapsed}" -lt "${timeout}" ]]; do
    sleep 0.01 2>/dev/null || sleep 1
    ((elapsed += interval))
  done

  git_async_result
}

git_async_cleanup() {
  # Clean up async resources
  [[ -n "${_GIT_ASYNC_PID:-}" ]] && kill "${_GIT_ASYNC_PID}" 2>/dev/null
  [[ -n "${_GIT_ASYNC_FILE:-}" ]] && rm -f "${_GIT_ASYNC_FILE}" 2>/dev/null
  [[ -n "${_GIT_ASYNC_DIR:-}" ]] && rmdir "${_GIT_ASYNC_DIR}" 2>/dev/null
  unset _GIT_ASYNC_PID
  _GIT_ASYNC_DIR=""
  _GIT_ASYNC_FILE=""
}

# Cleanup on shell exit
if declare -f jsh_trap_add >/dev/null 2>&1; then
  jsh_trap_add EXIT git_async_cleanup
else
  trap 'git_async_cleanup' EXIT
fi

# =============================================================================
# Repo Size Heuristics (for skipping slow repos)
# =============================================================================

_git_is_large_repo() {
  # Heuristic: check if repo might be slow
  local git_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1

  # Check if index is large (>50MB suggests large repo)
  local index_file="${git_dir}/index"
  if [[ -f "${index_file}" ]]; then
    local size
    if [[ "${JSH_OS}" == "macos" ]]; then
      size=$(stat -f%z "${index_file}" 2>/dev/null || echo 0)
    else
      size=$(stat -c%s "${index_file}" 2>/dev/null || echo 0)
    fi
    [[ "${size}" -gt 52428800 ]] && return 0
  fi

  return 1
}

git_prompt_smart() {
  # Smart prompt: async for large repos, sync for small
  if _git_is_large_repo; then
    # Use cached result or empty for large repos
    git_async_start
    echo ""  # Prompt will update async
  else
    # Sync for small repos (fast)
    git_prompt_info_colored
  fi
}

# =============================================================================
# External completions
# =============================================================================
# completion.sh - Cross-shell completion loaders for external tools
# Caches and sources completions for tools like kubectl, helm, etc.
# shellcheck disable=SC1090

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
# Usage: _jsh_cached_completion <tool> [max_age_days] [completion_subcommand]
#   tool: Command name (must support `<tool> completion <shell>` by default)
#   max_age_days: Cache expiry in days (default: 7)
#   completion_subcommand: Completion command name (default: completion)

_jsh_cached_completion() {
  local tool="${1:?tool required}"
  local max_age="${2:-7}"
  local completion_cmd="${3:-completion}"

  command -v "$tool" &>/dev/null || return 0

  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/jsh/${tool}-completion.${JSH_SHELL}"
  local bin
  bin="$(command -v "$tool")"

  # Ensure cache directory exists (portable dirname: ${var%/*})
  [[ -d "${cache%/*}" ]] || mkdir -p "${cache%/*}"

  # Regenerate if: missing, binary newer, or cache expired
  if [[ ! -f "$cache" || "$bin" -nt "$cache" ]] || \
     [[ -n "$(find "$cache" -mtime +"${max_age}" 2>/dev/null)" ]]; then
    "$tool" "$completion_cmd" "${JSH_SHELL}" > "$cache" 2>/dev/null
  fi

  [[ -f "$cache" ]] && _jsh_defer_completion_if_needed "$cache"
}

# Task and just emit completion code for the active shell. Cache it like other
# tools and source it after compinit becomes available.
_jsh_cached_completion task 7 --completion
_jsh_cached_completion just 7 --completions

# =============================================================================
# Load completions for installed tools on first use. Generating and sourcing
# large kubectl/bun scripts during shell startup is wasted work in most shells.
# =============================================================================

_jsh_kubectl_completion_stub() {
  _jsh_cached_completion kubectl
  if [[ -n "${ZSH_VERSION:-}" ]] && (( ${+functions[__start_kubectl]} )); then
    __start_kubectl "$@"
  elif [[ -n "${BASH_VERSION:-}" ]] && declare -f __start_kubectl >/dev/null 2>&1; then
    __start_kubectl "$@"
  fi
}

_jsh_bun_completion_stub() {
  _jsh_cached_completion bun 7 completions
  if [[ -n "${ZSH_VERSION:-}" ]] && (( ${+functions[_bun]} )); then
    _bun "$@"
  fi
}

_jsh_setup_external_completion_stubs() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    compdef _jsh_kubectl_completion_stub kubectl
    compdef _jsh_bun_completion_stub bun
  elif [[ -n "${BASH_VERSION:-}" ]]; then
    complete -F _jsh_kubectl_completion_stub kubectl
  fi
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _JSH_DEFERRED_COMPLETIONS+=("_jsh_setup_external_completion_stubs")
else
  _jsh_setup_external_completion_stubs
fi
# Future: _jsh_cached_completion helm
# Future: _jsh_cached_completion terraform

# =============================================================================
# Zsh setup and vendor plugins
# =============================================================================
# shellcheck shell=bash
# zsh.sh - Zsh-specific configuration
# No plugins required, pure zsh
# shellcheck disable=SC1090,SC1094,SC2016,SC2034,SC2153,SC2154

# =============================================================================
# Zsh Options
# =============================================================================

# Navigation
setopt AUTO_CD              # cd by typing directory name
setopt AUTO_PUSHD           # Push directories to stack
setopt PUSHD_IGNORE_DUPS    # No duplicates in dir stack
setopt PUSHD_SILENT         # Don't print dir stack
setopt CDABLE_VARS          # cd to named directories

# Globbing
setopt EXTENDED_GLOB        # Extended pattern matching
setopt GLOB_DOTS            # Include dotfiles in globs
setopt NO_CASE_GLOB         # Case-insensitive globbing
setopt NUMERIC_GLOB_SORT    # Sort numerically when relevant
setopt GLOB_COMPLETE        # Generate globs on completion

# History
setopt EXTENDED_HISTORY     # Record timestamp in history
setopt HIST_EXPIRE_DUPS_FIRST  # Expire duplicates first
setopt HIST_IGNORE_DUPS     # Don't record duplicates
setopt HIST_IGNORE_ALL_DUPS # Delete old duplicate
setopt HIST_IGNORE_SPACE    # Don't record if starts with space
setopt HIST_FIND_NO_DUPS    # Don't display duplicates
setopt HIST_REDUCE_BLANKS   # Remove excess blanks
setopt HIST_VERIFY          # Don't execute immediately
setopt SHARE_HISTORY        # Share history across sessions (implies INC_APPEND)
setopt HIST_SAVE_NO_DUPS    # Don't save duplicates

# Completion
setopt COMPLETE_IN_WORD     # Complete from cursor
setopt ALWAYS_TO_END        # Move cursor to end after complete
setopt AUTO_MENU            # Auto menu on double tab
setopt AUTO_LIST            # List choices on ambiguous
setopt AUTO_PARAM_KEYS      # Auto insert parameter keys
setopt AUTO_PARAM_SLASH     # Add slash to directories
setopt AUTO_REMOVE_SLASH    # Remove slash if next char is word delimiter
setopt LIST_PACKED          # Compact completion list
setopt LIST_ROWS_FIRST      # Rows before columns

# Correction
if [[ "${TERM_PROGRAM:-}" == vscode || "${VSCODE_INJECTION:-0}" == 1 ||
  -n "${CODEX_THREAD_ID:-}" || -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]]; then
  unsetopt CORRECT
else
  setopt CORRECT
fi
unsetopt CORRECT_ALL        # Don't correct arguments (too annoying)

# Misc
setopt INTERACTIVE_COMMENTS # Allow comments in interactive
setopt NO_BEEP              # No beep
setopt NO_FLOW_CONTROL      # Disable Ctrl-S/Ctrl-Q
setopt PROMPT_SUBST         # Enable prompt substitution

# =============================================================================
# History Settings
# =============================================================================

HISTFILE="${JSH_HISTFILE:-${JSH_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/jsh}/history}"
HISTSIZE=50000
SAVEHIST=50000

# =============================================================================
# Completion System
# =============================================================================

if jsh_feature_enabled completions; then
typeset -a _jsh_completion_dirs
_jsh_completion_dirs=()

# Add custom completions.
if [[ -d "${JSH_DIR}/dotfiles/.config/shell/completions" ]]; then
  _jsh_completion_dirs+=("${JSH_DIR}/dotfiles/.config/shell/completions")
  fpath=("${JSH_DIR}/dotfiles/.config/shell/completions" "${fpath[@]}")
fi

# Add zsh-completions (submodule preferred, core fallback for offline)
if [[ -d "${JSH_DIR}/vendor/zsh-completions/src" ]]; then
  # Full zsh-completions submodule available
  _jsh_completion_dirs+=("${JSH_DIR}/vendor/zsh-completions/src")
  fpath=("${JSH_DIR}/vendor/zsh-completions/src" "${fpath[@]}")
elif [[ -d "${JSH_DIR}/vendor/zsh-plugins/completions-core" ]]; then
  # Fallback to minimal core completions (offline/no submodule)
  _jsh_completion_dirs+=("${JSH_DIR}/vendor/zsh-plugins/completions-core")
  fpath=("${JSH_DIR}/vendor/zsh-plugins/completions-core" "${fpath[@]}")
fi

autoload -Uz compinit

_zsh_compdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-${ZSH_VERSION}"
_zsh_compdump_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
[[ -d "${_zsh_compdump_dir}" ]] || /bin/mkdir -p "${_zsh_compdump_dir}" 2>/dev/null

# Rebuild explicitly instead of relying on compinit's coarse file-count check.
# That check can keep a valid-looking dump which predates a newly added
# completion, leaving commands such as jsh without any tab completion.
_jsh_rebuild_compdump() {
  # Keep -D after -d: compinit processes options left-to-right, and -d would
  # otherwise turn automatic dump loading back on.
  # Jsh already sources executable code from JSH_DIR, so its completion files
  # have the same trust boundary. Using -i would silently remove them when a
  # checkout is group-writable (a common 770 setup on macOS).
  compinit -u -d "${_zsh_compdump}" -D || return
  compdump
  zcompile -R "${_zsh_compdump}.zwc" "${_zsh_compdump}" 2>/dev/null || true
}

_jsh_compdump_stale=0
if [[ ! -f "${_zsh_compdump}" || "${JSH_DIR}/dotfiles/.zshrc" -nt "${_zsh_compdump}" ]]; then
  _jsh_compdump_stale=1
else
  for _jsh_completion_dir in "${_jsh_completion_dirs[@]}"; do
    if [[ "${_jsh_completion_dir}" -nt "${_zsh_compdump}" ]]; then
      _jsh_compdump_stale=1
      break
    fi
  done
fi

if (( _jsh_compdump_stale )); then
  _jsh_rebuild_compdump
else
  compinit -C -d "${_zsh_compdump}"
fi

# Repair dumps produced before jsh's completion directory entered fpath. Use a
# completion that is still shipped; the old jsh management completion was
# intentionally removed when the launcher became self-contained.
if [[ "${_comps[gitx]-}" != "_gitx" ]]; then
  _jsh_rebuild_compdump
fi

unset _jsh_compdump_stale _jsh_completion_dir _jsh_completion_dirs
unfunction _jsh_rebuild_compdump

# Process deferred completions (registered before compinit loaded)
if [[ -n "${_JSH_DEFERRED_COMPLETIONS[*]:-}" ]]; then
  for _fn in "${_JSH_DEFERRED_COMPLETIONS[@]}"; do
    "${_fn}"
  done
  unset _JSH_DEFERRED_COMPLETIONS _fn
fi

# Just's dynamic completer mixes filesystem entries into recipe completion.
_jsh_just_completion() {
  local summary recipe completion value
  local -a recipes completions filtered
  local -A recipe_names
  summary="$(just --summary 2>/dev/null)" || summary=""
  recipes=(${=summary})

  if (( CURRENT == 2 )) && [[ "${words[CURRENT]}" != -* ]]; then
    (( ${#recipes} )) && _describe 'recipe' recipes
    return
  fi

  for recipe in "${recipes[@]}"; do
    recipe_names[$recipe]=1
  done
  completions=("${(@f)$(
      _CLAP_IFS=$'\n' \
        _CLAP_COMPLETE_INDEX=$((CURRENT - 1)) \
        JUST_COMPLETE=zsh \
        just -- "${words[@]}" 2>/dev/null
    )}")
  for completion in "${completions[@]}"; do
    value="${completion%%:*}"
    [[ "$value" == */ ]] && continue
    [[ -e "$completion" && -z "${recipe_names[$completion]-}" ]] && continue
    filtered+=("$completion")
  done
  (( ${#filtered} )) && _describe -V values filtered
}
if (( ${+functions[_clap_dynamic_completer_just]} )); then
  compdef _jsh_just_completion just
fi

# Completion options
zstyle ':completion:*' completer _complete _match _approximate
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
[[ -n "${LS_COLORS:-}" ]] && zstyle ':completion:*' list-colors "${LS_COLORS}"
zstyle ':completion:*' menu select=2
zstyle ':completion:*' verbose yes
zstyle ':completion:*' group-name ''
zstyle ':completion:*' use-cache yes
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"

# Group formatting
zstyle ':completion:*:descriptions' format "%F{${JSH_STYLE_MUTED}}%d%f"
zstyle ':completion:*:corrections' format "%F{${JSH_STYLE_WARN}}%d (errors: %e)%f"
zstyle ':completion:*:messages' format "%F{${JSH_STYLE_INFO}}%d%f"
zstyle ':completion:*:warnings' format "%F{${JSH_STYLE_ERROR}}no matches found%f"

# Completion for specific commands
zstyle ':completion:*:just:*' sort false
zstyle ':completion:*:*:kill:*:processes' list-colors "=(#b) #([0-9]#)*=0=01;${JSH_STYLE_ERROR_SGR}"
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# The stock _ssh completer reads known_hosts lazily. Avoid parsing it on every
# shell start, especially on network-mounted home directories.
fi

# =============================================================================
# Key Bindings (Zsh-specific)
# =============================================================================

# History search
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

bindkey '^[[A' up-line-or-beginning-search    # Up
bindkey '^[[B' down-line-or-beginning-search  # Down
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search

# Home/End
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[1~' beginning-of-line
bindkey '^[[4~' end-of-line

# Delete/Backspace (handle both DEL and ^H for compatibility)
bindkey '^[[3~' delete-char
bindkey '^?' backward-delete-char   # DEL (0x7F) - most modern terminals
bindkey '^H' backward-delete-char   # BS (0x08) - some terminals/SSH

# Word navigation
bindkey '^[[1;5D' backward-word  # Ctrl+Left
bindkey '^[[1;5C' forward-word   # Ctrl+Right
bindkey '^[b' backward-word      # Alt+b
bindkey '^[f' forward-word       # Alt+f

# Word deletion (Ctrl+Backspace / Ctrl+Delete)
zle -N _vimode_backward_kill_path_component_zsh
bindkey '^W' backward-kill-word         # Ctrl+W - traditional Unix binding
bindkey '^[[3;5~' kill-word             # Ctrl+Delete - delete word forward
bindkey '^[[127;5u' _vimode_backward_kill_path_component_zsh
bindkey '^[^?' _vimode_backward_kill_path_component_zsh
bindkey '^[^H' _vimode_backward_kill_path_component_zsh

# =============================================================================
# Directory Hashing (Quick cd)
# =============================================================================

# Named directories (cd ~projects)
hash -d projects="${HOME}/projects" 2>/dev/null
hash -d dl="${HOME}/Downloads" 2>/dev/null
hash -d docs="${HOME}/Documents" 2>/dev/null
hash -d jsh="${JSH_DIR}" 2>/dev/null

# =============================================================================
# Magic Space (History Expansion)
# =============================================================================

# Space expands history (!!, !$, etc.)
bindkey ' ' magic-space

# =============================================================================
# Hooks
# =============================================================================

autoload -Uz add-zsh-hook

# Terminal title
_jsh_set_title() {
  local title="${PWD/#$HOME/~}"
  printf '\e]2;%s\a' "${title}"
}
jsh_hook_add preexec _jsh_operation_title_preexec 40
jsh_hook_add precmd _jsh_operation_title_precmd 40
jsh_hook_add zshexit _jsh_operation_title_precmd 40
jsh_hook_add precmd _jsh_terminal_cwd 50
jsh_hook_add precmd _jsh_set_title 50

# =============================================================================
# History Search with system fzf fallback
# =============================================================================
# Runtime-safe: checks fzf availability on each invocation, not just at startup.
# Falls back to zsh's native incremental search (bck-i-search) if fzf goes missing.

_jsh_history_search() {
  if (( $+commands[fzf] )); then
    # fzf available - use fzf-history-widget if loaded
    if (( $+widgets[fzf-history-widget] )); then
      zle fzf-history-widget
    else
      # fzf exists but widget not loaded - use basic fzf search
      local selected
      selected=$(fc -rl 1 | fzf --height=40% --reverse --tac --no-sort --exact --query="${LBUFFER}" | sed 's/^ *[0-9]* *//')
      if [[ -n "$selected" ]]; then
        BUFFER="$selected"
        CURSOR=${#BUFFER}
      fi
      zle redisplay
    fi
  else
    # fzf not available - rebind to native and invoke it
    # This ensures the native bck-i-search mode is properly entered
    bindkey '^R' history-incremental-search-backward
    zle history-incremental-search-backward
  fi
}
zle -N _jsh_history_search

# Prefer integration generated by newer fzf versions, then install our
# wrapper so Ctrl+R remains resilient if fzf later disappears.
if jsh_feature_enabled plugins && has fzf; then
  if _jsh_fzf_integration="$(fzf --zsh 2>/dev/null)" && [[ -n "${_jsh_fzf_integration}" ]]; then
    eval "${_jsh_fzf_integration}"
  fi
  unset _jsh_fzf_integration
  bindkey '^R' _jsh_history_search
else
  # No fzf - explicitly bind to native incremental search
  # (bare zsh in vi mode has ^R bound to 'redisplay' which does nothing useful)
  bindkey '^R' history-incremental-search-backward
fi

bindkey '^S' history-incremental-search-forward

# One-time warning in SSH sessions when fzf not available
if ! has fzf && [[ "${JSH_ENV:-}" == "ssh" ]] && [[ -z "${_JSH_FZF_WARNED:-}" ]]; then
  export _JSH_FZF_WARNED=1
  printf '%s\n' "${C_MUTED:-\033[2m}[jsh] fzf not found - using standard history search (Ctrl+R)${RST:-\033[0m}" >&2
fi

# =============================================================================
# Zsh plugins under vendor/.
# =============================================================================

# fzf-tab - FZF-powered completion menu (submodule)
# NOTE: Must be sourced AFTER compinit and BEFORE autosuggestions
if jsh_feature_enabled plugins && jsh_feature_enabled completions && has fzf && [[ -f "${JSH_DIR}/vendor/fzf-tab/fzf-tab.plugin.zsh" ]]; then
  source "${JSH_DIR}/vendor/fzf-tab/fzf-tab.plugin.zsh"
  # Preview directory contents
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath'
  # Disable sort for git checkout
  zstyle ':completion:*:git-checkout:*' sort false
  # Use tmux popup if in tmux AND tmux version >= 3.2 (popup introduced in 3.2)
  # Graceful fallback to standard fzf-tab behavior for older tmux versions
  if [[ -n "${TMUX:-}" ]]; then
    _jsh_tmux_version=$(tmux -V 2>/dev/null | sed -n 's/^tmux \([0-9]*\)\.\([0-9]*\).*/\1.\2/p')
    if [[ -n "${_jsh_tmux_version}" ]]; then
      _jsh_tmux_major=${_jsh_tmux_version%%.*}
      _jsh_tmux_minor=${_jsh_tmux_version#*.}
      if (( _jsh_tmux_major > 3 || (_jsh_tmux_major == 3 && _jsh_tmux_minor >= 2) )); then
        zstyle ':fzf-tab:*' fzf-command ftb-tmux-popup
      fi
    fi
    unset _jsh_tmux_version _jsh_tmux_major _jsh_tmux_minor
  fi
  # Disable group headers (Homebrew's "internal commands" categorization is confusing)
  zstyle ':fzf-tab:*' show-group none
  # Remove redundant dot prefix on completion items
  zstyle ':fzf-tab:*' prefix ''
fi

# zsh-autosuggestions - Fish-like autosuggestions
if jsh_feature_enabled plugins && [[ -f "${JSH_DIR}/vendor/zsh-plugins/zsh-autosuggestions.zsh" ]]; then
  source "${JSH_DIR}/vendor/zsh-plugins/zsh-autosuggestions.zsh"
  # Configuration
  ZSH_AUTOSUGGEST_STRATEGY=(history completion)
  ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=${JSH_STYLE_MUTED}"
  # Accept suggestion with right arrow or end key
  bindkey '^[[C' forward-char  # Right arrow accepts char
  bindkey '^[f' forward-word   # Alt+f accepts word
fi

# zsh-syntax-highlighting - Fish-like syntax highlighting
# NOTE: Must be sourced AFTER all other plugins and before history-substring-search
if jsh_feature_enabled plugins && [[ -f "${JSH_DIR}/vendor/zsh-plugins/zsh-syntax-highlighting.zsh" ]]; then
  source "${JSH_DIR}/vendor/zsh-plugins/zsh-syntax-highlighting.zsh"
  ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
  typeset -A ZSH_HIGHLIGHT_STYLES
  ZSH_HIGHLIGHT_STYLES[command]="fg=${JSH_STYLE_OK},bold"
  ZSH_HIGHLIGHT_STYLES[alias]="fg=${JSH_STYLE_OK},bold"
  ZSH_HIGHLIGHT_STYLES[builtin]="fg=${JSH_STYLE_OK},bold"
  ZSH_HIGHLIGHT_STYLES[function]="fg=${JSH_STYLE_OK},bold"
  ZSH_HIGHLIGHT_STYLES[path]="fg=${JSH_STYLE_INFO},underline"
  ZSH_HIGHLIGHT_STYLES[globbing]="fg=${JSH_STYLE_ACCENT}"
  ZSH_HIGHLIGHT_STYLES[unknown-token]="fg=${JSH_STYLE_ERROR}"
fi

# zsh-history-substring-search - Fish-like history search
# NOTE: Must be sourced AFTER zsh-syntax-highlighting
if jsh_feature_enabled plugins && [[ -f "${JSH_DIR}/vendor/zsh-plugins/zsh-history-substring-search.zsh" ]]; then
  source "${JSH_DIR}/vendor/zsh-plugins/zsh-history-substring-search.zsh"
  # Bind up/down arrows to substring search
  bindkey '^[[A' history-substring-search-up
  bindkey '^[[B' history-substring-search-down
  # Bind in vi mode as well
  bindkey -M vicmd 'k' history-substring-search-up
  bindkey -M vicmd 'j' history-substring-search-down
  # Configuration
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND="fg=${JSH_STYLE_OK},bold,underline"
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND="fg=${JSH_STYLE_ERROR},bold,underline"
  HISTORY_SUBSTRING_SEARCH_FUZZY=1
fi

# =============================================================================
# Vi mode and key bindings
# =============================================================================
# vi.sh - Vi-mode editing with cursor shape indicators
# Works in both bash and zsh
# shellcheck disable=SC2034

# =============================================================================
# Configuration
# =============================================================================

VIMODE_ENABLED="${VIMODE_ENABLED:-1}"
VIMODE_CURSOR="${VIMODE_CURSOR:-1}"           # Change cursor shape
VIMODE_JJ_ESCAPE="${VIMODE_JJ_ESCAPE:-1}"     # jj to exit insert mode
VIMODE_EMACS_INSERT="${VIMODE_EMACS_INSERT:-1}" # Emacs keys in insert mode

# Cursor shapes (DECSCUSR)
# 0 = default, 1 = blinking block, 2 = steady block
# 3 = blinking underline, 4 = steady underline
# 5 = blinking bar, 6 = steady bar
CURSOR_NORMAL="${CURSOR_NORMAL:-2}"   # Block for normal/command mode
CURSOR_INSERT="${CURSOR_INSERT:-6}"   # Bar for insert mode
CURSOR_VISUAL="${CURSOR_VISUAL:-2}"   # Block for visual mode

# =============================================================================
# Cursor Shape Functions
# =============================================================================

_cursor_shape() {
  # Set cursor shape via ANSI escape
  [[ -t 1 ]] || return 0
  printf '\e[%d q' "$1"
}

_cursor_normal() {
  [[ "${VIMODE_CURSOR}" == "1" ]] && _cursor_shape "${CURSOR_NORMAL}"
}

_cursor_insert() {
  [[ "${VIMODE_CURSOR}" == "1" ]] && _cursor_shape "${CURSOR_INSERT}"
}

_cursor_visual() {
  [[ "${VIMODE_CURSOR}" == "1" ]] && _cursor_shape "${CURSOR_VISUAL}"
}

_cursor_reset() {
  # Reset to default cursor on exit
  [[ -t 1 ]] || return 0
  printf '\e[0 q'
}

_vimode_backward_kill_path_component_zsh() {
  local WORDCHARS="${WORDCHARS:-}"
  WORDCHARS="${WORDCHARS//\//}"
  zle backward-kill-word
}

_vimode_backward_kill_path_component_bash() {
  local prefix="${READLINE_LINE:0:READLINE_POINT}"
  local suffix="${READLINE_LINE:READLINE_POINT}"
  local start="${#prefix}"

  if ((start > 0)) && [[ "${prefix:start-1:1}" == "/" ]]; then
    start=$((start - 1))
  fi
  while ((start > 0)); do
    case "${prefix:start-1:1}" in
      / | ' ' | $'\t' | $'\n') break ;;
    esac
    start=$((start - 1))
  done

  READLINE_LINE="${prefix:0:start}${suffix}"
  READLINE_POINT=${start}
}

# =============================================================================
# Zsh Vi-Mode Setup
# =============================================================================

_vimode_setup_zsh() {
  [[ "${VIMODE_ENABLED}" != "1" ]] && return

  # Enable vi mode
  bindkey -v

  # Reduce key timeout (faster escape)
  export KEYTIMEOUT=1

  zle -N _vimode_backward_kill_path_component_zsh
  bindkey -M viins '^[[127;5u' _vimode_backward_kill_path_component_zsh
  bindkey -M viins '^[^?' _vimode_backward_kill_path_component_zsh
  bindkey -M viins '^[^H' _vimode_backward_kill_path_component_zsh

  # Cursor shape hooks
  if [[ "${VIMODE_CURSOR}" == "1" ]]; then
    # shellcheck disable=SC2329  # ZLE widget, invoked on keymap change
    zle-keymap-select() {
      case "${KEYMAP}" in
        vicmd)      _cursor_normal ;;
        viins|main) _cursor_insert ;;
      esac
    }
    zle -N zle-keymap-select

    # shellcheck disable=SC2329  # ZLE widget, invoked on line init
    zle-line-init() {
      _cursor_insert
    }
    zle -N zle-line-init

    # Reset cursor on line finish
    # shellcheck disable=SC2329  # ZLE widget, invoked on line finish
    zle-line-finish() {
      _cursor_normal
    }
    zle -N zle-line-finish
  fi

  # jj to escape insert mode
  if [[ "${VIMODE_JJ_ESCAPE}" == "1" ]]; then
    bindkey -M viins 'jj' vi-cmd-mode
  fi

  # Emacs-style shortcuts in insert mode
  if [[ "${VIMODE_EMACS_INSERT}" == "1" ]]; then
    bindkey -M viins '^A' beginning-of-line
    bindkey -M viins '^E' end-of-line
    bindkey -M viins '^K' kill-line
    bindkey -M viins '^U' backward-kill-line
    bindkey -M viins '^W' backward-kill-word
    bindkey -M viins '^Y' yank
    bindkey -M viins '^?' backward-delete-char  # Backspace
    bindkey -M viins '^H' backward-delete-char
    bindkey -M viins '^D' delete-char-or-list

    bindkey -M viins '^B' backward-char
    bindkey -M viins '^F' forward-char
  fi

  # History search with arrows
  # Use history-substring-search if available (set by zsh.sh), otherwise fall back
  if (( ${+widgets[history-substring-search-up]} )); then
    bindkey -M viins '^[[A' history-substring-search-up
    bindkey -M viins '^[[B' history-substring-search-down
    bindkey -M vicmd '^[[A' history-substring-search-up
    bindkey -M vicmd '^[[B' history-substring-search-down
  else
    bindkey -M viins '^[[A' up-line-or-beginning-search
    bindkey -M viins '^[[B' down-line-or-beginning-search
    bindkey -M vicmd '^[[A' up-line-or-beginning-search
    bindkey -M vicmd '^[[B' down-line-or-beginning-search
  fi

  # History search in command mode
  bindkey -M vicmd '/' history-incremental-search-backward
  bindkey -M vicmd '?' history-incremental-search-forward

  # Word navigation (Alt+Arrow)
  bindkey -M viins '^[b' backward-word           # Alt+Left
  bindkey -M viins '^[f' forward-word            # Alt+Right
  bindkey -M viins '^[[1;3D' backward-word       # Alt+Left (alternate)
  bindkey -M viins '^[[1;3C' forward-word        # Alt+Right (alternate)

  # Ctrl+Arrow word navigation
  bindkey -M viins '^[[1;5D' backward-word       # Ctrl+Left
  bindkey -M viins '^[[1;5C' forward-word        # Ctrl+Right

  # Edit command in $EDITOR (V to edit, v remains visual mode)
  autoload -Uz edit-command-line
  zle -N edit-command-line
  bindkey -M vicmd 'V' edit-command-line
  bindkey -M viins '^X^E' edit-command-line

  # Clear screen
  bindkey -M viins '^L' clear-screen
  bindkey -M vicmd '^L' clear-screen

  # Undo/redo
  bindkey -M vicmd 'u' undo
  # Ctrl+R: use redo only if fzf available (fzf overrides for history search)
  # Otherwise, use history-beginning-search (works with complex multi-line prompts)
  if has fzf; then
    bindkey -M vicmd '^R' redo
  else
    # history-beginning-search: type prefix, then Ctrl+R cycles through matches
    # More compatible with multi-line prompts than incremental search
    bindkey -M vicmd '^R' history-beginning-search-backward
    bindkey -M viins '^R' history-beginning-search-backward
    bindkey -M vicmd '^S' history-beginning-search-forward
    bindkey -M viins '^S' history-beginning-search-forward
  fi

  # Beginning/end of history
  bindkey -M vicmd 'gg' beginning-of-buffer-or-history
  bindkey -M vicmd 'G' end-of-buffer-or-history

  # Yank to system clipboard (if available)
  if has pbcopy || has xclip || has xsel; then
    # shellcheck disable=SC2329  # ZLE widget, bound via bindkey
    _vimode_yank_clipboard() {
      zle vi-yank
      if has pbcopy; then
        echo "${CUTBUFFER}" | pbcopy
      elif has xclip; then
        echo "${CUTBUFFER}" | xclip -selection clipboard
      elif has xsel; then
        echo "${CUTBUFFER}" | xsel --clipboard
      fi
    }
    zle -N _vimode_yank_clipboard
    bindkey -M vicmd 'Y' _vimode_yank_clipboard
  fi
}

# =============================================================================
# Bash Vi-Mode Setup
# =============================================================================

_vimode_setup_bash() {
  [[ "${VIMODE_ENABLED}" != "1" ]] && return

  # Enable vi mode
  set -o vi

  # Cursor shape hooks via PROMPT_COMMAND
  if [[ "${VIMODE_CURSOR}" == "1" ]]; then
    # Insert mode cursor on new prompt
    # shellcheck disable=SC2329  # Used in PROMPT_COMMAND
    _vimode_prompt_hook() {
      _cursor_insert
    }

    if declare -f jsh_hook_add >/dev/null 2>&1; then
      jsh_hook_add precmd _vimode_prompt_hook 50
    elif [[ -z "${PROMPT_COMMAND:-}" ]]; then
      PROMPT_COMMAND="_vimode_prompt_hook"
    else
      PROMPT_COMMAND="_vimode_prompt_hook; ${PROMPT_COMMAND}"
    fi

    # Note: Bash doesn't have native keymap-change hooks
    # Cursor changes work via readline (inputrc) bindings
  fi

  # Key bindings via bind
  # jj to escape (requires inputrc support, see config/inputrc)

  bind -m vi-insert -x '"\e[127;5u":_vimode_backward_kill_path_component_bash' 2>/dev/null
  bind -m vi-insert -x '"\e\C-?":_vimode_backward_kill_path_component_bash' 2>/dev/null
  bind -m vi-insert -x '"\e\C-h":_vimode_backward_kill_path_component_bash' 2>/dev/null

  # History search with arrows
  bind '"\e[A": history-search-backward' 2>/dev/null
  bind '"\e[B": history-search-forward' 2>/dev/null

  # Word navigation
  bind '"\e[1;5D": backward-word' 2>/dev/null  # Ctrl+Left
  bind '"\e[1;5C": forward-word' 2>/dev/null   # Ctrl+Right
  bind '"\eb": backward-word' 2>/dev/null      # Alt+b
  bind '"\ef": forward-word' 2>/dev/null       # Alt+f

  # Clear screen in both modes
  bind -m vi-insert '"\C-l": clear-screen' 2>/dev/null
  bind -m vi-command '"\C-l": clear-screen' 2>/dev/null

  # Emacs shortcuts in insert mode
  if [[ "${VIMODE_EMACS_INSERT}" == "1" ]]; then
    bind -m vi-insert '"\C-a": beginning-of-line' 2>/dev/null
    bind -m vi-insert '"\C-e": end-of-line' 2>/dev/null
    bind -m vi-insert '"\C-k": kill-line' 2>/dev/null
    bind -m vi-insert '"\C-u": unix-line-discard' 2>/dev/null
    bind -m vi-insert '"\C-w": unix-word-rubout' 2>/dev/null
  fi

  # Edit command in editor
  bind -m vi-command '"\C-x\C-e": edit-and-execute-command' 2>/dev/null
  bind -m vi-insert '"\C-x\C-e": edit-and-execute-command' 2>/dev/null
}

# =============================================================================
# Public API
# =============================================================================

vimode_init() {
  if [[ "${JSH_SHELL}" == "zsh" ]]; then
    _vimode_setup_zsh
  else
    _vimode_setup_bash
  fi

  # Reset cursor on shell exit
  if declare -f jsh_trap_add >/dev/null 2>&1; then
    jsh_trap_add EXIT _cursor_reset
  else
    trap '_cursor_reset' EXIT
  fi
}

vimode_enable() {
  VIMODE_ENABLED=1
  vimode_init
}

vimode_disable() {
  VIMODE_ENABLED=0
  if [[ "${JSH_SHELL}" == "zsh" ]]; then
    bindkey -e  # Emacs mode
  else
    set +o vi
  fi
  _cursor_reset
}

# Mode indicator for prompt (if needed separately)
vimode_indicator() {
  # Returns current mode for prompt integration
  # Note: This is difficult in bash without ZLE
  if [[ "${JSH_SHELL}" == "zsh" ]]; then
    case "${KEYMAP:-viins}" in
      vicmd) echo "N" ;;  # Normal
      viins|main) echo "I" ;;  # Insert
      visual|viopp) echo "V" ;;  # Visual
      *) echo "I" ;;
    esac
  else
    echo "I"  # Bash doesn't expose this easily
  fi
}

# =============================================================================
# Prompt
# =============================================================================
#!/usr/bin/env bash
# prompt.sh - Fast, responsive native prompt for Bash and zsh
# shellcheck disable=SC2034,SC2088,SC2153,SC2296,SC2329

_ICON_PROMPT="❯"
_ICON_FAIL="✘"
_ICON_ELLIPSIS="…"
_ICON_AHEAD="⇡"
_ICON_BEHIND="⇣"
_ICON_STASH="*"
_ICON_CONFLICT="~"
_ICON_STAGED="+"
_ICON_UNSTAGED="!"
_ICON_UNTRACKED="?"
[[ -n "${JSH_PROMPT_MARKER+x}" ]] && _ICON_PROMPT="${JSH_PROMPT_MARKER}"

JSH_PROMPT_DIR_MIN="${JSH_PROMPT_DIR_MIN:-14}"
JSH_PROMPT_DURATION_MIN_MS="${JSH_PROMPT_DURATION_MIN_MS:-2000}"
JSH_PROMPT_KUBE="${JSH_PROMPT_KUBE:-auto}"
[[ ${#JSH_PROMPT_LEFT[@]} -gt 0 ]] || JSH_PROMPT_LEFT=(directory git)
[[ ${#JSH_PROMPT_RIGHT[@]} -gt 0 ]] ||
  JSH_PROMPT_RIGHT=(status duration node python kube jobs context time)

REPLY=""

# Command state.
_P_EXIT_CODE=""
_P_HAS_RESULT=0
_P_CMD_START_MS=0
_P_CMD_DURATION_MS=0

# Git state. The last result remains visible while a fresh async result is built.
_P_GIT_CACHE_PWD=""
_P_GIT_CACHE_VALID=0
_P_GIT_INVALIDATE=1
_P_GIT_BRANCH=""
_P_GIT_STAGED=0
_P_GIT_UNSTAGED=0
_P_GIT_UNTRACKED=0
_P_GIT_AHEAD=0
_P_GIT_BEHIND=0
_P_GIT_STASH=0
_P_GIT_CONFLICTS=0
_P_GIT_STATE=""
_P_GIT_ASYNC_DIR=""
_P_GIT_ASYNC_FD=-1

# Optional context state.
_P_KUBE_CACHE=""
_P_KUBE_INVALIDATE=1
_P_NODE_CACHE=""
_P_NODE_CACHE_PWD=""
_P_NPM_VERSION=""
_P_USER="${USER:-}"
_P_HOST="${HOST:-${HOSTNAME:-}}"
_P_HOST="${_P_HOST%%.*}"
_P_USER="${_P_USER%%@*}"
_P_SHOW_CONTEXT=0
[[ -n "${SSH_CONNECTION:-}" || "${JSH_ENV:-}" == ssh ||
  "${JSH_ENV:-}" == container || "${EUID:-1}" == 0 ]] && _P_SHOW_CONTEXT=1

# Render controls are internal and reset for every prompt.
_P_DIR_MAX=0
_P_BRANCH_MAX=0
_P_TIME_MODE=full
_P_HIDE_DURATION=0
_P_HIDE_NODE=0
_P_HIDE_PYTHON=0
_P_HIDE_KUBE=0
_P_HIDE_JOBS=0
_P_HIDE_CONTEXT=0

# Preserve the legacy prompt palette without changing colors used elsewhere.
if [[ "${JSH_HAS_COLOR:-0}" == 1 ]]; then
  _p_legacy_rst=$'\e[0m'
  _p_legacy_bold=$'\e[1m'
  _p_legacy_red=$'\e[31m'
  _p_legacy_green=$'\e[32m'
  _p_legacy_yellow=$'\e[33m'
  _p_legacy_blue=$'\e[34m'
  _p_legacy_magenta=$'\e[35m'
  _p_legacy_cyan=$'\e[36m'
  _p_legacy_error=$'\e[38;5;196m'
  _p_legacy_info=$'\e[38;5;75m'
  _p_legacy_muted=$'\e[38;5;245m'

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    _C_DIR="%{${_p_legacy_bold}${_p_legacy_cyan}%}"
    _C_GIT="%{${_p_legacy_green}%}"
    _C_STAGED="%{${_p_legacy_cyan}%}"
    _C_DIRTY="%{${_p_legacy_yellow}%}"
    _C_UNTRACKED="%{${_p_legacy_red}%}"
    _C_CONFLICT="%{${_p_legacy_red}%}"
    _C_STASH="%{${_p_legacy_magenta}%}"
    _C_AHEAD="%{${_p_legacy_green}%}"
    _C_BEHIND="%{${_p_legacy_green}%}"
    _C_OPERATION="%{${_p_legacy_red}%}"
    _C_ERROR="%{${_p_legacy_error}%}"
    _C_DURATION="%{${_p_legacy_muted}%}"
    _C_NODE="%{${_p_legacy_info}%}"
    _C_PYTHON="%{${_p_legacy_yellow}%}"
    _C_KUBE="%{${_p_legacy_blue}%}"
    _C_CONTEXT="%{${_p_legacy_yellow}%}"
    _C_CONTEXT_ROOT="%{${_p_legacy_bold}${_p_legacy_yellow}%}"
    _C_TIME="%{${_p_legacy_muted}%}"
    _C_JOBS="%{${_p_legacy_green}%}"
    _C_PROMPT_IDLE="%{${_p_legacy_green}%}"
    _C_PROMPT_OK="%{${_p_legacy_green}%}"
    _C_PROMPT_ERR="%{${_p_legacy_error}%}"
    _C_RST="%{${_p_legacy_rst}%}"
  else
    _C_DIR="\[${_p_legacy_bold}${_p_legacy_cyan}\]"
    _C_GIT="\[${_p_legacy_green}\]"
    _C_STAGED="\[${_p_legacy_cyan}\]"
    _C_DIRTY="\[${_p_legacy_yellow}\]"
    _C_UNTRACKED="\[${_p_legacy_red}\]"
    _C_CONFLICT="\[${_p_legacy_red}\]"
    _C_STASH="\[${_p_legacy_magenta}\]"
    _C_AHEAD="\[${_p_legacy_green}\]"
    _C_BEHIND="\[${_p_legacy_green}\]"
    _C_OPERATION="\[${_p_legacy_red}\]"
    _C_ERROR="\[${_p_legacy_error}\]"
    _C_DURATION="\[${_p_legacy_muted}\]"
    _C_NODE="\[${_p_legacy_info}\]"
    _C_PYTHON="\[${_p_legacy_yellow}\]"
    _C_KUBE="\[${_p_legacy_blue}\]"
    _C_CONTEXT="\[${_p_legacy_yellow}\]"
    _C_CONTEXT_ROOT="\[${_p_legacy_bold}${_p_legacy_yellow}\]"
    _C_TIME="\[${_p_legacy_muted}\]"
    _C_JOBS="\[${_p_legacy_green}\]"
    _C_PROMPT_IDLE="\[${_p_legacy_green}\]"
    _C_PROMPT_OK="\[${_p_legacy_green}\]"
    _C_PROMPT_ERR="\[${_p_legacy_error}\]"
    _C_RST="\[${_p_legacy_rst}\]"
  fi
else
  _C_DIR='' _C_GIT='' _C_STAGED='' _C_DIRTY='' _C_UNTRACKED=''
  _C_CONFLICT='' _C_STASH='' _C_AHEAD='' _C_BEHIND='' _C_OPERATION=''
  _C_ERROR='' _C_DURATION='' _C_NODE='' _C_PYTHON='' _C_KUBE=''
  _C_CONTEXT='' _C_CONTEXT_ROOT='' _C_TIME='' _C_JOBS=''
  _C_PROMPT_IDLE='' _C_PROMPT_OK='' _C_PROMPT_ERR='' _C_RST=''
fi
unset _p_legacy_rst _p_legacy_bold _p_legacy_red _p_legacy_green
unset _p_legacy_yellow _p_legacy_blue _p_legacy_magenta _p_legacy_cyan
unset _p_legacy_error _p_legacy_info _p_legacy_muted

# -----------------------------------------------------------------------------
# Pure-shell formatting
# -----------------------------------------------------------------------------

_prompt_terminal_width() {
  REPLY="${COLUMNS:-80}"
  case "${REPLY}" in ""|*[!0-9]*) REPLY=80 ;; esac
  [[ "${REPLY}" -gt 0 ]] || REPLY=80
}

_prompt_visible_len() {
  local _p_text="$1" _p_len=0 _p_i=0 _p_escape=0 _p_char=""

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    # Zsh can remove complete SGR sequences in one native expansion. The
    # previous character-by-character scan made the normal colored prompt
    # several times slower than the no-color path.
    setopt localoptions extendedglob
    _p_text="${_p_text//\%\{/}"
    _p_text="${_p_text//\%\}/}"
    _p_text="${_p_text//$'\e'\[[0-9;]##m/}"
    REPLY="${#_p_text}"
    return
  else
    _p_text="${_p_text//\\[/}"
    _p_text="${_p_text//\\]/}"
  fi
  if [[ "${_p_text}" != *$'\e'* ]]; then
    REPLY="${#_p_text}"
    return
  fi
  while [[ ${_p_i} -lt ${#_p_text} ]]; do
    _p_char="${_p_text:${_p_i}:1}"
    if [[ ${_p_escape} -eq 1 ]]; then
      [[ "${_p_char}" == m ]] && _p_escape=0
    elif [[ "${_p_char}" == $'\e' ]]; then
      _p_escape=1
    else
      _p_len=$((_p_len + 1))
    fi
    _p_i=$((_p_i + 1))
  done
  REPLY="${_p_len}"
}

_prompt_dir_plain() {
  if [[ "${PWD}" == "${HOME}" ]]; then
    REPLY="~"
  elif [[ "${PWD}" == "${HOME}/"* ]]; then
    REPLY="~/${PWD#"${HOME}/"}"
  else
    REPLY="${PWD}"
  fi
}

# Preserve the leaf, shorten parents to initials, then elide from the left.
_prompt_abbreviate_dir() {
  local _p_dir="$1" _p_max="${2:-0}" _p_prefix="" _p_body=""
  local _p_leaf="" _p_piece="" _p_result="" _p_index=0 _p_count=0 _p_keep=0
  local -a _p_parts

  REPLY="${_p_dir}"
  [[ ${_p_max} -gt 0 && ${#_p_dir} -gt ${_p_max} ]] || return 0
  [[ ${_p_max} -gt 1 ]] || { REPLY="${_ICON_ELLIPSIS}"; return 0; }

  case "${_p_dir}" in
    "~") return ;;
    "~/"*) _p_prefix="~/"; _p_body="${_p_dir#\~/}" ;;
    /*) _p_prefix="/"; _p_body="${_p_dir#/}" ;;
    *) _p_body="${_p_dir}" ;;
  esac
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    IFS='/' read -rA _p_parts <<< "${_p_body}"
  else
    IFS='/' read -ra _p_parts <<< "${_p_body}"
  fi
  _p_count=${#_p_parts[@]}
  [[ ${_p_count} -gt 0 ]] || { REPLY="${_p_prefix:-/}"; return; }
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    _p_leaf="${_p_parts[_p_count]}"
  else
    _p_leaf="${_p_parts[_p_count-1]}"
  fi

  _p_result="${_p_prefix}"
  for _p_piece in "${_p_parts[@]}"; do
    _p_index=$((_p_index + 1))
    if [[ ${_p_index} -eq ${_p_count} ]]; then
      _p_result+="${_p_piece}"
    elif [[ "${_p_piece}" == .* ]]; then
      _p_result+="${_p_piece:0:2}/"
    else
      _p_result+="${_p_piece:0:1}/"
    fi
  done
  [[ ${#_p_result} -le ${_p_max} ]] || _p_result="${_ICON_ELLIPSIS}/${_p_leaf}"
  if [[ ${#_p_result} -gt ${_p_max} ]]; then
    _p_keep=$((_p_max - 1))
    [[ ${_p_keep} -gt 0 ]] || _p_keep=1
    _p_result="${_ICON_ELLIPSIS}${_p_leaf: -${_p_keep}}"
  fi
  REPLY="${_p_result}"
}

_prompt_abbreviate_branch() {
  local _p_branch="$1" _p_max="${2:-0}" _p_keep=0
  REPLY="${_p_branch}"
  [[ ${_p_max} -gt 0 && ${#_p_branch} -gt ${_p_max} ]] || return 0
  [[ ${_p_max} -gt 1 ]] || { REPLY="${_ICON_ELLIPSIS}"; return 0; }
  _p_keep=$((_p_max - 1))
  REPLY="${_ICON_ELLIPSIS}${_p_branch: -${_p_keep}}"
}

_prompt_join_segments() {
  local _p_separator="$1" _p_name="" _p_fn="" _p_part="" _p_result=""
  shift
  for _p_name in "$@"; do
    _p_fn="_prompt_segment_${_p_name}"
    (( ${+functions[${_p_fn}]} )) || continue
    "${_p_fn}" || continue
    _p_part="${REPLY}"
    [[ -n "${_p_part}" ]] || continue
    [[ -z "${_p_result}" ]] || _p_result+="${_p_separator}"
    _p_result+="${_p_part}"
  done
  REPLY="${_p_result}"
}

_prompt_overflows() {
  _prompt_visible_len "$1"
  [[ ${REPLY} -gt $2 ]]
}

# -----------------------------------------------------------------------------
# Information segments
# -----------------------------------------------------------------------------

_prompt_segment_directory() {
  local _p_dir=""
  _prompt_dir_plain
  _p_dir="${REPLY}"
  if [[ ${_P_DIR_MAX} -gt 0 ]]; then
    _prompt_abbreviate_dir "${_p_dir}" "${_P_DIR_MAX}"
    _p_dir="${REPLY}"
  fi
  REPLY="${_C_DIR}${_p_dir}${_C_RST}"
}

_prompt_segment_git() {
  local _p_branch="${_P_GIT_BRANCH}" _p_result=""
  REPLY=""
  [[ -n "${_p_branch}" ]] || return 0
  if [[ ${_P_BRANCH_MAX} -gt 0 ]]; then
    _prompt_abbreviate_branch "${_p_branch}" "${_P_BRANCH_MAX}"
    _p_branch="${REPLY}"
    [[ -n "${_p_branch}" ]] || return 0
  fi
  _p_result="${_C_GIT}${_p_branch}${_C_RST}"

  if [[ ${_P_GIT_BEHIND:-0} -gt 0 || ${_P_GIT_AHEAD:-0} -gt 0 ]]; then
    _p_result+=" "
    [[ ${_P_GIT_BEHIND:-0} -gt 0 ]] &&
      _p_result+="${_C_BEHIND}${_ICON_BEHIND}${_P_GIT_BEHIND}${_C_RST}"
    [[ ${_P_GIT_AHEAD:-0} -gt 0 ]] &&
      _p_result+="${_C_AHEAD}${_ICON_AHEAD}${_P_GIT_AHEAD}${_C_RST}"
  fi
  if [[ ${_P_GIT_STASH:-0} -gt 0 ]]; then
    _p_result+=" ${_C_STASH}${_ICON_STASH}${_P_GIT_STASH}${_C_RST}"
  fi
  if [[ ${_P_GIT_CONFLICTS:-0} -gt 0 ]]; then
    _p_result+=" ${_C_CONFLICT}${_ICON_CONFLICT}${_P_GIT_CONFLICTS}${_C_RST}"
  fi
  if [[ ${_P_GIT_STAGED:-0} -gt 0 ]]; then
    _p_result+=" ${_C_STAGED}${_ICON_STAGED}${_P_GIT_STAGED}${_C_RST}"
  fi
  if [[ ${_P_GIT_UNSTAGED:-0} -gt 0 ]]; then
    _p_result+=" ${_C_DIRTY}${_ICON_UNSTAGED}${_P_GIT_UNSTAGED}${_C_RST}"
  fi
  if [[ ${_P_GIT_UNTRACKED:-0} -gt 0 ]]; then
    _p_result+=" ${_C_UNTRACKED}${_ICON_UNTRACKED}${_P_GIT_UNTRACKED}${_C_RST}"
  fi
  if [[ -n "${_P_GIT_STATE}" ]]; then
    _p_result+=" ${_C_OPERATION}${_P_GIT_STATE}${_C_RST}"
  fi
  REPLY="${_p_result}"
}

_prompt_segment_status() {
  local _p_text="${_P_EXIT_CODE}"
  REPLY=""
  [[ -n "${_P_EXIT_CODE}" && "${_P_EXIT_CODE}" -ne 0 ]] || return 0
  case "${_P_EXIT_CODE}" in
    129) _p_text=HUP ;;
    130) _p_text=INT ;;
    131) _p_text=QUIT ;;
    137) _p_text=KILL ;;
    143) _p_text=TERM ;;
  esac
  REPLY="${_C_ERROR}${_ICON_FAIL} ${_p_text}${_C_RST}"
}

_prompt_segment_duration() {
  local _p_ms=${_P_CMD_DURATION_MS:-0} _p_seconds=0 _p_days=0 _p_minutes=0 _p_hours=0
  local _p_result=""
  REPLY=""
  [[ ${_P_HIDE_DURATION} -eq 0 && ${_p_ms} -ge ${JSH_PROMPT_DURATION_MIN_MS} ]] || return 0
  _p_seconds=$((_p_ms / 1000))
  _p_days=$((_p_seconds / 86400))
  _p_seconds=$((_p_seconds % 86400))
  _p_hours=$((_p_seconds / 3600))
  _p_seconds=$((_p_seconds % 3600))
  _p_minutes=$((_p_seconds / 60))
  _p_seconds=$((_p_seconds % 60))
  [[ ${_p_days} -gt 0 ]] && _p_result+="${_p_days}d"
  [[ ${_p_hours} -gt 0 ]] && _p_result+="${_p_hours}h"
  [[ ${_p_minutes} -gt 0 ]] && _p_result+="${_p_minutes}m"
  if [[ -z "${_p_result}" && ${_p_ms} -lt 10000 && $((_p_ms % 1000)) -ge 100 ]]; then
    _p_result+="$((_p_ms / 1000)).$(((_p_ms % 1000) / 100))s"
  elif [[ ${_p_seconds} -gt 0 || -z "${_p_result}" ]]; then
    _p_result+="${_p_seconds}s"
  fi
  REPLY="${_C_DURATION}${_p_result}${_C_RST}"
}

_prompt_segment_node() {
  REPLY=""
  [[ ${_P_HIDE_NODE} -eq 0 && -n "${_P_NODE_CACHE}" ]] || return 0
  REPLY="${_C_NODE}${_P_NODE_CACHE}${_C_RST}"
}

_prompt_segment_python() {
  local _p_env="${VIRTUAL_ENV:-${CONDA_DEFAULT_ENV:-}}"
  REPLY=""
  [[ ${_P_HIDE_PYTHON} -eq 0 && -n "${_p_env}" ]] || return 0
  _p_env="${_p_env##*/}"
  REPLY="${_C_PYTHON}(${_p_env})${_C_RST}"
}

_prompt_segment_context() {
  REPLY=""
  [[ ${_P_HIDE_CONTEXT} -eq 0 && ${_P_SHOW_CONTEXT} -eq 1 ]] || return 0
  [[ -n "${_P_USER}" && -n "${_P_HOST}" ]] || return 0
  if [[ "${EUID:-1}" == 0 ]]; then
    REPLY="${_C_CONTEXT_ROOT}${_P_USER}@${_P_HOST}${_C_RST}"
  else
    REPLY="${_C_CONTEXT}${_P_USER}@${_P_HOST}${_C_RST}"
  fi
}

_prompt_segment_jobs() {
  local _p_count=0
  REPLY=""
  [[ ${_P_HIDE_JOBS} -eq 0 && -n "${ZSH_VERSION:-}" ]] || return 0
  _p_count=${#jobstates}
  [[ ${_p_count} -gt 0 ]] || return 0
  REPLY="${_C_JOBS}[${_p_count}]${_C_RST}"
}

_prompt_segment_kube() {
  REPLY=""
  [[ ${_P_HIDE_KUBE} -eq 0 && "${JSH_PROMPT_KUBE}" != 0 ]] || return 0
  [[ -n "${_P_KUBE_CACHE}" ]] || return 0
  REPLY="${_C_KUBE}⎈ ${_P_KUBE_CACHE}${_C_RST}"
}

_prompt_segment_time() {
  local _p_format="%H:%M:%S" _p_now=""
  REPLY=""
  [[ "${_P_TIME_MODE}" != none ]] || return 0
  [[ "${_P_TIME_MODE}" == compact ]] && _p_format="%H:%M"
  if [[ -n "${ZSH_VERSION:-}" ]] && (( ${+builtins[strftime]} )); then
    strftime -s _p_now "${_p_format}" "${EPOCHSECONDS:-0}"
  else
    _p_now="$(command date "+${_p_format}" 2>/dev/null)"
  fi
  REPLY="${_C_TIME}${_p_now}${_C_RST}"
}

_prompt_segment_character() {
  if [[ ${_P_HAS_RESULT:-0} -eq 0 ]]; then
    REPLY="${_C_PROMPT_IDLE}${_ICON_PROMPT}${_C_RST} "
  elif [[ "${_P_EXIT_CODE:-0}" -ne 0 ]]; then
    REPLY="${_C_PROMPT_ERR}${_ICON_PROMPT}${_C_RST} "
  else
    REPLY="${_C_PROMPT_OK}${_ICON_PROMPT}${_C_RST} "
  fi
}

_prompt_build_left() {
  local _p_width="$1" _p_full="" _p_git="" _p_full_len=0 _p_git_len=0
  local _p_dir_room=0 _p_indicators=0 _p_branch_room=0 _p_dir_floor=0
  _P_DIR_MAX=0 _P_BRANCH_MAX=0
  _prompt_join_segments " " "${JSH_PROMPT_LEFT[@]}"; _p_full="${REPLY}"
  _prompt_visible_len "${_p_full}"; _p_full_len="${REPLY}"
  if [[ ${_p_full_len} -lt ${_p_width} ]]; then REPLY="${_p_full}"; return; fi

  _prompt_segment_git; _p_git="${REPLY}"
  _prompt_visible_len "${_p_git}"; _p_git_len="${REPLY}"
  _p_dir_room=$((_p_width - _p_git_len - 1))
  if [[ ${_p_dir_room} -ge ${JSH_PROMPT_DIR_MIN} ]]; then
    _P_DIR_MAX="${_p_dir_room}"
    _prompt_join_segments " " "${JSH_PROMPT_LEFT[@]}"
    return
  fi

  _p_dir_floor="${JSH_PROMPT_DIR_MIN}"
  [[ ${_p_dir_floor} -lt $((_p_width - 4)) ]] || _p_dir_floor=$((_p_width / 2))
  [[ ${_p_dir_floor} -ge 4 ]] || _p_dir_floor=4
  _P_DIR_MAX="${_p_dir_floor}"
  _p_indicators=$((_p_git_len - ${#_P_GIT_BRANCH}))
  [[ ${_p_indicators} -ge 0 ]] || _p_indicators=0
  _p_branch_room=$((_p_width - _p_dir_floor - _p_indicators - 1))
  [[ ${_p_branch_room} -ge 4 ]] && _P_BRANCH_MAX="${_p_branch_room}" || _P_BRANCH_MAX=1
  _prompt_join_segments " " "${JSH_PROMPT_LEFT[@]}"
}

_prompt_build_right() {
  local _p_width="$1" _p_right="" _p_len=0
  _P_TIME_MODE=full _P_HIDE_DURATION=0 _P_HIDE_NODE=0 _P_HIDE_PYTHON=0
  _P_HIDE_KUBE=0 _P_HIDE_JOBS=0 _P_HIDE_CONTEXT=0

  _prompt_join_segments "  " "${JSH_PROMPT_RIGHT[@]}"; _p_right="${REPLY}"
  _prompt_visible_len "${_p_right}"; _p_len="${REPLY}"
  if [[ $((_p_len + 4)) -ge ${_p_width} ]]; then
    _P_TIME_MODE=compact
    _prompt_join_segments "  " "${JSH_PROMPT_RIGHT[@]}"; _p_right="${REPLY}"
  fi
  for _p_name in jobs context kube node python duration; do
    _prompt_visible_len "${_p_right}"; _p_len="${REPLY}"
    [[ $((_p_len + 4)) -lt ${_p_width} ]] && break
    case "${_p_name}" in
      jobs) _P_HIDE_JOBS=1 ;; context) _P_HIDE_CONTEXT=1 ;;
      kube) _P_HIDE_KUBE=1 ;; node) _P_HIDE_NODE=1 ;;
      python) _P_HIDE_PYTHON=1 ;; duration) _P_HIDE_DURATION=1 ;;
    esac
    _prompt_join_segments "  " "${JSH_PROMPT_RIGHT[@]}"; _p_right="${REPLY}"
  done
  _prompt_visible_len "${_p_right}"; _p_len="${REPLY}"
  if [[ $((_p_len + 4)) -ge ${_p_width} ]]; then
    _P_TIME_MODE=none
    _prompt_join_segments "  " "${JSH_PROMPT_RIGHT[@]}"; _p_right="${REPLY}"
  fi
  REPLY="${_p_right}"
}

# -----------------------------------------------------------------------------
# Async Git and Kubernetes state
# -----------------------------------------------------------------------------

_prompt_git_clear() {
  _P_GIT_BRANCH="" _P_GIT_STAGED=0 _P_GIT_UNSTAGED=0 _P_GIT_UNTRACKED=0
  _P_GIT_AHEAD=0 _P_GIT_BEHIND=0 _P_GIT_STASH=0 _P_GIT_CONFLICTS=0
  _P_GIT_STATE=""
}

_prompt_git_parse() {
  local _p_data="$1"
  _prompt_git_clear
  [[ -n "${_p_data}" && "${_p_data}" != - ]] || return 0
  IFS='|' read -r _P_GIT_BRANCH _P_GIT_STAGED _P_GIT_UNSTAGED \
    _P_GIT_UNTRACKED _P_GIT_AHEAD _P_GIT_BEHIND _P_GIT_STASH \
    _P_GIT_CONFLICTS _P_GIT_STATE <<< "${_p_data}"
  _P_GIT_STAGED="${_P_GIT_STAGED:-0}"
  _P_GIT_UNSTAGED="${_P_GIT_UNSTAGED:-0}"
  _P_GIT_UNTRACKED="${_P_GIT_UNTRACKED:-0}"
  _P_GIT_AHEAD="${_P_GIT_AHEAD:-0}"
  _P_GIT_BEHIND="${_P_GIT_BEHIND:-0}"
  _P_GIT_STASH="${_P_GIT_STASH:-0}"
  _P_GIT_CONFLICTS="${_P_GIT_CONFLICTS:-0}"
}

_prompt_git_operation() {
  local _p_dir="$1" _p_git_dir="" _p_current="" _p_total=""
  REPLY=""
  _p_git_dir="$(command git -C "${_p_dir}" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  if [[ -d "${_p_git_dir}/rebase-merge" ]]; then
    REPLY="REBASE"
    IFS= read -r _p_current < "${_p_git_dir}/rebase-merge/msgnum" 2>/dev/null || true
    IFS= read -r _p_total < "${_p_git_dir}/rebase-merge/end" 2>/dev/null || true
  elif [[ -d "${_p_git_dir}/rebase-apply" ]]; then
    if [[ -f "${_p_git_dir}/rebase-apply/applying" ]]; then REPLY="AM"
    else REPLY="REBASE"; fi
    IFS= read -r _p_current < "${_p_git_dir}/rebase-apply/next" 2>/dev/null || true
    IFS= read -r _p_total < "${_p_git_dir}/rebase-apply/last" 2>/dev/null || true
  elif [[ -f "${_p_git_dir}/MERGE_HEAD" ]]; then REPLY="MERGE"
  elif [[ -f "${_p_git_dir}/CHERRY_PICK_HEAD" ]]; then REPLY="CHERRY-PICK"
  elif [[ -f "${_p_git_dir}/REVERT_HEAD" ]]; then REPLY="REVERT"
  elif [[ -f "${_p_git_dir}/BISECT_LOG" ]]; then REPLY="BISECT"
  fi
  if [[ -n "${REPLY}" && -n "${_p_current}" && -n "${_p_total}" &&
    "${_p_current}" != *[!0-9]* && "${_p_total}" != *[!0-9]* ]]; then
    REPLY+=" ${_p_current}/${_p_total}"
  fi
}

# All external Git processes run in a background worker.
_prompt_git_worker() {
  [[ -n "${ZSH_VERSION:-}" ]] && emulate -L zsh
  local _p_dir="$1" _p_output="" _p_line="" _p_head="" _p_oid="" _p_xy=""
  local _p_staged=0 _p_unstaged=0 _p_untracked=0 _p_ahead=0 _p_behind=0
  local _p_stash=0 _p_conflicts=0 _p_state=""

  _p_output="$(GIT_OPTIONAL_LOCKS=0 command git -C "${_p_dir}" status \
    --porcelain=v2 --branch --show-stash --untracked-files=normal 2>/dev/null)" || {
    printf '%s\n' -
    return
  }
  while IFS= read -r _p_line; do
    case "${_p_line}" in
      "# branch.oid "*) _p_oid="${_p_line#\# branch.oid }" ;;
      "# branch.head "*) _p_head="${_p_line#\# branch.head }" ;;
      "# branch.ab "*)
        _p_line="${_p_line#\# branch.ab }"
        _p_ahead="${_p_line%% *}"; _p_behind="${_p_line##* }"
        _p_ahead="${_p_ahead#+}"; _p_behind="${_p_behind#-}"
        ;;
      "# stash "*) _p_stash="${_p_line#\# stash }" ;;
      "1 "*|"2 "*)
        _p_xy="${_p_line:2:2}"
        [[ "${_p_xy:0:1}" != . ]] && _p_staged=$((_p_staged + 1))
        [[ "${_p_xy:1:1}" != . ]] && _p_unstaged=$((_p_unstaged + 1))
        ;;
      "u "*) _p_conflicts=$((_p_conflicts + 1)) ;;
      "? "*) _p_untracked=$((_p_untracked + 1)) ;;
    esac
  done <<< "${_p_output}"
  [[ -n "${_p_head}" && "${_p_head}" != "(detached)" ]] || _p_head="@${_p_oid:0:7}"
  _prompt_git_operation "${_p_dir}"; _p_state="${REPLY}"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "${_p_head}" "${_p_staged}" \
    "${_p_unstaged}" "${_p_untracked}" "${_p_ahead}" "${_p_behind}" \
    "${_p_stash}" "${_p_conflicts}" "${_p_state}"
}

_prompt_git_async_stop() {
  [[ -n "${ZSH_VERSION:-}" ]] || return 0
  if [[ "${_P_GIT_ASYNC_FD:-1}" -ge 0 ]]; then
    zle -F "${_P_GIT_ASYNC_FD}" 2>/dev/null || true
    exec {_P_GIT_ASYNC_FD}<&-
    _P_GIT_ASYNC_FD=-1
  fi
}

_prompt_git_async_callback() {
  [[ -n "${ZSH_VERSION:-}" ]] && emulate -L zsh
  local _p_fd="$1" _p_data="" _p_dir="${_P_GIT_ASYNC_DIR}"
  IFS= read -r _p_data <&"${_p_fd}" || _p_data=-
  zle -F "${_p_fd}" 2>/dev/null || true
  exec {_p_fd}<&-
  _P_GIT_ASYNC_FD=-1
  [[ "${_p_dir}" == "${PWD}" ]] || return 0
  _prompt_git_parse "${_p_data}"
  _P_GIT_CACHE_PWD="${_p_dir}" _P_GIT_CACHE_VALID=1 _P_GIT_INVALIDATE=0
  _prompt_render_zsh
  zle reset-prompt 2>/dev/null || true
}

_prompt_git_async_start() {
  [[ -n "${ZSH_VERSION:-}" ]] || return 1
  _prompt_git_async_stop
  _P_GIT_ASYNC_DIR="${PWD}"
  unset _P_GIT_ASYNC_FD
  exec {_P_GIT_ASYNC_FD}< <(_prompt_git_worker "${_P_GIT_ASYNC_DIR}")
  zle -F "${_P_GIT_ASYNC_FD}" _prompt_git_async_callback 2>/dev/null || {
    exec {_P_GIT_ASYNC_FD}<&-
    _P_GIT_ASYNC_FD=-1
    return 1
  }
}

_prompt_git_shared_worker() {
  printf '%s\n' "$1"
  _prompt_git_worker "$1"
}

_prompt_git_shared_done() {
  local _p_status="$2" _p_data="$3" _p_dir="" _p_record=""
  [[ "${_p_status}" == 0 && "${_p_data}" == *$'\n'* ]] || return 0
  _p_dir="${_p_data%%$'\n'*}"; _p_record="${_p_data#*$'\n'}"
  [[ "${_p_dir}" == "${PWD}" ]] || return 0
  _prompt_git_parse "${_p_record}"
  _P_GIT_CACHE_PWD="${_p_dir}" _P_GIT_CACHE_VALID=1 _P_GIT_INVALIDATE=0
}

_prompt_git_update() {
  local _p_async_allowed=1
  if [[ "${_P_GIT_CACHE_PWD}" != "${PWD}" ]]; then
    _prompt_git_clear
    _P_GIT_CACHE_VALID=0 _P_GIT_INVALIDATE=1
  fi
  [[ ${_P_GIT_INVALIDATE} -eq 1 || ${_P_GIT_CACHE_VALID} -eq 0 ]] || return 0
  if declare -f jsh_feature_enabled >/dev/null 2>&1 && ! jsh_feature_enabled async; then
    _p_async_allowed=0
  fi
  if [[ ${_p_async_allowed} -eq 1 && -n "${ZSH_VERSION:-}" ]]; then
    _prompt_git_async_start || true
  elif [[ ${_p_async_allowed} -eq 1 ]] &&
    declare -f jsh_async_submit >/dev/null 2>&1; then
    jsh_async_submit prompt.git _prompt_git_shared_worker _prompt_git_shared_done "${PWD}" || true
  fi
}

_prompt_find_up() {
  local _p_name="$1" _p_dir="${PWD}"
  REPLY=""
  while [[ -n "${_p_dir}" ]]; do
    if [[ -r "${_p_dir}/${_p_name}" ]]; then
      REPLY="${_p_dir}/${_p_name}"
      return 0
    fi
    [[ "${_p_dir}" == / ]] && break
    _p_dir="${_p_dir:h}"
  done
  return 1
}

_prompt_node_update() {
  local _p_file="" _p_version=""
  [[ "${_P_NODE_CACHE_PWD}" == "${PWD}" ]] && return 0
  _P_NODE_CACHE_PWD="${PWD}"
  _P_NODE_CACHE=""

  if [[ -n "${NODE_ENV:-}" ]]; then
    _P_NODE_CACHE="node:${NODE_ENV}"
    return 0
  fi
  if _prompt_find_up .nvmrc || _prompt_find_up .node-version; then
    _p_file="${REPLY}"
    IFS= read -r _p_version <"${_p_file}" || true
    _p_version="${_p_version#v}"
    [[ -n "${_p_version}" ]] && _P_NODE_CACHE="node:${_p_version}"
    return 0
  fi
  _prompt_find_up package.json || return 0
  if command -v npm >/dev/null 2>&1; then
    [[ -n "${_P_NPM_VERSION}" ]] || _P_NPM_VERSION="$(command npm --version 2>/dev/null)"
    [[ -n "${_P_NPM_VERSION}" ]] && _P_NODE_CACHE="npm:${_P_NPM_VERSION}"
  elif command -v node >/dev/null 2>&1; then
    _p_version="$(command node --version 2>/dev/null)"
    _p_version="${_p_version#v}"
    [[ -n "${_p_version}" ]] && _P_NODE_CACHE="node:${_p_version}"
  fi
}

_prompt_kube_worker() {
  local _p_context="" _p_namespace=""
  _p_context="$(command kubectl config current-context 2>/dev/null)" || return 1
  [[ -n "${_p_context}" ]] || return 1
  _p_namespace="$(command kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)"
  if [[ -n "${_p_namespace}" && "${_p_namespace}" != default ]]; then
    printf '%s/%s\n' "${_p_context}" "${_p_namespace}"
  else
    printf '%s\n' "${_p_context}"
  fi
}

_prompt_kube_done() {
  local _p_status="$2" _p_context="$3"
  if [[ "${_p_status}" != 0 ]]; then
    _P_KUBE_CACHE=""
    return 0
  fi
  [[ ${#_p_context} -le 20 ]] || _p_context="${_p_context:0:8}${_ICON_ELLIPSIS}${_p_context: -8}"
  _P_KUBE_CACHE="${_p_context}"
}

_prompt_kube_update() {
  [[ "${JSH_PROMPT_KUBE}" != 0 && ${_P_KUBE_INVALIDATE} -eq 1 ]] || return 0
  _P_KUBE_INVALIDATE=0
  command -v kubectl >/dev/null 2>&1 || return 0
  if jsh_feature_enabled async && declare -f jsh_async_submit >/dev/null 2>&1; then
    jsh_async_submit prompt.kube _prompt_kube_worker _prompt_kube_done || true
  else
    _P_KUBE_CACHE="$(_prompt_kube_worker 2>/dev/null)" || _P_KUBE_CACHE=""
  fi
}

# -----------------------------------------------------------------------------
# Hooks and renderers
# -----------------------------------------------------------------------------

_prompt_now_ms() {
  if [[ -n "${ZSH_VERSION:-}" && -n "${EPOCHREALTIME:-}" ]]; then
    printf -v REPLY '%.0f' "$((EPOCHREALTIME * 1000))"
  elif [[ -n "${EPOCHSECONDS:-}" ]]; then
    REPLY=$((EPOCHSECONDS * 1000))
  else
    REPLY=$((${SECONDS:-0} * 1000))
  fi
}

_prompt_preexec() {
  local _p_command="$1"
  _P_HAS_RESULT=1
  _prompt_now_ms
  _P_CMD_START_MS="${REPLY}"
  _P_GIT_INVALIDATE=1
  case "${_p_command%% *}" in
    kubectl|kubectx|kubens|kubie|kctx|kns|kx) _P_KUBE_INVALIDATE=1 ;;
  esac
}

_prompt_precmd() {
  local _p_exit_code="${1:-0}" _p_now=0
  if [[ ${_P_HAS_RESULT} -eq 1 ]]; then _P_EXIT_CODE="${_p_exit_code}"
  else _P_EXIT_CODE=""; fi
  if [[ ${_P_CMD_START_MS} -gt 0 ]]; then
    _prompt_now_ms; _p_now="${REPLY}"
    _P_CMD_DURATION_MS=$((_p_now - _P_CMD_START_MS))
  else
    _P_CMD_DURATION_MS=0
  fi
  _P_CMD_START_MS=0
  _prompt_git_update
  _prompt_kube_update
}

_prompt_render_zsh() {
  _prompt_render_bash
  RPROMPT=""
}

_prompt_render_bash() {
  local _p_width=80 _p_left="" _p_right="" _p_character=""
  local _p_left_len=0 _p_right_len=0 _p_spaces=1 _p_padding=""
  _prompt_terminal_width; _p_width="${REPLY}"
  _prompt_build_left "${_p_width}"; _p_left="${REPLY}"
  _prompt_build_right "${_p_width}"; _p_right="${REPLY}"
  _prompt_visible_len "${_p_left}"; _p_left_len="${REPLY}"
  _prompt_visible_len "${_p_right}"; _p_right_len="${REPLY}"
  _p_spaces=$((_p_width - _p_left_len - _p_right_len))
  [[ ${_p_spaces} -gt 0 ]] || _p_spaces=1
  printf -v _p_padding '%*s' "${_p_spaces}" ""
  _prompt_segment_character; _p_character="${REPLY}"
  PS1="${_p_left}${_p_padding}${_p_right}"$'\n'"${_p_character}"
}

_prompt_setup_zsh_safe() {
  setopt PROMPT_SUBST
  if [[ "${EUID:-1}" == 0 ]]; then
    PROMPT=$'%F{yellow}%n@%m%f %F{cyan}%~%f\n%(?.%F{green}.%F{red})❯%f '
  else
    PROMPT=$'%F{cyan}%~%f\n%(?.%F{green}.%F{red})❯%f '
  fi
  RPROMPT='%(?..%F{red}✘ %?%f  )%F{8}%D{%H:%M:%S}%f'
}

_prompt_should_use_safe_zsh() {
  [[ -n "${ZSH_VERSION:-}" ]] || return 1
  [[ "${JSH_RUNTIME_PROFILE:-}" == safe ]] && return 0
  [[ "${JSH_PROMPT_FORCE_ADVANCED_ZSH:-0}" == 1 ]] && return 1
  [[ "${JSH_PROMPT_FORCE_SAFE_ZSH:-0}" == 1 ]] && return 0
  autoload -Uz is-at-least add-zsh-hook 2>/dev/null || return 0
  is-at-least 5.4 "${ZSH_VERSION}" || return 0
  zmodload zsh/datetime 2>/dev/null || return 0
  (( ${+builtins[strftime]} )) || return 0
  return 1
}

_prompt_setup_zsh() {
  setopt PROMPT_SUBST
  autoload -Uz add-zsh-hook
  zmodload zsh/datetime 2>/dev/null || true
  _prompt_preexec_zsh() { _prompt_preexec "$1"; }
  _prompt_precmd_zsh() {
    local _p_exit_code=$?
    jsh_async_poll 2>/dev/null || true
    _prompt_precmd "${_p_exit_code}"
    _prompt_render_zsh
  }
  _prompt_chpwd_zsh() {
    _P_GIT_INVALIDATE=1 _P_GIT_CACHE_VALID=0
    _P_KUBE_INVALIDATE=1
    _prompt_git_clear
    _prompt_node_update
  }
  _prompt_zshexit_zsh() { _prompt_git_async_stop; }
  if (( ${+functions[jsh_hook_add]} )); then
    jsh_hook_add preexec _prompt_preexec_zsh 0
    jsh_hook_add precmd _prompt_precmd_zsh 0
    jsh_hook_add chpwd _prompt_chpwd_zsh 0
    jsh_hook_add zshexit _prompt_zshexit_zsh 0
  else
    add-zsh-hook preexec _prompt_preexec_zsh
    add-zsh-hook precmd _prompt_precmd_zsh
    add-zsh-hook chpwd _prompt_chpwd_zsh
    add-zsh-hook zshexit _prompt_zshexit_zsh
  fi
  _prompt_node_update
  _prompt_render_zsh
}

_prompt_setup_bash() {
  _prompt_precmd_bash() {
    local _p_exit_code="${1:-$?}"
    jsh_async_poll 2>/dev/null || true
    _prompt_precmd "${_p_exit_code}"
    _prompt_render_bash
  }
  if declare -f jsh_hook_add >/dev/null 2>&1; then
    _prompt_preexec_bash_hook() { _prompt_preexec "$1"; }
    jsh_hook_add preexec _prompt_preexec_bash_hook 0
    jsh_hook_add precmd _prompt_precmd_bash 0
  else
    trap '_prompt_preexec "${BASH_COMMAND}"' DEBUG
    PROMPT_COMMAND=_prompt_precmd_bash
  fi
  _prompt_render_bash
}

prompt_refresh() {
  _P_GIT_INVALIDATE=1
  _P_GIT_CACHE_VALID=0
}

prompt_init() {
  [[ "${_P_PROMPT_INITIALIZED:-0}" == 1 ]] && return 0
  _P_PROMPT_INITIALIZED=1
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    if _prompt_should_use_safe_zsh; then _prompt_setup_zsh_safe
    else _prompt_setup_zsh; fi
  else _prompt_setup_bash; fi
}

# =============================================================================
# Modern integrations
# =============================================================================
#!/usr/bin/env bash
# integrations.sh - Optional modern shell tools with graceful fallbacks
# shellcheck disable=SC1090,SC1094,SC2016

_jsh_integration_enabled() {
  local _jsh_integration_value=""
  case "$1" in
    fnm) _jsh_integration_value="${JSH_FEATURE_FNM:-1}" ;;
    zoxide) _jsh_integration_value="${JSH_FEATURE_ZOXIDE:-1}" ;;
    direnv) _jsh_integration_value="${JSH_FEATURE_DIRENV:-1}" ;;
    atuin) _jsh_integration_value="${JSH_FEATURE_ATUIN:-1}" ;;
    *) return 2 ;;
  esac
  [[ "${_jsh_integration_value}" != 0 ]]
}

# Most integration commands print a deterministic shell script. Cache those
# scripts and invalidate them when the producing binary changes. fnm is the
# exception because it creates session-specific environment state.
_jsh_cached_integration_eval() {
  local _jsh_integration_tool="$1" _jsh_integration_key="$2"
  shift 2
  local _jsh_integration_bin="" _jsh_integration_cache="" _jsh_integration_tmp=""

  _jsh_integration_bin="$(command -v "${_jsh_integration_tool}" 2>/dev/null)" || return 1
  _jsh_integration_cache="${JSH_CACHE_DIR}/integrations/${_jsh_integration_key}.${JSH_SHELL}"

  if [[ ! -s "${_jsh_integration_cache}" || "${_jsh_integration_bin}" -nt "${_jsh_integration_cache}" ]]; then
    ensure_dir "${JSH_CACHE_DIR}/integrations"
    _jsh_integration_tmp="${_jsh_integration_cache}.$$"
    if ! command "${_jsh_integration_tool}" "$@" >"${_jsh_integration_tmp}" 2>/dev/null ||
      [[ ! -s "${_jsh_integration_tmp}" ]]; then
      command rm -f -- "${_jsh_integration_tmp}"
      return 1
    fi
    command mv -f -- "${_jsh_integration_tmp}" "${_jsh_integration_cache}"
  fi

  source "${_jsh_integration_cache}"
  return 0
}

# The prompt has one implementation so startup and rendering behavior stay
# predictable across machines.
jsh_prompt_init() {
  jsh_feature_enabled prompt || return 0
  prompt_init
}

# Initialize directory and language tools after completion and prompt setup.
# zoxide intentionally keeps its default `z`/`zi` commands and never replaces
# the predictable semantics of `cd`. fnm is initialized without its directory
# hook so changing directories never emits version-resolution errors.
jsh_modern_tools_init() {
  local _jsh_tool_init=""

  if _jsh_integration_enabled fnm && has fnm; then
    _jsh_tool_init="$(fnm env --shell "${JSH_SHELL}" --version-file-strategy=recursive 2>/dev/null)" &&
      [[ -n "${_jsh_tool_init}" ]] && eval "${_jsh_tool_init}"
  fi

  if _jsh_integration_enabled zoxide && has zoxide; then
    _jsh_cached_integration_eval zoxide zoxide init "${JSH_SHELL}" || true
  fi

  if _jsh_integration_enabled direnv && has direnv; then
    _jsh_cached_integration_eval direnv direnv hook "${JSH_SHELL}" || true
  fi
}

# Atuin owns history hooks and key bindings, so callers must invoke this after
# all other shell setup. The tracked .zshrc defers it until its final line.
jsh_atuin_init() {
  [[ -n "${_JSH_ATUIN_INITIALIZED:-}" ]] && return 0
  _jsh_integration_enabled atuin || return 0

  if ! has atuin && [[ -r "${HOME}/.atuin/bin/env" ]]; then
    source "${HOME}/.atuin/bin/env"
  fi
  has atuin || return 0

  _jsh_cached_integration_eval atuin atuin init "${JSH_SHELL}" || return 0
  _JSH_ATUIN_INITIALIZED=1
}

# =============================================================================
# Project environments
# =============================================================================
# project-env.sh - Fast, reversible project-local environments

JSH_PROJECT_TRUST_FILE="${JSH_PROJECT_TRUST_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/jsh/trusted-projects}"
_JSH_PROJECT_ENV_FILE=""
_JSH_PROJECT_ENV_KEYS=()
_JSH_PROJECT_ENV_OLD_VALUES=()
_JSH_PROJECT_ENV_OLD_SET=()

_jsh_project_hash() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    REPLY="$(shasum -a 256 "$file" 2>/dev/null)"; REPLY="${REPLY%% *}"
  elif command -v sha256sum >/dev/null 2>&1; then
    REPLY="$(sha256sum "$file" 2>/dev/null)"; REPLY="${REPLY%% *}"
  else
    REPLY=""; return 1
  fi
  [[ -n "$REPLY" ]]
}

_jsh_project_find() {
  local dir="$PWD"
  REPLY=""
  while [[ -n "$dir" ]]; do
    if [[ -r "$dir/.jshenv" ]]; then REPLY="${dir:A}/.jshenv"; return 0; fi
    if [[ -r "$dir/.jshrc" ]]; then REPLY="${dir:A}/.jshrc"; return 0; fi
    [[ "$dir" == / ]] && break
    dir="${dir%/*}"; [[ -n "$dir" ]] || dir=/
  done
  return 1
}

_jsh_project_restore() {
  local i=0 key
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays
  while [[ $i -lt ${#_JSH_PROJECT_ENV_KEYS[@]} ]]; do
    key="${_JSH_PROJECT_ENV_KEYS[$i]}"
    if [[ "${_JSH_PROJECT_ENV_OLD_SET[$i]}" == 1 ]]; then
      printf -v "$key" '%s' "${_JSH_PROJECT_ENV_OLD_VALUES[$i]}"
      export "${key?}"
    else
      unset "$key"
    fi
    i=$((i + 1))
  done
  _JSH_PROJECT_ENV_KEYS=(); _JSH_PROJECT_ENV_OLD_VALUES=(); _JSH_PROJECT_ENV_OLD_SET=()
  _JSH_PROJECT_ENV_FILE=""
}

_jsh_project_set() {
  local key="$1" value="$2" i=${#_JSH_PROJECT_ENV_KEYS[@]}
  [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays
  case "$key" in [A-Za-z_][A-Za-z0-9_]*) ;; *) return 1 ;; esac

  # A declarative file may assign the same key more than once. Preserve the
  # pre-project value only on the first assignment so leaving the directory
  # always restores the true original value.
  local existing=0
  while [[ $existing -lt ${#_JSH_PROJECT_ENV_KEYS[@]} ]]; do
    if [[ "${_JSH_PROJECT_ENV_KEYS[$existing]}" == "$key" ]]; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
      return 0
    fi
    existing=$((existing + 1))
  done

  _JSH_PROJECT_ENV_KEYS[i]="$key"
  if eval '[[ ${'"$key"'+set} == set ]]'; then
    _JSH_PROJECT_ENV_OLD_SET[i]=1
    eval '_JSH_PROJECT_ENV_OLD_VALUES[$i]=${'"$key"'}'
  else
    _JSH_PROJECT_ENV_OLD_SET[i]=0
    _JSH_PROJECT_ENV_OLD_VALUES[i]=""
  fi
  printf -v "$key" '%s' "$value"
  export "${key?}"
}

_jsh_project_load_declarative() {
  local file="$1" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; export[[:space:]]*) line="${line#export }" ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$value" in \"*\") value="${value#\"}"; value="${value%\"}" ;; \'*\') value="${value#\'}"; value="${value%\'}" ;; esac
    _jsh_project_set "$key" "$value" || warn "Ignoring invalid .jshenv key: $key"
  done <"$file"
}

_jsh_project_is_trusted() {
  local file="$1" hash trusted_file trusted_hash
  _jsh_project_hash "$file" || return 1; hash="$REPLY"
  [[ -r "$JSH_PROJECT_TRUST_FILE" ]] || return 1
  while IFS='|' read -r trusted_file trusted_hash; do
    [[ "$trusted_file" == "$file" && "$trusted_hash" == "$hash" ]] && return 0
  done <"$JSH_PROJECT_TRUST_FILE"
  return 1
}

jsh_project_env_refresh() {
  local file=""
  _jsh_project_find && file="$REPLY"
  [[ "$file" == "$_JSH_PROJECT_ENV_FILE" ]] && return 0
  _jsh_project_restore
  [[ -n "$file" ]] || return 0
  _JSH_PROJECT_ENV_FILE="$file"
  case "$file" in
    *.jshenv) _jsh_project_load_declarative "$file" ;;
    *.jshrc)
      if _jsh_project_is_trusted "$file"; then
        # shellcheck disable=SC1090
        source "$file"
      else
        warn "Project .jshrc is not trusted: $file"
        prefix_info "Run: jsh env trust '$file'"
      fi
      ;;
  esac
}

jsh_project_env_reload() {
  _jsh_project_restore
  jsh_project_env_refresh
}

jsh_project_env_status() {
  local file="" state="" result=0

  if ! jsh_feature_enabled project-env; then
    printf 'status: disabled\n'
    return 1
  fi
  if ! _jsh_project_find; then
    printf 'status: no project environment\n'
    return 1
  fi

  file="$REPLY"
  case "$file" in
    *.jshenv)
      if [[ "$_JSH_PROJECT_ENV_FILE" == "$file" ]]; then state="loaded"
      else state="available"; result=1
      fi
      ;;
    *.jshrc)
      if ! _jsh_project_is_trusted "$file"; then state="untrusted"; result=1
      elif [[ "$_JSH_PROJECT_ENV_FILE" == "$file" ]]; then state="loaded"
      else state="trusted"; result=1
      fi
      ;;
  esac

  printf 'file: %s\nstatus: %s\n' "$file" "$state"
  return "$result"
}

jsh_project_env_trust() {
  local file="${1:-}" hash="" trust_dir="" tmp="" line=""

  if [[ -z "$file" ]]; then
    if ! _jsh_project_find; then
      printf 'jsh: no project environment found\n' >&2
      return 1
    fi
    file="$REPLY"
  elif [[ -d "$file" ]]; then
    file="${file}/.jshrc"
  fi
  file="${file:A}"

  if [[ "${file:t}" != .jshrc || ! -r "$file" ]]; then
    printf 'jsh: trust requires a readable .jshrc file\n' >&2
    return 1
  fi
  case "$file" in *'|'*|*$'\n'*) printf 'jsh: unsupported project path\n' >&2; return 1 ;; esac
  _jsh_project_hash "$file" || {
    printf 'jsh: unable to hash %s\n' "$file" >&2
    return 1
  }
  hash="$REPLY"

  trust_dir="${JSH_PROJECT_TRUST_FILE:h}"
  ensure_dir "$trust_dir" || return 1
  tmp="$(mktemp "${JSH_PROJECT_TRUST_FILE}.tmp.XXXXXX")" || return 1
  {
    if [[ -r "$JSH_PROJECT_TRUST_FILE" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "${line%%|*}" == "$file" ]] || printf '%s\n' "$line"
      done <"$JSH_PROJECT_TRUST_FILE"
    fi
    printf '%s|%s\n' "$file" "$hash"
  } >"$tmp" || {
    command rm -f -- "$tmp"
    return 1
  }
  command mv -f -- "$tmp" "$JSH_PROJECT_TRUST_FILE" || {
    command rm -f -- "$tmp"
    return 1
  }

  printf 'trusted: %s\n' "$file"
  if _jsh_project_find && [[ "$REPLY" == "$file" ]]; then
    jsh_project_env_reload
  fi
}

_jsh_env_usage() {
  printf 'Usage: jsh env status|trust [file]|reload\n' >&2
}

jsh() {
  case "${1:-}" in
    reload | -r)
      [[ $# -eq 1 ]] || { printf 'Usage: jsh reload\n' >&2; return 2; }
      unset _JSH_DOTFILES_ZSH_LOADED
      source "${JSH_DIR}/dotfiles/.zshrc"
      ;;
    env)
      shift
      case "${1:-status}" in
        status)
          [[ $# -le 1 ]] || { _jsh_env_usage; return 2; }
          jsh_project_env_status
          ;;
        trust)
          [[ $# -le 2 ]] || { _jsh_env_usage; return 2; }
          jsh_project_env_trust "${2:-}"
          ;;
        reload)
          [[ $# -eq 1 ]] || { _jsh_env_usage; return 2; }
          jsh_project_env_reload
          ;;
        *)
          _jsh_env_usage
          return 2
          ;;
      esac
      ;;
    *)
      command "${JSH_DIR}/bin/jsh" "$@"
      ;;
  esac
}

# =============================================================================
# Startup orchestration
# =============================================================================
vimode_init
if jsh_feature_enabled prompt; then
  prompt_init
fi
jsh_plugins_load

if jsh_feature_enabled project-env; then
  jsh_hook_add chpwd jsh_project_env_refresh 40
  jsh_project_env_refresh
fi

export PNPM_HOME="${HOME}/.local/share/pnpm"
if [[ -z ${RIPGREP_CONFIG_PATH+x} ]]; then
  export RIPGREP_CONFIG_PATH="${HOME}/.ripgreprc"
fi
jsh_modern_tools_init

if has nvim; then
  export EDITOR="nvim" VISUAL="nvim"
elif has vim; then
  export EDITOR="vim" VISUAL="vim"
fi

export LESS="-R -F -i -M -S"
export LESSHISTFILE="${XDG_CACHE_HOME:-$HOME/.cache}/less/history"
ensure_dir "${LESSHISTFILE%/*}"
export GPG_TTY="${GPG_TTY:-${TTY:-}}"

[[ ! -r "${JSH_DIR}/local/.jshrc" ]] || source "${JSH_DIR}/local/.jshrc"
if [[ "${JSH_MODE:-}" != lite ]]; then
  [[ ! -r "${HOME}/.zshrc.local" ]] || source "${HOME}/.zshrc.local"
fi
jsh_atuin_init
path_prepend "${JSH_DIR}/bin"
fi
