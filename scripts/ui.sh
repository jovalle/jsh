#!/bin/sh

jsh_ui_color_enabled() {
  jsh_ui_fd=${1:-1}
  [ "${JSH_PLAIN_OUTPUT:-0}" != 1 ] || return 1
  [ "${TERM:-dumb}" != dumb ] || return 1
  [ -z "${NO_COLOR+x}" ] || return 1
  case "${JSH_COLOR:-auto}" in
    always) return 0 ;;
    auto) [ -t "${jsh_ui_fd}" ] ;;
    *) return 1 ;;
  esac
}

jsh_ui_message() {
  jsh_ui_state=$1
  shift
  jsh_ui_color=''
  jsh_ui_reset=''
  jsh_ui_stream=1

  case ${jsh_ui_state} in
    success) jsh_ui_code=32; jsh_ui_mark='✔'; jsh_ui_plain_mark='[ok]' ;;
    warn | warning) jsh_ui_code=33; jsh_ui_mark='▲'; jsh_ui_plain_mark='[warn]'; jsh_ui_stream=2 ;;
    error | fail) jsh_ui_code=31; jsh_ui_mark='✖'; jsh_ui_plain_mark='[error]'; jsh_ui_stream=2 ;;
    plan) jsh_ui_code=36; jsh_ui_mark='➜'; jsh_ui_plain_mark='[plan]' ;;
    *) jsh_ui_code=36; jsh_ui_mark='›'; jsh_ui_plain_mark='[note]' ;;
  esac

  if jsh_ui_color_enabled "${jsh_ui_stream}"; then
    jsh_ui_color=$(printf '\033[%sm' "${jsh_ui_code}")
    jsh_ui_reset=$(printf '\033[0m')
    jsh_ui_plain_mark=${jsh_ui_mark}
  fi

  if [ "${jsh_ui_stream}" = 2 ]; then
    printf '%s%s%s %s\n' "${jsh_ui_color}" "${jsh_ui_plain_mark}" "${jsh_ui_reset}" "$*" >&2
  else
    printf '%s%s%s %s\n' "${jsh_ui_color}" "${jsh_ui_plain_mark}" "${jsh_ui_reset}" "$*"
  fi
}

jsh_info() { jsh_ui_message info "$@"; }
jsh_success() { jsh_ui_message success "$@"; }
jsh_warn() { jsh_ui_message warn "$@"; }
jsh_error() { jsh_ui_message error "$@"; }
