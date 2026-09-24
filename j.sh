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
    local banner
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
 =   :-=-:                          -:
BANNER
    )
    jsh_blank
    jsh_stdout '1;36' '' "${banner}"
    jsh_blank
  }
fi

usage() {
  cat <<'EOF'
Usage: j.sh [-y|--yes] [runtime|install|setup|update]

With no arguments, prepare and open the isolated Jsh runtime.
Run with runtime for the same minimal, ephemeral experience.
Run with install to add the launcher, core shell tools, and managed dotfiles.
Run with setup to install and configure the complete managed workstation.
Run with update to update Jsh and reapply the managed environment.
Use -y or --yes to accept prompts for the selected command without interactive input.
EOF
}

mode=runtime
command_seen=0
while (($#)); do
  case $1 in
    -y | --yes)
      export JSH_ASSUME_YES=1 JSH_CONFIGURE_ASSUME_YES=1 JSH_UPDATE_ASSUME_YES=1
      export JSH_NON_INTERACTIVE=1
      ;;
    runtime | install | setup | update)
      if ((command_seen)); then
        jsh_error "Too many commands."
        usage >&2
        exit 2
      fi
      mode=$1
      command_seen=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      jsh_error "Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

install_profile=
case ${mode} in
  install) install_profile=slim ;;
  setup) install_profile=full ;;
esac

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
  if [[ ${mode} == install || ${mode} == setup || ${mode} == update ]]; then
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

install_prerequisites() {
  local install_mode=$1 prompt_for_install=$2 manager package
  local -a packages=()
  command -v git > /dev/null 2>&1 || packages+=(git)
  if [[ ${install_mode} == install ]]; then
    command -v zsh > /dev/null 2>&1 || packages+=(zsh)
    command -v make > /dev/null 2>&1 || packages+=(make)
    command -v jq > /dev/null 2>&1 || packages+=(jq)
    command -v curl > /dev/null 2>&1 || packages+=(curl)
    if ! command -v bash > /dev/null 2>&1 ||
      ! bash -c '((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))' 2> /dev/null; then
      packages+=(bash)
    fi
    if ! command -v python3 > /dev/null 2>&1; then
      package=python
      if manager=$(linux_package_manager) && [[ ${manager} != pacman ]]; then
        package=python3
      fi
      packages+=("${package}")
    fi
  elif ! command -v zsh > /dev/null 2>&1 &&
    { ! command -v bash > /dev/null 2>&1 ||
      ! bash -c '((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))' 2> /dev/null; }; then
    packages+=(zsh)
  fi

  if ((${#packages[@]} > 0)); then
    jsh_warn "Missing required tools: ${packages[*]}"
    if [[ ${prompt_for_install} == 1 ]] && ! confirm "Install them now?"; then
      jsh_error "Git and either Zsh or Bash 5.1+ are required to try Jsh."
      return 1
    fi
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

sync_repository() {
  if ! command -v git > /dev/null 2>&1; then
    jsh_error "Git is required. Run the prerequisite phase first."
    exit 1
  fi

  if [[ -d "${JSH_DIR}/.git" ]]; then
    if [[ -n "$(git -C "${JSH_DIR}" status --porcelain --untracked-files=no)" ]]; then
      jsh_note "Local changes found in ${JSH_DIR}; skipping repository pull."
    elif confirm "Pull Jsh from upstream?"; then
      git -C "${JSH_DIR}" pull --ff-only || return
    else
      jsh_note "Skipped repository pull."
    fi
    sync_submodules || return
    return
  fi

  if [[ -e "${JSH_DIR}" ]]; then
    jsh_error "Install path exists but is not a Git checkout: ${JSH_DIR}"
    exit 1
  fi

  mkdir -p "$(dirname "${JSH_DIR}")"
  git clone "${JSH_REPO}" "${JSH_DIR}"
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
  if [[ -n "$(git -C "${JSH_DIR}" status --porcelain --untracked-files=no)" ]]; then
    jsh_note "Local changes found in ${JSH_DIR}; skipping repository pull."
  elif confirm "Pull Jsh from upstream?"; then
    git -C "${JSH_DIR}" pull --ff-only || return
  else
    jsh_note "Skipped repository pull."
  fi
  sync_submodules || return
}

setup_system() {
  local profile=${1:-full}
  if [[ ! -f "${JSH_DIR}/Makefile" ]]; then
    jsh_error "Repository is unavailable at ${JSH_DIR}. Run the repository phase first."
    exit 1
  fi

  case ${profile} in
    slim)
      install_core_packages
      run_make_target deploy
      if [[ -x "${JSH_DIR}/scripts/unix/configure/shell.sh" ]]; then
        "${JSH_DIR}/scripts/unix/configure/shell.sh" < "${TTY}"
      fi
      ;;
    full)
      JSH_UPDATE=1 run_make_target install
      run_make_target deploy
      run_make_target configure
      ;;
    *)
      jsh_error "Unknown install profile: ${profile}"
      return 2
      ;;
  esac
}

install_core_packages() {
  run_make_target essentials
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
      bare | slim | full) printf '%s\n' "${profile}"; return ;;
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
  case ${profile} in bare | slim | full) ;; *) return 2 ;; esac
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
      run_update_step "Runtime prerequisites" install_prerequisites shell 0
      ;;
    slim)
      run_update_step "Prerequisites" install_prerequisites install 0
      run_update_step "Core shell packages" install_core_packages
      run_update_step "Dotfiles" run_make_target deploy
      ;;
    full)
      run_update_step "Prerequisites" install_prerequisites install 0
      run_update_step "Packages and dependencies" update_full_packages
      run_update_step "Betterfox" "${JSH_DIR}/scripts/unix/configure/waterfox.sh" update
      run_update_step "Dotfiles" run_make_target deploy
      run_update_step "Configuration" run_make_target configure
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

