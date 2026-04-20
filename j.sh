#!/bin/sh

set -eu

# j.sh is intentionally small and portable: it is the curl-friendly entry
# point that acquires a checkout before handing all setup work to `jsh install`.

jsh_bootstrap_error() {
  jsh_ui_init 2
  jsh_ui_style error
  printf '%s%s%s jsh: %s\n' "${JSH_UI_COLOR}" "${JSH_UI_MARK}" "${JSH_UI_RESET}" "$*" >&2
  exit 1
}

jsh_ui_init() {
  jsh_ui_output_fd=${1:-1}
  JSH_UI_BOLD=''
  JSH_UI_CYAN=''
  JSH_UI_RED=''
  JSH_UI_GREEN=''
  JSH_UI_YELLOW=''
  JSH_UI_RESET=''
  if [ "${JSH_PLAIN_OUTPUT:-0}" != 1 ] && [ "${TERM:-dumb}" != dumb ] \
    && [ -z "${NO_COLOR+x}" ]; then
    case "${JSH_COLOR:-auto}" in
      always) jsh_ui_color=1 ;;
      auto) if [ -t "${jsh_ui_output_fd}" ]; then jsh_ui_color=1; else jsh_ui_color=0; fi ;;
      *) jsh_ui_color=0 ;;
    esac
    if [ "${jsh_ui_color}" = 1 ]; then
      JSH_UI_BOLD=$(printf '\033[1m')
      JSH_UI_CYAN=$(printf '\033[36m')
      JSH_UI_RED=$(printf '\033[31m')
      JSH_UI_GREEN=$(printf '\033[32m')
      JSH_UI_YELLOW=$(printf '\033[33m')
      JSH_UI_RESET=$(printf '\033[0m')
    fi
  fi
}

jsh_ui_style() {
  case "$1" in
    plan)
      JSH_UI_COLOR=${JSH_UI_CYAN}
      if [ -n "${JSH_UI_RESET}" ]; then JSH_UI_MARK='➜'; else JSH_UI_MARK='[plan]'; fi
      ;;
    note)
      JSH_UI_COLOR=${JSH_UI_CYAN}
      if [ -n "${JSH_UI_RESET}" ]; then JSH_UI_MARK='›'; else JSH_UI_MARK='[note]'; fi
      ;;
    error)
      JSH_UI_COLOR=${JSH_UI_RED}
      if [ -n "${JSH_UI_RESET}" ]; then JSH_UI_MARK='✖'; else JSH_UI_MARK='[error]'; fi
      ;;
  esac
}

jsh_ui_message() {
  jsh_ui_style "$1"
  shift
  printf '%s%s%s %s\n' "${JSH_UI_COLOR}" "${JSH_UI_MARK}" "${JSH_UI_RESET}" "$*"
}

