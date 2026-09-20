#!/usr/bin/env bash

# Interactive rendering uses UI_OUTPUT_FD; selected values are returned on stdout.

ui::_gum_file() {
  if [[ -n ${BASH_VERSION:-} ]]; then
    printf '%s' "${BASH_SOURCE[0]}"
  else
    # funcsourcetrace is a Zsh special parameter.
    # shellcheck disable=SC2154
    printf '%s' "${funcsourcetrace[1]%:*}"
  fi
}

if ! typeset -f ui::box > /dev/null 2>&1; then
  UI_GUM_FILE=$(ui::_gum_file)
  case ${UI_GUM_FILE} in
    */*) UI_GUM_DIR=${UI_GUM_FILE%/*} ;;
    *) UI_GUM_DIR=. ;;
  esac
  . "${UI_GUM_DIR}/lipgloss.sh"
  unset UI_GUM_FILE UI_GUM_DIR
fi
unset -f ui::_gum_file

UI_INPUT_FD=${UI_INPUT_FD:-0}
UI_OUTPUT_FD=${UI_OUTPUT_FD:-2}
UI_SPINNER_INTERVAL=${UI_SPINNER_INTERVAL:-0.08}

ui::_terminal_cleanup() {
  if [[ -n ${UI_STTY_STATE:-} ]]; then
    stty "${UI_STTY_STATE}" <&"${UI_ACTIVE_INPUT_FD}" 2> /dev/null || true
    UI_STTY_STATE=
  fi
  if [[ ${UI_CURSOR_HIDDEN:-0} == 1 ]]; then
    printf '\033[?25h' >&"${UI_ACTIVE_OUTPUT_FD}"
    UI_CURSOR_HIDDEN=0
  fi
}

ui::_terminal_begin() {
  local mode=${1:-line} hide_cursor=${2:-0}
  UI_ACTIVE_INPUT_FD=${UI_INPUT_FD}
  UI_ACTIVE_OUTPUT_FD=${UI_OUTPUT_FD}
  UI_STTY_STATE=
  UI_CURSOR_HIDDEN=0

  if [[ -t ${UI_ACTIVE_INPUT_FD} ]]; then
    UI_STTY_STATE=$(stty -g <&"${UI_ACTIVE_INPUT_FD}") || return 1
  fi

  case ${mode} in
    key) [[ -z ${UI_STTY_STATE} ]] || stty -echo -icanon min 1 time 0 <&"${UI_ACTIVE_INPUT_FD}" || return 1 ;;
    secret) [[ -z ${UI_STTY_STATE} ]] || stty -echo <&"${UI_ACTIVE_INPUT_FD}" || return 1 ;;
  esac
  if ((hide_cursor)) && [[ -t ${UI_ACTIVE_OUTPUT_FD} ]]; then
    printf '\033[?25l' >&"${UI_ACTIVE_OUTPUT_FD}"
    UI_CURSOR_HIDDEN=1
  fi
}

ui::_read_key() {
  local _target_var=${1:-}
  local _read_char=
  if [[ -n ${BASH_VERSION:-} ]]; then
    IFS= read -r -s -n 1 -u "${UI_ACTIVE_INPUT_FD}" _read_char || [[ -n ${_read_char} ]]
  else
    IFS= read -r -s -k 1 -u "${UI_ACTIVE_INPUT_FD}" _read_char || [[ -n ${_read_char} ]]
  fi
  if [[ -n ${_target_var} ]]; then
    if [[ -n ${BASH_VERSION:-} ]]; then
      printf -v "${_target_var}" '%s' "${_read_char}"
    else
      typeset -g "${_target_var}=${_read_char}"
    fi
  else
    printf '%s' "${_read_char}"
  fi
}

ui::_read_escape_tail() {
  local _target_var=${1:-}
  local _tail=
  if [[ -n ${BASH_VERSION:-} ]]; then
    IFS= read -r -s -n 2 -t 0.1 -u "${UI_ACTIVE_INPUT_FD}" _tail || [[ -n ${_tail} ]]
  else
    IFS= read -r -s -k 2 -t 0.1 -u "${UI_ACTIVE_INPUT_FD}" _tail || [[ -n ${_tail} ]]
  fi
  if [[ -n ${_target_var} ]]; then
    if [[ -n ${BASH_VERSION:-} ]]; then
      printf -v "${_target_var}" '%s' "${_tail}"
    else
      typeset -g "${_target_var}=${_tail}"
    fi
  else
    printf '%s' "${_tail}"
  fi
}

ui::_nth_argument() {
  local index=$1
  shift
  while ((index > 1)); do
    shift
    index=$((index - 1))
  done
  printf '%s' "${1:-}"
}

ui::_read_masked() {
  local mask=$1 key='' value='' m_idx
  while :; do
    ui::_read_key key || return 130
    case ${key} in
      '' | $'\r' | $'\n')
        printf '\n' >&"${UI_ACTIVE_OUTPUT_FD}"
        printf '%s' "${value}"
        return
        ;;
      $'\177' | $'\b')
        if [[ -n ${value} ]]; then
          value=${value%?}
          for ((m_idx = 0; m_idx < ${#mask}; m_idx++)); do
            printf '\b \b' >&"${UI_ACTIVE_OUTPUT_FD}"
          done
        fi
        ;;
      $'\025')
        while [[ -n ${value} ]]; do
          value=${value%?}
          for ((m_idx = 0; m_idx < ${#mask}; m_idx++)); do
            printf '\b \b' >&"${UI_ACTIVE_OUTPUT_FD}"
          done
        done
        ;;
      $'\003' | $'\004' | $'\033') return 130 ;;
      *)
        value+=${key}
        printf '%s' "${mask}" >&"${UI_ACTIVE_OUTPUT_FD}"
        ;;
    esac
  done
}

ui::confirm() (
  local prompt=${1:-Continue?} default=no hint key
  (($# == 0)) || shift
  while (($# > 0)); do
    case $1 in
      --default)
        default=${2:-}
        shift 2
        ;;
      *) return 2 ;;
    esac
  done
  case ${default} in
    yes) hint='Y/n' ;;
    no) hint='y/N' ;;
    *) return 2 ;;
  esac

  trap 'ui::_terminal_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ui::_terminal_begin key 0 || return
  while :; do
    printf '%s %s ' "$(ui::style --fg ACCENT_SECONDARY --bold -- "? ${prompt}")" "(${hint})" >&"${UI_ACTIVE_OUTPUT_FD}"
    ui::_read_key key || return 130
    printf '\n' >&"${UI_ACTIVE_OUTPUT_FD}"
    case ${key} in
      y | Y) return 0 ;;
      n | N) return 1 ;;
      $'\003' | $'\004' | $'\033' | q | Q) return 130 ;;
      '' | $'\r' | $'\n')
        [[ ${default} == yes ]]
        return
        ;;
    esac
  done
)

ui::_choose_render() {
  local selected=$1 redraw=$2 prompt=$3 option index=1 count
  shift 3
  count=$#

  if ((redraw)); then
    printf '\033[%dA\033[1G' "$((count + 1))" >&"${UI_ACTIVE_OUTPUT_FD}"
  fi
  printf '\033[2K%s\n' "$(ui::style --fg TEXT_PRIMARY --bold -- "${prompt}")" >&"${UI_ACTIVE_OUTPUT_FD}"
  for option in "$@"; do
    if ((index == selected)); then
      printf '\033[2K  %s %s\n' \
        "$(ui::style --fg ACCENT_SECONDARY --bold -- '❯')" \
        "$(ui::style --fg TEXT_PRIMARY -- "${option}")" >&"${UI_ACTIVE_OUTPUT_FD}"
    else
      printf '\033[2K    %s\n' "$(ui::style --fg TEXT_MUTED -- "${option}")" >&"${UI_ACTIVE_OUTPUT_FD}"
    fi
    index=$((index + 1))
  done
}

ui::choose() (
  local prompt=${1:-Choose:} selected=1 key tail redraw=0 result
  (($# == 0)) || shift
  (($# > 0)) || return 2

  trap 'ui::_terminal_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ui::_terminal_begin key 1 || return
  ui::_choose_render "${selected}" 0 "${prompt}" "$@"
  while :; do
    ui::_read_key key || return 130
    case ${key} in
      $'\033')
        ui::_read_escape_tail tail || tail=
        case ${tail} in
          '[A') ((selected > 1)) && selected=$((selected - 1)) ;;
          '[B') ((selected < $#)) && selected=$((selected + 1)) ;;
          '') return 130 ;;
        esac
        redraw=1
        ;;
      '' | $'\r' | $'\n') break ;;
      k)
        ((selected > 1)) && selected=$((selected - 1))
        redraw=1
        ;;
      j)
        ((selected < $#)) && selected=$((selected + 1))
        redraw=1
        ;;
      $'\003' | $'\004' | q | Q) return 130 ;;
    esac
    ((redraw == 0)) || ui::_choose_render "${selected}" 1 "${prompt}" "$@"
    redraw=0
  done

  result=$(ui::_nth_argument "${selected}" "$@")
  printf '%s\n' "${result}"
)

ui::input() (
  local prompt=${1:-Value} default='' placeholder='' secret=0 mask='' hidden=0 value display_hint=''
  (($# == 0)) || shift
  while (($# > 0)); do
    case $1 in
      --default)
        default=${2:-}
        shift 2
        ;;
      --placeholder)
        placeholder=${2:-}
        shift 2
        ;;
      --secret)
        secret=1
        shift
        ;;
      --mask)
        mask='•'
        shift
        ;;
      --mask-char)
        mask=${2:-}
        shift 2
        ;;
      --hidden)
        hidden=1
        secret=1
        mask=''
        shift
        ;;
      *) return 2 ;;
    esac
  done

  # Secret input defaults to bullet masking unless explicitly requested hidden
  if ((secret && hidden == 0)) && [[ -z ${mask} ]]; then
    mask='•'
  fi

  trap 'ui::_terminal_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ -n ${mask} ]]; then
    ui::_terminal_begin key 0 || return
  elif ((secret)); then
    ui::_terminal_begin secret 0 || return
  else
    ui::_terminal_begin line 0 || return
  fi

  if [[ -n ${default} ]]; then
    display_hint=" [${default}]"
  elif [[ -n ${placeholder} ]]; then
    display_hint=" (${placeholder})"
  fi

  printf '%s%s: ' "$(ui::style --fg ACCENT_SECONDARY --bold -- "${prompt}")" \
    "$(ui::style --fg TEXT_MUTED -- "${display_hint}")" >&"${UI_ACTIVE_OUTPUT_FD}"
  if [[ -n ${mask} ]]; then
    value=$(ui::_read_masked "${mask}") || return
  else
    IFS= read -r -u "${UI_ACTIVE_INPUT_FD}" value || [[ -n ${value} ]] || return 130
    ((secret == 0)) || printf '\n' >&"${UI_ACTIVE_OUTPUT_FD}"
  fi
  if [[ ${value} == *$'\003'* || ${value} == *$'\004'* ]]; then
    return 130
  fi
  [[ -n ${value} ]] || value=${default}
  printf '%s\n' "${value}"
)

ui::_spinner_pause() {
  IFS= read -r -t "${UI_SPINNER_INTERVAL}" -u "${UI_INPUT_FD}" || true
}

ui::_job_running() {
  local target_pid=$1 active_jobs
  # Unlike kill -0, the job table excludes completed children waiting to be reaped.
  active_jobs=$(jobs -pr)
  case $'\n'${active_jobs}$'\n' in
    *$'\n'"${target_pid}"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

ui::spin() {
  local target_pid=${1:-} message=${2:-Working} frame exit_status interactive=0
  local interrupted=0 old_hup old_int old_term
  local -a frames=()
  while IFS= read -r frame; do
    frames+=("${frame}")
  done < <(ui::spinner_frames)

  [[ ${target_pid} == *[!0-9]* || -z ${target_pid} ]] && return 2
  old_hup=$(trap -p HUP)
  old_int=$(trap -p INT)
  old_term=$(trap -p TERM)
  trap 'interrupted=129' HUP
  trap 'interrupted=130' INT
  trap 'interrupted=143' TERM

  if [[ -t ${UI_OUTPUT_FD} && -t ${UI_INPUT_FD} && ${TERM:-} != dumb ]]; then
    interactive=1
    printf '\033[?25l' >&"${UI_OUTPUT_FD}"
  else
    printf '%s\n' "${message}" >&"${UI_OUTPUT_FD}"
  fi

  if ((interactive)); then
    while ui::_job_running "${target_pid}" && ((interrupted == 0)); do
      for frame in "${frames[@]}"; do
        ui::_job_running "${target_pid}" || break
        printf '\r\033[2K%s %s' "$(ui::style --fg ACCENT_SECONDARY -- "${frame}")" "${message}" >&"${UI_OUTPUT_FD}"
        ui::_spinner_pause
        ((interrupted == 0)) || break
      done
    done
  fi

  if ((interrupted)); then
    kill "${target_pid}" 2> /dev/null || true
  fi
  if wait "${target_pid}"; then
    exit_status=0
  else
    exit_status=$?
  fi
  ((interrupted == 0)) || exit_status=${interrupted}

  if ((interactive)); then
    printf '\r\033[2K\033[?25h' >&"${UI_OUTPUT_FD}"
  fi
  if ((exit_status == 0)); then
    printf '%s %s\n' "$(ui::style --fg SUCCESS --bold -- '✓')" "${message}" >&"${UI_OUTPUT_FD}"
  else
    printf '%s %s\n' "$(ui::style --fg ERROR --bold -- '✗')" "${message}" >&"${UI_OUTPUT_FD}"
  fi

  [[ -z ${old_hup} ]] && trap - HUP || eval "${old_hup}"
  [[ -z ${old_int} ]] && trap - INT || eval "${old_int}"
  [[ -z ${old_term} ]] && trap - TERM || eval "${old_term}"
  return "${exit_status}"
}
