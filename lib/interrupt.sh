#!/usr/bin/env bash
# Clean up registered staging paths and preserve conventional signal statuses.

if [[ ${JSH_INTERRUPT_INITIALIZED:-0} != 1 ]]; then
  JSH_INTERRUPT_INITIALIZED=1
  JSH_INTERRUPT_PATHS=
  JSH_INTERRUPT_ROOT_PATHS=

  jsh_interrupt_cleanup_path() {
    [[ -n ${1:-} ]] || return 2
    JSH_INTERRUPT_PATHS="$1
${JSH_INTERRUPT_PATHS}"
  }

  jsh_interrupt_cleanup_root_path() {
    [[ -n ${1:-} ]] || return 2
    JSH_INTERRUPT_ROOT_PATHS="$1
${JSH_INTERRUPT_ROOT_PATHS}"
  }

  jsh_interrupt_cleanup() {
    local cleanup_target
    trap - HUP INT TERM
    if typeset -f jsh::cleanup >/dev/null 2>&1; then
      jsh::cleanup
    elif typeset -f jsh_spinner_stop >/dev/null 2>&1; then
      jsh_spinner_stop
    elif typeset -f jsh::sudo_keepalive_stop >/dev/null 2>&1; then
      jsh::sudo_keepalive_stop
    fi
    while IFS= read -r cleanup_target; do
      [[ -n ${cleanup_target} ]] && rm -rf -- "${cleanup_target}" 2>/dev/null || true
    done <<EOF
${JSH_INTERRUPT_PATHS}
EOF
    while IFS= read -r cleanup_target; do
      [[ -n ${cleanup_target} ]] || continue
      if [[ $(id -u) == 0 ]]; then
        rm -rf -- "${cleanup_target}" 2>/dev/null || true
      elif command -v sudo >/dev/null 2>&1; then
        sudo -n rm -rf -- "${cleanup_target}" >/dev/null 2>&1 || true
      fi
    done <<EOF
${JSH_INTERRUPT_ROOT_PATHS}
EOF
  }

  jsh_interrupt_handler() {
    local signal=$1 exit_code=$2
    jsh_interrupt_cleanup
    if [[ ${signal} == INT && ${JSH_INTERRUPT_REPORT:-1} == 1 ]]; then
      printf '\nInterrupted.\n' >&2
    fi
    exit "${exit_code}"
  }

  trap 'jsh_interrupt_handler HUP 129' HUP
  trap 'jsh_interrupt_handler INT 130' INT
  trap 'jsh_interrupt_handler TERM 143' TERM
fi
