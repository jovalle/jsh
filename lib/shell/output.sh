#!/usr/bin/env bash
# Colored, symbol-led output and selection menus shared by jsh commands (Bash and Zsh).

# Records whether stdout and stderr take color; rerun after redirecting either stream.
jsh::color_init() {
  _jsh_color_1=0
  _jsh_color_2=0
  [[ -z ${NO_COLOR:-} && ${TERM:-} != dumb ]] || return 0
  [[ ! -t 1 ]] || _jsh_color_1=1
  [[ ! -t 2 ]] || _jsh_color_2=1
}

# Usage: jsh::paint FD SGR TEXT. FD 1 or 2 selects which stream's color decision applies.
jsh::paint() {
  local enabled=${_jsh_color_1:-0}
  [[ $1 != 2 ]] || enabled=${_jsh_color_2:-0}
  if [[ ${enabled} == 1 ]]; then
    printf '\033[%sm%s\033[0m' "$2" "$3"
  else
    printf '%s' "$3"
  fi
}

jsh::log_info() { printf '%s %s\n' "$(jsh::paint 1 36 '›')" "$*"; }
# Usage: jsh::log_field LABEL VALUE. Prints "› LABEL: VALUE" with the value in cyan.
jsh::log_field() { printf '%s %s: %s\n' "$(jsh::paint 1 36 '›')" "$1" "$(jsh::paint 1 36 "$2")"; }
jsh::log_note() { printf '%s\n' "$(jsh::paint 1 2 "$*")"; }
jsh::log_detail() { printf '%s\n' "$(jsh::paint 1 2 "$*")"; }
jsh::log_item() { printf '  %s %s\n' "$(jsh::paint 1 32 +)" "$*"; }
jsh::log_current() { printf '  %s %s\n' "$(jsh::paint 1 32 '✓')" "$(jsh::paint 1 2 "$*")"; }
jsh::log_success() { printf '%s %s\n' "$(jsh::paint 1 32 '✓')" "$*"; }
jsh::log_warn() { printf '%s %s\n' "$(jsh::paint 2 33 !)" "$(jsh::paint 2 33 "$*")" >&2; }
jsh::log_error() { printf '%s %s\n' "$(jsh::paint 2 31 '✗')" "$(jsh::paint 2 31 "$*")" >&2; }
jsh::log_section() { printf '\n%s\n' "$(jsh::paint 1 1 "$*")"; }

jsh::reload_pending() {
  local request
  [[ -n ${JSH_RUNTIME_DIR:-} && ${JSH_RELOAD_PID:-} == "$$" ]] || return 0
  request=${JSH_RUNTIME_DIR}/reload-${JSH_RELOAD_PID}
  [[ -d ${request} ]] || return 0
  rmdir -- "${request}" || return
  printf 'Reloading the jsh runtime...\n'
  jsh reload
}

# Usage: jsh::log_summary LABEL DETAIL. Matches the Python step result lines.
jsh::log_summary() {
  printf '%s %-9s %s\n' "$(jsh::paint 1 32 '✓')" "$1" "$(jsh::paint 1 2 "$2")"
}

# Milliseconds since an arbitrary point; whole seconds where EPOCHREALTIME is missing (Bash 3.2).
jsh::clock() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    local now=${EPOCHREALTIME//[!0-9]/}
    printf '%s\n' "$((10#${now} / 1000))"
  else
    printf '%s\n' "$((SECONDS * 1000))"
  fi
}

jsh::duration() {
  local ms=$1
  if ((ms < 1000)); then
    printf '%sms\n' "${ms}"
  else
    printf '%s.%02ds\n' "$((ms / 1000))" "$((ms % 1000 / 10))"
  fi
}

# A numbered fallback keeps selection usable without fzf or a Python runtime.
_jsh_menu() {
  local mode=$1 label=$2 answer item shift_count index=1
  shift 2
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  printf '%s\n' "${label}" >/dev/tty
  for item in "$@"; do
    printf '  %s) %s\n' "${index}" "${item}" >/dev/tty
    index=$((index + 1))
  done
  printf 'Choose number%s: ' "$([[ ${mode} != many ]] || printf 's separated by spaces')" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  local -a choices=()
  if [[ -n ${ZSH_VERSION:-} ]]; then
    read -r -A choices <<<"${answer}"
  else
    read -r -a choices <<<"${answer}"
  fi
  [[ ${#choices[@]} -gt 0 ]] || return 1
  [[ ${mode} == many || ${#choices[@]} == 1 ]] || return 1
  for index in "${choices[@]}"; do
    case ${index} in '' | *[!0-9]*) return 1 ;; esac
    index=$((10#${index}))
    ((index > 0 && index <= $#)) || return 1
  done
  for index in "${choices[@]}"; do
    shift_count=$((10#${index} - 1))
    item=$(
      shift "${shift_count}"
      printf '%s' "$1"
    )
    printf '%s\n' "${item}"
  done
}

# Usage: jsh::choose LABEL ITEM... Prints the chosen item; fzf when installed, else a numbered menu.
jsh::choose() {
  local label=$1
  shift
  (($#)) || return 1
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$@" | fzf --height=40% --reverse --prompt="${label}> "
    return
  fi
  _jsh_menu one "${label}" "$@"
}

# Usage: jsh::choose_many LABEL ITEM... Prints the chosen items, one per line.
jsh::choose_many() {
  local label=$1
  shift
  (($#)) || return 1
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$@" | fzf --multi --height=40% --reverse --prompt="${label} (Tab marks)> "
    return
  fi
  _jsh_menu many "${label}" "$@"
}

jsh_banner() {
  local banner
  banner=$(
    cat <<'BANNER'
   :%@@@@@@@@@#*#@%-              +-:##
  :#    -#%%+=#:@#                :@@%:
   %@@     +@++@@-            *-   @@%:
          *@%:%@@:    :%@@@@*%+  *@@@%::*@@#
     -###%@@+:%@@:  :%@#:--=%:    -@@@#: #@@=
       :#@@@+:%@@:  :%@#  -#-     -@@%   *@@=
      *#:#@@+:%@@:  :%@@@@@@@@*   -@@%   *@@=
       -#@@@+:%@%:     *%  -@@*   -@@%   *@@=
         :@@+:%@*     -*   -@@*   -@@%   *@@=
          +@+:%*     *@@@@@%@%-   #@@@+  *@@-
   :==--::*#:#-     -:   -*:        +   =@@=
 :@@@@@@@@#@-                         +@#:
 =   :-=-:                          -:
BANNER
  )
  if [[ -n ${1:-} ]]; then
    banner=${banner%" =   :-=-:                          -:"}
    banner+=$(printf ' =   :-=-:        %-18s-:' "$1")
  fi
  local line
  # Paint each line so the color survives line-by-line relaying.
  while IFS= read -r line; do printf '%s\n' "$(jsh::paint 1 36 "${line}")"; done <<<"${banner}"
  [[ -z ${2:-}${3:-} ]] || printf '\n'
  [[ -z ${2:-} ]] || jsh::log_field OS "$2"
  [[ -z ${3:-} ]] || jsh::log_field Desktop "$3"
}

jsh::color_init
