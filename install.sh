#!/usr/bin/env bash
# Bootstrap jsh: core packages, shell plugins, dotfiles, and commands. Configure with make configure.

set -euo pipefail

export JSH_SESSION_START=$SECONDS

jsh::usage() {
  printf '%s\n' 'Usage: ./install.sh [--dry-run] [--update]' \
    '' 'Install core packages and shell plugins, then link dotfiles and commands.' \
    'Apps, agents, and system settings are configured separately with make configure.' \
    '' 'Use --update to update core packages and shell plugins.'
}

# Read every option first.
help=0
for argument in "$@"; do
  case ${argument} in
    --help | -h) help=1 ;;
    --dry-run) export JSH_DRY_RUN=1 ;;
    --update) export JSH_UPDATE=1 ;;
    -*)
      printf 'jsh: unknown option or group: %s\n' "${argument}" >&2
      exit 2
      ;;
    *)
      printf 'jsh: install.sh takes no groups; run make configure %s\n' "${argument}" >&2
      exit 2
      ;;
  esac
done

# Piped bootstrap has no source file; clone first, then use the checked-out installer.
source_path=${BASH_SOURCE[0]:-}
if [[ -z ${source_path} || ! -f ${source_path} || ! -d $(dirname -- "${source_path}")/scripts ]]; then
  target=${JSH_HOME:-${HOME}/.jsh}
  if ((help)); then
    jsh::usage
    exit 0
  fi
  [[ ! -e ${target} && ! -L ${target} ]] || {
    printf 'jsh: %s already exists; run its install.sh\n' "${target}" >&2
    exit 1
  }
  command -v git >/dev/null 2>&1 || {
    printf 'jsh: install Git first\n' >&2
    exit 1
  }
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    printf '+ would clone  %s\n\nPreview complete\nNo settings changed\n' "${target}"
    exit 0
  fi
  export GIT_TERMINAL_PROMPT=0
  git clone --quiet -- https://github.com/jovalle/jsh.git "${target}"
  printf '+ checkout  %s\n' "${target}"
  exec bash "${target}/install.sh" "$@"
fi
# Setup never reads input; the runtime handoff opens /dev/tty itself.
exec </dev/null
JSH_ROOT=$(cd -- "$(dirname -- "${source_path}")" && pwd -P)
export JSH_ROOT
unset source_path

# common.sh parses the arguments it sees; install.sh has already read its own.
set --
export JSH_OUTPUT=plain
# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT}/scripts/lib/common.sh"
if ((help)); then
  jsh::usage
  exit 0
fi
export JSH_PACKAGE_STATE=${JSH_TMP}/packages

jsh::handoff() {
  local request
  if [[ -n ${JSH_RUNTIME_DIR:-} ]]; then
    if [[ ${JSH_RELOAD_PID:-} =~ ^[0-9]+$ ]]; then
      request=${JSH_RUNTIME_DIR}/reload-${JSH_RELOAD_PID}
      if [[ -d ${request} ]] || mkdir -- "${request}"; then return; fi
    fi
    jsh::info 'Run "jsh reload" to refresh the current runtime'
  elif [[ -t 1 && -t 2 ]]; then
    jsh::info 'Opening the jsh runtime...'
    env -u JSH_REPORT -u JSH_PACKAGE_STATE -u JSH_DRY_RUN \
      -u JSH_UPDATE -u JSH_KEEP_APPS -u JSH_OUTPUT -u JSH_SESSION_START \
      "${JSH_ROOT}/bin/jsh" </dev/tty
  else
    printf 'Run "$HOME/.local/bin/jsh" to open the runtime\n'
  fi
}

export JSH_REPORT=${JSH_TMP}/report
mkdir -p "${JSH_REPORT}"
: >"${JSH_REPORT}/events"
: >"${JSH_REPORT}/failures"
: >"${JSH_REPORT}/notices"
_JSH_SESSION_OWNER=plain

action=Install
[[ ${JSH_UPDATE:-0} != 1 ]] || action=Update
[[ ${JSH_DRY_RUN} != 1 ]] || action=Preview
jsh_banner "${action}"
printf "\n"

jsh::group core "Bootstrap packages and the checkout link"
jsh::step detect platform
case ${JSH_PLATFORM} in
  darwin) jsh::info "Detected macOS" ;;
  debian) jsh::info "Detected Debian-family Linux" ;;
  rhel) jsh::info "Detected RHEL-family Linux" ;;
  *) jsh::info "Detected Linux" ;;
esac
[[ -z ${JSH_DESKTOP} ]] || jsh::info "Detected desktop: ${JSH_DESKTOP}"

# Make the checkout available at the standard path, unless it already lives there.
if [[ ! ${HOME}/.jsh -ef ${JSH_ROOT} ]]; then
  jsh::link "${JSH_ROOT}" "${HOME}/.jsh"
fi

# Base prerequisites come first so every script has jq, curl, and a supported shell.
if jsh::packages core; then :; else
  status=$?
  jsh::fail "core failed (${status})"
  jsh::session_close "${status}"
  exit "${status}"
fi
jsh::event end "$((SECONDS - JSH_SESSION_START))" 0
jsh::session_open || :

jsh::group shell "Shell plugins and runtime"
shell_status=0
bash "${JSH_ROOT}/scripts/shell.sh" || shell_status=$?
jsh::event stepclose
if ((shell_status != 0)); then
  jsh::fail "shell failed (${shell_status})"
  jsh::session_close "${shell_status}"
  exit "${shell_status}"
fi

# Link files individually so unmanaged sibling settings remain intact.
jsh::group links "Dotfiles and commands"
jsh::step link dotfiles
while IFS= read -r -d "" source; do
  relative=${source#"${JSH_ROOT}/dotfiles/"}
  case ${relative} in
    .agents/skills/*) continue ;;
    .config/xfce4/*) [[ ${JSH_DESKTOP} == xfce ]] || continue ;;
    .local/share/icons/*) [[ ${JSH_PLATFORM} != darwin ]] || continue ;;
  esac
  jsh::link "${source}" "${HOME}/${relative}"
done < <(find "${JSH_ROOT}/dotfiles" -type f -print0)
if [[ ${JSH_PLATFORM} == linux ]]; then
  jsh::link "${JSH_ROOT}/ansible/roles/ghostty/files/linux.conf" "${HOME}/.config/ghostty/linux.conf"
fi
jsh::step link commands
for source in "${JSH_ROOT}"/bin/*; do
  [[ -f ${source} && -x ${source} ]] || continue
  jsh::link "${source}" "${HOME}/.local/bin/${source##*/}"
done

jsh::info 'Run "make configure" to set up apps, agents, and system settings'

jsh::session_close 0
if [[ ${JSH_DRY_RUN} != 1 ]]; then jsh::handoff; fi
