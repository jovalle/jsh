#!/usr/bin/env bash
# Shared app configuration: JSONC merges, policy files, and safe browser restarts.
# shellcheck disable=SC2154 # Shared paths and launch command are supplied by callers.

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

app::jsonc() {
  jq -Rs '
    gsub("(?<s>\"(?:[^\"\\\\]|\\\\.)*\")|//[^\\n]*|/\\*[\\s\\S]*?\\*/";
      if .s then .s else " " end)
    | gsub("(?<s>\"(?:[^\"\\\\]|\\\\.)*\")|,(?=\\s*[}\\]])";
      if .s then .s else "" end)
    | fromjson | if type == "object" then . else error("settings must be an object") end' "$1"
}

app::local() {
  local candidate
  for candidate in "${XDG_CONFIG_HOME:-${HOME}/.config}/jsh/$1/$2" "${JSH_ROOT}/local/$1/$2"; do
    if [[ -f ${candidate} ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
}

app::desired() {
  local group=$1 name=$2 extra current overlay
  current=$(mktemp "${APP_TMP}/desired.XXXXXX")
  app::jsonc "${SCRIPT_DIR}/${group}/${name}" >"${current}" || return
  extra=$(app::local "${group}" "${name}")
  if [[ -n ${extra} ]]; then
    overlay=$(mktemp "${APP_TMP}/overlay.XXXXXX")
    app::jsonc "${extra}" >"${overlay}" || return
    jq -s '.[0] * .[1]' "${current}" "${overlay}"
  else cat "${current}"; fi
}

app::merged() {
  local desired=$1 target=$2 current
  current=$(mktemp "${APP_TMP}/current.XXXXXX")
  if [[ -f ${target} ]]; then
    app::jsonc "${target}" >"${current}" || return
  else printf '{}\n' >"${current}"; fi
  jq -e -s 'if length == 2 and all(.[]; type == "object") then .[0] * .[1]
    else error("settings must be objects") end' "${current}" "${desired}"
}

app::pending() {
  local desired=$1 target=$2 current merged
  jsh::activity "Checking settings ${target}"
  APP_PENDING=1
  [[ -f ${target} ]] || return 0
  current=$(mktemp "${APP_TMP}/compare.XXXXXX")
  merged=$(mktemp "${APP_TMP}/compare.XXXXXX")
  app::jsonc "${target}" | jq -Sc . >"${current}" || return
  app::merged "${desired}" "${target}" | jq -Sc . >"${merged}" || return
  if cmp -s "${current}" "${merged}"; then APP_PENDING=0; fi
}

app::json() {
  local desired=$1 target=$2 staged
  app::pending "${desired}" "${target}" || return
  if [[ ${APP_PENDING} == 0 ]]; then
    jsh::current
    return
  fi
  staged=$(mktemp "${APP_TMP}/json.XXXXXX")
  app::merged "${desired}" "${target}" >"${staged}" || return
  jsh::file "${staged}" "${target}"
}

app::policy() {
  local desired=$1 target=$2 keep=${3:-0} current updated domain backup
  APP_POLICY_CHANGED=0
  jsh::activity "Checking policy ${target}"
  current=${APP_TMP}/policy-current.json
  updated=${APP_TMP}/policy-updated.json
  if [[ -f ${target} ]]; then
    if [[ ${target} == *.plist ]]; then
      plutil -convert json -o - "${target}" >"${current}"
    else app::jsonc "${target}" >"${current}"; fi
  else printf '{}\n' >"${current}"; fi
  if [[ ${keep} == 1 ]]; then
    jq -s '.[0] + .[1]' "${current}" "${desired}" >"${updated}"
  else cp "${desired}" "${updated}"; fi
  if cmp -s <(jq -Sc . "${current}") <(jq -Sc . "${updated}"); then
    jsh::current
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    APP_POLICY_CHANGED=1
    jsh::changed "${target}"
    return
  fi
  if ! jsh::admin; then
    jsh::notice "${target} needs sudo; run sudo -v first, then rerun"
    return
  fi
  # Back up the original policy before privileged replacement.
  if [[ -e ${target} ]]; then
    backup=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d-%H%M%S)-$$${target}
    mkdir -p -- "${backup%/*}"
    cp -p -- "${target}" "${backup}"
  fi
  if [[ ${target} == *.plist ]]; then
    plutil -convert xml1 "${updated}"
    if [[ ${target%/*} == /Library/Preferences ]]; then
      domain=${target%.plist}
      jsh::root defaults import "${domain}" "${updated}"
    else
      jsh::root install -d -m 755 "${target%/*}"
      jsh::root install -m 644 "${updated}" "${target}"
    fi
    killall cfprefsd >/dev/null 2>&1 || :
  else
    jsh::root install -d -m 755 "${target%/*}"
    jsh::root install -m 644 "${updated}" "${target}"
  fi
  # shellcheck disable=SC2034 # Consumed by the caller.
  APP_POLICY_CHANGED=1
  jsh::changed "${target}"
}

app::with_closed() (
  local label=$1 pattern=$2 callback=$3 pids index pid
  shift 3
  pids=$(pgrep -u "$(id -u)" -x "${pattern}" || :)
  if [[ -z ${pids} ]]; then
    "${callback}" "$@"
    return
  fi
  # APP_LIVE=1 marks callbacks whose writes survive while the app stays open.
  if [[ ${JSH_KEEP_APPS:-0} == 1 ]]; then
    if [[ ${APP_LIVE:-0} == 1 ]]; then
      APP_OPEN=1 "${callback}" "$@" || return
      jsh::notice "restart ${label} to apply its changes"
    else
      jsh::notice "quit ${label}, then run jsh update to apply its settings"
    fi
    return
  fi
  if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
    jsh::notice "${label} must close and reopen for pending changes"
    "${callback}" "$@"
    return
  fi
  command -v "${APP_LAUNCH[0]}" >/dev/null 2>&1 || {
    jsh::notice "cannot reopen ${label}; close it and rerun"
    return 1
  }
  jsh::activity "Closing ${label}"
  if [[ $(uname -s) == Darwin ]]; then
    app::bounded 10 osascript -e "tell application \"${label}\" to quit" >/dev/null 2>&1 || {
      while IFS= read -r pid; do kill -TERM "${pid}" 2>/dev/null || :; done <<<"${pids}"
    }
  else
    while IFS= read -r pid; do kill -TERM "${pid}" 2>/dev/null || :; done <<<"${pids}"
  fi
  for ((index = 0; index < 100; index++)); do
    pgrep -u "$(id -u)" -x "${pattern}" >/dev/null || break
    sleep 0.1
  done
  if pgrep -u "$(id -u)" -x "${pattern}" >/dev/null; then
    jsh::notice "${label} did not close; changes were skipped"
    return 1
  fi
  trap 'jsh::activity "Reopening ${label}"; "${APP_LAUNCH[@]}" </dev/null >/dev/null 2>&1 &' EXIT
  "${callback}" "$@"
)

app::bounded() (
  local seconds=$1 pid timer result=0
  shift
  "$@" &
  pid=$!
  (
    sleep "${seconds}"
    kill -TERM "${pid}" 2>/dev/null || :
    sleep 1
    kill -KILL "${pid}" 2>/dev/null || :
  ) &
  timer=$!
  trap '[[ -z ${pid:-} ]] || kill "${pid}" 2>/dev/null || :; kill "${timer}" 2>/dev/null || :' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  wait "${pid}" || result=$?
  pid=
  kill "${timer}" 2>/dev/null || :
  wait "${timer}" 2>/dev/null || :
  return "${result}"
)

app::download() {
  local url=$1 target=$2 digest=$3 actual
  [[ ${url} == https://* && ${digest} =~ ^[[:xdigit:]]{64}$ ]] || {
    jsh::notice 'HTTPS and a SHA-256 digest are required'
    return 1
  }
  jsh::download "${url}" "${target}"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "${target}")
  else actual=$(shasum -a 256 "${target}"); fi
  [[ ${actual%% *} == "${digest}" ]] || {
    jsh::notice "checksum mismatch: ${url}"
    return 1
  }
}

jsh::need jq
APP_TMP=$(jsh::temp)
