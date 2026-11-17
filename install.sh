#!/usr/bin/env bash
# Bootstrap jsh, link dotfiles, and set up explicitly named apps or system settings.

set -euo pipefail

export JSH_SESSION_START=$SECONDS

jsh::usage() {
  printf '%s\n' 'Usage: ./install.sh [--dry-run] [--update] [--list] [GROUP ...]' \
    '' 'With no groups, the scope follows the machine: every group on a workstation' \
    'with admin rights (sudo/root on Linux, the admin group on macOS), otherwise only' \
    'the base shell and dotfiles. Named groups run only those;' \
    'scripts/NAME.sh runs directly.' \
    '' 'Use --update to update software; Homebrew updates all installed packages and' \
    'removes deprecated or disabled packages. Configuration remains idempotent.'
}

# Read every option first; group names are checked against the checkout's scripts/groups.tsv.
help=0
list=0
groups=()
for argument in "$@"; do
  case ${argument} in
    --help | -h) help=1 ;;
    --list) list=1 ;;
    --dry-run) export JSH_DRY_RUN=1 ;;
    --update) export JSH_UPDATE=1 ;;
    -*)
      printf 'jsh: unknown option or group: %s\n' "${argument}" >&2
      exit 2
      ;;
    *) groups+=("${argument}") ;;
  esac
done

# Piped bootstrap has no source file; clone first, then use the checked-out installer.
source_path=${BASH_SOURCE[0]:-}
if [[ -z ${source_path} || ! -f ${source_path} || ! -d $(dirname -- "${source_path}")/scripts ]]; then
  target=${JSH_HOME:-${HOME}/.jsh}
  if ((help || list)); then
    jsh::usage
    printf '\nGroups: run %s/install.sh --list after installing.\n' "${target}"
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
jsh::groups >/dev/null || exit 2
if ((list)); then
  jsh::groups
  exit 0
fi
if ((help)); then
  jsh::usage
  printf '\nGroups:\n'
  while IFS=$'\t' read -r name purpose; do
    printf '  %-12s %s\n' "${name}" "${purpose}"
  done < <(jsh::groups table)
  exit 0
fi
# Validate every name before making changes; core and shell always run first.
for group in ${groups[@]+"${groups[@]}"}; do
  case ${group} in core | shell) continue ;; esac
  jsh::is_group "${group}" || {
    printf 'jsh: unknown option or group: %s\n' "${group}" >&2
    printf 'jsh: rerun %s/install.sh with names from --list\n' "${JSH_ROOT}" >&2
    exit 2
  }
done
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

# Without named groups, select every workstation group when the user has admin access.
skip_workstation=0
if ((${#groups[@]} == 0)); then
  workstation=0
  if [[ ${JSH_PLATFORM} == darwin ]]; then
    [[ ${EUID} != 0 && " $(id -Gn) " == *" admin "* ]] && workstation=1
  elif jsh::admin; then
    workstation=1
  elif [[ " $(id -Gn) " == *' sudo '* || " $(id -Gn) " == *' wheel '* ]]; then
    jsh::notice 'Workstation setup needs sudo; run sudo -v first, then rerun ./install.sh'
  fi
  if ((workstation)); then
    while IFS= read -r group; do groups+=("${group}"); done < <(jsh::groups)
  else
    skip_workstation=1
  fi
fi

# Bootstrap core, shell, and links always run first.
selected=()
for group in ${groups[@]+"${groups[@]}"}; do
  case ${group} in core | shell) ;; *) selected+=("${group}") ;; esac
done
if [[ ${JSH_UPDATE:-0} == 1 ]]; then
  export JSH_BREW_DEFER=1
fi

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
  jsh::link "${JSH_ROOT}/scripts/ghostty/linux.conf" "${HOME}/.config/ghostty/linux.conf"
fi
jsh::step link commands
for source in "${JSH_ROOT}"/bin/*; do
  [[ -f ${source} && -x ${source} ]] || continue
  jsh::link "${source}" "${HOME}/.local/bin/${source##*/}"
done
if ((skip_workstation)); then
  jsh::skipped "workstation groups: needs admin rights"
fi

status=0
if [[ ${JSH_UPDATE:-0} == 1 ]]; then
  jsh::group packages
  group_status=0
  JSH_BREW_DEFER=0 jsh::packages maintenance || group_status=$?
  if ((group_status != 0)); then
    jsh::fail "packages failed (${group_status})"
    status=1
  fi
fi
for group in ${selected[@]+"${selected[@]}"}; do
  group_platform=
  group_purpose=
  while IFS="	" read -r name platform purpose; do
    if [[ ${name} == "${group}" ]]; then
      group_platform=${platform}
      group_purpose=${purpose}
      break
    fi
  done <"${JSH_ROOT}/scripts/groups.tsv"
  jsh::group "${group}" "${group_purpose}"
  if [[ ${group_platform} == linux && ${JSH_PLATFORM} == darwin ]]; then
    if [[ ${group} == linux ]]; then
      jsh::skipped "Linux configuration on macOS"
    else
      jsh::skipped "${group} on macOS: Linux only"
    fi
    continue
  fi
  if [[ ${group_platform} == darwin && ${JSH_PLATFORM} != darwin ]]; then
    if [[ ${group} == macos ]]; then
      jsh::skipped "macOS configuration on Linux"
    else
      jsh::skipped "${group} on Linux: macOS only"
    fi
    continue
  fi
  group_status=0
  if [[ -f ${JSH_ROOT}/scripts/${group}.sh ]]; then
    bash "${JSH_ROOT}/scripts/${group}.sh" || group_status=$?
  else
    jsh::packages "${group}" || group_status=$?
  fi
  jsh::event stepclose
  if ((group_status != 0)); then
    jsh::fail "${group} failed (${group_status})"
    status=1
  fi
done
unset JSH_BREW_DEFER
jsh::session_close "${status}"
if [[ ${status} == 0 && ${JSH_DRY_RUN} != 1 ]]; then jsh::handoff; fi
exit "${status}"
