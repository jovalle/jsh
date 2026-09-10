#!/usr/bin/env bash

set -eu

JSH_REPO=${JSH_REPO:-https://github.com/jovalle/jsh.git}
JSH_DIR=${JSH_DIR:-"${HOME}/.jsh"}
TTY=${JSH_TTY:-/dev/tty}

for library_file in "${JSH_DIR}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

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
  jsh_error() { jsh_stderr 31 '✗ ' "$*"; }
  jsh_prompt() {
    if jsh_color_enabled 1; then
      printf '\033[36m%s\033[0m' "$*"
    else
      printf '%s' "$*"
    fi
  }
  jsh_detail() { printf '%s\n' "$*"; }
  jsh_blank() { printf '\n'; }
fi

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

usage() {
  cat <<'EOF'
Usage: j.sh [--yes] [runtime|install|update]

With no arguments, install or update Jsh and open an isolated shell environment.
Run with runtime to install a persistent jsh command without deploying managed dotfiles.
Run with install to install packages, deploy dotfiles, and configure the system.
Run with update to update Jsh and reapply the managed environment.
Use --yes to accept setup workflow prompts.
EOF
}

mode=shell
command_seen=0
while (($#)); do
  case $1 in
    --yes)
      export JSH_ASSUME_YES=1
      ;;
    runtime | install | update)
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

if [[ ! -r "${TTY}" ]] || [[ ! -w "${TTY}" ]]; then
  jsh_error "jsh needs an interactive terminal."
  exit 1
fi

relaunch_if_privileges_restricted() {
  local script_path
  local -a relaunch

  [[ ${mode} == install || ${mode} == update ]] || return 0
  [[ -r /proc/self/status ]] || return 0
  grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status || return 0

  if [[ ${JSH_SYSTEMD_REEXEC:-0} == 1 ]]; then
    jsh_error "The user systemd manager also launched Jsh with no-new-privileges enabled."
    return 1
  fi
  command -v systemd-run > /dev/null 2>&1 || {
    jsh_error "Cannot elevate from this restricted session, and systemd-run is unavailable."
    jsh_detail "Rerun ./j.sh ${mode} from a terminal outside this restricted session."
    return 1
  }

  script_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")
  relaunch=(
    systemd-run --user --quiet --pty --wait --collect --same-dir
    --setenv="JSH_SYSTEMD_REEXEC=1"
    --setenv="JSH_DIR=${JSH_DIR}"
    --setenv="JSH_REPO=${JSH_REPO}"
    --setenv="JSH_INSTALL_RETURN=${JSH_INSTALL_RETURN:-0}"
    --setenv="PATH=${PATH}"
    "${script_path}"
  )
  [[ ${JSH_ASSUME_YES:-0} != 1 ]] || relaunch+=(--yes)
  relaunch+=("${mode}")

  jsh_note "Relaunching Jsh through the user systemd manager to enable sudo."
  exec "${relaunch[@]}"
}

relaunch_if_privileges_restricted

heading() {
  jsh_blank
  jsh_info "[$1] $2"
  jsh_detail "$3"
}

confirm() {
  local default=${2:-yes} prompt='Y/n'
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
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

is_arch_family() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ "$(uname -s)" == Linux && -r "${os_release}" ]] || return 1

  local ID='' ID_LIKE=''
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ " ${ID:-} ${ID_LIKE:-} " == *" endeavouros "* ||
    " ${ID:-} ${ID_LIKE:-} " == *" arch "* ||
    " ${ID:-} ${ID_LIKE:-} " == *" archlinux "* ]]
}

install_arch_prerequisites() {
  if [[ "$(id -u)" -eq 0 ]]; then
    pacman -S --needed --noconfirm "$@"
  elif command -v sudo > /dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm "$@"
  else
    jsh_error "sudo is required to install missing setup tools."
    return 1
  fi
}

