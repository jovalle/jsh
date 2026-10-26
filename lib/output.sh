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
jsh::log_note() { printf '%s\n' "$(jsh::paint 1 2 "$*")"; }
jsh::log_detail() { printf '%s\n' "$(jsh::paint 1 2 "$*")"; }
jsh::log_item() { printf '  %s %s\n' "$(jsh::paint 1 32 +)" "$*"; }
jsh::log_current() { printf '  %s %s\n' "$(jsh::paint 1 32 '✓')" "$(jsh::paint 1 2 "$*")"; }
jsh::log_success() { printf '%s %s\n' "$(jsh::paint 1 32 '✓')" "$*"; }
jsh::log_warn() { printf '%s %s\n' "$(jsh::paint 2 33 !)" "$(jsh::paint 2 33 "$*")" >&2; }
jsh::log_error() { printf '%s %s\n' "$(jsh::paint 2 31 '✗')" "$(jsh::paint 2 31 "$*")" >&2; }
jsh::log_section() { printf '\n%s\n' "$(jsh::paint 1 1 "$*")"; }

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

# Usage: _jsh_menu LABEL ITEM... Prints a numbered menu on stderr and reads the reply from the terminal.
_jsh_menu() {
  local label=$1 item index=0
  shift
  for item in "$@"; do
    index=$((index + 1))
    printf '%3d) %s\n' "${index}" "${item}" >&2
  done
  printf '%s %s: ' "$(jsh::paint 2 '1;36' '?')" "${label}" >&2
  IFS= read -r _jsh_menu_reply </dev/tty
}

# Usage: _jsh_pick N ITEM... Prints the Nth item.
_jsh_pick() {
  local wanted=$1 item
  shift
  [[ ${wanted} =~ ^[0-9]+$ ]] && ((wanted >= 1 && wanted <= $#)) || return 1
  for item in "$@"; do
    wanted=$((wanted - 1))
    if ((wanted == 0)); then
      printf '%s\n' "${item}"
      return 0
    fi
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
  _jsh_menu "${label}" "$@" || return 1
  _jsh_pick "${_jsh_menu_reply}" "$@"
}

# Usage: jsh::choose_many LABEL ITEM... Prints the chosen items, one per line.
jsh::choose_many() {
  local label=$1 number
  shift
  (($#)) || return 1
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$@" | fzf --multi --height=40% --reverse --prompt="${label} (Tab marks)> "
    return
  fi
  _jsh_menu "${label} (numbers separated by spaces)" "$@" || return 1
  while IFS= read -r number; do
    [[ -z ${number} ]] || _jsh_pick "${number}" "$@" || return 1
  done < <(printf '%s\n' "${_jsh_menu_reply}" | tr -s ' ,' '\n\n')
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
  printf '%s\n' "$(jsh::paint 1 36 "${banner}")"
}

jsh::color_init
