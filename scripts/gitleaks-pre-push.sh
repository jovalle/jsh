#!/usr/bin/env bash

set -euo pipefail

ZERO_OID=0000000000000000000000000000000000000000
FULL_AUDIT=false

fail() {
  printf 'gitleaks: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

scan_file_for_identity() {
  local category=$1
  local file=$2

  [[ -s "${MARKERS_FILE}" ]] || return 0
  if LC_ALL=C grep -Fqi -f "${MARKERS_FILE}" -- "${file}"; then
    fail "protected identity detected in ${category}"
  fi
}

capture_and_scan() {
  local category=$1
  shift

  local output_file="${WORK_DIR}/candidate"
  : >"${output_file}"
  "$@" >"${output_file}" || fail "could not inspect ${category}"
  scan_file_for_identity "${category}" "${output_file}"
  rm -f -- "${output_file}"
}

scan_value() {
  local category=$1
  local value=$2
  local output_file="${WORK_DIR}/candidate"

  printf '%s\n' "${value}" >"${output_file}"
  scan_file_for_identity "${category}" "${output_file}"
  rm -f -- "${output_file}"
}

remote_owner() {
  local url=$1
  local path

  case "${url}" in
    *@*:*/*)
      path=${url#*:}
      ;;
    ssh://* | http://* | https://*)
      path=${url#*://}
      path=${path#*/}
      ;;
    *)
      return 0
      ;;
  esac

  [[ "${path}" == */* ]] && printf '%s\n' "${path%%/*}"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

build_identity_markers() {
  [[ -f "${PROFILES_FILE}" ]] || fail "local profile data is unavailable"
  jq -e '.profiles | type == "object"' "${PROFILES_FILE}" >/dev/null 2>&1 \
    || fail "local profile data is invalid"
  jq -e '
        [.profiles[] | .name, .email, .user, .ssh_host, .ssh_key, .signingkey]
        | all(. == null or (type == "string" and (contains("\n") or contains("\r") | not)))
    ' "${PROFILES_FILE}" >/dev/null 2>&1 || fail "local profile fields are invalid"

  ACTIVE_PROFILE=$(git config --local jsh.profile 2>/dev/null || true)
  [[ -n "${ACTIVE_PROFILE}" ]] || fail "no jsh.profile is assigned"
  jq -e --arg profile "${ACTIVE_PROFILE}" '.profiles[$profile] | type == "object"' \
    "${PROFILES_FILE}" >/dev/null 2>&1 || fail "assigned profile is unavailable"

  ACTIVE_USER=$(jq -er --arg profile "${ACTIVE_PROFILE}" \
    '.profiles[$profile].user | select(type == "string" and length > 0)' \
    "${PROFILES_FILE}") || fail "assigned profile has no account user"

  jq -r --arg profile "${ACTIVE_PROFILE}" '
        .profiles[$profile]
        | [.name, .email, .user, .ssh_host, (.ssh_key // "" | split("/")[-1]),
           (.signingkey // "" | split("/")[-1])]
        | .[] | select(type == "string" and length >= 4)
    ' "${PROFILES_FILE}" >"${WORK_DIR}/active-markers"

  jq -r --arg profile "${ACTIVE_PROFILE}" '
        .profiles | to_entries[] | select(.key != $profile) | .value
        | [.name, .email, .user, .ssh_host,
           (.ssh_key // "" | split("/")[-1]),
           (.signingkey // "" | split("/")[-1])]
        | .[] | select(type == "string" and length >= 4)
    ' "${PROFILES_FILE}" >"${WORK_DIR}/raw-markers"

  awk '
        NR == FNR { active[tolower($0)] = 1; next }
        {
            marker = tolower($0)
            if (!active[marker] && marker != "id_rsa" && marker != "id_dsa" &&
                marker != "id_ecdsa" && marker != "id_ed25519") print marker
        }
    ' "${WORK_DIR}/active-markers" "${WORK_DIR}/raw-markers" \
    | LC_ALL=C sort -fu >"${MARKERS_FILE}"
}

run_gitleaks() {
  local log_options=$1
  local report_file="${WORK_DIR}/gitleaks.json"
  local log_file="${WORK_DIR}/gitleaks.log"

  if gitleaks git --config "${ROOT_DIR}/.gitleaks.toml" \
    --log-opts="${log_options}" --redact=100 --verbose --no-banner \
    --ignore-gitleaks-allow --max-decode-depth 3 --max-archive-depth 2 \
    --timeout "${GITLEAKS_TIMEOUT_SECONDS:-600}" --report-format json \
    --report-path "${report_file}" "${ROOT_DIR}" >"${log_file}" 2>&1; then
    return 0
  fi

  if [[ -s "${report_file}" ]] && jq -e 'length > 0' "${report_file}" >/dev/null 2>&1; then
    jq -r '.[] | "gitleaks: \(.RuleID) in \(.File):\(.StartLine) commit \(.Commit)"' \
      "${report_file}" >&2
    fail "push blocked by secret findings"
  fi

  fail "secret scan failed; rerun the full audit locally for diagnostics"
}

scan_git_range() {
  local revision_spec=$1
  local commit

  while IFS= read -r commit; do
    [[ -n "${commit}" ]] || continue
    capture_and_scan "commit identity or message in commit ${commit}" \
      git show -s --format='%H%n%an%n%ae%n%cn%n%ce%n%B' "${commit}"
    capture_and_scan "changed path in commit ${commit}" git show "${commit}" \
      --format= --diff-merges=separate --name-only --diff-filter=ACMRT
    capture_and_scan "added content in commit ${commit}" sh -c \
      'git show "$1" --format= --diff-merges=separate -p --no-ext-diff | sed -n '\''/^+++ /d; /^+/s/^+//p'\''' \
      sh "${commit}"
  done < <(git rev-list "${revision_spec}")
}

scan_all_metadata() {
  capture_and_scan "repository refs" git for-each-ref --format='%(refname)'
  capture_and_scan "configured remotes" git remote -v
  capture_and_scan "tag metadata" git for-each-ref refs/tags --format='%(contents)'
}

case "${1:-}" in
  --full-audit)
    FULL_AUDIT=true
    shift
    ;;
  "") ;;
  *) fail "unknown argument: $1" ;;
esac
[[ $# -eq 0 ]] || fail "unexpected arguments"

require_command git
require_command gitleaks
require_command jq

ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not in a Git repository"
cd "${ROOT_DIR}"

PROFILES_FILE=${JSH_PROFILES:-${ROOT_DIR}/local/profiles.json}
mkdir -p "${ROOT_DIR}/tmp"
umask 077
WORK_DIR=$(mktemp -d "${ROOT_DIR}/tmp/gitleaks.XXXXXX")
trap 'rm -rf -- "${WORK_DIR}"' EXIT HUP INT TERM
MARKERS_FILE=${WORK_DIR}/identity-markers

build_identity_markers

if [[ "${FULL_AUDIT}" == true ]]; then
  run_gitleaks '--all --full-history --diff-merges=separate'
  scan_git_range '--all'
  scan_all_metadata
  printf 'gitleaks: full audit passed\n'
  exit 0
fi

REMOTE_OID=${PRE_COMMIT_FROM_REF:-}
LOCAL_OID=${PRE_COMMIT_TO_REF:-}
REMOTE_URL=${PRE_COMMIT_REMOTE_URL:-}
REMOTE_BRANCH=${PRE_COMMIT_REMOTE_BRANCH:-}
LOCAL_BRANCH=${PRE_COMMIT_LOCAL_BRANCH:-}

[[ "${REMOTE_OID}" =~ ^[0-9a-fA-F]{40}$ ]] || fail "invalid remote object ID"
[[ "${LOCAL_OID}" =~ ^[0-9a-fA-F]{40}$ ]] || fail "invalid local object ID"
[[ -n "${REMOTE_URL}" ]] || fail "destination remote URL is unavailable"

if [[ "${LOCAL_OID}" == "${ZERO_OID}" ]]; then
  exit 0
fi

git cat-file -e "${LOCAL_OID}^{object}" 2>/dev/null || fail "local object is unavailable"
LOCAL_COMMIT=$(git rev-parse "${LOCAL_OID}^{commit}" 2>/dev/null) \
  || fail "pushed object does not resolve to a commit"

OWNER=$(remote_owner "${REMOTE_URL}")
if [[ -n "${OWNER}" ]] \
  && [[ "$(lowercase "${OWNER}")" != "$(lowercase "${ACTIVE_USER}")" ]]; then
  fail "assigned profile does not match the destination remote owner"
fi

scan_value "destination remote URL" "${REMOTE_URL}"
scan_value "local ref name" "${LOCAL_BRANCH}"
scan_value "remote ref name" "${REMOTE_BRANCH}"

if [[ "${REMOTE_OID}" == "${ZERO_OID}" ]]; then
  REVISION_SPEC=${LOCAL_COMMIT}
  LOG_OPTIONS="--full-history --diff-merges=separate ${LOCAL_COMMIT}"
else
  git cat-file -e "${REMOTE_OID}^{commit}" 2>/dev/null || fail "remote commit is unavailable"
  REVISION_SPEC="${REMOTE_OID}..${LOCAL_COMMIT}"
  LOG_OPTIONS="--full-history --diff-merges=separate ${REVISION_SPEC}"
fi

if [[ "$(git cat-file -t "${LOCAL_OID}")" == tag ]]; then
  capture_and_scan "tag metadata" git cat-file tag "${LOCAL_OID}"
fi

run_gitleaks "${LOG_OPTIONS}"
scan_git_range "${REVISION_SPEC}"
printf 'gitleaks: outgoing audit passed\n'
