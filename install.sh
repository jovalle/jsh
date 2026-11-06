#!/usr/bin/env bash
# Bootstrap jsh, link dotfiles, and set up explicitly named apps or system settings.

set -euo pipefail

# Validate every choice before making changes.
groups=()
for argument in "$@"; do
  case ${argument} in
    --help | -h)
      printf '%s\n' 'Usage: ./install.sh [--dry-run] [--update] [GROUP ...]' \
        '' 'With no groups, the scope follows the machine: every group on a workstation' \
        'with admin rights (sudo/root on Linux, the admin group on macOS), otherwise only' \
        'the base shell and dotfiles. Named groups run only those;' \
        'scripts/NAME.sh runs directly.' \
        'Groups: ai apps audio containers desktop dev display dock fonts ghostty git' \
        '        helium keybindings kube linux macos password services shell skills' \
        '        sublime tools vscode wallpaper waterfox' \
        '' 'Use --update to update software; Homebrew updates all installed packages and' \
        'removes deprecated or disabled packages. Configuration remains idempotent.'
      exit 0
      ;;
    --dry-run) export JSH_DRY_RUN=1 ;;
    --update) export JSH_UPDATE=1 ;;
    ai | apps | audio | containers | core | desktop | dev | display | dock | fonts | ghostty | git | helium | keybindings | kube | linux | macos | password | services | shell | skills | sublime | tools | vscode | wallpaper | waterfox) groups+=("${argument}") ;;
    *)
      printf 'jsh: unknown option or group: %s\n' "${argument}" >&2
      exit 2
      ;;
  esac
done

# Piped bootstrap has no source file; clone first, then use the checked-out installer.
source_path=${BASH_SOURCE[0]:-}
if [[ -z ${source_path} || ! -f ${source_path} || ! -d $(dirname -- "${source_path}")/scripts ]]; then
  target=${JSH_HOME:-${HOME}/.jsh}
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
JSH_ROOT=$(cd -- "$(dirname -- "${source_path}")" && pwd -P)
export JSH_ROOT
unset source_path

# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT}/scripts/lib/common.sh"
export JSH_PACKAGE_STATE=${JSH_TMP}/packages

jsh::handoff() {
  local request
  if [[ -n ${JSH_RUNTIME_DIR:-} ]]; then
    if [[ ${JSH_RELOAD_PID:-} =~ ^[0-9]+$ ]]; then
      request=${JSH_RUNTIME_DIR}/reload-${JSH_RELOAD_PID}
      if [[ -d ${request} ]] || mkdir -- "${request}"; then return; fi
    fi
    jsh::log_detail 'Run "jsh reload" to refresh the current runtime'
  elif [[ -t 1 && -t 2 ]]; then
    jsh::log_detail 'Opening the jsh runtime...'
    env -u JSH_PROGRESS_FILE -u JSH_REPORT -u JSH_PACKAGE_STATE -u JSH_STEP -u JSH_DRY_RUN \
      -u JSH_UPDATE "${JSH_ROOT}/bin/jsh" </dev/tty
  else
    printf 'Run "$HOME/.local/bin/jsh" to open the runtime\n'
  fi
}

# One monitor owns the terminal while the child runs every setup step.
if [[ -t 1 && -t 2 && ${TERM:-} != dumb && ${JSH_DRY_RUN} != 1 && -z ${JSH_PROGRESS_FILE:-} ]]; then
  export JSH_PROGRESS_FILE=${JSH_TMP}/progress
  printf '%s\n' 'Starting installer' >"${JSH_PROGRESS_FILE}"
  status=0
  jsh::monitor bash "${JSH_ROOT}/install.sh" "$@" || status=$?
  if ((status == 0)); then jsh::handoff; fi
  exit "${status}"
fi

export JSH_REPORT=${JSH_TMP}/report
mkdir -p "${JSH_REPORT}"
: >"${JSH_REPORT}/events"
: >"${JSH_REPORT}/notices"
start=${SECONDS}
failures=0
jsh::install_summary() {
  local event added=0 changed=0 removed=0 elapsed=$((SECONDS - start)) label
  [[ -z ${JSH_PROGRESS_FILE:-} ]] || : >"${JSH_PROGRESS_FILE}"
  while IFS= read -r event; do
    case ${event} in
      added) added=$((added + 1)) ;;
      changed) changed=$((changed + 1)) ;;
      removed) removed=$((removed + 1)) ;;
    esac
  done <"${JSH_REPORT}/events"
  if ((failures)); then label='Finished with errors'
  elif [[ ${JSH_DRY_RUN} == 1 ]]; then label='Preview complete'
  else label='Ready'; fi
  if ((failures)); then label=$(jsh::paint 1 31 "${label}")
  else label=$(jsh::paint 1 32 "${label}"); fi
  printf '\n%s' "${label}"
  if ((added + changed + removed == 0)); then
    if ((failures)); then :
    elif [[ ${JSH_DRY_RUN} == 1 ]]; then printf '  No changes identified'
    else printf '  Everything is current'; fi
  else
    ((added == 0)) || printf '  %s added' "${added}"
    ((changed == 0)) || printf '  %s changed' "${changed}"
    ((removed == 0)) || printf '  %s removed' "${removed}"
  fi
  ((failures == 0)) || printf '  %s failed' "${failures}"
  printf '  %sm %02ds\n' "$((elapsed / 60))" "$((elapsed % 60))"
  if [[ ${JSH_DRY_RUN} == 1 ]]; then printf 'No settings changed\n'; fi
  if [[ -s ${JSH_REPORT}/notices ]]; then
    printf '\n%s\n' "$(jsh::paint 1 33 'Action needed')"
    while IFS= read -r event; do printf '  %s\n' "${event}"; done <"${JSH_REPORT}/notices"
  fi
}

