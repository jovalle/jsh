#!/usr/bin/env bash
# Shared safe writes, dry runs, and progress for standalone setup scripts.

[[ ${JSH_COMMON_LOADED:-0} != 1 ]] || return 0
JSH_COMMON_LOADED=1

: "${JSH_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
export JSH_ROOT
export PATH="${PATH}:/usr/sbin:/sbin"
for _jsh_prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
  if ! command -v brew >/dev/null 2>&1 && [[ -x ${_jsh_prefix}/bin/brew ]]; then
    export PATH="${_jsh_prefix}/bin:${PATH}"
  fi
done
unset _jsh_prefix
# shellcheck source=lib/shell/output.sh
. "${JSH_ROOT}/lib/shell/output.sh"

jsh::log_note() {
  local message=$*
  if [[ -n ${JSH_REPORT:-} && ${message} == '  › '* ]]; then message="  ${message#'  › '}"; fi
  printf '%s\n' "$(jsh::paint 1 2 "${message}")"
}

_JSH_AUTOMATION=0
case ${BASH_SOURCE[1]:-} in
  "${JSH_ROOT}/scripts/"* | "${JSH_ROOT}/install.sh" | scripts/* | ./scripts/* | install.sh | ./install.sh) _JSH_AUTOMATION=1 ;;
esac
if [[ ${_JSH_AUTOMATION} == 1 ]]; then
  for _jsh_arg in "$@"; do
    case ${_jsh_arg} in
      --dry-run) export JSH_DRY_RUN=1 ;;
      --update) export JSH_UPDATE=1 ;;
      --help | -h)
        sed -n '2s/^# //p' "${BASH_SOURCE[1]}"
        printf 'Usage: %s [--dry-run] [--update]\n' "${BASH_SOURCE[1]##*/}"
        exit 0
        ;;
    esac
  done
  unset _jsh_arg
fi
export JSH_DRY_RUN=${JSH_DRY_RUN:-0}
if [[ -z ${JSH_PLATFORM:-} ]]; then
  if [[ $(uname -s) == Darwin ]]; then
    JSH_PLATFORM=darwin
  elif command -v apt-get >/dev/null 2>&1; then
    JSH_PLATFORM=debian
  elif command -v dnf >/dev/null 2>&1; then
    JSH_PLATFORM=rhel
  else
    JSH_PLATFORM=linux
  fi
fi
JSH_HOST=${JSH_HOST:-$(hostname -s)}
if [[ -z ${JSH_DESKTOP:-} ]]; then
  case ${JSH_PLATFORM}:${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}} in
    darwin:*) JSH_DESKTOP=darwin ;;
    *:[Gg][Nn][Oo][Mm][Ee]*) JSH_DESKTOP=gnome ;;
    *:*[Xx][Ff][Cc][Ee]*) JSH_DESKTOP=xfce ;;
    *) JSH_DESKTOP= ;;
  esac
fi
export JSH_PLATFORM JSH_HOST JSH_DESKTOP

