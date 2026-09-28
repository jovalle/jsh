#!/usr/bin/env bash

set -eu

JSH_REPO=${JSH_REPO:-https://github.com/jovalle/jsh.git}
JSH_DIR=${JSH_DIR:-"${HOME}/.jsh"}
TTY=${JSH_TTY:-/dev/tty}

load_jsh_libraries() {
  local library_file
  for library_file in "${JSH_DIR}"/lib/*; do
    [[ -f ${library_file} && -x ${library_file} ]] || continue
    # shellcheck source=/dev/null
    . "${library_file}"
  done
}

load_jsh_libraries

if ! declare -F jsh_error > /dev/null; then
  # First installs run before the repository and its shared output library exist.
  jsh_color_enabled() {
    [[ "${JSH_PLAIN_OUTPUT:-0}" != 1 && "${TERM:-}" != dumb && -z "${NO_COLOR+x}" ]] || return 1
    [[ "${JSH_COLOR:-auto}" == always ]] ||
      { [[ "${JSH_COLOR:-auto}" != never ]] && [[ -t "$1" ]]; }
  }

  jsh_stdout() {
    local color=$1 prefix=$2
    shift 2
    if jsh_color_enabled 1; then
      printf '\033[%sm%s%s\033[0m\n' "${color}" "${prefix}" "$*"
    else
      printf '%s%s\n' "${prefix}" "$*"
    fi
  }

  jsh_stderr() {
    local color=$1 prefix=$2
    shift 2
    if jsh_color_enabled 2; then
      printf '\033[%sm%s%s\033[0m\n' "${color}" "${prefix}" "$*" >&2
    else
      printf '%s%s\n' "${prefix}" "$*" >&2
    fi
  }

  jsh_info() { jsh_stdout 36 '' "$*"; }
  jsh_note() { jsh_stdout '2;37' '' "$*"; }
  jsh_success() { jsh_stdout 32 '✓ ' "$*"; }
  jsh_warn() { jsh_stderr 33 '' "$*"; }
  jsh_warn_stdout() { jsh_stdout 33 '' "$*"; }
  jsh_error() { jsh_stderr 31 '✗ ' "$*"; }
  jsh_prompt() {
    if jsh_color_enabled 1; then
      printf '\033[33m%s\033[0m' "$*"
    else
      printf '%s' "$*"
    fi
  }
  jsh_detail() { printf '%s\n' "$*"; }
  jsh_blank() { printf '\n'; }
fi

if ! declare -F jsh_interrupt_handler > /dev/null; then
  trap 'trap - HUP INT TERM; exit 129' HUP
  trap 'trap - HUP INT TERM; printf "\nInterrupted.\n" >&2; exit 130' INT
  trap 'trap - HUP INT TERM; exit 143' TERM
fi

if ! declare -F jsh_banner > /dev/null; then
  jsh_banner() {
    local banner label=${1:-} left right
    if [[ -n ${SSH_CONNECTION:-} ]]; then
      [[ -z ${label} ]] || jsh_info "jsh ${label}"
      return 0
    fi
    left=$(((26 - ${#label}) / 2))
    right=$((26 - ${#label} - left))
    banner=$(
      cat << 'BANNER'
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
BANNER
    )
    printf -v banner '%s\n =   :-=-:%*s%s%*s-:' "${banner}" "${left}" '' "${label}" "${right}" ''
    jsh_blank
    jsh_stdout '1;36' '' "${banner}"
    jsh_blank
  }
fi

usage() {
  cat <<'EOF'
Usage: j.sh [-y|--yes] [runtime | setup [bare|lite|full] [OPTIONS] | update [--dry-run]]

With no arguments, prepare and open the isolated Jsh runtime.

Commands:
  runtime               Open the minimal, ephemeral runtime (default)
  setup PROFILE         Apply a persistent profile:
                          bare  launcher only
                          lite  bare plus managed dotfiles and default shell
                          full  lite plus packages, configuration, and patches
  update                Update Jsh and reapply the recorded profile

Setup options:
  --resume, --retry     Continue the last setup from its unfinished phases
  --from PHASE          Run PHASE and every phase after it
  --phase PHASE[,...]   Run only the named phases
  --list                Show the profile's phases and their last status
  --dry-run             Show what would run without changing anything (also for update)

Phases: prerequisites, repository, launcher, dotfiles, shell, packages, configure, patch
Runtime, bare, and lite never install packages; missing tools are reported instead.
Without a profile, setup reuses the recorded profile or asks for one.
Use -y or --yes to accept prompts for the selected command without interactive input.
EOF
}

usage_error() {
  jsh_error "$1"
  usage >&2
  exit 2
}

select_setup_mode() {
  [[ -z ${setup_selector} ]] || usage_error "Use only one of --resume, --from, or --phase."
  setup_selector=$1
  setup_phase_argument=${2:-}
}

mode=runtime
command_seen=0
dry_run=0
list_phases=0
install_profile=
setup_selector=
setup_phase_argument=
setup_option=
while (($#)); do
  case $1 in
    -y | --yes)
      export JSH_ASSUME_YES=1 JSH_CONFIGURE_ASSUME_YES=1 JSH_UPDATE_ASSUME_YES=1
      export JSH_NON_INTERACTIVE=1
      ;;
    --dry-run) dry_run=1 ;;
    --list)
      list_phases=1
      setup_option=${setup_option:-$1}
      ;;
    --resume | --retry)
      select_setup_mode resume
      setup_option=${setup_option:-$1}
      ;;
    --from | --phase)
      (($# > 1)) && [[ -n $2 && $2 != -* ]] || usage_error "$1 requires a phase name."
      select_setup_mode "${1#--}" "$2"
      setup_option=${setup_option:-$1}
      shift
      ;;
    --from=* | --phase=*)
      [[ -n ${1#*=} ]] || usage_error "${1%%=*} requires a phase name."
      setup_option=${setup_option:-${1%%=*}}
      option_name=${1%%=*}
      select_setup_mode "${option_name#--}" "${1#*=}"
      ;;
    runtime | setup | update)
      ((!command_seen)) || usage_error "Too many commands."
      mode=$1
      command_seen=1
      ;;
    bare | lite | full)
      [[ ${mode} == setup && -z ${install_profile} ]] || usage_error "Unknown argument: $1"
      install_profile=$1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "Unknown argument: $1" ;;
  esac
  shift
done

if [[ ${mode} != setup && -n ${setup_option} ]]; then
  usage_error "${setup_option} is only supported by setup."
fi
if ((dry_run)) && [[ ${mode} != setup && ${mode} != update ]]; then
  usage_error "--dry-run is only supported by setup and update."
fi
if ((dry_run || list_phases)); then
  export JSH_NON_INTERACTIVE=1
fi

declare -F jsh_env_detect > /dev/null && jsh_env_detect

if ! ( : <> "${TTY}" ) 2>/dev/null; then
  if [[ ${JSH_ASSUME_YES:-0} == 1 || ${JSH_NON_INTERACTIVE:-0} == 1 ]]; then
    TTY=/dev/null
  else
    jsh_error "jsh needs an interactive terminal."
    exit 1
  fi
fi

exec 8<> "${TTY}"
if declare -F jsh::init > /dev/null; then
  jsh::init --input-fd 8 --output-fd 8 --owns-fd
fi

if [[ -r /proc/self/status ]] && grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status; then
  if [[ ${mode} == setup || ${mode} == update ]] && ((!dry_run && !list_phases)); then
    jsh_error "This session prohibits privilege elevation. Run Jsh from a regular terminal."
    exit 1
  fi
fi

heading() {
  if declare -F jsh::section > /dev/null; then
    jsh::section "$@"
  else
    jsh_blank
    jsh_info "[$1] $2"
    jsh_detail "$3"
  fi
}

confirm() {
  local default=${2:-yes} prompt='Y/n'
  if declare -F jsh::confirm > /dev/null; then
    jsh::confirm "$1" --default "${default}"
    return
  fi
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  if [[ ${JSH_NON_INTERACTIVE:-0} == 1 ]]; then
    [[ ${default} == yes ]]
    return
  fi
  [[ ${default} == no ]] && prompt='y/N'
  while :; do
    jsh_prompt "$1 [${prompt}] " > "${TTY}"
    IFS= read -r answer < "${TTY}"
    case "${answer}" in
      '') [[ ${default} == yes ]]; return ;;
      y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) jsh_warn "Please answer yes or no." 2> "${TTY}" ;;
    esac
  done
}

load_brew() {
  if command -v brew > /dev/null 2>&1; then
    return
  fi

  for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [[ -x "${brew_path}" ]]; then
      eval "$("${brew_path}" shellenv)"
      return
    fi
  done
}

linux_package_manager() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ "$(uname -s)" == Linux && -r "${os_release}" ]] || return 1

  local ID='' ID_LIKE=''
  # shellcheck source=/dev/null
  . "${os_release}"
  case " ${ID:-} ${ID_LIKE:-} " in
    *' arch '* | *' archlinux '* | *' endeavouros '*) printf '%s\n' pacman ;;
    *' fedora '* | *' rhel '* | *' centos '*)
      if command -v dnf5 > /dev/null 2>&1; then
        printf '%s\n' dnf5
      else
        printf '%s\n' dnf
      fi
      ;;
    *' debian '* | *' ubuntu '*) printf '%s\n' apt-get ;;
    *) return 1 ;;
  esac
}

install_linux_prerequisites() {
  local manager
  manager=$(linux_package_manager) || return 1
  if [[ "$(id -u)" -eq 0 ]]; then
    case "${manager}" in
      pacman) pacman -S --needed --noconfirm "$@" ;;
      dnf | dnf5) "${manager}" install -y "$@" ;;
      apt-get)
        apt-get update
        apt-get install -y "$@"
        ;;
    esac
  elif command -v sudo > /dev/null 2>&1; then
    case "${manager}" in
      pacman) sudo pacman -S --needed --noconfirm "$@" ;;
      dnf | dnf5) sudo "${manager}" install -y "$@" ;;
      apt-get)
        sudo apt-get update
        sudo apt-get install -y "$@"
        ;;
    esac
  else
    jsh_error "sudo is required to install missing setup tools."
    return 1
  fi
}

modern_bash_available() {
  command -v bash > /dev/null 2>&1 &&
    bash -c '((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))' 2> /dev/null
}

# Only the full profile installs missing tools; runtime, bare, and lite report them.
install_prerequisites() {
  local profile=$1 manager package
  local -a packages=()
  linux_package_manager > /dev/null || load_brew
  command -v git > /dev/null 2>&1 || packages+=(git)
  case ${profile} in
    full)
      command -v zsh > /dev/null 2>&1 || packages+=(zsh)
      command -v make > /dev/null 2>&1 || packages+=(make)
      command -v jq > /dev/null 2>&1 || packages+=(jq)
      command -v curl > /dev/null 2>&1 || packages+=(curl)
      modern_bash_available || packages+=(bash)
      if ! command -v python3 > /dev/null 2>&1; then
        package=python
        if manager=$(linux_package_manager) && [[ ${manager} != pacman ]]; then
          package=python3
        fi
        packages+=("${package}")
      fi
      ;;
    lite)
      command -v zsh > /dev/null 2>&1 || packages+=(zsh)
      command -v make > /dev/null 2>&1 || command -v gmake > /dev/null 2>&1 || packages+=(make)
      ;;
    *)
      command -v zsh > /dev/null 2>&1 || modern_bash_available || packages+=(zsh)
      ;;
  esac

  if ((${#packages[@]} > 0)) && [[ ${profile} != full ]]; then
    jsh_error "Missing required tools: ${packages[*]}"
    if manager=$(linux_package_manager); then
      jsh_detail "Install them with your package manager (${manager}), then run this command again."
    elif command -v brew > /dev/null 2>&1; then
      jsh_detail "Install them with: brew install ${packages[*]}"
    else
      jsh_detail "Install them with your system package manager, then run this command again."
    fi
    jsh_detail "Only the full profile installs missing tools automatically."
    return 1
  fi

  if ((${#packages[@]} > 0)); then
    jsh_warn "Missing required tools: ${packages[*]}"
    if linux_package_manager > /dev/null; then
      install_linux_prerequisites "${packages[@]}" || return
    else
      load_brew
      if ! command -v brew > /dev/null 2>&1; then
        jsh_info "Homebrew is required to install missing setup tools."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
          < "${TTY}" || return
        load_brew
      fi
      for package in "${packages[@]}"; do
        brew list "${package}" > /dev/null 2>&1 || brew install "${package}" || return
      done
    fi
  else
    jsh_note "Required tools are already installed."
  fi

  if ! linux_package_manager > /dev/null && command -v brew > /dev/null 2>&1; then
    brew_prefix=$(brew --prefix) || return
    PATH="${brew_prefix}/bin:${brew_prefix}/opt/make/libexec/gnubin:${PATH}"
    export PATH
  fi
}

refresh_vendored_fzf() {
  local fzf_dir=${JSH_DIR}/local/vendor/fzf pinned installed
  [[ -x ${fzf_dir}/bin/fzf && -x ${fzf_dir}/install ]] || return 0
  pinned=$(sed -n 's/^version=//p' "${fzf_dir}/install")
  installed=$("${fzf_dir}/bin/fzf" --version 2> /dev/null) || installed=
  [[ -n ${pinned} && ${installed%% *} != "${pinned}" ]] || return 0
  jsh_info "Updating the vendored fzf executable to ${pinned}..."
  "${fzf_dir}/install" --bin
}

sync_submodules() {
  if ! confirm "Initialize and update Jsh submodules?"; then
    jsh_note "Skipped submodule initialization and update."
    return
  fi
  git -C "${JSH_DIR}" submodule sync --recursive || return
  git -C "${JSH_DIR}" submodule update --init --recursive || return
  refresh_vendored_fzf
}

plural() {
  (($1 == 1)) || printf s
}

# Sets REPOSITORY_AHEAD, REPOSITORY_BEHIND, and REPOSITORY_DIRTY; returns 10 when upstream is unavailable.
inspect_repository() {
  local counts
  REPOSITORY_AHEAD=0 REPOSITORY_BEHIND=0 REPOSITORY_DIRTY=0
  if ! git -C "${JSH_DIR}" rev-parse --verify --quiet '@{upstream}' > /dev/null; then
    jsh_note "No upstream is configured for ${JSH_DIR}; skipping repository pull."
    return 10
  fi
  if ! git -C "${JSH_DIR}" fetch --quiet --no-recurse-submodules; then
    jsh_warn "Could not fetch Jsh from upstream; skipping repository pull."
    return 10
  fi
  counts=$(git -C "${JSH_DIR}" rev-list --left-right --count 'HEAD...@{upstream}') || return
  read -r REPOSITORY_AHEAD REPOSITORY_BEHIND <<< "${counts}"
  [[ -z "$(git -C "${JSH_DIR}" status --porcelain --untracked-files=no)" ]] || REPOSITORY_DIRTY=1

  if ((REPOSITORY_AHEAD && REPOSITORY_BEHIND)); then
    jsh_warn "Jsh has diverged from upstream: ${REPOSITORY_AHEAD} ahead, ${REPOSITORY_BEHIND} behind."
  elif ((REPOSITORY_BEHIND)); then
    jsh_note "Upstream has ${REPOSITORY_BEHIND} new commit$(plural "${REPOSITORY_BEHIND}")."
  elif ((REPOSITORY_AHEAD)); then
    jsh_note "Jsh is ${REPOSITORY_AHEAD} commit$(plural "${REPOSITORY_AHEAD}") ahead of upstream."
  else
    jsh_note "Jsh is up to date with upstream."
  fi
  ((REPOSITORY_DIRTY == 0)) || jsh_note "Local changes found in ${JSH_DIR}."
}

# Returns 10 when the pull is skipped so update summaries report it.
pull_repository() {
  inspect_repository || return
  ((REPOSITORY_BEHIND)) || return 0
  if ((REPOSITORY_AHEAD)); then
    jsh_warn "Rebase or merge ${JSH_DIR} manually; skipping repository pull."
    return 10
  fi
  if ((REPOSITORY_DIRTY)); then
    if ! confirm "Stash local changes, pull, and restore them?" no; then
      jsh_note "Skipped repository pull."
      return 10
    fi
    (cd -- "${JSH_DIR}" && "${JSH_DIR}/bin/jgit" update --stash)
    return
  fi
  if ! confirm "Pull Jsh from upstream?"; then
    jsh_note "Skipped repository pull."
    return 10
  fi
  git -C "${JSH_DIR}" pull --ff-only
}

sync_repository() {
  local result=0
  local -a clone_options=()
  if ! command -v git > /dev/null 2>&1; then
    jsh_error "Git is required. Run the prerequisite phase first."
    return 1
  fi

  if [[ -d "${JSH_DIR}/.git" ]]; then
    pull_repository || result=$?
    ((result == 0 || result == 10)) || return "${result}"
    sync_submodules || return
    return
  fi

  if [[ -e "${JSH_DIR}" ]]; then
    jsh_error "Install path exists but is not a Git checkout: ${JSH_DIR}"
    return 1
  fi

  # The runtime needs only the current tree; history blobs download on demand.
  [[ ${mode} != runtime ]] || clone_options=(--filter=blob:none)
  mkdir -p "$(dirname "${JSH_DIR}")" || return
  git clone ${clone_options[@]+"${clone_options[@]}"} "${JSH_REPO}" "${JSH_DIR}" || return
  sync_submodules
}

load_repository_ui() {
  load_jsh_libraries
  declare -F jsh_env_detect > /dev/null || return 0
  jsh_env_detect
  if declare -F jsh::init > /dev/null; then
    jsh::init --input-fd 8 --output-fd 8 --owns-fd
  fi
}

promote_workstation_ui() {
  load_repository_ui
  [[ ${JSH_INTERACTIVE:-0} == 1 && ${JSH_REMOTE:-0} != 1 ]] || return 0
  declare -F jsh::bootstrap_gum > /dev/null || return 0
  if ! jsh::bootstrap_gum; then
    jsh_warn 'Gum installation failed; continuing with the shell UI.'
    return 0
  fi
  jsh_env_detect
  if declare -F jsh::init > /dev/null; then
    jsh::init --input-fd "${JSH_UI_INPUT_FD:-0}" --output-fd "${JSH_UI_OUTPUT_FD:-2}"
  fi
}

update_repository() {
  if ! command -v git > /dev/null 2>&1; then
    jsh_error "Git is required to update Jsh."
    return 1
  fi
  if [[ ! -d "${JSH_DIR}/.git" ]]; then
    jsh_error "Jsh is not a Git checkout: ${JSH_DIR}"
    return 1
  fi
  local result=0
  pull_repository || result=$?
  ((result == 0 || result == 10)) || return "${result}"
  sync_submodules || return
  return "${result}"
}

preview_repository() {
  local drift
  if [[ ! -d "${JSH_DIR}/.git" ]]; then
    jsh_error "Jsh is not a Git checkout: ${JSH_DIR}"
    return 1
  fi
  inspect_repository || :
  drift=$(git -C "${JSH_DIR}" submodule status --recursive | grep -E '^[-+U]') || :
  if [[ -n ${drift} ]]; then
    jsh_note "Submodules that would be initialized or moved:"
    jsh_detail "${drift}"
  fi
}

preview_update() {
  local profile=$1 outdated
  jsh_blank
  jsh_info "Repository and submodules"
  preview_repository || return
  if [[ ${profile} != bare ]]; then
    load_brew
    if command -v brew > /dev/null 2>&1; then
      jsh_blank
      jsh_info "Outdated Homebrew packages"
      outdated=$(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --quiet 2> /dev/null) || :
      if [[ -n ${outdated} ]]; then
        jsh_detail "${outdated}"
      else
        jsh_note "None."
      fi
    fi
  fi
  jsh_blank
  jsh_info "Planned steps"
  UPDATE_PREVIEW=1 update_environment "${profile}"
}

# Each profile runs a prefix of this list: bare 3, lite 5, full all.
SETUP_PHASES=(prerequisites repository launcher dotfiles shell packages configure patch)

profile_phase_count() {
  case $1 in
    bare) printf '3\n' ;;
    lite) printf '5\n' ;;
    full) printf '%s\n' "${#SETUP_PHASES[@]}" ;;
    *) return 2 ;;
  esac
}

phase_index() {
  local index
  for index in "${!SETUP_PHASES[@]}"; do
    if [[ ${SETUP_PHASES[index]} == "$1" ]]; then
      printf '%s\n' "${index}"
      return
    fi
  done
  return 1
}

profile_phase_position() {
  local index count
  count=$(profile_phase_count "${install_profile}")
  if index=$(phase_index "$1") && ((index < count)); then
    printf '%s\n' "${index}"
    return
  fi
  jsh_error "Unknown ${install_profile} setup phase: $1"
  jsh_detail "Phases: ${SETUP_PHASES[*]:0:count}" >&2
  return 2
}

# Sets PHASE_TITLE and PHASE_DETAIL.
describe_phase() {
  case $1 in
    prerequisites)
      PHASE_TITLE=Prerequisites
      case ${install_profile} in
        full) PHASE_DETAIL='Install missing Git, Zsh, Make, jq, curl, Bash 5.1+, and Python 3.' ;;
        lite) PHASE_DETAIL='Check that Git, Zsh, and Make are available.' ;;
        *) PHASE_DETAIL='Check that Git and either Zsh or Bash 5.1+ are available.' ;;
      esac
      ;;
    repository)
      PHASE_TITLE=Repository
      PHASE_DETAIL="Clone ${JSH_REPO}, or fast-forward an existing clean checkout."
      ;;
    launcher)
      PHASE_TITLE=Launcher
      PHASE_DETAIL='Link the jsh command into ~/.local/bin and add it to PATH.'
      ;;
    dotfiles)
      PHASE_TITLE=Dotfiles
      PHASE_DETAIL='Link managed dotfiles into your home directory.'
      ;;
    shell)
      PHASE_TITLE=Shell
      PHASE_DETAIL='Offer Zsh as your default login shell.'
      ;;
    packages)
      PHASE_TITLE=Packages
      PHASE_DETAIL='Install and upgrade packages and platform applications.'
      ;;
    configure)
      PHASE_TITLE=Configure
      PHASE_DETAIL='Apply platform and application settings.'
      ;;
    patch)
      PHASE_TITLE=Patch
      PHASE_DETAIL='Apply application patches.'
      ;;
  esac
}

phase_prerequisites() { install_prerequisites "${install_profile}"; }
phase_repository() { sync_repository; }
phase_launcher() { install_runtime_launcher && configure_runtime_path; }
phase_dotfiles() { run_make_target deploy; }
phase_shell() { "${JSH_DIR}/scripts/unix/configure/shell.sh" < "${TTY}"; }
phase_packages() { update_full_packages; }
phase_configure() { run_make_target configure; }
phase_patch() { run_make_target patch; }

setup_state_file() {
  printf '%s\n' "${JSH_SETUP_STATE_FILE:-${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/setup-state}"
}

# Sets SETUP_STATE_PROFILE and PHASE_STATUS from the last setup run.
load_setup_state() {
  local state_file key value index
  SETUP_STATE_PROFILE=
  PHASE_STATUS=()
  state_file=$(setup_state_file)
  [[ -r ${state_file} ]] || return 1
  while IFS='=' read -r key value; do
    if [[ ${key} == profile ]]; then
      SETUP_STATE_PROFILE=${value}
    elif index=$(phase_index "${key}"); then
      PHASE_STATUS[index]=${value}
    fi
  done < "${state_file}"
  case ${SETUP_STATE_PROFILE} in
    bare | lite | full) ;;
    *)
      jsh_warn "Ignoring invalid setup progress in ${state_file}."
      SETUP_STATE_PROFILE=
      PHASE_STATUS=()
      return 1
      ;;
  esac
}

save_setup_state() {
  local state_file state_dir temporary index count
  state_file=$(setup_state_file)
  state_dir=${state_file%/*}
  count=$(profile_phase_count "${install_profile}")
  mkdir -p -- "${state_dir}" || return
  temporary=$(mktemp "${state_dir}/.setup-state.XXXXXX") || return
  {
    printf 'profile=%s\n' "${install_profile}"
    for ((index = 0; index < count; index++)); do
      printf '%s=%s\n' "${SETUP_PHASES[index]}" "${PHASE_STATUS[index]:-pending}"
    done
  } > "${temporary}" && chmod 0600 "${temporary}" && mv -f -- "${temporary}" "${state_file}"
}

# Sets PHASE_SELECTED from the setup selector; returns 2 for an invalid phase.
select_setup_phases() {
  local count index start name
  local -a names=()
  count=$(profile_phase_count "${install_profile}")
  PHASE_SELECTED=()
  case ${setup_selector} in
    resume)
      for ((index = 0; index < count; index++)); do
        [[ ${PHASE_STATUS[index]:-pending} == "done" ]] || PHASE_SELECTED[index]=1
      done
      ;;
    from)
      start=$(profile_phase_position "${setup_phase_argument}") || return
      for ((index = start; index < count; index++)); do
        PHASE_SELECTED[index]=1
      done
      ;;
    phase)
      IFS=, read -r -a names <<< "${setup_phase_argument}"
      for name in ${names[@]+"${names[@]}"}; do
        index=$(profile_phase_position "${name}") || return
        PHASE_SELECTED[index]=1
      done
      ;;
    *)
      for ((index = 0; index < count; index++)); do
        PHASE_SELECTED[index]=1
      done
      ;;
  esac
}

setup_phases_selected() {
  local index count
  count=$(profile_phase_count "${install_profile}")
  for ((index = 0; index < count; index++)); do
    [[ ${PHASE_SELECTED[index]:-0} != 1 ]] || return 0
  done
  return 1
}

setup_complete() {
  local index count
  count=$(profile_phase_count "${install_profile}")
  for ((index = 0; index < count; index++)); do
    [[ ${PHASE_STATUS[index]:-pending} == "done" ]] || return 1
  done
}

print_setup_phases() {
  local only_selected=${1:-0} index count
  count=$(profile_phase_count "${install_profile}")
  for ((index = 0; index < count; index++)); do
    ((!only_selected)) || [[ ${PHASE_SELECTED[index]:-0} == 1 ]] || continue
    describe_phase "${SETUP_PHASES[index]}"
    printf '  %d/%d  %-13s  %-11s  %s\n' "$((index + 1))" "${count}" \
      "${SETUP_PHASES[index]}" "${PHASE_STATUS[index]:-pending}" "${PHASE_DETAIL}"
  done
}

setup_command_hint() {
  if [[ ${HOME}/.local/bin/jsh -ef ${JSH_DIR}/bin/jsh ]]; then
    printf 'jsh setup'
  elif [[ -x ${JSH_DIR}/bin/jsh ]]; then
    printf '%s setup' "${JSH_DIR}/bin/jsh"
  else
    printf 'curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash -s -- setup'
  fi
}

report_setup_failure() {
  local phase=$1 result=$2 index count completed='' remaining='' command
  count=$(profile_phase_count "${install_profile}")
  for ((index = 0; index < count; index++)); do
    if [[ ${PHASE_STATUS[index]:-pending} == "done" ]]; then
      completed+=", ${SETUP_PHASES[index]}"
    else
      remaining+=", ${SETUP_PHASES[index]}"
    fi
  done
  command=$(setup_command_hint)
  jsh_blank
  jsh_error "Setup phase ${phase} failed (exit ${result})."
  [[ -z ${completed} ]] || jsh_detail "Done:      ${completed#, }"
  jsh_detail "Remaining: ${remaining#, }"
  jsh_detail "Resume:    ${command} --resume"
  jsh_detail "Only this: ${command} ${install_profile} --phase ${phase}"
}

run_setup_phases() {
  local index count phase result
  count=$(profile_phase_count "${install_profile}")
  save_setup_state || jsh_warn "Could not save setup progress."
  for ((index = 0; index < count; index++)); do
    phase=${SETUP_PHASES[index]}
    if [[ ${PHASE_SELECTED[index]:-0} == 1 ]]; then
      describe_phase "${phase}"
      heading "$((index + 1))/${count}" "${PHASE_TITLE}" "${PHASE_DETAIL}"
      if ! confirm "Run this phase?"; then
        jsh_note "Skipped ${phase}."
        PHASE_STATUS[index]=skipped
        save_setup_state || :
      else
        result=0
        if ((index > 1)) && [[ ! -f ${JSH_DIR}/Makefile ]]; then
          jsh_error "Repository is unavailable at ${JSH_DIR}. Run the repository phase first."
          result=1
        else
          # Remains recorded as interrupted if Jsh is killed mid-phase.
          PHASE_STATUS[index]=interrupted
          save_setup_state || :
          "phase_${phase}" || result=$?
        fi
        case ${result} in
          0) PHASE_STATUS[index]="done" ;;
          129 | 130 | 143) PHASE_STATUS[index]=interrupted ;;
          *) PHASE_STATUS[index]=failed ;;
        esac
        save_setup_state || :
        if ((result != 0)); then
          report_setup_failure "${phase}" "${result}"
          return "${result}"
        fi
      fi
    fi
    if [[ ${phase} == repository ]]; then
      load_repository_ui
      [[ ${install_profile} != full ]] || promote_workstation_ui
    fi
  done
}

# Recorded profile, legacy full dotfiles, or an interactive choice; --yes never picks one.
default_setup_profile() {
  local profile
  if [[ -r $(install_profile_state_file) || ${HOME}/.zshrc -ef ${JSH_DIR}/dotfiles/.zshrc ]]; then
    read_install_profile
    return
  fi
  if [[ ${JSH_ASSUME_YES:-0} != 1 ]] && declare -F jsh::choose_one > /dev/null &&
    profile=$(jsh::choose_one "Setup profile" \
      bare 'bare: launcher only' \
      lite 'lite: bare plus managed dotfiles and default shell' \
      full 'full: lite plus packages, configuration, and patches'); then
    printf '%s\n' "${profile}"
    return
  fi
  jsh_error "Choose a setup profile: setup bare, setup lite, or setup full."
  return 2
}

update_full_packages() {
  (export JSH_UPDATE=1; run_make_target install)
}

install_profile_state_file() {
  printf '%s\n' "${JSH_PROFILE_STATE_FILE:-${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/install-profile}"
}

read_install_profile() {
  local state_file profile
  state_file=$(install_profile_state_file)
  if [[ -r ${state_file} ]]; then
    IFS= read -r profile < "${state_file}" || true
    case ${profile} in
      bare | lite | full) printf '%s\n' "${profile}"; return ;;
      slim) printf '%s\n' lite; return ;;
      *) jsh_error "Invalid Jsh install profile in ${state_file}: ${profile}"; return 1 ;;
    esac
  fi
  if [[ -e ${HOME}/.zshrc && ${HOME}/.zshrc -ef ${JSH_DIR}/dotfiles/.zshrc ]]; then
    printf '%s\n' full
  else
    printf '%s\n' bare
  fi
}

record_install_profile() {
  local profile=$1 state_file state_dir temporary
  case ${profile} in bare | lite | full) ;; *) return 2 ;; esac
  state_file=$(install_profile_state_file)
  state_dir=${state_file%/*}
  mkdir -p -- "${state_dir}"
  temporary=$(mktemp "${state_dir}/.install-profile.XXXXXX")
  printf '%s\n' "${profile}" > "${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${state_file}"
}

update_environment() {
  local profile=$1
  run_update_step "Repository and submodules" update_repository
  case ${profile} in
    bare)
      run_update_step "Prerequisites" install_prerequisites bare
      ;;
    lite)
      run_update_step "Prerequisites" install_prerequisites lite
      run_update_step "Dotfiles" run_make_target deploy
      ;;
    full)
      run_update_step "Prerequisites" install_prerequisites full
      run_update_step "Packages and dependencies" update_full_packages
      run_update_step "Betterfox" "${JSH_DIR}/scripts/unix/configure/waterfox.sh" update
      run_update_step "Dotfiles" run_make_target deploy
      run_update_step "Configuration" run_make_target configure
      run_update_step "Patches" run_make_target patch
      ;;
    *)
      jsh_error "Unknown install profile: ${profile}"
      return 2
      ;;
  esac
}

run_make_target() {
  local target=$1
  if command -v make > /dev/null 2>&1; then
    JSH_INTERRUPT_REPORT=0 make --no-print-directory -C "${JSH_DIR}" "${target}" < "${TTY}"
  elif command -v gmake > /dev/null 2>&1; then
    JSH_INTERRUPT_REPORT=0 gmake --no-print-directory -C "${JSH_DIR}" "${target}" < "${TTY}"
  else
    jsh_error "Make is required to update Jsh."
    return 1
  fi
}

install_runtime_launcher() {
  local commands_dir=${HOME}/.local/bin
  local launcher=${commands_dir}/jsh
  local target=${JSH_DIR}/bin/jsh

  mkdir -p -- "${commands_dir}"
  if [[ -e ${launcher} || -L ${launcher} ]]; then
    if [[ ${launcher} -ef ${target} ]]; then
      jsh_note "Jsh command is already installed: ${launcher}"
      return
    fi
    jsh_error "Cannot install Jsh command; path already exists: ${launcher}"
    return 1
  fi

  ln -s -- "${target}" "${launcher}"
  jsh_success "Installed Jsh command: ${launcher}"
}

configure_runtime_path_file() {
  local rc_file=$1
  local block_start='# jsh runtime path: begin'
  local block_end='# jsh runtime path: end'

  if grep -Fqx -- "${block_start}" "${rc_file}" 2> /dev/null ||
    grep -Fqx -- "${block_end}" "${rc_file}" 2> /dev/null; then
    if grep -Fqx -- "${block_start}" "${rc_file}" 2> /dev/null &&
      grep -Fqx -- "${block_end}" "${rc_file}" 2> /dev/null; then
      jsh_note "Jsh PATH is already configured: ${rc_file}"
      return
    fi
    jsh_error "Incomplete Jsh PATH block in ${rc_file}; repair or remove it before retrying."
    return 1
  fi

  (
    umask 077
    [[ ! -s ${rc_file} ]] || printf '\n'
    printf '%s\n' \
      "${block_start}" \
      'case ":${PATH}:" in' \
      '  *:"${HOME}/.local/bin":*) ;;' \
      '  *) export PATH="${HOME}/.local/bin:${PATH}" ;;' \
      'esac' \
      "${block_end}"
  ) >> "${rc_file}"
  jsh_success "Configured Jsh PATH: ${rc_file}"
}

configure_runtime_path() {
  local rc_file

  if ! confirm "Add ${HOME}/.local/bin to PATH in Bash and Zsh?"; then
    jsh_note "Skipped PATH configuration. Run Jsh with: ${HOME}/.local/bin/jsh"
    return
  fi
  for rc_file in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    configure_runtime_path_file "${rc_file}" || return
  done
}

run_update_step() {
  local label=$1 result
  shift
  if [[ ${UPDATE_PREVIEW:-0} == 1 ]]; then
    jsh_detail "${label}"
    return
  fi
  jsh_blank
  jsh_info "${label}"
  if "$@"; then
    UPDATE_SUCCEEDED+=("${label}")
    return
  else
    result=$?
  fi
  if ((result == 10)); then
    UPDATE_WARNINGS+=("${label}")
  else
    UPDATE_ERRORS+=("${label}")
  fi
}

print_update_summary() {
  local label
  jsh_blank
  jsh_info "Update summary"
  for label in "${UPDATE_SUCCEEDED[@]}"; do
    jsh_success "${label}"
  done
  for label in "${UPDATE_WARNINGS[@]}"; do
    jsh_note "Skipped: ${label}"
  done
  for label in "${UPDATE_ERRORS[@]}"; do
    jsh_error "Failed: ${label}"
  done
  jsh_detail "${#UPDATE_SUCCEEDED[@]} succeeded, ${#UPDATE_WARNINGS[@]} skipped, ${#UPDATE_ERRORS[@]} failed."
}

jsh_banner "${mode}"
if [[ ${mode} == runtime ]]; then
  jsh_detail "Install directory: ${JSH_DIR}"
  jsh_detail "This opens an isolated J shell without installing a launcher, deploying dotfiles, or configuring the system."

  heading "1/2" "Prerequisites" "Check that Git and either Zsh or Bash 5.1+ are available."
  if confirm "Run this phase?"; then
    install_prerequisites runtime
  else
    jsh_note "Skipped prerequisites."
  fi

  heading "2/2" "Repository" "Clone ${JSH_REPO}, or fast-forward an existing clean checkout."
  if confirm "Run this phase?"; then
    sync_repository
  else
    jsh_note "Skipped repository sync."
  fi

  jsh_blank
  jsh_success "Jsh runtime is ready."
  if [[ ${JSH_INSTALL_RETURN:-0} == 1 || ${TTY} == /dev/null ]]; then
    declare -F jsh::cleanup > /dev/null && jsh::cleanup
    exit 0
  fi
  jsh_blank
  declare -F jsh::cleanup > /dev/null && jsh::cleanup
  exec "${JSH_DIR}/bin/jsh" < "${TTY}"
fi

if [[ ${mode} == update ]]; then
  declare -a UPDATE_SUCCEEDED=() UPDATE_WARNINGS=() UPDATE_ERRORS=()
  jsh_detail "Install directory: ${JSH_DIR}"
  install_profile=$(read_install_profile)
  case ${install_profile} in
    bare) profile_color=32 ;;
    lite) profile_color=34 ;;
    *) profile_color=35 ;;
  esac
  if jsh_color_enabled 1; then
    jsh_detail "Installed experience: "$'\033['"${profile_color}m${install_profile}"$'\033[0m'
  else
    jsh_detail "Installed experience: ${install_profile}"
  fi
  if ((dry_run)); then
    exit_status=0
    preview_update "${install_profile}" || exit_status=$?
    declare -F jsh::cleanup > /dev/null && jsh::cleanup
    exit "${exit_status}"
  fi
  export JSH_CONTINUE_ON_ERROR=1
  update_environment "${install_profile}"
  print_update_summary
  ((${#UPDATE_ERRORS[@]} == 0))
  declare -F jsh::cleanup > /dev/null && jsh::cleanup
  exit
fi

finish_setup() {
  declare -F jsh::cleanup > /dev/null && jsh::cleanup
  exit "$1"
}

declare -a PHASE_STATUS=() PHASE_SELECTED=()
SETUP_STATE_PROFILE=
setup_state_loaded=0
load_setup_state && setup_state_loaded=1
if [[ ${setup_selector} == resume ]]; then
  if ((!setup_state_loaded)); then
    jsh_note "Nothing to resume."
    finish_setup 0
  fi
  if [[ -n ${install_profile} && ${install_profile} != "${SETUP_STATE_PROFILE}" ]]; then
    jsh_error "The last setup run used ${SETUP_STATE_PROFILE}, not ${install_profile}."
    jsh_detail "Resume it with: $(setup_command_hint) --resume"
    jsh_detail "Start over with: $(setup_command_hint) ${install_profile}"
    finish_setup 2
  fi
  install_profile=${SETUP_STATE_PROFILE}
elif [[ -z ${install_profile} ]]; then
  install_profile=$(default_setup_profile) || finish_setup 2
fi
# Selectors and --list build on the last run of the same profile; a plain run starts fresh.
if [[ ${SETUP_STATE_PROFILE} != "${install_profile}" ]] || { [[ -z ${setup_selector} ]] && ((!list_phases)); }; then
  PHASE_STATUS=()
fi
select_setup_phases || finish_setup 2

jsh_detail "Install directory: ${JSH_DIR}"
jsh_detail "This command applies the ${install_profile} profile."
if ((list_phases)); then
  jsh_blank
  print_setup_phases
  finish_setup 0
fi
if ! setup_phases_selected; then
  if [[ ${setup_selector} == resume ]]; then
    jsh_note "Nothing to resume; the ${install_profile} setup is complete."
    finish_setup 0
  fi
  jsh_error "No setup phases selected."
  finish_setup 2
fi
if ((dry_run)); then
  jsh_blank
  jsh_info "Planned phases"
  print_setup_phases 1
  finish_setup 0
fi

setup_status=0
run_setup_phases || setup_status=$?
((setup_status == 0)) || finish_setup "${setup_status}"

jsh_blank
if setup_complete; then
  record_install_profile "${install_profile}"
  jsh_success "Jsh ${install_profile} setup finished."
else
  jsh_note "Jsh ${install_profile} setup is incomplete; skipped phases remain."
  jsh_detail "Finish with: $(setup_command_hint) --resume"
fi
if [[ ${JSH_INSTALL_RETURN:-0} == 1 || ${TTY} == /dev/null || ${JSH_ASSUME_YES:-0} == 1 ]]; then
  finish_setup 0
fi
jsh_blank
declare -F jsh::cleanup > /dev/null && jsh::cleanup
exec "${JSH_DIR}/bin/jsh" < "${TTY}"