install_prerequisites() {
  local install_mode=$1 prompt_for_install=$2 package
  local -a packages=()
  command -v git > /dev/null 2>&1 || packages+=(git)
  command -v zsh > /dev/null 2>&1 || packages+=(zsh)
  if [[ ${install_mode} == install ]]; then
    command -v make > /dev/null 2>&1 || packages+=(make)
    if ! command -v bash > /dev/null 2>&1 || ! bash -c '((BASH_VERSINFO[0] >= 5))' 2> /dev/null; then
      packages+=(bash)
    fi
  fi

  if ((${#packages[@]} > 0)); then
    jsh_warn "Missing required tools: ${packages[*]}"
    if [[ ${prompt_for_install} == 1 ]] && ! confirm "Install them now?"; then
      jsh_error "Git and Zsh are required to try Jsh."
      return 1
    fi
    if is_arch_family; then
      install_arch_prerequisites "${packages[@]}" || return
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
    jsh_success "Required tools are already installed."
  fi

  if ! is_arch_family && command -v brew > /dev/null 2>&1; then
    brew_prefix=$(brew --prefix) || return
    PATH="${brew_prefix}/bin:${brew_prefix}/opt/make/libexec/gnubin:${PATH}"
    export PATH
  fi
}

sync_submodules() {
  if ! confirm "Initialize and update Jsh submodules?"; then
    jsh_note "Skipped submodule initialization and update."
    return
  fi
  git -C "${JSH_DIR}" submodule sync --recursive
  git -C "${JSH_DIR}" submodule update --init --recursive
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
  if [[ ! -f "${JSH_DIR}/Makefile" ]]; then
    jsh_error "Repository is unavailable at ${JSH_DIR}. Run the repository phase first."
    exit 1
  fi

  if command -v make > /dev/null 2>&1; then
    make --no-print-directory -C "${JSH_DIR}" setup < "${TTY}"
  elif command -v gmake > /dev/null 2>&1; then
    gmake --no-print-directory -C "${JSH_DIR}" setup < "${TTY}"
  else
    jsh_error "Make is required. Run the prerequisite phase first."
    exit 1
  fi
}

run_make_target() {
  local target=$1
  if command -v make > /dev/null 2>&1; then
    make --no-print-directory -C "${JSH_DIR}" "${target}" < "${TTY}"
  elif command -v gmake > /dev/null 2>&1; then
    gmake --no-print-directory -C "${JSH_DIR}" "${target}" < "${TTY}"
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
      jsh_success "Jsh command is already installed: ${launcher}"
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
      jsh_success "Jsh PATH is already configured: ${rc_file}"
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
if [[ ${mode} == shell ]]; then
  jsh_info "jsh"
  jsh_detail "Install directory: ${JSH_DIR}"
  jsh_detail "This opens an isolated shell without changing your dotfiles or system configuration."
  install_prerequisites shell 1
  sync_repository
  jsh_blank
  jsh_success "Jsh is ready."
  jsh_detail "When you want the full Jsh experience, run: jsh install"
  jsh_blank
  exec "${JSH_DIR}/bin/jsh" < "${TTY}"
fi

if [[ ${mode} == runtime ]]; then
  jsh_info "jsh runtime"
  jsh_detail "Install directory: ${JSH_DIR}"
  jsh_detail "This installs an opt-in J shell without deploying managed dotfiles or configuring the system."

  heading "1/3" "Prerequisites" "Ensure Git and Zsh are available."
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

  heading "3/3" "Shell runtime" "Install the launcher and optionally configure Bash and Zsh PATH."
  if confirm "Run this phase?"; then
    install_runtime_launcher
    configure_runtime_path
  else
    jsh_note "Skipped shell runtime installation."
  fi

  jsh_blank
  jsh_success "Runtime installation finished."
  [[ ${JSH_INSTALL_RETURN:-0} == 1 ]] && exit 0
  jsh_blank
  exec "${JSH_DIR}/bin/jsh" < "${TTY}"
fi

if [[ ${mode} == update ]]; then
  declare -a UPDATE_SUCCEEDED=() UPDATE_WARNINGS=() UPDATE_ERRORS=()
  jsh_info "jsh update"
  jsh_detail "Install directory: ${JSH_DIR}"
  export JSH_CONTINUE_ON_ERROR=1 JSH_UPDATE=1
  run_update_step "Repository and submodules" update_repository
  run_update_step "Prerequisites" install_prerequisites install 0
  run_update_step "Packages and dependencies" run_make_target install
  run_update_step "Betterfox" "${JSH_DIR}/scripts/unix/configure/waterfox.sh" update
  run_update_step "Dotfiles" run_make_target deploy
  run_update_step "Configuration" run_make_target configure
  run_update_step "Patches" run_make_target patch
  print_update_summary
  ((${#UPDATE_ERRORS[@]} == 0))
  exit
fi

jsh_info "jsh install"
jsh_detail "Install directory: ${JSH_DIR}"
jsh_detail "Each phase explains its changes before it runs."

heading "1/3" "Prerequisites" "Install Homebrew when needed, then ensure Git, Make, Zsh, and Bash 5 are available."
if confirm "Run this phase?"; then
  install_prerequisites install 0
else
  jsh_note "Skipped prerequisites."
fi

heading "2/3" "Repository" "Clone ${JSH_REPO}, or fast-forward an existing clean checkout."
if confirm "Run this phase?"; then
  sync_repository
else
  jsh_note "Skipped repository sync."
fi

heading "3/3" "System setup" "Deploy dotfiles, install packages, then run the conversational configuration scripts for this platform."
if confirm "Run this phase?"; then
  jsh_blank
  setup_system
else
  jsh_note "Skipped system setup."
fi

jsh_blank
jsh_success "Installation finished."
[[ ${JSH_INSTALL_RETURN:-0} == 1 ]] && exit 0
jsh_blank
exec "${JSH_DIR}/bin/jsh" < "${TTY}"