# Without named groups, select workstation setup when the user has admin access.
if ((${#groups[@]} == 0)); then
  workstation=0
  if [[ ${JSH_PLATFORM} == darwin ]]; then
    [[ ${EUID} != 0 && " $(id -Gn) " == *' admin '* ]] && workstation=1
  elif jsh::admin; then
    workstation=1
  elif [[ " $(id -Gn) " == *' sudo '* || " $(id -Gn) " == *' wheel '* ]]; then
    jsh::notice 'Workstation setup needs sudo; run sudo -v first, then rerun ./install.sh'
  fi
  if ((workstation)); then
    if [[ ${JSH_PLATFORM} == darwin ]]; then groups=(macos); else groups=(linux); fi
    groups+=(dev git ghostty containers kube fonts password tools services apps desktop dock
      display keybindings audio wallpaper vscode sublime helium waterfox ai skills)
  fi
fi

# Bootstrap core, shell, and links always run first, so they count as steps 1-3.
selected=()
for group in ${groups[@]+"${groups[@]}"}; do
  case ${group} in core | shell) ;; *) selected+=("${group}") ;; esac
done
total=$((${#selected[@]} + 3))
if [[ ${JSH_UPDATE:-0} == 1 ]]; then
  total=$((total + 1))
  export JSH_BREW_DEFER=1
fi

action=Install
[[ ${JSH_UPDATE:-0} != 1 ]] || action=Update
[[ ${JSH_DRY_RUN} != 1 ]] || action=Preview
# A monitored child writes to a log, but the monitor relays to the terminal.
if [[ -n ${JSH_PROGRESS_FILE:-} && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
  _jsh_color_1=1 jsh_banner "${action}"
else
  jsh_banner "${action}"
fi
printf '\n'
jsh::module() {
  local _jsh_color_1=${_jsh_color_1}
  if [[ -n ${JSH_PROGRESS_FILE:-} && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then _jsh_color_1=1; fi
  jsh::log_info "$(jsh::paint 1 36 "$1")"
}
jsh::module core


# Make the checkout available at the standard path, unless it already lives there.
if [[ ! ${HOME}/.jsh -ef ${JSH_ROOT} ]]; then
  jsh::link "${JSH_ROOT}" "${HOME}/.jsh"
fi

# Base prerequisites come first so every script has jq, curl, and a supported shell.
export JSH_STEP="[1/${total}] core "
if jsh::packages core; then :; else
  status=$?
  jsh::log_error "core bootstrap failed (${status})"
  failures=1
  jsh::install_summary
  exit "${status}"
fi
jsh::module shell
export JSH_STEP="[2/${total}] shell "
if bash "${JSH_ROOT}/scripts/shell.sh"; then :; else
  status=$?
  jsh::log_error "shell bootstrap failed (${status})"
  failures=1
  jsh::install_summary
  exit "${status}"
fi

# Link files individually so unmanaged sibling settings remain intact.
jsh::module links
export JSH_STEP="[3/${total}] links "
jsh::activity 'Linking configuration'
while IFS= read -r -d '' source; do
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
for source in "${JSH_ROOT}"/bin/*; do
  [[ -f ${source} && -x ${source} ]] || continue
  jsh::link "${source}" "${HOME}/.local/bin/${source##*/}"
done


status=0
step=3
if [[ ${JSH_UPDATE:-0} == 1 ]]; then
  step=$((step + 1))
  export JSH_STEP="[${step}/${total}] packages "
  jsh::module packages
  if JSH_BREW_DEFER=0 jsh::packages maintenance; then :; else
    jsh::log_error 'packages failed'
    failures=$((failures + 1))
    status=1
  fi
fi
for group in ${selected[@]+"${selected[@]}"}; do
  step=$((step + 1))
  export JSH_STEP="[${step}/${total}] ${group} "
  jsh::module "${group}"
  jsh::activity "Starting ${group}"
  group_status=0
  if [[ -f ${JSH_ROOT}/scripts/${group}.sh ]]; then
    bash "${JSH_ROOT}/scripts/${group}.sh" || group_status=$?
  else
    jsh::packages "${group}" || group_status=$?
  fi
  if ((group_status != 0)); then
    jsh::log_error "${group} failed (${group_status})"
    failures=$((failures + 1))
    status=1
  fi
done
unset JSH_STEP JSH_BREW_DEFER
jsh::install_summary
if [[ ${status} == 0 && ${JSH_DRY_RUN} != 1 && -z ${JSH_PROGRESS_FILE:-} ]]; then jsh::handoff; fi
exit "${status}"
