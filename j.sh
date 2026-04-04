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
    JSH_UI_DIM=$(printf '\033[2m')
    JSH_UI_RED=$(printf '\033[31m')
    JSH_UI_GREEN=$(printf '\033[32m')
    JSH_UI_YELLOW=$(printf '\033[33m')
    JSH_UI_CYAN=$(printf '\033[36m')
  else
    JSH_UI_RESET=''
    JSH_UI_BOLD=''
    JSH_UI_DIM=''
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
    warning)
      JSH_UI_COLOR=${JSH_UI_YELLOW}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='▲' || JSH_UI_MARK=warn
      ;;
    note)
      JSH_UI_COLOR=${JSH_UI_CYAN}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='›' || JSH_UI_MARK=note
      ;;
    info)
      JSH_UI_COLOR=${JSH_UI_DIM}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='•' || JSH_UI_MARK=info
      ;;
    error)
      JSH_UI_COLOR=${JSH_UI_RED}
      [ "${JSH_UI_RICH}" = 1 ] && JSH_UI_MARK='✖' || JSH_UI_MARK=error
      ;;
    *)
      JSH_UI_COLOR=${JSH_UI_DIM}
      JSH_UI_MARK=$1
      ;;
  esac
}

jsh_ui_row() {
  status=$1
  message=$2
  stream=${3:-stdout}
  jsh_ui_init
  jsh_ui_status "${status}"
  [ "${JSH_UI_RICH}" = 1 ] || JSH_UI_MARK="[${JSH_UI_MARK}]"
  if [ "${stream}" = stderr ]; then
    printf '%s%s%s %s\n' "${JSH_UI_COLOR}" "${JSH_UI_MARK}" "${JSH_UI_RESET}" "${message}" >&2
  else
    printf '%s%s%s %s\n' "${JSH_UI_COLOR}" "${JSH_UI_MARK}" "${JSH_UI_RESET}" "${message}"
  fi
}

