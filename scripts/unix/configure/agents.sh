#!/usr/bin/env bash
# Validate AI agent clients, apply shared agent config, and reconcile undeclared extras.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

dry_run=${JSH_CONFIGURE_DRY_RUN:-0}
jagents=${JSH_ROOT}/bin/jagents

report() {
  local kind message
  while IFS=$'\t' read -r kind message; do
    case ${kind} in
      ok) jsh::log_detail "${message}" ;;
      fixed) jsh::log_success "${message}" ;;
      issue) jsh::log_warn "${message}" ;;
    esac
  done <<< "$1"
}

repair=--repair
[[ ${dry_run} != 1 ]] || repair=
report "$("${JSH_ROOT}/lib/unix/agents.sh" "${JSH_ROOT}" ${repair})"

command -v python3 > /dev/null 2>&1 || {
  jsh::log_warn 'AI agent parity skipped: python3 is missing.'
  exit 0
}
apply_args=()
[[ ${dry_run} != 1 ]] || apply_args+=(--dry-run)
report "$("${jagents}" apply ${apply_args[@]+"${apply_args[@]}"})"

extras=$("${jagents}" extras --tsv) || {
  jsh::log_warn 'AI agent extras could not be listed; run `jagents extras` for details.'
  exit 0
}
[[ -n ${extras} ]] || {
  jsh::log_detail 'AI agents: nothing configured outside conf/agents.json'
  exit 0
}

count=$(grep -c . <<< "${extras}")
jsh::log_warn "AI agents: ${count} item(s) configured but not declared in conf/agents.json"
while IFS=$'\t' read -r id _ location; do
  jsh::log_detail "${id}  ${location}"
done <<< "${extras}"

# Unattended runs only report; reconciling extras always needs an explicit choice.
if [[ ${dry_run} == 1 || ${JSH_ASSUME_YES:-0} == 1 || ${JSH_NON_INTERACTIVE:-0} == 1 ||
  ${JSH_INTERACTIVE:-0} != 1 ]]; then
  jsh::log_note 'Run `jagents extras` and `jagents remove|keep|adopt ID...` to reconcile.'
  exit 0
fi

pairs=()
while IFS=$'\t' read -r id _ _; do
  pairs+=("${id}" "${id}")
done <<< "${extras}"

for action in adopt keep remove; do
  case ${action} in
    adopt) header='Adopt into the shared config for every agent? (none by default)' ;;
    keep) header='Keep for that agent only? (none by default)' ;;
    remove) header='Remove from the agent? (none by default)' ;;
  esac
  selected=$(jsh::choose_many "${header}" "${pairs[@]}") || continue
  [[ -n ${selected} ]] || continue
  mapfile -t picks <<< "${selected}"
  if output=$("${jagents}" "${action}" "${picks[@]}" 2>&1); then
    while IFS= read -r line; do jsh::log_success "${line}"; done <<< "${output}"
    [[ ${action} != adopt ]] || report "$("${jagents}" apply)"
  else
    while IFS= read -r line; do jsh::log_warn "${line}"; done <<< "${output}"
  fi
  remaining=()
  for ((index = 0; index < ${#pairs[@]}; index += 2)); do
    grep -Fxq -- "${pairs[index]}" <<< "${selected}" || remaining+=("${pairs[index]}" "${pairs[index]}")
  done
  pairs=("${remaining[@]}")
  ((${#pairs[@]} > 0)) || break
done
if ((${#pairs[@]} > 0)); then
  jsh::log_note "$((${#pairs[@]} / 2)) extra(s) left as they are."
fi
