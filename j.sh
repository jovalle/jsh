#!/bin/sh

set -eu

jsh_ui_init() {
  JSH_UI_RICH=0
  if [ "${JSH_PLAIN_OUTPUT:-0}" != 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    case "${JSH_COLOR:-auto}" in
      always) JSH_UI_RICH=1 ;;
      auto) [ -t 1 ] && JSH_UI_RICH=1 ;;
    esac
  fi
  if [ "${JSH_UI_RICH}" = 1 ]; then
    JSH_UI_RESET=$(printf '\033[0m')
    JSH_UI_BOLD=$(printf '\033[1m')
    JSH_UI_RED=$(printf '\033[31m')
    JSH_UI_GREEN=$(printf '\033[32m')
    JSH_UI_YELLOW=$(printf '\033[33m')
    JSH_UI_CYAN=$(printf '\033[36m')
  else
    JSH_UI_RESET=''
    JSH_UI_BOLD=''
    JSH_UI_RED=''
    JSH_UI_GREEN=''
    JSH_UI_YELLOW=''
    JSH_UI_CYAN=''
  fi
}

jsh_ui_status() {
  case "$1" in
    current | success)
      JSH_UI_COLOR=${JSH_UI_GREEN}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='✔' || JSH_UI_MARK=ok
      ;;
    plan)
      JSH_UI_COLOR=${JSH_UI_CYAN}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='➜' || JSH_UI_MARK=plan
      ;;
    warning | changed)
      JSH_UI_COLOR=${JSH_UI_YELLOW}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='▲' || JSH_UI_MARK=warn
      ;;
    *)
      JSH_UI_COLOR=${JSH_UI_RED}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='✖' || JSH_UI_MARK=error
      ;;
  esac
}

jsh_ui_stage() {
  jsh_ui_init
  printf '\n%s%s[%s/%s] %s%s\n' \
    "${JSH_UI_BOLD}" "${JSH_UI_CYAN}" "$1" "$2" "$3" "${JSH_UI_RESET}"
}

