#!/usr/bin/env bash
# Install or update the foobar2000 SACD decoder from its SourceForge release feed.
set -euo pipefail
. "${JSH_ROOT:?}/scripts/lib/common.sh" "$@"
APP_TMP=$(jsh::temp)

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
  jsh::info "Closing ${label}"
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
  app::reopen() {
    local index
    jsh::info "Reopening ${label}"
    jsh::detach "${APP_LAUNCH[@]}"
    for ((index = 0; index < 50; index++)); do
      if pgrep -u "$(id -u)" -x "${pattern}" >/dev/null; then
        jsh::changed "${label} restarted" "${label} needs a restart"
        return
      fi
      sleep 0.1
    done
    jsh::info "${label} did not restart; open it manually"
  }
  trap app::reopen EXIT
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

components=${HOME}/Library/foobar2000-v2/user-components
name=foo_input_sacd
target=${components}/${name}.component
state=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/foobar2000/decoder
# The SACD decoder replaced the standalone DSD decoder; both register the same formats.
retired=("${components}/foo_input_udsd.component" "${components}/foo_input_udsd")
jsh::step check "foobar2000 SACD decoder"
if [[ ! -d /Applications/foobar2000.app && ! -d ${components%/*} ]]; then
  jsh::skip "foobar2000 decoder: foobar2000 is not installed"
fi
existing=0
for path in "${target}" "${retired[@]}"; do [[ ! -e ${path} ]] || existing=1; done
if ((existing)) && [[ ${JSH_UPDATE:-0} != 1 ]]; then
  jsh::ok "foobar2000 decoder is installed"
  exit 0
fi
((existing)) || [[ ${JSH_UPDATE:-0} != 1 ]] ||
  jsh::skip "foobar2000 decoder update: no decoder is installed"
installed=''
[[ ! -e ${target} || ! -f ${state} ]] || installed=$(<"${state}")
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  if ((existing)); then
    jsh::info "foobar2000 decoder update is unchecked in preview"
  else
    jsh::added "foobar2000 SACD decoder installed" "foobar2000 SACD decoder is missing"
  fi
  exit 0
fi
jsh::download "https://sourceforge.net/projects/sacddecoder/rss?path=/${name}" "${APP_TMP}/releases.xml"
release=$(awk -v name="${name}" '
  /<title>/ {
    file = ""
    if (match($0, name "-[0-9]+(\\.[0-9]+)+\\.zip")) file = substr($0, RSTART, RLENGTH)
  }
  file != "" && match($0, /<media:hash algo="md5">[0-9a-f]+</) {
    print file, substr($0, RSTART + 23, RLENGTH - 24)
    file = ""
  }' "${APP_TMP}/releases.xml" | sort -V | tail -n 1)
version=${release%% *}
version=${version#"${name}-"}
version=${version%.zip}
digest=${release##* }
[[ ${version} =~ ^[0-9]+(\.[0-9]+)+$ && ${digest} =~ ^[0-9a-f]{32}$ ]] || {
  jsh::notice 'No foobar2000 decoder release found'
  exit 1
}
if [[ ${installed} == "${version}" ]]; then
  jsh::ok "foobar2000 SACD decoder is ${version}"
  exit 0
fi
jsh::download "https://downloads.sourceforge.net/project/sacddecoder/${name}/${name}-${version}.zip" "${APP_TMP}/decoder.zip"
# SourceForge publishes only MD5 digests, served over HTTPS in its release feed.
[[ $(md5 -q "${APP_TMP}/decoder.zip") == "${digest}" ]] || {
  jsh::notice "checksum mismatch: ${name}-${version}.zip"
  exit 1
}
unzip -p "${APP_TMP}/decoder.zip" "${name}.fb2k-component" >"${APP_TMP}/component.zip"
prefix=mac/${name}.component/
jsh::status "decoder archive"
unzip -Z1 "${APP_TMP}/component.zip" >"${APP_TMP}/entries"
grep -Fx "${prefix}Contents/Info.plist" "${APP_TMP}/entries" >/dev/null
grep -Fx "${prefix}Contents/MacOS/${name}" "${APP_TMP}/entries" >/dev/null
while IFS= read -r entry; do
  [[ ${entry} == "${prefix}"* && ${entry} != */ ]] || continue
  relative=${entry#"${prefix}"}
  case /${relative}/ in *'/../'* | *'/./'* | *'//'*)
    jsh::notice 'invalid decoder archive path'
    exit 1
    ;;
  esac
  mkdir -p -- "${APP_TMP}/component/${relative%/*}"
  unzip -p "${APP_TMP}/component.zip" "${entry}" >"${APP_TMP}/component/${relative}"
  chmod 644 "${APP_TMP}/component/${relative}"
done <"${APP_TMP}/entries"
chmod 755 "${APP_TMP}/component/Contents/MacOS/${name}"
APP_LAUNCH=(open -a foobar2000)
APP_LIVE=1
install_component() {
  local path backup
  backup=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d-%H%M%S)-$$/foobar2000
  mkdir -p -- "${components}"
  for path in "${retired[@]}" "${target}"; do
    [[ -e ${path} ]] || continue
    mkdir -p -- "${backup}"
    mv -- "${path}" "${backup}/"
    [[ ${path} == "${target}" ]] ||
      jsh::removed "${path##*/} removed" \
        "${path##*/} is replaced by the SACD decoder"
  done
  mv -- "${APP_TMP}/component" "${target}"
  mkdir -p -- "${state%/*}"
  printf '%s\n' "${version}" >"${state}"
  if [[ -n ${installed} ]]; then
    jsh::changed "foobar2000 SACD decoder set ${version}" "foobar2000 SACD decoder is ${installed}"
  else
    jsh::added "foobar2000 SACD decoder ${version} installed" "foobar2000 SACD decoder is missing"
  fi
}
app::with_closed foobar2000 foobar2000 install_component
