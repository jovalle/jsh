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
Usage: j.sh [install|update]

With no arguments, install or update Jsh and open an isolated shell environment.
Run with install to install packages, deploy dotfiles, and configure the system.
Run with update to update Jsh and reapply the managed environment.
EOF
}

case ${1:-} in
  '') mode=shell ;;
  install)
    mode=install
    shift
    ;;
  update)
    mode=update
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    jsh_error "Unknown command: $1"
    usage >&2
    exit 2
    ;;
esac
if (($#)); then
  jsh_error "Too many arguments."
  usage >&2
  exit 2
fi

if [[ ! -r "${TTY}" ]] || [[ ! -w "${TTY}" ]]; then
  jsh_error "jsh needs an interactive terminal."
  exit 1
fi

heading() {
  jsh_blank
  jsh_info "[$1] $2"
  jsh_detail "$3"
}

confirm() {
  local default=${2:-yes} prompt='Y/n'
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

sync_repository() {
  if ! command -v git > /dev/null 2>&1; then
    jsh_error "Git is required. Run the prerequisite phase first."
    exit 1
  fi

  if [[ -d "${JSH_DIR}/.git" ]]; then
    if ! confirm "Update Jsh from upstream?" no; then
      return
    fi
    if [[ -n "$(git -C "${JSH_DIR}" status --porcelain)" ]]; then
      jsh_warn "Local changes found in ${JSH_DIR}; leaving the checkout unchanged."
      return
    fi
    git -C "${JSH_DIR}" pull --ff-only
    git -C "${JSH_DIR}" submodule update --init --recursive
    return
  fi

  if [[ -e "${JSH_DIR}" ]]; then
    jsh_error "Install path exists but is not a Git checkout: ${JSH_DIR}"
    exit 1
  fi

  mkdir -p "$(dirname "${JSH_DIR}")"
  git clone --recurse-submodules "${JSH_REPO}" "${JSH_DIR}"
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
  if [[ -n "$(git -C "${JSH_DIR}" status --porcelain --untracked-files=all)" ]]; then
    jsh_warn "Local changes found in ${JSH_DIR}; skipping repository and submodule updates."
    return 10
  fi

  git -C "${JSH_DIR}" pull --ff-only || return
  git -C "${JSH_DIR}" submodule sync --recursive || return
  git -C "${JSH_DIR}" submodule update --init --recursive || return
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
    jsh_warn "Skipped: ${label}"
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
  jsh_warn "Skipped prerequisites."
fi

heading "2/3" "Repository" "Clone ${JSH_REPO}, or fast-forward an existing clean checkout."
if confirm "Run this phase?"; then
  sync_repository
else
  jsh_warn "Skipped repository sync."
fi

heading "3/3" "System setup" "Deploy dotfiles, install packages, then run the conversational configuration scripts for this platform."
if confirm "Run this phase?"; then
  jsh_blank
  setup_system
else
  jsh_warn "Skipped system setup."
fi

jsh_blank
jsh_success "Installation finished."
[[ ${JSH_INSTALL_RETURN:-0} == 1 ]] && exit 0
jsh_blank
exec "${JSH_DIR}/bin/jsh" < "${TTY}"
