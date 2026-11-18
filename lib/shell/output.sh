#!/usr/bin/env bash
# Colored, symbol-led output and selection menus shared by jsh commands (Bash and Zsh).

case $- in *i*) unset JSH_OUTPUT JSH_REPORT JSH_SESSION_START ;; esac

# Records whether stdout and stderr take color; rerun after redirecting either stream.
jsh::color_init() {
  _jsh_color_1=0
  _jsh_color_2=0
  [[ -z ${NO_COLOR+x} && ${TERM:-} != dumb && ${JSH_COLOR:-auto} != never ]] || return 0
  if [[ ${JSH_COLOR:-auto} == always ]]; then
    _jsh_color_1=1
    _jsh_color_2=1
    return 0
  fi
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

# Replace wire-breaking characters in one event field without starting a subprocess.
jsh::_wire_field() {
  _jsh_field=${1-}
  _jsh_field=${_jsh_field//$'\t'/ }
  _jsh_field=${_jsh_field//$'\r'/ }
  _jsh_field=${_jsh_field//$'\n'/ }
  _jsh_field=${_jsh_field//$'\x1e'/}
}

# Strip terminal controls from a field before plain output.
jsh::_plain_field() {
  local text=${1-}
  text=${text//$'\t'/}
  text=${text//$'\r'/}
  text=${text//$'\n'/}
  LC_ALL=C sed -E $'s#\x1b\\]([^\x07\x1b]|\x1b[^\\\\])*(\x07|\x1b\\\\)##g; s#\x1b\\[[0-?]*[ -/]*[@-~]##g; s#[\x01-\x09\x0b-\x1f\x7f]##g' <<EOF
${text}
EOF
}

jsh::_display_path() {
  _jsh_display=$1
  case ${_jsh_display} in
    '$HOME/'*) _jsh_display=\~/"${_jsh_display#'$HOME/'}" ;;
    "${HOME}/"*) _jsh_display=\~/"${_jsh_display#"${HOME}/"}" ;;
  esac
}

# Load step conjugations only when plain output first needs one.
jsh::_verb_ing() {
  local requested=$1 verb ing _
  if [[ ${_jsh_verbs_loaded:-0} != 1 ]]; then
    _jsh_verbs_loaded=1
    _jsh_verbs=
    if [[ -n ${JSH_ROOT:-} && -r ${JSH_ROOT}/lib/verbs.tsv ]]; then
      while IFS=$'\t' read -r verb ing _; do
        [[ -n ${verb} && ${verb} != '#'* && -n ${ing} ]] || continue
        _jsh_verbs=${_jsh_verbs}${verb}$'\t'${ing}$'\n'
      done <"${JSH_ROOT}/lib/verbs.tsv"
    fi
  fi
  _jsh_ing=${requested}
  while IFS=$'\t' read -r verb ing; do
    if [[ ${verb} == "${requested}" ]]; then
      _jsh_ing=${ing}
      break
    fi
  done <<<"${_jsh_verbs}"
}

jsh::_plain_item_line() {
  local fd=$1 kind=$2 text=$3 was=$4 symbol code action fact
  case ${kind} in
    added | changed | removed)
      if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
        fact=${was:-${text}}
        case ${kind} in
          added) action=add ;;
          changed) action=change ;;
          removed) action=remove ;;
        esac
        jsh::paint "${fd}" 33 !
        printf ' %s' "${fact}"
        jsh::paint "${fd}" 2 "  would ${action}"
        printf '\n'
        return
      fi
      if [[ -n ${was} ]]; then
        jsh::paint "${fd}" 33 !
        printf ' %s\n' "${was}"
      fi
      case ${kind} in
        added) symbol=+ code=32 ;;
        changed) symbol='~' code=33 ;;
        removed) symbol=- code=31 ;;
      esac
      ;;
    ok) symbol=✓ code=32 ;;
    drift | notice) symbol=! code=33 ;;
    fail) symbol=✕ code=31 ;;
    info | skip)
      jsh::paint "${fd}" 2 "${text}"
      printf '\n'
      return
      ;;
    output | *)
      jsh::paint "${fd}" 2 "    ${text}"
      printf '\n'
      return
      ;;
  esac
  jsh::paint "${fd}" "${code}" "${symbol}"
  printf ' %s\n' "${text}"
}

jsh::_report_count() {
  local path=$1 line
  _jsh_count=0
  [[ -f ${path} ]] || return 0
  while IFS= read -r line || [[ -n ${line} ]]; do
    _jsh_count=$((_jsh_count + 1))
  done <"${path}"
}

