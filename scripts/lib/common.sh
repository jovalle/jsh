#!/usr/bin/env bash
# Shared safe writes, dry runs, and task output for standalone setup scripts.
# shellcheck disable=SC2312 # Substitutions here format output or fail closed in the comparison that uses them.

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
if [[ -n ${JSH_REPORT:-} && ! -d ${JSH_REPORT} ]]; then unset JSH_REPORT; fi
# shellcheck source=lib/shell/output.sh
. "${JSH_ROOT}/lib/shell/output.sh"

# Options apply to the outermost script; other arguments, such as group names, stay with it.
_jsh_script=${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}
JSH_SCRIPT_NAME=${_jsh_script##*/}
JSH_SCRIPT_NAME=${JSH_SCRIPT_NAME%.sh}
for _jsh_arg in "$@"; do
  case ${_jsh_arg} in
    --dry-run) export JSH_DRY_RUN=1 ;;
    --update) export JSH_UPDATE=1 ;;
    --help | -h)
      sed -n '2s/^# //p' "${_jsh_script}"
      printf 'Usage: %s [--dry-run] [--update]\n' "${_jsh_script##*/}"
      exit 0
      ;;
    -*)
      jsh::fail "unknown option: ${_jsh_arg}"
      exit 2
      ;;
    *) ;;
  esac
done
unset _jsh_arg _jsh_script
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