jsh::emit() {
  local verb=$1 value=$2 kind=${3:-item} prefix width=8
  if [[ -n ${JSH_REPORT:-} && ${verb} != detail && ${verb} != notice ]]; then
    printf '%s\n' "${verb}" >>"${JSH_REPORT}/events"
  fi
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    width=12
    case ${verb}:${kind} in
      added:link) prefix='would link' ;;
      changed:link) prefix='would relink' ;;
      added:package) prefix='would install' ;;
      added:*) prefix='would add' ;;
      changed:*) prefix='would change' ;;
      removed:*) prefix='would remove' ;;
    esac
  else
    prefix=${kind}
  fi
  if [[ ${value} == "${HOME}/"* ]]; then printf -v value '%s/%s' '~' "${value#"${HOME}/"}"; fi
  case $1 in
    added) printf '%s %-*s %s\n' "$(jsh::paint 1 32 +)" "${width}" "${prefix}" "${value}" ;;
    changed) printf '%s %-*s %s\n' "$(jsh::paint 1 33 '~')" "${width}" "${prefix}" "${value}" ;;
    removed) printf '%s %-*s %s\n' "$(jsh::paint 1 31 -)" "${width}" "${prefix}" "${value}" ;;
    notice)
      if [[ -n ${JSH_REPORT:-} && ${JSH_DRY_RUN} != 1 ]]; then
        printf '%s\n' "${value}" >>"${JSH_REPORT}/notices"
      else jsh::log_warn "${value}"; fi ;;
    detail)
      if [[ -z ${JSH_REPORT:-} || ${value} != *'up to date' ]]; then printf '  %s\n' "${value}"; fi ;;
  esac
}
jsh::added() { jsh::emit added "$*" "${JSH_ITEM_KIND:-item}"; }
jsh::changed() { jsh::emit changed "$*" "${JSH_ITEM_KIND:-item}"; }
jsh::removed() { jsh::emit removed "$*" "${JSH_ITEM_KIND:-item}"; }
jsh::current() { :; }
jsh::detail() { jsh::emit detail "$*"; }
jsh::progress() { jsh::log_info "$*"; }
jsh::activity() {
  local message=$*
  message=${message//"${HOME}"/\~}
  [[ -z ${JSH_PROGRESS_FILE:-} ]] || printf '%s\n' "${JSH_STEP:+${JSH_STEP} }${message}" >"${JSH_PROGRESS_FILE}"
}
jsh::notice() { jsh::emit notice "$*"; }
jsh::need() { command -v "$1" >/dev/null 2>&1 || {
  jsh::log_error "$1 is required"
  return 1
}; }
jsh::run() {
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    printf '  would run'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
jsh::root() {
  if [[ ${JSH_DRY_RUN} == 1 || ${EUID} == 0 ]]; then
    jsh::run "$@"
  else
    jsh::run sudo -n -- "$@"
  fi
}
jsh::admin() { [[ ${EUID} == 0 ]] || sudo -n true >/dev/null 2>&1; }
jsh::confirm() {
  local answer
  [[ ${JSH_DRY_RUN} != 1 && ${JSH_ASSUME_YES:-0} != 1 ]] || return 0
  [[ -t 0 ]] || {
    jsh::notice 'Use --yes to apply changes without a terminal.'
    return 1
  }
  printf '%s (y/N) ' "$1" >&2
  IFS= read -r -n 1 answer || return 1
  printf '\n' >&2
  [[ ${answer} == [yY] ]]
}

# Automation owns one scratch directory; sourcing from everyday bin tools creates nothing.
jsh::cleanup() {
  if [[ -t 2 && ${TERM:-} != dumb ]]; then jsh::progress_clear; fi
  if [[ -n ${JSH_TASK_PID:-} ]]; then
    pkill -TERM -P "${JSH_TASK_PID}" 2>/dev/null || true
    kill "${JSH_TASK_PID}" 2>/dev/null || true
    wait "${JSH_TASK_PID}" 2>/dev/null || true
  fi
  [[ -z ${JSH_TMP:-} ]] || rm -rf -- "${JSH_TMP}"
}
if [[ ${_JSH_AUTOMATION} == 1 ]]; then
  JSH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jsh.XXXXXXXX")
  trap 'jsh::cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi
jsh::temp() { mktemp -d "${JSH_TMP:?automation scratch directory is missing}/work.XXXXXXXX"; }

# Keep a single wrapped progress display below completed output.
jsh::progress_clear() {
  if ((${JSH_PROGRESS_LINES:-0})); then
    local size width
    size=$(stty size <&2 2>/dev/null || printf '24 %s\n' "${JSH_PROGRESS_WIDTH:-80}")
    width=${size##* }
    if [[ ${width} =~ ^[0-9]+$ ]] && ((width > 1 && width != ${JSH_PROGRESS_WIDTH:-0})); then
      JSH_PROGRESS_LINES=$(printf '%s\n' "${JSH_PROGRESS_RENDERED}" | fold -w "${width}" | wc -l)
    fi
    if ((JSH_PROGRESS_LINES > 1)); then printf '\033[%sA' "$((JSH_PROGRESS_LINES - 1))" >&2; fi
    if [[ ${1:-} == move ]]; then printf '\r' >&2; else printf '\r\033[J' >&2; fi
    JSH_PROGRESS_LINES=0
  fi
}

jsh::progress_draw() {
  local label=$1 elapsed=$2 frame=$3 detail=${4:-} width line rendered spinner time
  local -a dots=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  width=$(stty size <&2 2>/dev/null || printf '24 80\n')
  width=${width##* }
  [[ ${width} =~ ^[0-9]+$ ]] && ((width > 1)) || width=80
  width=$((width - 1))
  spinner=${dots[$((frame % ${#dots[@]}))]}
  time=$(printf '%dm%02ds' "$((elapsed / 60))" "$((elapsed % 60))")
  line="${spinner} ${label}...  ${time}"
  [[ -z ${detail} ]] || line+=$'\n'"  ${detail}"
  rendered=$(printf '%s\n' "${line}" | fold -s -w "${width}")
  local next_rendered=${rendered} next_lines
  next_lines=$(printf '%s\n' "${rendered}" | wc -l)
  rendered=$(jsh::paint 2 37 "${rendered}")
  local white=''
  [[ ${_jsh_color_2:-0} != 1 ]] || white=$'\033[37m'
  rendered=${rendered/"${spinner}"/$(jsh::paint 2 36 "${spinner}")${white}}
  if [[ ${label} == \[*\]\ *\ \ * ]]; then
    local component=${label#*\] }
    component=${component%%  *}
    rendered=${rendered/"${component}"/$(jsh::paint 2 36 "${component}")${white}}
  fi
  rendered=${rendered/"${time}"/$(jsh::paint 2 2 "${time}")}
  rendered=${rendered//$'\n'/$'\033[K\n'}
  jsh::progress_clear move
  JSH_PROGRESS_WIDTH=$((width + 1))
  JSH_PROGRESS_RENDERED=${next_rendered}
  JSH_PROGRESS_LINES=${next_lines}
  printf '\r%s\033[J' "${rendered}" >&2
}

# Stream child reports above one persistent progress display while setup scripts run.
jsh::monitor() {
  local log=${JSH_TMP:?}/monitor.log pid status=0 frame=0 start=${SECONDS} line label detail partial='' finished=0
  local JSH_PROGRESS_LINES=0
  : >"${log}"
  "$@" </dev/null >"${log}" 2>&1 &
  pid=$!
  JSH_TASK_PID=${pid}
  exec 3<"${log}"
  while :; do
    while :; do
      line=''
      if ! IFS= read -r line <&3; then
        partial+=${line}
        break
      fi
      line=${partial}${line}
      partial=''
      jsh::progress_clear
      case ${line} in
        '+ '*) printf '%s %s\n' "$(jsh::paint 2 32 +)" "${line:2}" >&2 ;;
        '~ '*) printf '%s %s\n' "$(jsh::paint 2 33 '~')" "${line:2}" >&2 ;;
        '- '*) printf '%s %s\n' "$(jsh::paint 2 31 -)" "${line:2}" >&2 ;;
        '  '*) printf '%s\n' "$(jsh::paint 2 2 "${line}")" >&2 ;;
        '! '*) printf '%s\n' "$(jsh::paint 2 33 "${line}")" >&2 ;;
        '✗ '*) printf '%s\n' "$(jsh::paint 2 31 "${line}")" >&2 ;;
        '✓ '*) printf '%s\n' "$(jsh::paint 2 32 "${line}")" >&2 ;;
        '› '*) printf '%s\n' "$(jsh::paint 2 36 "${line}")" >&2 ;;
        'Ready'* | 'Preview complete'*) printf '%s\n' "$(jsh::paint 2 32 "${line}")" >&2 ;;
        'Finished with errors'*) printf '%s\n' "$(jsh::paint 2 31 "${line}")" >&2 ;;
        'Action needed') printf '%s\n' "$(jsh::paint 2 33 "${line}")" >&2 ;;
        *) printf '%s\n' "${line}" >&2 ;;
      esac
    done
    if ! kill -0 "${pid}" 2>/dev/null; then
      if ((finished)); then
        jsh::progress_clear
        [[ -z ${partial} ]] || printf '%s\n' "${partial}" >&2
        break
      fi
      finished=1
      continue
    fi
    label=$(jsh::task_text <"${JSH_PROGRESS_FILE}" 2>/dev/null || true)
    detail=$(cat "${JSH_PROGRESS_FILE}.detail" 2>/dev/null || true)
    if [[ -n ${label} ]]; then
      jsh::progress_draw "${label}" "$((SECONDS - start))" "${frame}" "${detail}"
    else jsh::progress_clear; fi
    frame=$((frame + 1))
    sleep 0.1
  done
  exec 3<&-
  wait "${pid}" || status=$?
  JSH_TASK_PID=
  return "${status}"
}