jsh::_plain_group_close() {
  unset _jsh_plain_group_name _jsh_plain_group_purpose
}

# Format one event directly when no renderer session is active.
jsh::plain() {
  local type=${1-} name purpose verb object kind text was fd=1
  jsh::color_init
  shift || return 0
  case ${type} in
    group)
      jsh::_plain_group_close
      unset _jsh_plain_step_ing _jsh_plain_step_object
      name=$(jsh::_plain_field "${1-}")
      purpose=$(jsh::_plain_field "${2-}")
      _jsh_plain_group_name=${name}
      _jsh_plain_group_purpose=${purpose}
      _jsh_plain_group_items=0
      _jsh_plain_group_skips=0
      _jsh_plain_group_failed=0
      _jsh_plain_group_item_start=0
      _jsh_plain_group_skip_start=0
      _jsh_plain_group_failure_start=0
      if [[ -d ${JSH_REPORT:-} ]]; then
        jsh::_report_count "${JSH_REPORT}/items"
        _jsh_plain_group_item_start=${_jsh_count}
        jsh::_report_count "${JSH_REPORT}/skips"
        _jsh_plain_group_skip_start=${_jsh_count}
        jsh::_report_count "${JSH_REPORT}/failures"
        _jsh_plain_group_failure_start=${_jsh_count}
      fi
      printf '\n'
      jsh::paint 1 '1;36' "› ${name}"
      if [[ -n ${purpose} ]]; then
        printf '  '
        jsh::paint 1 2 "${purpose}"
      fi
      printf '\n'
      ;;
    step)
      verb=$(jsh::_plain_field "${1-}")
      object=$(jsh::_plain_field "${2-}")
      jsh::_verb_ing "${verb}"
      _jsh_plain_step_ing=${_jsh_ing}
      _jsh_plain_step_object=${object}
      jsh::paint 1 2 "${_jsh_ing} ${object}..."
      printf '\n'
      ;;
    item)
      kind=${1-}
      text=$(jsh::_plain_field "${2-}")
      was=$(jsh::_plain_field "${3-}")
      jsh::_display_path "${text}"
      text=${_jsh_display}
      jsh::_display_path "${was}"
      was=${_jsh_display}
      if [[ -n ${_jsh_plain_group_name+x} ]]; then
        _jsh_plain_group_items=$((${_jsh_plain_group_items:-0} + 1))
        [[ ${kind} != skip ]] || _jsh_plain_group_skips=$((${_jsh_plain_group_skips:-0} + 1))
        [[ ${kind} != fail ]] || _jsh_plain_group_failed=1
      fi
      if [[ -z ${JSH_OUTPUT+x} ]]; then
        case ${kind} in drift | fail | notice) fd=2 ;; esac
      fi
      if [[ ${fd} == 2 ]]; then
        jsh::_plain_item_line "${fd}" "${kind}" "${text}" "${was}" >&2
      else
        jsh::_plain_item_line "${fd}" "${kind}" "${text}" "${was}"
      fi
      ;;
    stepclose)
      unset _jsh_plain_step_ing _jsh_plain_step_object
      ;;
    end)
      case ${2-0} in
        130 | 143)
          if [[ -s ${JSH_REPORT:-}/step ]]; then
            IFS="	" read -r _jsh_report_verb _jsh_plain_step_object <"${JSH_REPORT}/step"
            jsh::_verb_ing "${_jsh_report_verb}"
            _jsh_plain_step_ing=${_jsh_ing}
          fi
          if [[ -n ${_jsh_plain_step_ing+x} ]]; then
            _jsh_stopped_ing=$(printf "%s" "${_jsh_plain_step_ing}" | LC_ALL=C tr "[:upper:]" "[:lower:]")
            jsh::paint 1 31 ✕
            printf " Stopped %s %s\n" "${_jsh_stopped_ing}" "${_jsh_plain_step_object}"
            _jsh_plain_group_failed=1
          fi
          ;;
      esac
      unset _jsh_plain_step_ing _jsh_plain_step_object _jsh_stopped_ing _jsh_report_verb
      jsh::_plain_group_close
      ;;
    progress | task | taskend) ;;
  esac
}