jsh::need() { command -v "$1" >/dev/null 2>&1 || {
  jsh::fail "$1 is required"
  return 1
}; }
jsh::run() {
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    local command='' argument
    for argument in "$@"; do
      printf -v command "%s %q" "${command}" "${argument}"
    done
    jsh::info "would run${command}"
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
jsh::skip() {
  jsh::skipped "$*"
  exit 0
}

# Start a long-lived process without leaking setup session state or descriptors.
jsh::detach() {
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid env -u JSH_OUTPUT -u JSH_REPORT -u JSH_SESSION_START \
      -u JSH_PACKAGE_STATE "$@" 7>&- 8>&- </dev/null >/dev/null 2>&1 &
  else
    nohup env -u JSH_OUTPUT -u JSH_REPORT -u JSH_SESSION_START \
      -u JSH_PACKAGE_STATE "$@" 7>&- 8>&- </dev/null >/dev/null 2>&1 &
  fi
}

# Each setup script owns one scratch directory, removed when it exits.
jsh::cleanup() {
  local status=$?
  jsh::session_close "${status}"
  if [[ -n ${JSH_TASK_PID:-} ]]; then
    pkill -TERM -P "${JSH_TASK_PID}" 2>/dev/null || true
    kill "${JSH_TASK_PID}" 2>/dev/null || true
    wait "${JSH_TASK_PID}" 2>/dev/null || true
  fi
  [[ -z ${JSH_TMP:-} ]] || rm -rf -- "${JSH_TMP}"
}
JSH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jsh.XXXXXXXX")
trap 'jsh::cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
jsh::temp() { mktemp -d "${JSH_TMP:?automation scratch directory is missing}/work.XXXXXXXX"; }

# Child output is untrusted terminal data; discard escape sequences and control characters.
jsh::task_text() {
  LC_ALL=C sed $'s|\033\\[[0-9;?]*[ -/]*[@-~]||g; s|\033\\][^\007]*\007||g' |
    LC_ALL=C tr -d '\000-\011\013-\037\177'
}

# Run a command with its output in a log. Failures retain and display the sanitized tail.
JSH_TASK_LOG=${JSH_TMP}/task.log
jsh::task() {
  local record_failure=1 label status=0 pid saved='' line
  if [[ ${1:-} == --retryable ]]; then
    record_failure=0
    shift
  fi
  label=$1
  shift
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::run "$@"
    return
  fi
  : >"${JSH_TASK_LOG}"
  jsh::event task "${label}" "${JSH_TASK_LOG}"
  "$@" </dev/null >"${JSH_TASK_LOG}" 2>&1 &
  pid=$!
  JSH_TASK_PID=${pid}
  wait "${pid}" || status=$?
  JSH_TASK_PID=
  if ((status && record_failure)); then
    saved=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/logs
    mkdir -p -- "${saved}"
    saved=$(mktemp "${saved}/$(date +%Y%m%d-%H%M%S)-$$.XXXXXXXX")
    cp -- "${JSH_TASK_LOG}" "${saved}"
  fi
  if [[ ${JSH_OUTPUT:-} == renderer ]]; then
    if ((status && ! record_failure)); then
      jsh::event taskend 0 ""
    else
      jsh::event taskend "${status}" "${saved}"
    fi
  elif ((status && record_failure)); then
    jsh::plain item fail "${label} failed (${status})"
    LC_ALL=C sed $'s/\r$//; s/.*\r//' "${JSH_TASK_LOG}" | jsh::task_text | tail -n 10 |
      while IFS= read -r line; do
        [[ -z ${line} ]] || jsh::plain item output "${line}"
      done
    jsh::plain item output "Log: ${saved}"
  fi
  if ((status && record_failure)) && [[ -d ${JSH_REPORT:-} ]]; then
    jsh::_wire_field "${label} failed (${status})"
    printf "%s\n" "${_jsh_field}" >>"${JSH_REPORT}/failures"
  fi
  return "${status}"
}

# Refuse symlinked parent directories: app writes must not escape into another location.
jsh::parents() {
  local parent=${1%/*}
  while [[ ${parent} != / && ${parent} != . && -n ${parent} ]]; do
    [[ ! -L ${parent} ]] || {
      jsh::fail "symlinked directory needs review: ${parent}"
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
  jsh::status "Checking file ${destination}"
  [[ ! -d ${destination} ]] || {
    jsh::fail "refusing to replace directory: ${destination}"
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
    jsh::ok "${destination} is current"
    return
  fi
  [[ ! -e ${destination} && ! -L ${destination} ]] || existed=1
  jsh::parents "${destination}" || return
  if [[ ${JSH_DRY_RUN} != 1 ]]; then
    jsh::backup "${destination}" || return
    mkdir -p -- "${destination%/*}"
    staged=$(mktemp "${destination%/*}/.jsh.XXXXXXXX") || return
    if ! cat -- "${source}" >"${staged}" || ! chmod "${mode}" "${staged}" || ! mv -f -- "${staged}" "${destination}"; then
      rm -f -- "${staged}"
      return 1
    fi
  fi
  if ((existed)); then
    jsh::changed "${destination} written" "${destination} differs"
  else
    jsh::added "${destination} written" "${destination} is missing"
  fi
}
jsh::link() {
  local source=$1 destination=$2 existed=0
  case ${destination} in /*) ;; *) destination=${PWD}/${destination} ;; esac
  jsh::status "Checking link ${destination}"
  if [[ -L ${destination} && $(readlink "${destination}") == "${source}" ]]; then
    jsh::ok "${destination} linked"
    return
  fi
  [[ ! -d ${destination} || -L ${destination} ]] || {
    jsh::fail "refusing to replace directory: ${destination}"
    return 1
  }
  [[ ! -e ${destination} && ! -L ${destination} ]] || existed=1
  jsh::parents "${destination}" || return
  if [[ ${JSH_DRY_RUN} != 1 ]]; then
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
  if ((existed)); then
    jsh::changed "${destination} linked" "${destination} points elsewhere"
  else
    jsh::added "${destination} linked" "${destination} is missing"
  fi
}
jsh::download() {
  local url=$1 destination=$2
  [[ ${url} == https://* ]] || {
    jsh::fail "downloads require HTTPS: ${url}"
    return 1
  }
  jsh::need curl || return
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::info "would download ${url}"
    return
  fi
  jsh::task "Downloading ${destination##*/}" curl --fail --location --silent --show-error \
    --proto =https --proto-redir =https --connect-timeout 15 --max-time 300 --retry 2 --output "${destination}" "${url}"
}
jsh::sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Setup groups come from site.yml in include order. Role metadata supplies each purpose and
# whether the group supports all platforms, macOS only, or Linux only.
jsh::_load_groups() {
  [[ ${_JSH_GROUPS_LOADED:-0} != 1 ]] || return 0
  local output name meta description platform relative
  local names='' table='' darwin='' linux=''
  if ! output=$(awk '
    /^[ \t]*ansible\.builtin\.include_role:[ \t]*$/ {
      if (pending) { bad = pending; exit 2 }
      pending = NR
      next
    }
    pending {
      if (/^[ \t]*(#.*)?$/) { next }
      if (/^[ \t]+name:[ \t]*[a-z][a-z0-9_-]*[ \t]*$/) {
        name = $0
        sub(/^[ \t]+name:[ \t]*/, "", name)
        sub(/[ \t]*$/, "", name)
        if (seen[name]++) { bad = NR; exit 2 }
        rows = rows name "\n"
        pending = 0
        next
      }
      bad = pending
      exit 2
    }
    END {
      if (pending && !bad) { bad = pending }
      if (!bad && rows == "") { bad = 1 }
      if (bad) { print bad; exit 2 }
      printf "%s", rows
    }
  ' "${JSH_ROOT}/ansible/site.yml"); then
    [[ -z ${output} ]] || jsh::fail "site.yml line ${output}: expected a unique include_role name" >&2
    return 2
  fi
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    meta=${JSH_ROOT}/ansible/roles/${name}/meta/main.yml
    relative=${meta#"${JSH_ROOT}/"}
    [[ -r ${meta} ]] || {
      jsh::fail "${relative}: expected galaxy_info.description and platforms" >&2
      return 2
    }
    description=$(sed -n 's/^  description:[[:space:]]*\([^[:space:]].*\)$/\1/p' "${meta}")
    [[ -n ${description} && ${description} != *$'\n'* && ${description} != *$'\t'* ]] || {
      jsh::fail "${relative}: expected one plain galaxy_info.description" >&2
      return 2
    }
    if ! platform=$(awk '
      /^  platforms:[ \t]*$/ {
        if (seen) { bad = 1 }
        seen = 1
        active = 1
        next
      }
      active && /^    - name:[ \t]*/ {
        name = $0
        sub(/^    - name:[ \t]*/, "", name)
        sub(/[ \t]*$/, "", name)
        if (name == "MacOSX") { mac++ }
        else if (name == "Debian") { debian++ }
        else if (name == "EL") { el++ }
        else { bad = 1 }
        next
      }
      active && /^[^ \t]/ { active = 0 }
      END {
        if (!seen || bad || mac > 1 || debian > 1 || el > 1) { exit 2 }
        if (mac == 1 && debian == 0 && el == 0) { print "darwin" }
        else if (mac == 0 && debian == 1 && el == 1) { print "linux" }
        else if (mac == 1 && debian == 1 && el == 1) { print "all" }
        else { exit 2 }
      }
    ' "${meta}"); then
      jsh::fail "${relative}: expected MacOSX, Debian and EL platform metadata" >&2
      return 2
    fi
    names+=${name}$'\n'
    table+=${name}$'\t'${description}$'\n'
    [[ ${platform} == linux ]] || darwin+=${name}$'\n'
    [[ ${platform} == darwin ]] || linux+=${name}$'\n'
  done <<<"${output}"
  _JSH_GROUPS_ALL=${names}
  _JSH_GROUPS_TABLE=${table}
  _JSH_GROUPS_DARWIN=${darwin}
  _JSH_GROUPS_LINUX=${linux}
  _JSH_GROUPS_LOADED=1
}
jsh::groups() {
  jsh::_load_groups || return
  case ${1:-} in
    table) printf "%s" "${_JSH_GROUPS_TABLE}" ;;
    here)
      if [[ ${JSH_PLATFORM} == darwin ]]; then
        printf "%s" "${_JSH_GROUPS_DARWIN}"
      else
        printf "%s" "${_JSH_GROUPS_LINUX}"
      fi
      ;;
    *) printf "%s" "${_JSH_GROUPS_ALL}" ;;
  esac
}
jsh::is_group() {
  local names
  [[ -n ${1:-} ]] || return 1
  names=$(jsh::groups) || return
  [[ $'\n'${names}$'\n' == *$'\n'"$1"$'\n'* ]]
}

# Bootstrap packages and global package-manager maintenance remain in Bash.
jsh::packages() {
  local status=0
  jsh::status "Starting package checks for $1"
  bash "${JSH_ROOT}/scripts/packages.sh" "$@" || status=$?
  jsh::event stepclose
  return "${status}"
}

# Setup groups run as roles of ansible/site.yml, which tags each role with its group name.
jsh::playbook() {
  local home=${JSH_ANSIBLE_HOME:-${JSH_ROOT}/local/ansible} group tags update=false keep=false
  local preview=()
  if [[ ${JSH_DRY_RUN} == 1 && ! -x ${home}/venv/bin/ansible-playbook ]]; then
    for group in "$@"; do
      jsh::group "${group}" "$(jsh::groups table | awk -F'\t' -v name="${group}" '$1 == name { print $2 }')"
      jsh::skipped "${group} preview: Ansible is not installed yet"
    done
    return 0
  fi
  if [[ ${JSH_DRY_RUN} != 1 ]]; then
    bash "${JSH_ROOT}/scripts/ansible.sh" || return
  fi
  tags=$(
    IFS=,
    printf '%s' "$*"
  )
  [[ ${JSH_UPDATE:-0} != 1 ]] || update=true
  [[ ${JSH_KEEP_APPS:-0} != 1 ]] || keep=true
  [[ ${JSH_DRY_RUN} != 1 ]] || preview=(--check)
  ANSIBLE_CONFIG="${JSH_ROOT}/ansible/ansible.cfg" ANSIBLE_STDOUT_CALLBACK=jsh ANSIBLE_NOCOLOR=1 \
    "${home}/venv/bin/ansible-playbook" "${JSH_ROOT}/ansible/site.yml" --tags "${tags}" \
    ${preview[@]+"${preview[@]}"} --diff -e "{\"jsh_update\": ${update}, \"jsh_keep_apps\": ${keep}}"
}

jsh::python() {
  local python
  python=$(command -v python3 2>/dev/null) || return 1
  if [[ ${JSH_PLATFORM:-} == darwin && ${python} == /usr/bin/python3 ]]; then
    command -v xcode-select >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1 || return 1
  fi
  python3 -c "import sys; raise SystemExit(sys.version_info < (3, 9))" >/dev/null 2>&1
}

jsh::session_open() {
  if [[ -n ${JSH_OUTPUT+x} && ${JSH_OUTPUT} != plain ]]; then return 0; fi
  jsh::python || return 1
  if [[ -z ${JSH_REPORT:-} ]]; then JSH_REPORT=${JSH_TMP}/report; fi
  export JSH_REPORT
  mkdir -p -- "${JSH_REPORT}"
  mkfifo "${JSH_TMP}/output"
  exec 7>&1 8>&2
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    python3 "${JSH_ROOT}/lib/output.py" render --preview --report "${JSH_REPORT}" \
      <"${JSH_TMP}/output" &
  else
    python3 "${JSH_ROOT}/lib/output.py" render --report "${JSH_REPORT}" \
      <"${JSH_TMP}/output" &
  fi
  JSH_RENDERER_PID=$!
  exec >"${JSH_TMP}/output" 2>&1
  _JSH_SESSION_OWNER=renderer
  : "${JSH_SESSION_START:=$SECONDS}"
  export JSH_OUTPUT=renderer JSH_SESSION_START
}

jsh::summary() {
  local elapsed=${1:-0} status=${2:-0} event added=0 changed=0 removed=0 failed=0 label
  if [[ -f ${JSH_REPORT:-}/events ]]; then
    while IFS= read -r event; do
      case ${event} in
        added) added=$((added + 1)) ;;
        changed) changed=$((changed + 1)) ;;
        removed) removed=$((removed + 1)) ;;
      esac
    done <"${JSH_REPORT}/events"
  fi
  if [[ -f ${JSH_REPORT:-}/failures ]]; then
    while IFS= read -r event; do
      [[ -z ${event} ]] || failed=$((failed + 1))
    done <"${JSH_REPORT}/failures"
  fi
  if ((failed)) || [[ ${status} != 0 ]]; then
    label=$(jsh::paint 1 '1;31' "Finished with errors")
  elif [[ ${JSH_DRY_RUN} == 1 ]]; then label="Preview complete"
  else label=$(jsh::paint 1 '1;32' Ready); fi
  printf "\n%s" "${label}"
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    if ((added + changed + removed)); then
      printf "  %s would change" "$((added + changed + removed))"
    else
      printf "  No changes identified"
    fi
  elif ((added + changed + removed)); then
    ((added == 0)) || printf "  %s added" "${added}"
    ((changed == 0)) || printf "  %s changed" "${changed}"
    ((removed == 0)) || printf "  %s removed" "${removed}"
  else
    printf "  Everything is current"
  fi
  ((failed == 0)) || printf "  %s failed" "${failed}"
  printf "  %sm %02ds\n" "$((elapsed / 60))" "$((elapsed % 60))"
  [[ ${JSH_DRY_RUN} != 1 ]] || printf "No settings changed\n"
  if ((failed)); then
    printf "\n%s\n" "$(jsh::paint 1 '1;31' Failed)"
    while IFS= read -r event; do
      [[ -z ${event} ]] || printf "  ✕ %s\n" "${event}"
    done <"${JSH_REPORT}/failures"
  fi
  if [[ -s ${JSH_REPORT:-}/notices ]]; then
    printf "\n%s\n" "$(jsh::paint 1 '1;33' 'Action needed')"
    local width=0
    [[ ! -t 1 ]] || width=$(($(tput cols 2>/dev/null || echo 80) - 4))
    ((width <= 0 || width >= 20)) || width=20
    while IFS= read -r event; do
      [[ -z ${event} ]] || jsh::_notice_lines "${event}" "${width}"
    done <"${JSH_REPORT}/notices"
  fi
}

