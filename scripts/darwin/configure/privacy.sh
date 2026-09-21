#!/usr/bin/env bash
# Revoke optional macOS app privacy permissions through System Settings.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
POLICY_PATH="${JSH_ROOT}/conf/privacy.json"
readonly POLICY_PATH
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

render_policy_diff() {
  local color line
  while IFS= read -r line || [[ -n ${line} ]]; do
    case ${line} in
    '--- '* | '+++ '*) color='1;36' ;;
    '@@'*) color=36 ;;
    -*) color=31 ;;
    +*) color=32 ;;
    *) color=2 ;;
    esac
    jsh_stdout "${color}" '' "${line}"
  done
}

render_permission_change() {
  local current desired key transition
  key=${1%%: *}
  transition=${1#*: }
  current=${transition%% -> *}
  desired=${transition#* -> }
  if jsh_color_enabled 1; then
    printf '  %s: \033[32m%s\033[0m \033[2;37m->\033[0m \033[31m%s\033[0m\n' \
      "${key}" "${current}" "${desired}"
  else
    printf '  %s: %s -> %s\n' "${key}" "${current}" "${desired}"
  fi
}

privacy_progress_label() {
  local complete current=$1 detail=${3:-} empty filled total=$2 width=20
  ((total > 0)) || total=1
  filled=$((current * width / total))
  printf -v complete '%*s' "${filled}" ''
  printf -v empty '%*s' "$((width - filled))" ''
  complete=${complete// /#}
  empty=${empty// /-}
  printf 'Applying privacy permissions [%s%s] %d/%d' "${complete}" "${empty}" "${current}" "${total}"
  [[ -z ${detail} ]] || printf '  %s' "${detail}"
}

render_apply_progress() {
  local current detail event progress total
  while IFS=$'\t' read -r event current total detail || [[ -n ${event} ]]; do
    jsh::spinner_stop
    case ${event} in
    BEGIN)
      progress=$(privacy_progress_label "${current}" "${total}" "${detail}")
      jsh::spinner_start "${progress}"
      ;;
    AUTH)
      jsh::log_warn "Authorization required for ${detail}. Complete the System Settings prompt; waiting up to 5 minutes."
      jsh::spinner_start "Waiting for authorization  ${detail}"
      ;;
    PROGRESS)
      progress=$(privacy_progress_label "${current}" "${total}")
      jsh::spinner_start "${progress}"
      ;;
    COMPLETE)
      progress=$(privacy_progress_label "${current}" "${total}")
      jsh::log_success "${progress}"
      ;;
    *) jsh::log_detail "${event}" ;;
    esac
  done
  jsh::spinner_stop
}

backup_policy() {
  local candidate current diff_file diff_status staged
  mkdir -p "${JSH_ROOT}/tmp"
  candidate=$(mktemp "${JSH_ROOT}/tmp/privacy-policy.XXXXXX")
  diff_file=$(mktemp "${JSH_ROOT}/tmp/privacy-policy-diff.XXXXXX")
  jsh::spinner_start "Inspecting active privacy permissions"
  if ! xcrun swift "${JSH_ROOT}/lib/darwin/privacy.swift" --export | jq --sort-keys . >"${candidate}"; then
    jsh::spinner_stop
    rm -f -- "${candidate}" "${diff_file}"
    jsh::log_error "Could not export privacy permissions."
    return 1
  fi
  jsh::spinner_stop
  current=${POLICY_PATH}
  [[ -e ${current} ]] || current=/dev/null
  if diff -u -L "managed privacy policy" -L "active privacy permissions" \
    "${current}" "${candidate}" >"${diff_file}"; then
    rm -f -- "${candidate}" "${diff_file}"
    jsh::log_success "Privacy policy already matches active permissions."
    return
  else
    diff_status=$?
  fi
  if ((diff_status != 1)); then
    rm -f -- "${candidate}" "${diff_file}"
    jsh::log_error "Could not compare the privacy policy with active permissions."
    return "${diff_status}"
  fi
  jsh::log_info "Privacy policy changes:"
  render_policy_diff <"${diff_file}"
  if [[ ${mode} == check ]]; then
    rm -f -- "${candidate}" "${diff_file}"
    return 1
  fi
  if [[ ${mode} == dry-run ]] || ! jsh::confirm "Replace the privacy policy with active permissions?" --default no; then
    rm -f -- "${candidate}" "${diff_file}"
    [[ ${mode} == dry-run ]] || jsh::log_note "Keeping the current privacy policy."
    return
  fi
  staged=$(mktemp "${JSH_ROOT}/tmp/privacy-policy-install.XXXXXX")
  install -m 0644 -- "${candidate}" "${staged}"
  mv -f -- "${staged}" "${POLICY_PATH}"
  rm -f -- "${candidate}" "${diff_file}"
  jsh::log_success "Privacy policy updated: ${POLICY_PATH#"${JSH_ROOT}/"}"
}

