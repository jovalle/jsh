#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export HOME="${BATS_TEST_TMPDIR}/home"
  export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run"
  export CAFE_TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  export CAFE_TEST_LOG="${BATS_TEST_TMPDIR}/cafe.log"
  mkdir -p "${HOME}" "${XDG_RUNTIME_DIR}" "${CAFE_TEST_BIN}"
}

write_wrapper_backend() {
  local name=$1
  cat > "${CAFE_TEST_BIN}/${name}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CAFE_TEST_LOG}"
[[ -z ${CAFE_TEST_BACKEND_PID_FILE:-} ]] || printf '%s' "${BASHPID}" > "${CAFE_TEST_BACKEND_PID_FILE}"
duration= owner_pid=
while (($#)) && [[ $1 != -- ]]; do
  if [[ $1 == -t ]]; then
    duration=$2
    shift 2
  elif [[ $1 == -w ]]; then
    owner_pid=$2
    shift 2
  else
    shift
  fi
done
[[ -z ${CAFE_TEST_OWNER_PID_FILE:-} || -z ${owner_pid} ]] || printf '%s' "${owner_pid}" > "${CAFE_TEST_OWNER_PID_FILE}"
if [[ ${1:-} == -- ]]; then
  shift
  exec "$@"
elif [[ -n ${duration} ]]; then
  exec /bin/sleep "${duration}"
else
  exec /bin/sleep 86400
fi
EOF
  chmod +x "${CAFE_TEST_BIN}/${name}"
}

write_powershell_backend() {
  cat > "${CAFE_TEST_BIN}/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CAFE_TEST_LOG}"
printf 'WSLENV=%s\n' "${WSLENV:-}" >> "${CAFE_TEST_LOG}"
printf 'ready\n' > "${CAFE_READY_FILE}"
while [[ ! -e ${CAFE_STOP_FILE} ]]; do sleep 0.02; done
printf 'cleared\n' >> "${CAFE_TEST_LOG}"
EOF
  chmod +x "${CAFE_TEST_BIN}/powershell.exe"
}

write_pmset_backend() {
  cat > "${CAFE_TEST_BIN}/pmset" <<'EOF'
#!/usr/bin/env bash
owner_pid=$(cat "${CAFE_TEST_OWNER_PID_FILE}" 2>/dev/null || true)
printf "Details: caffeinate asserting on behalf of Process ID %s\n" "${owner_pid:-0}"
EOF
  chmod +x "${CAFE_TEST_BIN}/pmset"
}

write_gnome_backend() {
  cat > "${CAFE_TEST_BIN}/gnome-session-inhibit" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --list ]]; then
  cat "${CAFE_TEST_GNOME_STATE}" 2>/dev/null || true
  exit 0
fi
printf '%s\n' "$*" >> "${CAFE_TEST_LOG}"
app_id= reason=
while (($#)); do
  case $1 in
    --app-id) app_id=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s: %s\n' "${app_id}" "${reason}" > "${CAFE_TEST_GNOME_STATE}"
exec /bin/sleep 86400
EOF
  chmod +x "${CAFE_TEST_BIN}/gnome-session-inhibit"
}

write_xfce_command() {
  local name=$1
  cat > "${CAFE_TEST_BIN}/${name}" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "${CAFE_TEST_LOG}"
EOF
  chmod +x "${CAFE_TEST_BIN}/${name}"
}

@test "XFCE status renders Genmon state and merged click action" {
  local pid_file="${XDG_RUNTIME_DIR}/cafe.${USER}.pid"

  run env JSH_PLAIN_OUTPUT=1 "${JSH_ROOT}/bin/cafe" --xfce-status
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'cafe-off.svg'* ]]
  [[ ${output} == *"${JSH_ROOT}/bin/cafe --xfce-toggle"* ]]

  printf '%s' "$$" > "${pid_file}"
  run env JSH_PLAIN_OUTPUT=1 "${JSH_ROOT}/bin/cafe" --xfce-status
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'cafe-on.svg'* ]]
  rm -f "${pid_file}"
}

@test "XFCE toggle stops Cafe, restores sleep, and refreshes Genmon" {
  local command pid_file="${XDG_RUNTIME_DIR}/cafe.${USER}.pid" sleeper
  for command in xfconf-query xset xfce4-panel; do
    write_xfce_command "${command}"
  done
  mkdir -p "${HOME}/.config/xfce4/panel"
  printf 'Command=%s/bin/cafe --xfce-status\n' "${JSH_ROOT}" > \
    "${HOME}/.config/xfce4/panel/genmon-26.rc"
  sleep 30 &
  sleeper=$!
  printf '%s' "${sleeper}" > "${pid_file}"

  run env PATH="${CAFE_TEST_BIN}:${PATH}" JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" --xfce-toggle

  [[ ${status} -eq 0 ]]
  [[ ! -e "${pid_file}" ]]
  run kill -0 "${sleeper}"
  [[ ${status} -ne 0 ]]
  grep -Fq 'xfconf-query -c xfce4-screensaver -p /saver/enabled -s true' "${CAFE_TEST_LOG}"
  grep -Fq 'xset +dpms' "${CAFE_TEST_LOG}"
  grep -Fq 'xfce4-panel --plugin-event=genmon-26:refresh:bool:true' "${CAFE_TEST_LOG}"
}