# Usage: jsh::_notice_lines TEXT WIDTH. Prints a bullet with a hanging indent, wrapping at
# WIDTH (0 disables wrapping) without splitting `code` spans, which are shown in cyan.
jsh::_notice_lines() {
  local text=$1 width=$2 line='' token shown size used=0 prefix
  local -a tokens=()
  while [[ -n ${text} ]]; do
    text=${text#"${text%%[! ]*}"}
    [[ -n ${text} ]] || break
    if [[ ${text} =~ ^\`([^\`]+)\`(.*)$ ]]; then
      tokens+=("\`${BASH_REMATCH[1]}\`")
      text=${BASH_REMATCH[2]}
    else
      token=${text%%[ \`]*}
      [[ -n ${token} ]] || token=${text:0:1}
      tokens+=("${token}")
      text=${text:${#token}}
    fi
  done
  prefix="  $(jsh::paint 1 '1;33' '•') "
  for token in "${tokens[@]}"; do
    shown=${token}
    if [[ ${token} == \`?*\` && ${_jsh_color_1:-0} == 1 ]]; then
      shown=$(jsh::paint 1 36 "${token:1:${#token}-2}")
      size=$((${#token} - 2))
    else
      size=${#token}
    fi
    if [[ -n ${line} ]] && ((width && used + 1 + size > width)); then
      printf '%s%s\n' "${prefix}" "${line}"
      prefix='    '
      line='' used=0
    fi
    if [[ -n ${line} ]]; then line+=' '; used=$((used + 1)); fi
    line+=${shown}
    used=$((used + size))
  done
  printf '%s%s\n' "${prefix}" "${line}"
}

jsh::session_close() {
  local status=${1:-0} owner=${_JSH_SESSION_OWNER:-} group=${_JSH_SESSION_GROUP:-}
  local failure_start=${_JSH_SESSION_FAILURE_START:-0}
  [[ -n ${owner} ]] || return 0
  _JSH_SESSION_OWNER=
  _JSH_SESSION_GROUP=
  _JSH_SESSION_FAILURE_START=
  case ${status} in
    0 | 130 | 143) ;;
    *)
      if [[ -n ${group} ]]; then
        jsh::_report_count "${JSH_REPORT}/failures"
        if ((_jsh_count <= failure_start)); then jsh::fail "${group} failed (${status})"; fi
      fi
      ;;
  esac
  if [[ ${owner} == renderer ]]; then
    jsh::event end "$((SECONDS - JSH_SESSION_START))" "${status}" || true
    exec 1>&7 2>&8 7>&- 8>&-
    wait "${JSH_RENDERER_PID}" || true
  else
    jsh::event end "$((SECONDS - JSH_SESSION_START))" "${status}"
    jsh::summary "$((SECONDS - JSH_SESSION_START))" "${status}"
  fi
  export JSH_OUTPUT=plain
}

if [[ -z ${JSH_OUTPUT+x} ]]; then
  if ! jsh::session_open; then
    export JSH_OUTPUT=plain JSH_SESSION_START=$SECONDS
    _JSH_SESSION_OWNER=plain
    if [[ -z ${JSH_REPORT:-} ]]; then JSH_REPORT=${JSH_TMP}/report; fi
    export JSH_REPORT
    mkdir -p -- "${JSH_REPORT}"
  fi
  _JSH_SESSION_GROUP=${JSH_SCRIPT_NAME}
  jsh::_report_count "${JSH_REPORT}/failures"
  _JSH_SESSION_FAILURE_START=${_jsh_count}
  _jsh_group_purpose=
  _jsh_group_meta=${JSH_ROOT}/ansible/roles/${JSH_SCRIPT_NAME}/meta/main.yml
  if [[ -r ${_jsh_group_meta} ]] && awk -v wanted="${JSH_SCRIPT_NAME}" '
    /^[ \t]*ansible\.builtin\.include_role:[ \t]*$/ { included = 1; next }
    included && /^[ \t]+name:[ \t]*/ {
      name = $0
      sub(/^[ \t]+name:[ \t]*/, "", name)
      sub(/[ \t]*$/, "", name)
      if (name == wanted) { found = 1; exit }
      included = 0
    }
    END { exit !found }
  ' "${JSH_ROOT}/ansible/site.yml"; then
    _jsh_group_purpose=$(sed -n 's/^  description:[[:space:]]*//p' "${_jsh_group_meta}")
  fi
  jsh::group "${JSH_SCRIPT_NAME}" "${_jsh_group_purpose}"
  unset _jsh_group_meta _jsh_group_purpose
fi
unset JSH_SCRIPT_NAME