jsh_banner() {
  jsh_ui_init
  printf '\n%s%s' "${JSH_UI_BOLD}" "${JSH_UI_CYAN}"
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

jsh_bootstrap_script_dir() {
  jsh_bootstrap_script_path=$1
  while [ -L "${jsh_bootstrap_script_path}" ]; do
    jsh_bootstrap_parent=$(CDPATH='' cd -- "$(dirname -- "${jsh_bootstrap_script_path}")" 2>/dev/null && pwd -P) \
      || return 1
    jsh_bootstrap_link_target=$(readlink "${jsh_bootstrap_script_path}") || return 1
    case "${jsh_bootstrap_link_target}" in
      /*) jsh_bootstrap_script_path=${jsh_bootstrap_link_target} ;;
      *) jsh_bootstrap_script_path=${jsh_bootstrap_parent}/${jsh_bootstrap_link_target} ;;
    esac
  done
  CDPATH='' cd -- "$(dirname -- "${jsh_bootstrap_script_path}")" 2>/dev/null && pwd -P
}

jsh_bootstrap_dry_run=0
jsh_bootstrap_yes=0
jsh_bootstrap_mode=${JSH_MODE:-}
jsh_bootstrap_mode_value=0
for jsh_bootstrap_argument; do
  case "${jsh_bootstrap_argument}" in
    --dry-run | -n) jsh_bootstrap_dry_run=1 ;;
    --yes | -y) jsh_bootstrap_yes=1 ;;
    --mode)
      jsh_bootstrap_mode_value=1
      ;;
    --mode=*)
      case "${jsh_bootstrap_argument#*=}" in
        lite | runtime) jsh_bootstrap_mode=lite ;;
        full | install) jsh_bootstrap_mode=full ;;
        *) jsh_bootstrap_error 'Mode must be lite or full' ;;
      esac
      ;;
    *)
      if [ "${jsh_bootstrap_mode_value}" = 1 ]; then
        case "${jsh_bootstrap_argument}" in
          lite | runtime) jsh_bootstrap_mode=lite ;;
          full | install) jsh_bootstrap_mode=full ;;
          *) jsh_bootstrap_error 'Mode must be lite or full' ;;
        esac
        jsh_bootstrap_mode_value=0
      fi
      ;;
  esac
done
[ "${jsh_bootstrap_mode_value}" = 0 ] || jsh_bootstrap_error 'Missing value for --mode'

jsh_bootstrap_local=0
jsh_bootstrap_local_dir=
case "$0" in
  */j.sh | j.sh)
    jsh_bootstrap_local_dir=$(jsh_bootstrap_script_dir "$0" 2>/dev/null || true)
    if [ -n "${jsh_bootstrap_local_dir}" ] && [ -f "${jsh_bootstrap_local_dir}/bin/jsh" ]; then
      jsh_bootstrap_local=1
    fi
    ;;
esac

if [ "${jsh_bootstrap_local}" = 1 ]; then
  command -v bash >/dev/null 2>&1 || jsh_bootstrap_error 'Bash is required to run jsh'
  JSH_DIR="${jsh_bootstrap_local_dir}" exec bash "${jsh_bootstrap_local_dir}/bin/jsh" install "$@"
fi

jsh_bootstrap_home=${HOME:-}
[ -n "${jsh_bootstrap_home}" ] || jsh_bootstrap_error 'HOME is not set'
jsh_bootstrap_install_dir=${JSH_INSTALL_DIR:-${jsh_bootstrap_home}/.jsh}
case "${jsh_bootstrap_install_dir}" in
  '' | / | "${jsh_bootstrap_home}")
    jsh_bootstrap_error "unsafe install directory: ${jsh_bootstrap_install_dir}"
    ;;
  "${jsh_bootstrap_home}"/*) ;;
  *) jsh_bootstrap_error 'JSH_INSTALL_DIR must be under HOME' ;;
esac

if [ -f "${jsh_bootstrap_install_dir}/bin/jsh" ]; then
  command -v bash >/dev/null 2>&1 || jsh_bootstrap_error 'Bash is required to run jsh'
  JSH_DIR="${jsh_bootstrap_install_dir}" exec bash "${jsh_bootstrap_install_dir}/bin/jsh" install "$@"
fi

if [ -e "${jsh_bootstrap_install_dir}" ] || [ -L "${jsh_bootstrap_install_dir}" ]; then
  jsh_bootstrap_error "existing install path does not contain bin/jsh: ${jsh_bootstrap_install_dir}"
fi

jsh_bootstrap_repo=${JSH_INSTALL_REPO:-https://github.com/jovalle/jsh.git}
jsh_bootstrap_ref=${JSH_INSTALL_REF:-main}
command -v git >/dev/null 2>&1 || jsh_bootstrap_error 'Git is required to acquire jsh'

jsh_bootstrap_interactive=0
if [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
  jsh_bootstrap_interactive=1
fi
if [ "${jsh_bootstrap_interactive}" = 0 ] && [ -z "${jsh_bootstrap_mode}" ]; then
  jsh_bootstrap_error 'Noninteractive installation requires JSH_MODE=lite or JSH_MODE=full'
fi
if [ "${jsh_bootstrap_interactive}" = 0 ] && [ "${jsh_bootstrap_dry_run}" = 0 ] \
  && [ "${jsh_bootstrap_yes}" = 0 ]; then
  jsh_bootstrap_error 'Noninteractive installation requires --yes when a checkout must be acquired'
fi

if [ "${jsh_bootstrap_dry_run}" = 1 ]; then
  case "${jsh_bootstrap_mode:-lite}" in
    lite) jsh_bootstrap_plan_mode=lite ;;
    full) jsh_bootstrap_plan_mode=full ;;
    *) jsh_bootstrap_error 'JSH_MODE must be lite or full' ;;
  esac

  jsh_bootstrap_source_bin=
  case "${jsh_bootstrap_repo}" in
    /* | ./* | ../*)
      jsh_bootstrap_repo_dir=$(CDPATH='' cd -- "${jsh_bootstrap_repo}" 2>/dev/null && pwd -P || true)
      [ -z "${jsh_bootstrap_repo_dir}" ] || jsh_bootstrap_source_bin=${jsh_bootstrap_repo_dir}/bin/jsh
      ;;
    file://*)
      jsh_bootstrap_repo_dir=$(CDPATH='' cd -- "${jsh_bootstrap_repo#file://}" 2>/dev/null && pwd -P || true)
      [ -z "${jsh_bootstrap_repo_dir}" ] || jsh_bootstrap_source_bin=${jsh_bootstrap_repo_dir}/bin/jsh
      ;;
  esac
  if [ -n "${jsh_bootstrap_source_bin}" ] && [ -f "${jsh_bootstrap_source_bin}" ]; then
    JSH_DIR="${jsh_bootstrap_repo_dir}" \
      JSH_INSTALL_DIR="${jsh_bootstrap_install_dir}" \
      exec bash "${jsh_bootstrap_source_bin}" install "$@"
  fi

  jsh_banner
  printf '%s%sSetup plan (%s)%s\n' "${JSH_UI_BOLD}" "${JSH_UI_CYAN}" \
    "${jsh_bootstrap_plan_mode}" "${JSH_UI_RESET}"
  jsh_ui_message plan "Git checkout                  clone ${jsh_bootstrap_install_dir} at ${jsh_bootstrap_ref}"
  jsh_ui_message note 'Dry run: no checkout, packages, submodules, or links were changed'
  exit 0
fi

mkdir -p "$(dirname -- "${jsh_bootstrap_install_dir}")" \
  || jsh_bootstrap_error "cannot create install parent: $(dirname -- "${jsh_bootstrap_install_dir}")"
if ! git clone --quiet --branch "${jsh_bootstrap_ref}" \
  "${jsh_bootstrap_repo}" "${jsh_bootstrap_install_dir}"; then
  jsh_bootstrap_error 'failed to acquire the jsh checkout'
fi

command -v bash >/dev/null 2>&1 || jsh_bootstrap_error 'Bash is required to run jsh'
JSH_DIR="${jsh_bootstrap_install_dir}" exec bash "${jsh_bootstrap_install_dir}/bin/jsh" install "$@"