# Child output is untrusted terminal data; discard escape sequences and control characters.
jsh::task_text() {
  LC_ALL=C sed $'s|\033\\[[0-9;?]*[ -/]*[@-~]||g; s|\033\\][^\007]*\007||g' |
    LC_ALL=C tr -d '\000-\011\013-\037\177'
}

# Run long tasks with a spinner, elapsed time, and latest output line on a terminal; retain
# their output for failures. Nested installer tasks report their labels to its monitor.
jsh::task() {
  local label=${JSH_STEP:+${JSH_STEP} }$1 status=0 pid frame=0 log start line completed partial='' detail='' finished=0 stream=0 update_output=0 heading=0 previous=''
  local JSH_PROGRESS_LINES=0
  [[ ${JSH_UPDATE:-0} != 1 ]] || update_output=1
  case ${label} in *[Uu]pdat* | *[Uu]pgrad* | *[Rr]efresh* | *[Cc]hecking*) update_output=1 ;; esac
  shift
  if [[ -n ${JSH_PROGRESS_FILE:-} ]]; then
    previous=$(cat "${JSH_PROGRESS_FILE}" 2>/dev/null || true)
    printf '%s\n' "${label}" >"${JSH_PROGRESS_FILE}"
  fi
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::run "$@"
    [[ -z ${JSH_PROGRESS_FILE:-} ]] || printf '%s\n' "${previous}" >"${JSH_PROGRESS_FILE}"
    return
  fi
  log=${JSH_TMP:?}/task.log
  [[ ! -t 2 && -z ${JSH_PROGRESS_FILE:-} || ${TERM:-} == dumb ]] || stream=1
  [[ -z ${JSH_REPORT:-} ]] || stream=0
  [[ -z ${JSH_PROGRESS_FILE:-} ]] || : >"${JSH_PROGRESS_FILE}.detail"
  : >"${log}"
  "$@" </dev/null >"${log}" 2>&1 &
  pid=$!
  JSH_TASK_PID=${pid}
  start=${SECONDS}
  exec 4<"${log}"
  while :; do
    if ((stream)); then
      completed=''
      while :; do
        line=''
        if ! IFS= read -r line <&4; then
          partial+=${line}
          break
        fi
        line=${partial}${line}
        partial=''
        line=${line%$'\r'}
        line=${line##*$'\r'}
        if [[ -n ${line} ]]; then
          if ((update_output)); then
            if (( ! heading )); then completed+="${label}:"$'\n'; heading=1; fi
            line="  ${line}"
          fi
          completed+=${line}$'\n'
        fi
      done
      if [[ -n ${completed} ]]; then
        jsh::progress_clear
        printf '%s' "${completed}" | jsh::task_text >&2
      fi
      case ${partial} in
        *$'\r')
          detail=${partial%$'\r'}
          detail=${detail##*$'\r'}
          partial=${detail}$'\r'
          ;;
        *) partial=${partial##*$'\r'}; detail=${partial} ;;
      esac
      detail=$(printf '%s' "${detail}" | jsh::task_text)
      if [[ -n ${JSH_PROGRESS_FILE:-} ]]; then
        printf '%s' "${detail}" >"${JSH_PROGRESS_FILE}.detail"
      fi
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      if ((finished)); then
        jsh::progress_clear
        if [[ -n ${detail} ]] && ((update_output)); then
          if (( ! heading )); then printf '%s:\n' "${label}" | jsh::task_text >&2; fi
          detail="  ${detail}"
        fi
        [[ -z ${detail} ]] || printf '%s\n' "${detail}" >&2
        break
      fi
      finished=1
      continue
    fi
    if ((stream)) && [[ -z ${JSH_PROGRESS_FILE:-} ]]; then
      jsh::progress_draw "${label}" "$((SECONDS - start))" "${frame}" "${detail}"
    fi
    frame=$((frame + 1))
    sleep 0.1
  done
  exec 4<&-
  wait "${pid}" || status=$?
  JSH_TASK_PID=
  jsh::progress_clear
  [[ -z ${JSH_PROGRESS_FILE:-} ]] || : >"${JSH_PROGRESS_FILE}.detail"
  if ((status)); then
    local saved
    saved=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/logs
    mkdir -p -- "${saved}"
    saved=$(mktemp "${saved}/$(date +%Y%m%d-%H%M%S)-$$.XXXXXXXX")
    cp -- "${log}" "${saved}"
    if (( ! stream )); then
      if [[ -t 2 || -n ${JSH_PROGRESS_FILE:-} ]]; then
        tail -n 20 "${log}" | jsh::task_text >&2
      else tail -n 20 "${log}" >&2; fi
    fi
    jsh::log_error "${label} failed (${status})"
    printf '  Log: %s\n' "${saved}" >&2
  fi
  [[ -z ${JSH_PROGRESS_FILE:-} ]] || printf '%s\n' "${previous}" >"${JSH_PROGRESS_FILE}"
  return "${status}"
}

