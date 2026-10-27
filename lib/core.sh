#!/usr/bin/env bash
# Shared execution, platform detection, and plain logging.

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
  if [[ ${JSH_DRY_RUN:-0} == 1 || ${EUID} == 0 ]]; then
    jsh::run "$@"
  else
    # Never leave automation waiting for a password.
    sudo -n -- "$@"
  fi
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

jsh::platform() {
  case $(uname -s) in
    Darwin) printf '%s\n' darwin ;;
    Linux)
      local ID='' ID_LIKE=''
      # shellcheck source=/dev/null
      . /etc/os-release
      case " ${ID} ${ID_LIKE} " in
        *' debian '* | *' ubuntu '*) printf '%s\n' debian ;;
        *' rhel '* | *' fedora '* | *' centos '* | *' rocky '* | *' almalinux '*) printf '%s\n' rhel ;;
        *)
          jsh::log_error "Unsupported Linux distribution: ${ID}"
          return 1
          ;;
      esac
      ;;
    *)
      jsh::log_error 'Supported platforms: macOS, Debian-family Linux, RHEL-family Linux.'
      return 1
      ;;
  esac
}

_jsh_run_job() {
  local preferences=linux
  [[ ${JSH_PLATFORM} != darwin ]] || preferences=darwin
  case $1 in
    install) python3 "${JSH_ROOT}/scripts/install.py" "${2:-all}" ${3:+"$3"} ;;
    dotfiles) bash "${JSH_ROOT}/scripts/dotfiles.sh" ;;
    tweak) bash "${JSH_ROOT}/scripts/tweak/${preferences}.sh" ;;
    customize) bash "${JSH_ROOT}/scripts/customize.sh" "${2:-all}" ;;
    configure) python3 "${JSH_ROOT}/scripts/configure.py" "${2:-all}" ;;
  esac
}

# Usage: jsh::job JOB [COMPONENT] [--dry-run] [--yes]. Confirms once, then runs the job.
jsh::job() {
  local job=$1 component='' argument started
  shift
  export JSH_DRY_RUN=0 JSH_ASSUME_YES=0 PYTHONDONTWRITEBYTECODE=1
  for argument in "$@"; do
    case ${argument} in
      --dry-run) JSH_DRY_RUN=1 ;;
      -y | --yes) JSH_ASSUME_YES=1 ;;
      -*)
        jsh::log_error "Unknown option: ${argument}"
        return 2
        ;;
      *)
        if [[ -n ${component} ]]; then
          jsh::log_error 'Too many arguments.'
          return 2
        fi
        component=${argument}
        ;;
    esac
  done
  case ${job}:${component} in
    install: | install:all | install:core | install:tools | install:runtime | install:apps | \
      install:extensions | install:helium | install:waterfox | install:vscode | install:ghostty | \
      install:spotify | install:todoist | install:sublime | \
      dotfiles: | tweak: | tweak:preferences | customize: | customize:all | \
      customize:wallpaper | customize:keybindings | customize:desktop | customize:dock | \
      customize:audio | customize:display | configure: | configure:all | \
      configure:helium | configure:waterfox | configure:vscode | configure:sublime | \
      configure:agents | \
      setup:) ;;
    *)
      jsh::log_error "Unknown target: ${job}${component:+ ${component}}"
      return 2
      ;;
  esac
  JSH_PLATFORM=$(jsh::platform)
  export JSH_PLATFORM
  if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
    jsh::log_error 'Python 3.9 or later is required. See README.md for prerequisites.'
    return 1
  fi
  [[ ! -t 1 ]] || jsh_banner
  if ! jsh::confirm "Run ${job}${component:+ ${component}}?"; then
    jsh::log_info 'Skipped.'
    return 0
  fi
  # Subcommands have already received consent for this specific scope.
  export JSH_ASSUME_YES=1
  started=$(jsh::clock)
  if [[ ${job} == setup ]]; then
    for job in install dotfiles tweak customize configure; do
      jsh::log_section "${job}"
      _jsh_run_job "${job}"
    done
  else
    _jsh_run_job "${job}" "${component}"
  fi
  printf '\n'
  jsh::log_success "Done in $(jsh::duration "$(($(jsh::clock) - started))")"
}
