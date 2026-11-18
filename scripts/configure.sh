#!/usr/bin/env bash
# Configure apps, agents, and system settings through the Ansible setup groups.

set -euo pipefail

export JSH_SESSION_START=$SECONDS

jsh::usage() {
  printf '%s\n' 'Usage: scripts/configure.sh [GROUP ...]' \
    '       scripts/configure.sh [--dry-run] [--update] [--list] [GROUP ...]' \
    '' 'With no groups, every setup group runs when the user has admin rights' \
    '(sudo/root on Linux, the admin group on macOS). Named groups run only those.' \
    'Their ansible/roles/NAME roles run together in one playbook. Run ./install.sh first.' \
    '' 'Use --update to update software; Homebrew updates all installed packages and' \
    'removes deprecated or disabled packages. Configuration remains idempotent.'
}

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

exec </dev/null
JSH_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export JSH_ROOT

# common.sh parses the arguments it sees; this script has already read its own.
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
for group in ${groups[@]+"${groups[@]}"}; do
  jsh::is_group "${group}" || {
    printf 'jsh: unknown option or group: %s\n' "${group}" >&2
    printf 'jsh: rerun with names from make list groups\n' >&2
    exit 2
  }
done
[[ -L ${HOME}/.jsh || -d ${HOME}/.jsh ]] || {
  printf 'jsh: run %s/install.sh first\n' "${JSH_ROOT}" >&2
  exit 1
}
export JSH_PACKAGE_STATE=${JSH_TMP}/packages
export JSH_REPORT=${JSH_TMP}/report
mkdir -p "${JSH_REPORT}"
: >"${JSH_REPORT}/events"
: >"${JSH_REPORT}/failures"
: >"${JSH_REPORT}/notices"
_JSH_SESSION_OWNER=plain

# Without named groups, select every setup group when the user has admin access.
skip_workstation=0
if ((${#groups[@]} == 0)); then
  workstation=0
  if [[ ${JSH_PLATFORM} == darwin ]]; then
    [[ ${EUID} != 0 && " $(id -Gn) " == *" admin "* ]] && workstation=1
  elif jsh::admin; then
    workstation=1
  elif [[ " $(id -Gn) " == *' sudo '* || " $(id -Gn) " == *' wheel '* ]]; then
    jsh::notice 'Configuration needs sudo; run `sudo -v` first, then rerun `make configure`'
  fi
  if ((workstation)); then
    while IFS= read -r group; do groups+=("${group}"); done < <(jsh::groups)
  else
    skip_workstation=1
  fi
fi
[[ ${JSH_UPDATE:-0} != 1 ]] || export JSH_BREW_DEFER=1

action=Configure
[[ ${JSH_UPDATE:-0} != 1 ]] || action=Update
[[ ${JSH_DRY_RUN} != 1 ]] || action=Preview
jsh_banner "${action}"
printf "\n"
jsh::session_open || :

status=0
if ((skip_workstation)); then
  jsh::group configure "Apps, agents, and system settings"
  jsh::skipped "setup groups: needs admin rights"
fi
if [[ ${JSH_UPDATE:-0} == 1 ]]; then
  jsh::group packages
  group_status=0
  JSH_BREW_DEFER=0 jsh::packages maintenance || group_status=$?
  if ((group_status != 0)); then
    jsh::fail "packages failed (${group_status})"
    status=1
  fi
fi
# Every selected setup group runs in one playbook; the callback owns headers and platform skips.
if ((${#groups[@]})); then
  group_status=0
  jsh::playbook "${groups[@]}" || group_status=$?
  jsh::event stepclose
  if ((group_status != 0)); then
    jsh::fail "host configuration failed (${group_status})"
    status=1
  fi
fi
unset JSH_BREW_DEFER
jsh::session_close "${status}"
exit "${status}"
