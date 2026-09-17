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
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
[[ ${1:-} != -- ]] || shift
exec "$@"
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

@test "macOS uses caffeinate with idle and requested display assertions" {
  write_wrapper_backend caffeinate

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" -d -- true

  [[ ${status} -eq 0 ]]
  grep -Eq '(^| )-i( |$)' "${CAFE_TEST_LOG}"
  grep -Eq '(^| )-d( |$)' "${CAFE_TEST_LOG}"
  run ! grep -Eq '(^| )-s( |$)' "${CAFE_TEST_LOG}"
}

@test "systemd uses idle only by default and widens system scope on request" {
  write_wrapper_backend systemd-inhibit

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Linux JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" -- true
  [[ ${status} -eq 0 ]]
  grep -Fq -- '--what=idle' "${CAFE_TEST_LOG}"

  : > "${CAFE_TEST_LOG}"
  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Linux JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" -s -- true
  [[ ${status} -eq 0 ]]
  grep -Fq -- '--what=idle:sleep:shutdown' "${CAFE_TEST_LOG}"
  grep -Fq -- '--mode=block' "${CAFE_TEST_LOG}"
}

@test "a failing wrapped command runs once and preserves its status" {
  write_wrapper_backend systemd-inhibit
  local calls="${BATS_TEST_TMPDIR}/command-calls"

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Linux JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" -- bash -c 'printf "called\n" >> "$1"; exit 23' _ "${calls}"

  [[ ${status} -eq 23 ]]
  [[ $(wc -l < "${calls}") -eq 1 ]]
}

@test "WSL prefers PowerShell and clears its execution state on exit" {
  write_powershell_backend
  write_wrapper_backend systemd-inhibit

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=WSL JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" -d -- true

  [[ ${status} -eq 0 ]]
  grep -Fq 'SetThreadExecutionState' "${CAFE_TEST_LOG}"
  grep -Fq '0x80000003' "${CAFE_TEST_LOG}"
  grep -Fq 'CAFE_READY_FILE:CAFE_STOP_FILE' "${CAFE_TEST_LOG}"
  grep -Fq 'cleared' "${CAFE_TEST_LOG}"
  run ! grep -Fq -- '--what=' "${CAFE_TEST_LOG}"
}

@test "background status and stop preserve the public PID-file contract" {
  write_wrapper_backend caffeinate
  local -a cafe_env=(env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1)

  run "${cafe_env[@]}" "${JSH_ROOT}/bin/cafe" --background
  [[ ${status} -eq 0 ]]
  [[ -s "${XDG_RUNTIME_DIR}/cafe.${USER}.pid" ]]

  run "${cafe_env[@]}" "${JSH_ROOT}/bin/cafe" --status
  [[ ${status} -eq 0 ]]
  [[ ${output} = *'running'* ]]

  run "${cafe_env[@]}" "${JSH_ROOT}/bin/cafe" --stop
  [[ ${status} -eq 0 ]]
  [[ ! -e "${XDG_RUNTIME_DIR}/cafe.${USER}.pid" ]]
}

@test "background startup fails when no inhibitor is available" {
  run env PATH="${CAFE_TEST_BIN}:/usr/bin:/bin" CAFE_PLATFORM=Unsupported JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" --background

  [[ ${status} -ne 0 ]]
  [[ ! -e "${XDG_RUNTIME_DIR}/cafe.${USER}.pid" ]]
}

@test "a timed background session removes its PID file when complete" {
  write_wrapper_backend caffeinate
  local pid_file="${XDG_RUNTIME_DIR}/cafe.${USER}.pid"

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
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

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    CAFE_DURATION=1 /bin/bash < "${JSH_ROOT}/bin/cafe"

  [[ ${status} -eq 0 ]]
  [[ ${output} = *'Method caffeinate'* ]]
  [[ ${output} != *'Method bash'* ]]
}

@test "TUI animates dotted steam and repeats its cycle" {
  run env CAFE_SOURCE_ONLY=1 LINES=24 COLUMNS=80 JSH_PLAIN_OUTPUT=1 bash -c '
    source "$1"
    CAFE_METHOD=systemd-inhibit
    first=$(render_tui_frame 0 3661)
    next=$(render_tui_frame 1 3661)
    cycle=$(render_tui_frame 12 3661)
    [[ ${first} != "${next}" && ${first} == "${cycle}" ]]
    [[ ${first} == *"•"* && ${first} == *"01h 01m 01s"* ]]
    [[ ${first} == *"systemd-inhibit"* ]]
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

  run env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/cafe" --time 1

  [[ ${status} -eq 0 ]]
  [[ ${output} = *'Cafe stopped'* ]]
}

@test "SIGTERM restores state and exits with signal status" {
  write_wrapper_backend caffeinate
  local output_file="${BATS_TEST_TMPDIR}/signal-output"
  local exit_code=0 pid

  env PATH="${CAFE_TEST_BIN}:${PATH}" CAFE_PLATFORM=Darwin \
    CAFE_CAFFEINATE_BIN="${CAFE_TEST_BIN}/caffeinate" JSH_PLAIN_OUTPUT=1 \
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
  grep -Fq 'Stopped' "${output_file}"
  run ! pgrep -f -- "${XDG_RUNTIME_DIR}/cafe.${USER}.${pid}.stop"
}