# Refuse symlinked parent directories: app writes must not escape into another location.
jsh::parents() {
  local parent=${1%/*}
  while [[ ${parent} != / && ${parent} != . && -n ${parent} ]]; do
    [[ ! -L ${parent} ]] || {
      jsh::log_error "symlinked directory needs review: ${parent}"
      return 1
    }
    case ${parent} in */*) parent=${parent%/*} ;; *) parent=. ;; esac
  done
}
jsh::backup() {
  local destination=$1 relative backup
  [[ -e ${destination} || -L ${destination} ]] || return 0
  relative=${destination#"${HOME}/"}
  [[ ${relative} != "${destination}" ]] || relative=${destination#/}
  backup=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d-%H%M%S)-$$/${relative}
  [[ ! -e ${backup} && ! -L ${backup} ]] || return 0
  mkdir -p -- "${backup%/*}"
  cp -Pp -- "${destination}" "${backup}"
}
jsh::file() {
  local source=$1 destination=$2 staged mode=${3:-600} actual_mode existed=0
  case ${destination} in /*) ;; *) destination=${PWD}/${destination} ;; esac
  jsh::activity "Checking file ${destination}"
  [[ ! -d ${destination} ]] || {
    jsh::log_error "refusing to replace directory: ${destination}"
    return 1
  }
  if [[ -e ${destination} ]]; then
    if [[ ${JSH_PLATFORM} == darwin ]]; then
      actual_mode=$(stat -L -f '%Lp' "${destination}")
    else
      actual_mode=$(stat -L -c '%a' "${destination}")
    fi
    [[ $# -ge 3 ]] || mode=${actual_mode}
  fi
  if [[ -f ${destination} ]] && cmp -s -- "${source}" "${destination}" && [[ ${actual_mode} == "${mode}" ]]; then
    jsh::current
    return
  fi
  [[ ! -e ${destination} && ! -L ${destination} ]] || existed=1
  jsh::parents "${destination}" || return
  if [[ ${JSH_DRY_RUN} != 1 ]]; then
    jsh::activity "Writing file ${destination}"
    jsh::backup "${destination}" || return
    mkdir -p -- "${destination%/*}"
    staged=$(mktemp "${destination%/*}/.jsh.XXXXXXXX") || return
    if ! cat -- "${source}" >"${staged}" || ! chmod "${mode}" "${staged}" || ! mv -f -- "${staged}" "${destination}"; then
      rm -f -- "${staged}"
      return 1
    fi
  fi
  if ((existed)); then jsh::emit changed "${destination}" config; else jsh::emit added "${destination}" config; fi
}
jsh::link() {
  local source=$1 destination=$2 existed=0
  case ${destination} in /*) ;; *) destination=${PWD}/${destination} ;; esac
  jsh::activity "Checking link ${destination}"
  if [[ -L ${destination} && $(readlink "${destination}") == "${source}" ]]; then
    jsh::current
    return
  fi
  [[ ! -d ${destination} || -L ${destination} ]] || {
    jsh::log_error "refusing to replace directory: ${destination}"
    return 1
  }
  [[ ! -e ${destination} && ! -L ${destination} ]] || existed=1
  jsh::parents "${destination}" || return
  if [[ ${JSH_DRY_RUN} != 1 ]]; then
    jsh::activity "Linking ${destination}"
    jsh::backup "${destination}" || return
    mkdir -p -- "${destination%/*}"
    local staging
    staging=$(mktemp -d "${destination%/*}/.jsh.XXXXXXXX") || return
    local -a replace=(mv -fT)
    [[ ${JSH_PLATFORM} != darwin ]] || replace=(mv -fh)
    if ! ln -s -- "${source}" "${staging}/link" || ! "${replace[@]}" -- "${staging}/link" "${destination}"; then
      rm -rf -- "${staging}"
      return 1
    fi
    rmdir -- "${staging}"
  fi
  if ((existed)); then jsh::emit changed "${destination}" link; else jsh::emit added "${destination}" link; fi
}
jsh::json() {
  local source=$1 destination=$2 scratch current
  jsh::need jq || return
  scratch=$(jsh::temp) || return
  current=${destination}
  [[ -f ${current} ]] || {
    printf '{}\n' >"${scratch}/current.json"
    current=${scratch}/current.json
  }
  jq -e -s 'if all(.[]; type == "object") then .[0] * .[1] else error("settings must be objects") end' \
    "${current}" "${source}" >"${scratch}/merged.json" || return
  if [[ -f ${destination} ]] && jq -e -s '.[0] == .[1]' "${current}" "${scratch}/merged.json" >/dev/null; then
    jsh::current
    return
  fi
  jsh::file "${scratch}/merged.json" "${destination}"
}
jsh::download() {
  local url=$1 destination=$2
  [[ ${url} == https://* ]] || {
    jsh::log_error "downloads require HTTPS: ${url}"
    return 1
  }
  jsh::need curl || return
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::notice "would download ${url}"
    return
  fi
  jsh::task "Downloading ${destination##*/}" curl --fail --location --silent --show-error \
    --proto =https --proto-redir =https --connect-timeout 15 --max-time 300 --retry 2 --output "${destination}" "${url}"
}

# Ordinary package lists live in one script; app scripts remain directly runnable.
jsh::packages() {
  local status=0
  jsh::activity "Starting package checks for $1"
  bash "${JSH_ROOT}/scripts/packages.sh" "$@" || status=$?
  return "${status}"
}