@test "macOS starts and validates all caffeine assertions" {
  write_wrapper_backend caffeinate
  write_pmset_backend

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset" \
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid" \
    "${JSH_ROOT}/bin/cafe" -- true

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Validation: PASS - macOS display, user-idle, and system sleep assertions started'* ]]
  [[ ${output} == *'Inspect: pmset -g assertions'* ]]
  [[ ${output} == *'Cafe active: idle lock, display sleep, and system sleep are inhibited'* ]]
  [[ ${output} == *'Press Ctrl+C to stop.'* ]]
  [[ ${output} != *'Method caffeinate'* ]]
  grep -Eq '(^| )-i( |$)' "${CAFE_TEST_LOG}"
  grep -Eq '(^| )-u( |$)' "${CAFE_TEST_LOG}"
  grep -Eq '(^| )-d( |$)' "${CAFE_TEST_LOG}"
  grep -Eq '(^| )-s( |$)' "${CAFE_TEST_LOG}"
  grep -Eq '(^| )-w [0-9]+( |$)' "${CAFE_TEST_LOG}"
}

@test "Linux starts and validates GNOME idle and suspend inhibition" {
  write_gnome_backend

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Linux JSH_PLAIN_OUTPUT=1 \
    CAFE_TEST_GNOME_STATE="${BATS_TEST_TMPDIR}/gnome.state" \
    "${JSH_ROOT}/bin/cafe" -- true
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Validation: PASS - GNOME idle and suspend inhibitor registered'* ]]
  [[ ${output} == *'Inspect: gnome-session-inhibit --list'* ]]
  grep -Fq -- '--app-id cafe' "${CAFE_TEST_LOG}"
  grep -Fq -- '--reason User requested via cafe command' "${CAFE_TEST_LOG}"
  grep -Fq -- '--inhibit idle:suspend' "${CAFE_TEST_LOG}"
}

@test "a failing wrapped command runs once and preserves its status" {
  write_gnome_backend
  local calls="${BATS_TEST_TMPDIR}/command-calls"

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Linux JSH_PLAIN_OUTPUT=1 \
    CAFE_TEST_GNOME_STATE="${BATS_TEST_TMPDIR}/gnome.state" \
    "${JSH_ROOT}/bin/cafe" -- bash -c 'printf "called\n" >> "$1"; exit 23' _ "${calls}"

  [[ ${status} -eq 23 ]]
  [[ $(wc -l < "${calls}") -eq 1 ]]
}

@test "Windows sets execution state, sends F15 activity, and clears state" {
  write_powershell_backend

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Windows JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" -- true

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Validation: PASS - Windows display and system execution state set; F15 activity sent'* ]]
  [[ ${output} == *'Inspect: powercfg /requests'* ]]
  grep -Fq 'SetThreadExecutionState' "${CAFE_TEST_LOG}"
  grep -Fq 'SendInput' "${CAFE_TEST_LOG}"
  grep -Fq 'SendF15' "${CAFE_TEST_LOG}"
  grep -Fq '0x7E' "${CAFE_TEST_LOG}"
  grep -Fq 'CAFE_READY_FILE:CAFE_STOP_FILE' "${CAFE_TEST_LOG}"
  grep -Fq 'cleared' "${CAFE_TEST_LOG}"
}

@test "background status and stop preserve the public PID-file contract" {
  write_wrapper_backend caffeinate
  write_pmset_backend
  local backend_pid backend_pid_file="${BATS_TEST_TMPDIR}/backend.pid"
  local -a cafe_env=(env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate"
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset"
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid"
    CAFE_TEST_BACKEND_PID_FILE="${backend_pid_file}" JSH_PLAIN_OUTPUT=1)

  run "${cafe_env[@]}" "${JSH_ROOT}/bin/cafe" --background
  [[ ${status} -eq 0 ]]
  [[ -s "${XDG_RUNTIME_DIR}/cafe.${USER}.pid" ]]

  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -s ${backend_pid_file} ]] && break
    sleep 0.02
  done
  [[ -s ${backend_pid_file} ]]
  backend_pid=$(cat "${backend_pid_file}")

  run "${cafe_env[@]}" "${JSH_ROOT}/bin/cafe" --status
  [[ ${status} -eq 0 ]]
  [[ ${output} = *'running'* ]]

  run "${cafe_env[@]}" "${JSH_ROOT}/bin/cafe" --stop
  [[ ${status} -eq 0 ]]
  [[ ! -e "${XDG_RUNTIME_DIR}/cafe.${USER}.pid" ]]
  run kill -0 "${backend_pid}"
  [[ ${status} -ne 0 ]]
}

@test "background startup fails when no inhibitor is available" {
  run env PATH="${CAFE_TEST_BIN}:/usr/bin:/bin" CAFE_PLATFORM=Unsupported JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" --background

  [[ ${status} -ne 0 ]]
  [[ ! -e "${XDG_RUNTIME_DIR}/cafe.${USER}.pid" ]]
}