jsh_display_path() {
  case "$1" in
    "${HOME}") printf '~\n' ;;
    "${HOME}"/*) printf '%s/%s\n' '~' "${1#"${HOME}"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

jsh_display_repo() {
  case "$1" in
    [Hh][Tt][Tt][Pp]://* | [Hh][Tt][Tt][Pp][Ss]://*)
      printf '%s\n' "$1" | sed 's#^\([^:]*://\)[^/@]*@#\1#'
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

jsh_ui_heading() {
  jsh_ui_init
  printf '\n%s%s%s%s\n' "${JSH_UI_BOLD}" "${JSH_UI_CYAN}" "$1" "${JSH_UI_RESET}"
}

jsh_banner() {
  jsh_ui_init
  printf '%s%s' "${JSH_UI_BOLD}" "${JSH_UI_CYAN}"
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
  printf '%s\n' "${JSH_UI_RESET}"
}

jsh_spinner_start() {
  JSH_SPINNER_LABEL=$1
  JSH_SPINNER_STARTED=$(date +%s 2>/dev/null || printf 0)
  JSH_SPINNER_PID=
  jsh_ui_init
  if [ "${JSH_SPINNER:-auto}" = never ] || [ "${JSH_UI_RICH}" != 1 ] || [ ! -t 2 ]; then
    return 0
  fi

  (
    visible=0
    trap '[ "${visible}" = 0 ] || printf "\033[?25h\r\033[K" >&2' 0
    trap 'exit 0' 1 2 15
    sleep "${JSH_SPINNER_DELAY:-1}"
    visible=1
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
  fi
}

jsh_spinner_stop() {
  spinner_status=$1
  spinner_label=$2
  jsh_spinner_cleanup
  spinner_finished=$(date +%s 2>/dev/null || printf 0)
  spinner_elapsed=$((spinner_finished - JSH_SPINNER_STARTED))
  [ "${spinner_elapsed}" -ge 0 ] || spinner_elapsed=0
  if [ "${spinner_elapsed}" -ge 5 ]; then
    spinner_label="${spinner_label} (${spinner_elapsed}s)"
  fi
  if [ "${spinner_status}" = error ]; then
    jsh_ui_row error "${spinner_label}" stderr
  else
    jsh_ui_row "${spinner_status}" "${spinner_label}"
  fi
}

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

launch_if_jsh "$@" || fail 'Failed to resolve the jsh launcher'

JSH_TTY_STATE=

jsh_tty_restore() {
  if [ -n "${JSH_TTY_STATE}" ]; then
    stty "${JSH_TTY_STATE}" </dev/tty 2>/dev/null || true
    JSH_TTY_STATE=
  fi
}

jsh_read_key() {
  prompt=$1
  JSH_KEY=
  printf '%s' "${prompt}" >/dev/tty
  if command -v stty >/dev/null 2>&1 && command -v dd >/dev/null 2>&1 \
    && JSH_TTY_STATE=$(stty -g </dev/tty 2>/dev/null); then
    stty -icanon -echo min 1 time 0 </dev/tty
    JSH_KEY=$(dd bs=1 count=1 </dev/tty 2>/dev/null || true)
    jsh_tty_restore
  else
    IFS= read -r JSH_KEY </dev/tty || return 1
  fi
  printf '\n' >/dev/tty
}

jsh_interrupted() {
  trap - 1 2 15
  jsh_spinner_cleanup
  jsh_tty_restore
  jsh_ui_row error 'Interrupted' stderr
  exit 130
}

trap 'jsh_spinner_cleanup; jsh_tty_restore' 0
trap 'jsh_interrupted' 1 2 15

choose_mode() {
  if [ -n "${JSH_MODE:-}" ]; then
    case "${JSH_MODE}" in lite | full) return 0 ;; *) fail 'JSH_MODE must be lite or full' ;; esac
  fi

  if [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    jsh_ui_init
    printf '%s%sChoose a setup mode%s\n' "${JSH_UI_BOLD}" "${JSH_UI_CYAN}" "${JSH_UI_RESET}" >/dev/tty
    case "${COLUMNS:-}" in
      '' | *[!0-9]*) narrow=0 ;;
      *) [ "${COLUMNS}" -lt 72 ] && narrow=1 || narrow=0 ;;
    esac
    if [ "${narrow}" = 1 ]; then
      printf '  %sL%s  Lite\n      Isolated shell without HOME config links\n' \
        "${JSH_UI_CYAN}" "${JSH_UI_RESET}" >/dev/tty
      printf '  %sF%s  Full\n      Reversible HOME, XDG, and VS Code config links\n' \
        "${JSH_UI_CYAN}" "${JSH_UI_RESET}" >/dev/tty
    else
      printf '  %sL%s  Lite  Isolated shell without HOME config links\n' \
        "${JSH_UI_CYAN}" "${JSH_UI_RESET}" >/dev/tty
      printf '  %sF%s  Full  Reversible HOME, XDG, and VS Code config links\n' \
        "${JSH_UI_CYAN}" "${JSH_UI_RESET}" >/dev/tty
    fi
    jsh_read_key 'Mode [L]: ' || exit 130
    case "${JSH_KEY}" in
      '' | l | L) JSH_MODE=lite ;;
      f | F) JSH_MODE=full ;;
      *) fail 'Selection must be L or F' ;;
    esac
    export JSH_MODE
    return 0
  fi

  fail 'Noninteractive installation requires JSH_MODE=lite or JSH_MODE=full'
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

jsh_validate_existing_checkout() {
  [ -e "${install_dir}" ] || return 0
  [ -d "${install_dir}" ] || fail "Install path is not a directory (${install_dir})"
  checkout_root=$(git -C "${install_dir}" rev-parse --show-toplevel 2>/dev/null) \
    || fail "Existing path is not a Git checkout (${install_dir})"
  checkout_root=$(cd "${checkout_root}" && pwd -P)
  install_root=$(cd "${install_dir}" && pwd -P)
  [ "${checkout_root}" = "${install_root}" ] || fail 'Install path is not the checkout root'

  origin=$(git -C "${install_dir}" remote get-url origin 2>/dev/null) \
    || fail 'Existing checkout has no origin remote'
  [ "${origin}" = "${install_repo}" ] \
    || fail "Existing checkout origin does not match ${install_repo_display}"

  dirty=$(git -C "${install_dir}" status --porcelain --untracked-files=all --ignore-submodules=none)
  [ -z "${dirty}" ] || fail 'Existing checkout has local changes'
  git -C "${install_dir}" submodule foreach --quiet --recursive \
    "test -z \"\$(git status --porcelain --untracked-files=all)\"" >/dev/null 2>&1 \
    || fail 'A submodule has local changes'
}

prepare_checkout() {
  install_dir=$1
  install_repo=$2
  install_ref=$3

  command -v git >/dev/null 2>&1 || fail 'Git is required to clone or update jsh'

  case "${install_dir}" in
    '' | / | "${HOME}") fail "Install directory is unsafe (${install_dir})" ;;
    "${HOME}"/*) ;;
    *) fail 'JSH_INSTALL_DIR must be under HOME' ;;
  esac

  if [ ! -e "${install_dir}" ]; then
    mkdir -p "$(dirname "${install_dir}")"
    jsh_spinner_start 'Cloning repository'
    if git clone --quiet --recurse-submodules --branch "${install_ref}" \
      "${install_repo}" "${install_dir}" 2>/dev/null; then
      jsh_spinner_stop success 'Cloned repository'
    else
      jsh_spinner_stop error 'Failed to clone repository'
      exit 1
    fi
    jsh_ui_row success "Checkout is $(jsh_display_path "${install_dir}")"
    return 0
  fi

  jsh_validate_existing_checkout

  jsh_ui_row current "Checkout is $(jsh_display_path "${install_dir}")"
  jsh_spinner_start 'Fetching updates'
  if git -C "${install_dir}" fetch --quiet origin "${install_ref}" 2>/dev/null; then
    jsh_spinner_stop success 'Fetched updates'
  else
    jsh_spinner_stop error 'Failed to fetch updates'
    exit 1
  fi
  git -C "${install_dir}" merge-base --is-ancestor HEAD FETCH_HEAD \
    || fail 'Existing checkout has diverged'
  if [ "$(git -C "${install_dir}" rev-parse HEAD)" != "$(git -C "${install_dir}" rev-parse FETCH_HEAD)" ]; then
    git -C "${install_dir}" merge --quiet --ff-only FETCH_HEAD || fail 'Failed to fast-forward checkout'
    jsh_ui_row success 'Fast-forwarded checkout'
  fi
  jsh_spinner_start 'Updating submodules'
  if git -C "${install_dir}" submodule update --quiet --init --recursive; then
    jsh_spinner_stop success 'Updated submodules'
  else
    jsh_spinner_stop error 'Failed to update submodules'
    exit 1
  fi
  jsh_ui_row success 'Repository is up to date'
}

jsh_validate_install_dir() {
  case "$1" in
    '' | / | "${HOME}") fail "Install directory is unsafe ($1)" ;;
    "${HOME}"/*) ;;
    *) fail 'JSH_INSTALL_DIR must be under HOME' ;;
  esac
}

jsh_xcode_ready() {
  [ "$(uname -s 2>/dev/null)" != Darwin ] || {
    command -v xcode-select >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1
  }
}

jsh_xcode_plan() {
  if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
    jsh_ui_row current 'Apple Command Line Tools are not required'
  elif jsh_xcode_ready; then
    jsh_ui_row current 'Apple Command Line Tools are ready'
  else
    jsh_ui_row plan 'Would install Apple Command Line Tools'
  fi
}

jsh_install_xcode_tools() {
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0
  jsh_xcode_ready && return 0
  command -v xcode-select >/dev/null 2>&1 || fail 'xcode-select is unavailable'

  if ! xcode-select --install >/dev/null 2>&1; then
    fail 'Failed to start Apple Command Line Tools installation'
  fi

  attempts=${JSH_XCODE_WAIT_ATTEMPTS:-900}
  interval=${JSH_XCODE_POLL_INTERVAL:-2}
  case "${attempts}" in '' | *[!0-9]*) attempts=900 ;; esac
  case "${interval}" in '' | *[!0-9]*) interval=2 ;; esac
  jsh_spinner_start 'Waiting for Command Line Tools'
  while [ "${attempts}" -gt 0 ]; do
    if jsh_xcode_ready; then
      jsh_spinner_stop success 'Apple Command Line Tools are ready'
      return 0
    fi
    attempts=$((attempts - 1))
    sleep "${interval}"
  done
  jsh_spinner_stop error 'Failed to install Apple Command Line Tools'
  jsh_ui_row note 'Complete Apple Command Line Tools installation, then rerun jsh' stderr
  exit 1
}

jsh_parse_options() {
  JSH_ASSUME_YES=0
  JSH_DRY_RUN=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes | -y) JSH_ASSUME_YES=1 ;;
      --dry-run | -n) JSH_DRY_RUN=1 ;;
      *)
        jsh_ui_row error "Unknown installer option '$1'" stderr
        printf 'Usage: sh j.sh [-n|--dry-run] [-y|--yes]\n' >&2
        jsh_ui_row note 'Run sh j.sh --dry-run to preview installation' stderr
        exit 2
        ;;
    esac
    shift
  done
}

jsh_install_plan() {
  mode_label=Lite
  config_detail='launcher only; HOME and XDG configs stay untouched'
  if [ "${JSH_MODE}" = full ]; then
    mode_label=Full
    config_detail='launcher plus reversible HOME, XDG, and VS Code config links'
  fi

  if [ -n "${JSH_BIN_DIR:-}" ]; then
    case "${JSH_BIN_DIR}" in
      /*) launcher_detail="${JSH_BIN_DIR%/}/jsh" ;;
      *) fail 'JSH_BIN_DIR must be an absolute path' ;;
    esac
  elif [ -w /usr/local/bin ] || { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; then
    launcher_detail=/usr/local/bin/jsh
  else
    launcher_detail="${HOME}/.local/bin/jsh"
  fi
  install_display=$(jsh_display_path "${install_dir}")
  launcher_display=$(jsh_display_path "${launcher_detail}")

  jsh_ui_heading Install
  jsh_ui_row info "Mode is ${mode_label}"
  if [ -n "${local_checkout}" ]; then
    jsh_ui_row current "Checkout is ${install_display}"
  elif [ -e "${install_dir}" ]; then
    jsh_ui_row plan "Would update ${install_display}"
  else
    jsh_ui_row plan "Would clone ${install_repo_display} to ${install_display}"
  fi
  jsh_ui_row info "Launcher is ${launcher_display}"
  jsh_ui_row info "Configuration is ${config_detail}"
  jsh_ui_heading Prerequisite
  jsh_xcode_plan
}

jsh_confirm_install() {
  [ "${JSH_ASSUME_YES}" = 0 ] || return 0
  [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ] || fail 'Noninteractive installation requires --yes'
  jsh_read_key 'Continue? [y/N] ' || exit 130
  case "${JSH_KEY}" in
    y | Y) ;;
    *)
      jsh_ui_row note 'Installation was cancelled'
      exit 1
      ;;
  esac
}

jsh_parse_options "$@"
jsh_banner
[ "$(id -u)" -ne 0 ] || fail 'Do not run the installer as root'
command -v bash >/dev/null 2>&1 || fail 'Bash is required'
choose_mode
install_mode=runtime
[ "${JSH_MODE}" != full ] || install_mode=install

local_checkout=$(resolve_local_checkout 2>/dev/null || true)
if [ -n "${local_checkout}" ]; then
  install_dir=${JSH_INSTALL_DIR:-${local_checkout}}
  [ "$(cd "${install_dir}" 2>/dev/null && pwd -P)" = "${local_checkout}" ] \
    || fail 'JSH_INSTALL_DIR cannot redirect a local j.sh execution'
else
  install_dir=${JSH_INSTALL_DIR:-"${HOME}/.jsh"}
  install_repo=${JSH_INSTALL_REPO:-https://github.com/jovalle/jsh.git}
  install_repo_display=$(jsh_display_repo "${install_repo}")
  install_ref=${JSH_INSTALL_REF:-main}
  jsh_validate_install_dir "${install_dir}"
  command -v git >/dev/null 2>&1 || fail 'Git is required to clone or update jsh'
  jsh_validate_existing_checkout
fi

jsh_install_plan
if [ "${JSH_DRY_RUN}" = 1 ]; then
  if [ -n "${local_checkout}" ]; then
    JSH_DIR="${install_dir}" JSH_BANNER_SHOWN=1 \
      bash "${install_dir}/bin/jsh" install --mode "${install_mode}" --dry-run
  else
    jsh_ui_row plan 'Would finish without creating a checkout'
  fi
  exit 0
fi

jsh_confirm_install
jsh_install_xcode_tools
jsh_ui_heading 'Preparing checkout'
if [ -n "${local_checkout}" ]; then
  jsh_ui_row current "Checkout is $(jsh_display_path "${local_checkout}")"
else
  prepare_checkout "${install_dir}" "${install_repo}" "${install_ref}"
fi

JSH_DIR="${install_dir}" JSH_BANNER_SHOWN=1 \
  bash "${install_dir}/bin/jsh" install --mode "${install_mode}"