jsh_banner
if [[ ${mode} == runtime ]]; then
  if declare -F jsh::title > /dev/null; then jsh::title "jsh runtime"; else jsh_info "jsh runtime"; fi
  jsh_detail "Install directory: ${JSH_DIR}"
  jsh_detail "This opens an isolated J shell without installing a launcher, deploying dotfiles, or configuring the system."

  heading "1/2" "Prerequisites" "Ensure Git and either Zsh or Bash 5.1+ are available."
  if confirm "Run this phase?"; then
    install_prerequisites shell 0
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
  if declare -F jsh::title > /dev/null; then jsh::title "jsh update"; else jsh_info "jsh update"; fi
  jsh_detail "Install directory: ${JSH_DIR}"
  install_profile=$(read_install_profile)
  jsh_detail "Installed experience: ${install_profile}"
  export JSH_CONTINUE_ON_ERROR=1
  update_environment "${install_profile}"
  print_update_summary
  ((${#UPDATE_ERRORS[@]} == 0))
  declare -F jsh::cleanup > /dev/null && jsh::cleanup
  exit
fi

if declare -F jsh::title > /dev/null; then jsh::title "jsh ${mode}"; else jsh_info "jsh ${mode}"; fi
jsh_detail "Install directory: ${JSH_DIR}"
jsh_detail "This command applies the ${install_profile} managed experience."

heading "1/3" "Runtime prerequisites" "Ensure Git and either Zsh or Bash 5.1+ are available."
if confirm "Run this phase?"; then
  install_prerequisites shell 0
else
  jsh_note "Skipped prerequisites."
fi

heading "2/3" "Repository" "Clone ${JSH_REPO}, or fast-forward an existing clean checkout."
if confirm "Run this phase?"; then
  sync_repository
else
  jsh_note "Skipped repository sync."
fi

load_repository_ui
if [[ ${install_profile} == full ]]; then
  promote_workstation_ui
fi

heading "3/3" "Apply ${install_profile}" "Install only the components included in this command."
if confirm "Run this phase?"; then
  jsh_blank
  install_runtime_launcher
  configure_runtime_path
  if [[ ${install_profile} == slim || ${install_profile} == full ]]; then
    install_prerequisites install 0
    setup_system "${install_profile}"
  fi
  record_install_profile "${install_profile}"
else
  jsh_note "Skipped ${install_profile} setup."
fi

jsh_blank
jsh_success "Jsh ${mode} finished."
if [[ ${JSH_INSTALL_RETURN:-0} == 1 || ${TTY} == /dev/null || ${JSH_ASSUME_YES:-0} == 1 ]]; then
  declare -F jsh::cleanup > /dev/null && jsh::cleanup
  exit 0
fi
jsh_blank
declare -F jsh::cleanup > /dev/null && jsh::cleanup
exec "${JSH_DIR}/bin/jsh" < "${TTY}"