jsh_ui_row() {
  status=$1
  key=$2
  value=${3:-}
  position=${4:-more}
  jsh_ui_init
  jsh_ui_status "${status}"
  if [ "${JSH_UI_RICH}" = 1 ]; then
    [ "${position}" = last ] && connector='└──' || connector='├──'
  else
    [ "${position}" = last ] && connector='\--' || connector='|--'
    JSH_UI_MARK="[${JSH_UI_MARK}]"
  fi
  tilde='~'
  case "${value}" in
    "${HOME}") value='~' ;;
    "${HOME}"/*) value="${tilde}/${value#"${HOME}"/}" ;;
  esac
  dot_count=$((28 - ${#key}))
  [ "${dot_count}" -ge 3 ] || dot_count=3
  dots=
  while [ "${dot_count}" -gt 0 ]; do
    dots="${dots}."
    dot_count=$((dot_count - 1))
  done
  printf '  %s %s %s %s%s%s %s\n' \
    "${connector}" "${key}" "${dots}" "${JSH_UI_COLOR}" "${JSH_UI_MARK}" "${JSH_UI_RESET}" "${value}"
}

jsh_ui_heading() {
  jsh_ui_init
  printf '\n%s%s%s%s\n' "${JSH_UI_BOLD}" "${JSH_UI_CYAN}" "$1" "${JSH_UI_RESET}"
}

jsh_spinner_start() {
  JSH_SPINNER_LABEL=$1
  JSH_SPINNER_STARTED=$(date +%s 2>/dev/null || printf 0)
  JSH_SPINNER_PID=
  if [ "${JSH_SPINNER:-auto}" = never ] || [ "${JSH_PLAIN_OUTPUT:-0}" = 1 ] \
    || [ "${TERM:-dumb}" = dumb ] || [ -n "${NO_COLOR+x}" ] || [ ! -t 2 ]; then
    return 0
  fi

  (
    trap 'printf "\033[?25h\r\033[K" >&2' 0
    trap 'exit 0' 1 2 15
    frame=0
    printf '\033[?25l' >&2
    while :; do
      case "${frame}" in
        0) glyph='⠋' ;; 1) glyph='⠙' ;; 2) glyph='⠹' ;; 3) glyph='⠸' ;; 4) glyph='⠼' ;;
        5) glyph='⠴' ;; 6) glyph='⠦' ;; 7) glyph='⠧' ;; 8) glyph='⠇' ;; *) glyph='⠏' ;;
      esac
      printf '\r\033[K%s %s' "${glyph}" "${JSH_SPINNER_LABEL}" >&2
      frame=$(((frame + 1) % 10))
      sleep 0.1
    done
  ) &
  JSH_SPINNER_PID=$!
}

jsh_spinner_cleanup() {
  if [ -n "${JSH_SPINNER_PID:-}" ]; then
    kill "${JSH_SPINNER_PID}" 2>/dev/null || true
    wait "${JSH_SPINNER_PID}" 2>/dev/null || true
    JSH_SPINNER_PID=
    [ ! -t 2 ] || printf '\033[?25h\r\033[K' >&2
  fi
}

jsh_spinner_stop() {
  spinner_status=$1
  spinner_label=$2
  spinner_position=${3:-more}
  jsh_spinner_cleanup
  spinner_finished=$(date +%s 2>/dev/null || printf 0)
  spinner_elapsed=$((spinner_finished - JSH_SPINNER_STARTED))
  [ "${spinner_elapsed}" -ge 0 ] || spinner_elapsed=0
  jsh_ui_row "${spinner_status}" "${spinner_label}" "${spinner_elapsed}s" "${spinner_position}"
}

trap 'jsh_spinner_cleanup' 0
trap 'jsh_spinner_cleanup; exit 130' 1 2 15

fail() {
  jsh_ui_init
  jsh_ui_status error
  if [ "${JSH_UI_RICH}" = 1 ]; then
    printf '%s%s%s jsh: %s\n' "${JSH_UI_COLOR}" "${JSH_UI_MARK}" "${JSH_UI_RESET}" "$*" >&2
  else
    printf '[%s] jsh: %s\n' "${JSH_UI_MARK}" "$*" >&2
  fi
  exit 1
}

launch_if_jsh() {
  [ "${0##*/}" = jsh ] || return 0

  script_path=$0
  case "${script_path}" in */*) ;; *) script_path=$(command -v "${script_path}") || return 1 ;; esac
  while [ -L "${script_path}" ]; do
    script_dir=$(CDPATH='' cd -- "$(dirname -- "${script_path}")" 2>/dev/null && pwd -P) || return 1
    link_target=$(readlink "${script_path}") || return 1
    case "${link_target}" in
      /*) script_path=${link_target} ;;
      *) script_path=${script_dir}/${link_target} ;;
    esac
  done
  script_dir=$(CDPATH='' cd -- "$(dirname -- "${script_path}")" 2>/dev/null && pwd -P) || return 1
  exec "${script_dir}/bin/jsh" "$@"
}

launch_if_jsh "$@" || fail 'unable to resolve the jsh launcher'

choose_mode() {
  if [ -n "${JSH_MODE:-}" ]; then
    case "${JSH_MODE}" in runtime | install) return 0 ;; *) fail 'JSH_MODE must be runtime or install' ;; esac
  fi

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s\n' \
      'Choose how to enable jsh:' \
      '  [1] Runtime (recommended) - run jsh without linking dotfiles into HOME' \
      '  [2] Install               - manage reversible links in HOME and XDG config' \
      >/dev/tty
    printf 'Selection [1]: ' >/dev/tty
    IFS= read -r answer </dev/tty || exit 130
    case "${answer}" in
      '' | 1 | runtime) JSH_MODE=runtime ;;
      2 | install) JSH_MODE=install ;;
      *) fail 'selection must be 1 or 2' ;;
    esac
    export JSH_MODE
    return 0
  fi

  fail 'noninteractive install requires JSH_MODE=runtime or JSH_MODE=install'
}

resolve_local_checkout() {
  case "$0" in
    */j.sh | j.sh)
      script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || return 1
      [ -f "${script_dir}/bin/jsh" ] \
        && [ -f "${script_dir}/dotfiles/.bashrc" ] \
        && [ -f "${script_dir}/dotfiles/.zshrc" ] || return 1
      printf '%s\n' "${script_dir}"
      ;;
    *) return 1 ;;
  esac
}