main() {
  local action=apply arg category line mode=apply plan plan_count platform previous_category='' progress
  local -a target_arguments=()
  for arg in "$@"; do
    case ${arg} in
    backup) action=backup ;;
    -y | --yes) export JSH_ASSUME_YES=1 ;;
    --check) mode=check ;;
    --dry-run) mode=dry-run ;;
    -h | --help)
      jsh::log_info "Usage: ${0##*/} [backup] [--yes | --dry-run | --check]"
      jsh::log_detail "Uses conf/privacy.json as the allowlist for Privacy & Security grants."
      jsh::log_detail "Listed grants may remain allowed; missing grants are revoked, never granted."
      jsh::log_detail "backup exports the currently allowed managed grants after review."
      jsh::log_detail "Retains Accessibility grants, Location Services itself, and Find My."
      jsh::log_detail "Requires English System Settings and terminal Accessibility permission."
      return
      ;;
    *)
      jsh::log_error "Unknown option: ${arg}"
      return 2
      ;;
    esac
  done
  platform=$(uname -s)
  [[ ${platform} == Darwin ]] || {
    jsh::log_note "Skipping privacy permissions: macOS not detected."
    return
  }
  [[ ${EUID} -ne 0 ]] || {
    jsh::log_error "Run as your normal user, without sudo."
    return 1
  }
  xcrun --find swift >/dev/null 2>&1 || {
    jsh::log_error "The Swift command-line tools are required."
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    jsh::log_error "jq is required to manage the privacy policy."
    return 1
  }
  if [[ ${action} == backup ]]; then
    backup_policy
    return
  fi
  [[ -r ${POLICY_PATH} ]] || {
    jsh::log_error "Privacy policy not found: ${POLICY_PATH#"${JSH_ROOT}/"}. Run '${0##*/} backup' first."
    return 1
  }
  jsh::spinner_start "Inspecting optional app privacy permissions"
  if ! plan=$(xcrun swift "${JSH_ROOT}/lib/darwin/privacy.swift" --dry-run --policy "${POLICY_PATH}" 2>&1); then
    jsh::spinner_stop
    while IFS= read -r line; do jsh::log_detail "${line}"; done <<<"${plan}"
    jsh::log_error "Could not inspect privacy permissions."
    return 1
  fi
  jsh::spinner_stop
  if [[ -z ${plan} ]]; then
    jsh::log_success "macOS privacy permissions already match the desired state."
    return
  fi
  plan_count=$(printf '%s\n' "${plan}" | wc -l | tr -d ' ')
  jsh::log_info "Privacy permission changes (${plan_count}):"
  while IFS= read -r line; do render_permission_change "${line}"; done <<<"${plan}"
  if [[ ${mode} == check ]]; then
    jsh::log_error "Privacy permissions differ from the desired state."
    return 1
  fi
  [[ ${mode} == dry-run ]] && return
  jsh::confirm "Apply these privacy permission changes?" --default no || {
    jsh::log_note "Skipping privacy permissions."
    return
  }
  while IFS= read -r line; do
    category=${line%% / *}
    [[ -n ${category} && ${category} != "${previous_category}" ]] || continue
    target_arguments+=(--category "${category}")
    previous_category=${category}
  done <<<"${plan}"
  progress=$(privacy_progress_label 0 "${plan_count}")
  jsh::spinner_start "${progress}"
  # shellcheck disable=SC2310 # The renderer is a streaming callback and checks its own commands.
  if xcrun swift "${JSH_ROOT}/lib/darwin/privacy.swift" \
    --policy "${POLICY_PATH}" --total "${plan_count}" "${target_arguments[@]}" 2>&1 | render_apply_progress; then
    jsh::spinner_stop
    jsh::log_success "macOS privacy permissions revoked and verified."
  else
    jsh::spinner_stop
    jsh::log_error "Privacy configuration did not complete. See the error above; rerun to finish."
    return 1
  fi
}

main "$@"
