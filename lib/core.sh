#!/usr/bin/env bash
# Helpers for module scripts and bin tools: progress events, dry-run-aware commands, prompts.

export PATH="${PATH}:/usr/sbin:/sbin"

for _jsh_brew in /opt/homebrew /home/linuxbrew/.linuxbrew; do
  if ! command -v brew >/dev/null 2>&1 && [[ -x ${_jsh_brew}/bin/brew ]]; then
    export PATH="${_jsh_brew}/bin:${_jsh_brew}/sbin:${PATH}"
  fi
done
unset _jsh_brew

: "${JSH_ROOT:?JSH_ROOT must point to the checkout}"

# shellcheck source=lib/output.sh
. "${JSH_ROOT}/lib/output.sh"

# Usage: jsh::emit EVENT [TEXT]. Reports to the jsh runner, or prints when run by hand.
jsh::emit() {
  if [[ -n ${JSH_EVENTS:-} ]]; then
    printf '%s %s\n' "$1" "${2:-}" >&"${JSH_EVENTS}"
    return
  fi
  case $1 in
    added) printf '%s %s\n' "$(jsh::paint 1 32 +)" "$2" ;;
    changed) printf '%s %s\n' "$(jsh::paint 1 33 '~')" "$2" ;;
    removed) printf '%s %s\n' "$(jsh::paint 1 31 -)" "$2" ;;
    notice) jsh::log_warn "$2" ;;
    detail) printf '  %s\n' "$2" ;;
  esac
}

jsh::added() { jsh::emit added "$*"; }
jsh::detail() { jsh::emit detail "$*"; }
jsh::changed() { jsh::emit changed "$*"; }
jsh::removed() { jsh::emit removed "$*"; }
jsh::current() { jsh::emit current "${1:-1}"; }
jsh::progress() { jsh::emit progress "$*"; }
jsh::notice() { jsh::emit notice "$*"; }

jsh::run() {
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    local command
    command=$(printf ' %q' "$@")
    jsh::log_note "  › would run${command}"
  else
    "$@"
  fi
}

jsh::root() {
  if [[ ${JSH_USER_ONLY:-0} == 1 ]]; then
    jsh::notice 'System changes are available through jsh.'
    return 1
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 || ${EUID} == 0 ]]; then
    jsh::run "$@"
  else
    # Never leave automation waiting for a password.
    sudo -n -- "$@"
  fi
}

# Succeeds when system changes can run without a password prompt.
jsh::admin() {
  [[ ${EUID} == 0 ]] || sudo -n true >/dev/null 2>&1
}

jsh::confirm() {
  local answer
  [[ ${JSH_DRY_RUN:-0} != 1 && ${JSH_ASSUME_YES:-0} != 1 ]] || return 0
  if [[ ! -t 0 ]]; then
    jsh::log_warn 'Use --yes to apply changes without an interactive terminal.'
    return 1
  fi
  printf '%s %s %s ' "$(jsh::paint 1 '1;36' '?')" "$1" "$(jsh::paint 1 2 '(y/N)')"
  IFS= read -r -s -n 1 answer || return 1
  if [[ ${answer} == [yY] ]]; then
    printf 'y\n'
    return 0
  fi
  printf 'n\n'
  return 1
}