prepare_checkout() {
  install_dir=$1
  install_repo=$2
  install_ref=$3

  command -v git >/dev/null 2>&1 || fail 'git is required to clone or update jsh'

  case "${install_dir}" in
    '' | / | "${HOME}") fail "unsafe install directory: ${install_dir}" ;;
    "${HOME}"/*) ;;
    *) fail 'JSH_INSTALL_DIR must be under HOME' ;;
  esac

  if [ ! -e "${install_dir}" ]; then
    mkdir -p "$(dirname "${install_dir}")"
    jsh_spinner_start 'Cloning repository'
    if git clone --quiet --recurse-submodules --branch "${install_ref}" \
      "${install_repo}" "${install_dir}"; then
      jsh_spinner_stop success 'Cloning repository'
    else
      jsh_spinner_stop error 'Cloning repository'
      fail 'clone failed'
    fi
    jsh_ui_row success Checkout "${install_dir}" last
    return 0
  fi

  [ -d "${install_dir}" ] || fail "install path is not a directory: ${install_dir}"
  checkout_root=$(git -C "${install_dir}" rev-parse --show-toplevel 2>/dev/null) \
    || fail "existing path is not a Git checkout: ${install_dir}"
  checkout_root=$(cd "${checkout_root}" && pwd -P)
  install_root=$(cd "${install_dir}" && pwd -P)
  [ "${checkout_root}" = "${install_root}" ] || fail 'install path is not the checkout root'

  origin=$(git -C "${install_dir}" remote get-url origin 2>/dev/null) \
    || fail 'existing checkout has no origin remote'
  [ "${origin}" = "${install_repo}" ] || fail "existing checkout origin does not match ${install_repo}"

  dirty=$(git -C "${install_dir}" status --porcelain --untracked-files=all --ignore-submodules=none)
  [ -z "${dirty}" ] || fail 'existing checkout has local changes; update refused'
  git -C "${install_dir}" submodule foreach --quiet --recursive \
    'test -z "$(git status --porcelain --untracked-files=all)"' >/dev/null 2>&1 \
    || fail 'a submodule has local changes; update refused'

  jsh_ui_row current Checkout "${install_dir}"
  jsh_spinner_start 'Fetching updates'
  if git -C "${install_dir}" fetch --quiet origin "${install_ref}"; then
    jsh_spinner_stop success 'Fetching updates'
  else
    jsh_spinner_stop error 'Fetching updates'
    fail 'fetch failed'
  fi
  git -C "${install_dir}" merge-base --is-ancestor HEAD FETCH_HEAD \
    || fail 'existing checkout has diverged; update refused'
  if [ "$(git -C "${install_dir}" rev-parse HEAD)" != "$(git -C "${install_dir}" rev-parse FETCH_HEAD)" ]; then
    jsh_ui_row changed Repository 'fast-forwarding checkout'
    git -C "${install_dir}" merge --quiet --ff-only FETCH_HEAD || fail 'fast-forward update failed'
  fi
  jsh_spinner_start 'Updating submodules'
  if git -C "${install_dir}" submodule update --quiet --init --recursive; then
    jsh_spinner_stop success 'Updating submodules'
  else
    jsh_spinner_stop error 'Updating submodules'
    fail 'submodule update failed'
  fi
  jsh_ui_row success Repository 'up to date' last
}

[ "$(id -u)" -ne 0 ] || fail 'do not run the installer as root'
command -v bash >/dev/null 2>&1 || fail 'bash is required'

choose_mode
jsh_ui_stage 1 3 'Preparing Checkout'

local_checkout=$(resolve_local_checkout 2>/dev/null || true)
if [ -n "${local_checkout}" ]; then
  install_dir=${JSH_INSTALL_DIR:-${local_checkout}}
  [ "$(cd "${install_dir}" 2>/dev/null && pwd -P)" = "${local_checkout}" ] \
    || fail 'JSH_INSTALL_DIR cannot redirect a local j.sh execution'
  jsh_ui_row current Checkout "${local_checkout}" last
else
  install_dir=${JSH_INSTALL_DIR:-"${HOME}/.jsh"}
  install_repo=${JSH_INSTALL_REPO:-https://github.com/jovalle/jsh.git}
  install_ref=${JSH_INSTALL_REF:-main}
  prepare_checkout "${install_dir}" "${install_repo}" "${install_ref}"
fi

JSH_DIR="${install_dir}" JSH_STAGE_OFFSET=1 JSH_STAGE_TOTAL=3 \
  bash "${install_dir}/bin/jsh" install --mode "${JSH_MODE}"

if command -v jsh >/dev/null 2>&1; then
  run_command=jsh
else
  link_state=${JSH_LINK_STATE:-${JSH_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/jsh}/managed-links}
  launcher_path=''
  if [ -r "${link_state}" ]; then
    while IFS='|' read -r source destination _; do
      [ "${source}" != "${install_dir}/bin/jsh" ] || launcher_path=${destination}
    done <"${link_state}"
  fi
  run_command=${launcher_path:-jsh}
fi
jsh_ui_heading Ready
jsh_ui_row success Command "${run_command}" last