jsh::_report_event() {
  local type=$1 kind=${2-} text=${3-} line found=0 verb object
  [[ -d ${JSH_REPORT:-} ]] || return 0
  case ${type} in
    group | stepclose) : >"${JSH_REPORT}/step" ;;
    step)
      jsh::_wire_field "${kind}"
      verb=${_jsh_field}
      jsh::_wire_field "${text}"
      object=${_jsh_field}
      printf "%s\t%s\n" "${verb}" "${object}" >"${JSH_REPORT}/step"
      ;;
  esac
  [[ ${type} == item ]] || return 0
  jsh::_wire_field "${text}"
  line=${_jsh_field}
  printf "%s\n" "${kind}" >>"${JSH_REPORT}/items"
  case ${kind} in
    added | changed | removed)
      printf "%s\n" "${kind}" >>"${JSH_REPORT}/events"
      ;;
    skip)
      printf "%s\n" "${line}" >>"${JSH_REPORT}/skips"
      ;;
    fail)
      printf "%s\n" "${line}" >>"${JSH_REPORT}/failures"
      ;;
    notice)
      if [[ -f ${JSH_REPORT}/notices ]]; then
        while IFS= read -r text || [[ -n ${text} ]]; do
          if [[ ${text} == "${line}" ]]; then
            found=1
            break
          fi
        done <"${JSH_REPORT}/notices"
      fi
      [[ ${found} == 1 ]] || printf "%s\n" "${line}" >>"${JSH_REPORT}/notices"
      ;;
  esac
  return 0
}

# Emit one renderer event, or format it directly when no renderer is active.
jsh::event() {
  local type=${1-} field
  shift || return 0
  jsh::_report_event "${type}" "$@"
  if [[ ${JSH_OUTPUT:-} == renderer ]]; then
    printf '\036%s' "${type}"
    for field in "$@"; do
      jsh::_wire_field "${field}"
      printf '\t%s' "${_jsh_field}"
    done
    printf '\n'
  else
    jsh::plain "${type}" "$@"
  fi
}

jsh::group() { jsh::event group "${1-}" "${2-}"; }
jsh::step() { jsh::event step "${1-}" "${2-}"; }
jsh::status() { jsh::event progress "$*"; }
jsh::ok() { jsh::event item ok "$*"; }
jsh::drift() { jsh::event item drift "$*"; }
jsh::added() { jsh::event item added "${1-}" "${2-}"; }
jsh::changed() { jsh::event item changed "${1-}" "${2-}"; }
jsh::removed() { jsh::event item removed "${1-}" "${2-}"; }
jsh::fail() { jsh::event item fail "$*"; }
jsh::info() { jsh::event item info "$*"; }
jsh::skipped() { jsh::event item skip "Skipping $*"; }
jsh::notice() { jsh::event item notice "$*"; }
jsh::output() { jsh::event item output "$*"; }

jsh::reload_pending() {
  local request
  [[ -n ${JSH_RUNTIME_DIR:-} && ${JSH_RELOAD_PID:-} == "$$" ]] || return 0
  request=${JSH_RUNTIME_DIR}/reload-${JSH_RELOAD_PID}
  [[ -d ${request} ]] || return 0
  rmdir -- "${request}" || return
  printf 'Reloading the jsh runtime...\n'
  jsh reload
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

# Usage: jsh::confirm PROMPT. Succeeds on y or Y; previews and --yes accept without asking.
jsh::confirm() {
  local answer
  [[ ${JSH_DRY_RUN:-0} != 1 && ${JSH_ASSUME_YES:-0} != 1 ]] || return 0
  [[ -t 0 ]] || {
    jsh::notice 'Use --yes to apply changes without a terminal.'
    return 1
  }
  printf '%s (y/N) ' "$1" >&2
  IFS= read -r -n 1 answer || return 1
  printf '\n' >&2
  [[ ${answer} == [yY] ]]
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
  [[ -z ${2:-} ]] || jsh::info "OS: $2"
  [[ -z ${3:-} ]] || jsh::info "Desktop: $3"
}

jsh::color_init

# Compatibility aliases retained only for bin/git and bin/kubectx.
# New code must not use these names.
jsh::log_info() {
  jsh::color_init
  printf '%s %s\n' "$(jsh::paint 1 36 '›')" "$*"
}
jsh::log_field() { jsh::info "$1: $2"; }
jsh::log_note() { jsh::info "$*"; }
jsh::log_detail() { jsh::info "$*"; }
jsh::log_item() { jsh::added "$*"; }
jsh::log_current() { jsh::ok "$*"; }
jsh::log_success() { jsh::ok "$*"; }
jsh::log_warn() { jsh::notice "$*"; }
jsh::log_error() { jsh::fail "$*"; }
jsh::log_section() { jsh::group "$*"; }
jsh::log_summary() { jsh::ok "$1${2:+ $2}"; }