@test "a timed background session removes its PID file when complete" {
  write_wrapper_backend caffeinate
  write_pmset_backend
  local pid_file="${XDG_RUNTIME_DIR}/cafe.${USER}.pid"

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset" \
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid" \
    "${JSH_ROOT}/bin/cafe" --background --time 1
  [[ ${status} -eq 0 ]]

  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -e ${pid_file} ]] || break
    sleep 0.05
  done
  [[ ! -e ${pid_file} ]]
}

@test "piped execution does not depend on the script path" {
  write_wrapper_backend caffeinate
  write_pmset_backend

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset" \
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid" \
    CAFE_DURATION=1 /bin/bash < "${JSH_ROOT}/bin/cafe"

  [[ ${status} -eq 0 ]]
  [[ ${output} = *'Validation: PASS'* ]]
  [[ ${output} != *'Method bash'* ]]
}

@test "active output uses semantic success, detail, and activity colors" {
  write_wrapper_backend caffeinate
  write_pmset_backend

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin TERM=xterm \
    JSH_COLOR=always CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" \
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset" \
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid" \
    "${JSH_ROOT}/bin/cafe" -- true

  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'\033[32m✓ Validation: PASS - macOS'* ]]
  [[ ${output} == *$'\033[2;37mInspect: pmset -g assertions'* ]]
  [[ ${output} == *$'\033[36mCafe active: idle lock'* ]]
  [[ ${output} == *$'\033[2;37mPress Ctrl+C to stop.'* ]]
}

@test "TUI animates dotted steam and repeats its cycle" {
  run env CAFE_SOURCE_ONLY=1 LINES=24 COLUMNS=80 JSH_PLAIN_OUTPUT=1 bash -c '
    source "$1"
    CAFE_METHOD=gnome-session-inhibit
    first=$(render_tui_frame 0 3661)
    next=$(render_tui_frame 1 3661)
    cycle=$(render_tui_frame 12 3661)
    [[ ${first} != "${next}" && ${first} == "${cycle}" ]]
    [[ ${first} == *"•"* && ${first} == *"01h 01m 01s"* ]]
    [[ ${first} == *"gnome-session-inhibit"* ]]
  ' _ "${JSH_ROOT}/bin/cafe"
  [[ ${status} -eq 0 ]]
}

@test "TUI scales again after terminal dimensions change" {
  run env CAFE_SOURCE_ONLY=1 JSH_PLAIN_OUTPUT=1 bash -c '
    source "$1"
    LINES=24 COLUMNS=80
    small=$(render_tui_frame 0 0)
    LINES=50 COLUMNS=160
    large=$(render_tui_frame 0 0)
    [[ ${#large} -gt ${#small} ]]
    LINES=10 COLUMNS=24
    compact=$(render_tui_frame 0 0)
    [[ ${compact} == *"•"* && ${compact} == *"Ctrl+C to stop"* ]]
    [[ ${compact} != *"Method"* ]]
    LINES=3 COLUMNS=12
    tiny=$(render_tui_frame 0 0)
    [[ ${tiny} != *"•"* && ${tiny} == *"Cafe"* ]]
  ' _ "${JSH_ROOT}/bin/cafe"
  [[ ${status} -eq 0 ]]
}

@test "TUI enters and leaves the alternate screen" {
  run env CAFE_SOURCE_ONLY=1 TERM=xterm bash -c '
    source "$1"
    enter_tui
    leave_tui
  ' _ "${JSH_ROOT}/bin/cafe"

  [[ ${status} -eq 0 ]]
  [[ ${output} = *$'\033[?1049h'* ]]
  [[ ${output} = *$'\033[?1049l'* ]]
}

@test "a completed foreground wait prints an exit message" {
  write_wrapper_backend caffeinate
  write_pmset_backend

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset" \
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid" \
    "${JSH_ROOT}/bin/cafe" --time 1

  [[ ${status} -eq 0 ]]
  [[ ${output} = *'Cafe stopped'* ]]
}

@test "SIGTERM restores state and exits with signal status" {
  write_wrapper_backend caffeinate
  write_pmset_backend
  local output_file="${BATS_TEST_TMPDIR}/signal-output"
  local exit_code=0 pid

  env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    CAFE_PMSET_BIN="${CAFE_TEST_BIN}/pmset" \
    CAFE_TEST_OWNER_PID_FILE="${BATS_TEST_TMPDIR}/owner.pid" \
    "${JSH_ROOT}/bin/cafe" --time 30 > "${output_file}" 2>&1 &
  pid=$!
  local attempt
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -s ${CAFE_TEST_LOG} ]] && break
    sleep 0.02
  done
  kill -TERM "${pid}"
  wait "${pid}" || exit_code=$?

  [[ ${exit_code} -eq 143 ]]
  grep -Fq 'Cafe stopped.' "${output_file}"
  run ! pgrep -f -- "${XDG_RUNTIME_DIR}/cafe.${USER}.${pid}.stop"
}
