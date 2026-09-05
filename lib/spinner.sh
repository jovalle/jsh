#!/usr/bin/env bash

JSH_SPINNER_PID=
JSH_SPINNER_VISIBLE=0

jsh_spinner_static() {
  jsh_spinner_stop
  jsh_info "$*" >&2
}

jsh_spinner_start() {
  jsh_spinner_stop

  if [[ ! -t 2 || ${TERM:-} == dumb || ${JSH_PLAIN_OUTPUT:-0} == 1 ]]; then
    jsh_info "$*" >&2
    return
  fi

  JSH_SPINNER_VISIBLE=1
  (
    trap 'exit 0' INT TERM
    while :; do
      for frame in '|' '/' '-' "\\"; do
        printf '\r\033[36m%s\033[0m %s' "${frame}" "$*" >&2
        sleep 0.1
      done
    done
  ) &
  JSH_SPINNER_PID=$!
}

jsh_spinner_stop() {
  if [[ -n ${JSH_SPINNER_PID:-} ]]; then
    kill "${JSH_SPINNER_PID}" 2>/dev/null || true
    wait "${JSH_SPINNER_PID}" 2>/dev/null || true
  fi
  if [[ ${JSH_SPINNER_VISIBLE:-0} == 1 ]]; then
    printf '\r\033[2K' >&2
  fi
  JSH_SPINNER_PID=
  JSH_SPINNER_VISIBLE=0
}
