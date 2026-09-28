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

write_gnome_backend() {
  cat > "${CAFE_TEST_BIN}/gnome-session-inhibit" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --list ]]; then
  cat "${CAFE_TEST_GNOME_STATE}" 2>/dev/null || true
  exit 0
fi
printf 'gnome-session-inhibit %s\n' "$*" >> "${CAFE_TEST_LOG}"
app_id= reason=
while (($#)); do
  case $1 in
    --app-id) app_id=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --inhibit) shift 2 ;;
    *) break ;;
  esac
done
printf '%s: %s\n' "${app_id}" "${reason}" > "${CAFE_TEST_GNOME_STATE}"
exec "$@"
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

@test "XFCE toggle starts a validated inhibitor, disables sleep, and toggles off" {
  local command pid pid_file="${XDG_RUNTIME_DIR}/cafe.${USER}.pid" attempt
  write_gnome_backend
  for command in xfconf-query xset xfce4-panel xfce4-screensaver-command; do
    write_xfce_command "${command}"
  done
  mkdir -p "${HOME}/.config/xfce4/panel"
  printf 'Command=%s/bin/cafe --xfce-status\n' "${JSH_ROOT}" > \
    "${HOME}/.config/xfce4/panel/genmon-26.rc"
  export PATH="${CAFE_TEST_BIN}:${PATH}"
  export CAFE_TEST_GNOME_STATE="${BATS_TEST_TMPDIR}/gnome.state"

  run "${JSH_ROOT}/bin/cafe" --xfce-toggle

  [[ ${status} -eq 0 ]]
  [[ -s "${pid_file}" ]]
  pid=$(cat "${pid_file}")
  for ((attempt = 0; attempt < 100; attempt++)); do
    pgrep -g "${pid}" -f -- --linux-inhibited > /dev/null && break
    sleep 0.05
  done
  pgrep -g "${pid}" -f -- --linux-inhibited > /dev/null
  grep -Fq -- 'gnome-session-inhibit --app-id caffeine --reason Keep the screen active --inhibit idle:suspend' "${CAFE_TEST_LOG}"
  grep -Fq 'xfconf-query -c xfce4-screensaver -p /saver/enabled -s false' "${CAFE_TEST_LOG}"
  grep -Fq 'xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/presentation-mode -n -t bool -s true' "${CAFE_TEST_LOG}"
  grep -Fq 'xset -dpms' "${CAFE_TEST_LOG}"
  grep -Fq 'xfce4-screensaver-command -d' "${CAFE_TEST_LOG}"
  grep -Fq 'xfce4-panel --plugin-event=genmon-26:refresh:bool:true' "${CAFE_TEST_LOG}"

  run "${JSH_ROOT}/bin/cafe" --xfce-status
  [[ ${output} == *'cafe-on.svg'* ]]

  run "${JSH_ROOT}/bin/cafe" --xfce-toggle

  [[ ${status} -eq 0 ]]
  [[ ! -e "${pid_file}" ]]
  for ((attempt = 0; attempt < 100; attempt++)); do
    pgrep -g "${pid}" > /dev/null || break
    sleep 0.05
  done
  run pgrep -g "${pid}"
  [[ ${status} -ne 0 ]]
  grep -Fq 'xset +dpms' "${CAFE_TEST_LOG}"
}

@test "unsupported arguments report usage instead of Genmon markup" {
  run "${JSH_ROOT}/bin/cafe" --unknown

  [[ ${status} -eq 1 ]]
  [[ ${output} == *'usage: cafe'* ]]
  [[ ${output} != *'<img>'* ]]
}
