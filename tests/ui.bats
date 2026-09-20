#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export UI_COLOR_MODE=none
}

@test "converts semantic colors to TrueColor and ANSI 256" {
  run bash -c '
    source "$1/lib/ui/theme.sh"
    UI_COLOR_MODE=truecolor
    [[ $(ui::ansi_fg ERROR) == $'"'"'\033[38;2;238;53;46m'"'"' ]]
    UI_COLOR_MODE=256
    [[ $(ui::ansi_bg SURFACE) == $'"'"'\033[48;5;16m'"'"' ]]
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}

@test "renders wrapped multiline boxes with padding and alignment" {
  run bash -c '
    source "$1/lib/ui/lipgloss.sh"
    ui::box --border normal --padding-x 1 --width 5 --align center -- $'"'"'abc\ndefghij'"'"'
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'┌───────┐\n│  abc  │\n│ defgh │\n│  ij   │\n└───────┘' ]]
}

@test "preserves styled text width while wrapping" {
  run bash -c '
    source "$1/lib/ui/lipgloss.sh"
    UI_COLOR_MODE=truecolor
    styled=$(ui::style --fg ERROR -- abcde)
    UI_COLOR_MODE=none
    rendered=$(ui::box --border normal --padding-x 0 --width 3 -- "$styled")
    ui::_strip_ansi "$rendered"
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'┌───┐\n│abc│\n│de │\n└───┘' ]]
}

@test "box backgrounds are transparent unless explicitly set" {
  run bash -c '
    source "$1/lib/ui/lipgloss.sh"
    UI_COLOR_MODE=truecolor
    transparent=$(ui::box --width 2 -- ok)
    opaque=$(ui::box --bg SURFACE --width 2 -- ok)
    [[ $transparent != *$'"'"'\033[48;'"'"'* ]]
    [[ $opaque == *$'"'"'\033[48;2;0;0;0m'"'"'* ]]
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}

@test "returns prompt values on stdout and renders UI on stderr" {
  local prompt_log="${BATS_TEST_TMPDIR}/ui-prompts.err"

  run bash -c '
    source "$1/lib/ui/gum.sh"
    exec 3<<<$'"'"'\033[B\n'"'"'
    UI_INPUT_FD=3
    choice=$(ui::choose "Pick one" alpha beta gamma 2>"$2")
    exec 3<<<$'"'"'\n'"'"'
    value=$(ui::input "Name" --default jay 2>>"$2")
    printf "%s|%s\n" "$choice" "$value"
  ' _ "${JSH_ROOT}" "${prompt_log}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == 'beta|jay' ]]
  run grep -F 'Pick one' "${prompt_log}"
  [[ ${status} -eq 0 ]]
}

@test "supports hidden and masked input without leaking the value" {
  local prompt_log="${BATS_TEST_TMPDIR}/ui-secret.err"

  run bash -c '
    source "$1/lib/ui/gum.sh"
    exec 3<<<$'"'"'s3cr3t\n'"'"'
    UI_INPUT_FD=3
    value=$(ui::input "Password" --mask 2>"$2")
    [[ $value == s3cr3t ]]
  ' _ "${JSH_ROOT}" "${prompt_log}"

  [[ ${status} -eq 0 ]]
  run grep -F '••••••' "${prompt_log}"
  [[ ${status} -eq 0 ]]
  run grep -F 's3cr3t' "${prompt_log}"
  [[ ${status} -ne 0 ]]
}

@test "supports secret bullet masking by default in Bash and Zsh" {
  local bash_log="${BATS_TEST_TMPDIR}/ui-secret-bash.err"
  local zsh_log="${BATS_TEST_TMPDIR}/ui-secret-zsh.err"

  run bash -c '
    source "$1/lib/ui/gum.sh"
    exec 3<<<$'"'"'mysecret\n'"'"'
    UI_INPUT_FD=3
    value=$(ui::input "Password" --secret 2>"$2")
    [[ $value == mysecret ]]
  ' _ "${JSH_ROOT}" "${bash_log}"
  [[ ${status} -eq 0 ]]
  run grep -F '••••••••' "${bash_log}"
  [[ ${status} -eq 0 ]]

  if command -v zsh > /dev/null 2>&1; then
    run zsh -f -c '
      source "$1/lib/ui/gum.sh"
      exec 3<<<$'"'"'mysecret\n'"'"'
      UI_INPUT_FD=3
      value=$(ui::input "Password" --secret 2>"$2")
      [[ $value == mysecret ]]
    ' _ "${JSH_ROOT}" "${zsh_log}"
    [[ ${status} -eq 0 ]]
    run grep -F '••••••••' "${zsh_log}"
    [[ ${status} -eq 0 ]]
  fi
}

@test "supports backspace and Ctrl-U clearing bullets in masked input" {
  run bash -c '
    source "$1/lib/ui/gum.sh"
    exec 3<<<$'"'"'abc\177d\n'"'"'
    UI_INPUT_FD=3
    value=$(ui::input "Password" --mask 2>/dev/null)
    [[ $value == abd ]]
  ' _ "${JSH_ROOT}"
  [[ ${status} -eq 0 ]]

  run bash -c '
    source "$1/lib/ui/gum.sh"
    exec 3<<<$'"'"'abc\025xyz\n'"'"'
    UI_INPUT_FD=3
    value=$(ui::input "Password" --mask 2>/dev/null)
    [[ $value == xyz ]]
  ' _ "${JSH_ROOT}"
  [[ ${status} -eq 0 ]]
}

@test "supports completely hidden input with --hidden" {
  local hidden_log="${BATS_TEST_TMPDIR}/ui-hidden.err"

  run bash -c '
    source "$1/lib/ui/gum.sh"
    exec 3<<<$'"'"'hiddenvalue\n'"'"'
    UI_INPUT_FD=3
    value=$(ui::input "Secret" --hidden 2>"$2")
    [[ $value == hiddenvalue ]]
  ' _ "${JSH_ROOT}" "${hidden_log}"
  [[ ${status} -eq 0 ]]
  run grep -F '••••' "${hidden_log}"
  [[ ${status} -ne 0 ]]
  run grep -F 'hiddenvalue' "${hidden_log}"
  [[ ${status} -ne 0 ]]
}

@test "secret bullet masking renders incrementally in interactive PTY across Zsh and Bash" {
  command -v python3 > /dev/null 2>&1 || skip "python3 not available"

  python3 -c '
import pty, os, time, fcntl

def read_until(master, expected, timeout=1.0):
  deadline = time.time() + timeout
  output = b""
  while expected not in output and time.time() < deadline:
    try:
      output += os.read(master, 1024)
    except BlockingIOError:
      time.sleep(0.01)
    except OSError:
      break
  return output

def test_pty(shell, root):
    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(slave)
        os.environ["TERM"] = "xterm-256color"
        os.execv(shell, [shell, "-c", f"source {root}/lib/ui/gum.sh; v=$(ui::input \"PW\" --secret); echo VAL:$v"])
    else:
        os.close(slave)
        flags = fcntl.fcntl(master, fcntl.F_GETFL)
        fcntl.fcntl(master, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        assert b": " in read_until(master, b": "), "prompt did not render"
        events = []
        for ch, expected in [
          (b"x", b"\xe2\x80\xa2"),
          (b"y", b"\xe2\x80\xa2"),
          (b"\x7f", b"\x08 \x08"),
          (b"z", b"\xe2\x80\xa2"),
          (b"\r", b"VAL:xz"),
        ]:
            os.write(master, ch)
            buf = read_until(master, expected)
            events.append((ch, buf))
        _, status = os.waitpid(pid, 0)
        assert os.WEXITSTATUS(status) == 0
        assert any(b"\xe2\x80\xa2" in out for ch, out in events if ch == b"x"), "x did not emit bullet"
        assert any(b"\x08 \x08" in out for ch, out in events if ch == b"\x7f"), "backspace did not erase bullet"
        assert any(b"VAL:xz" in out for ch, out in events if ch == b"\r"), "final value incorrect"

test_pty("/bin/bash", "'"${JSH_ROOT}"'")
if os.path.exists("/usr/bin/zsh"):
    test_pty("/usr/bin/zsh", "'"${JSH_ROOT}"'")
'
}

@test "interactive primitives preserve caller traps" {
  run bash -c '
    source "$1/lib/ui/gum.sh"
    trap ": caller cleanup" EXIT
    before=$(trap -p EXIT)
    exec 3<<<n
    UI_INPUT_FD=3
    ui::confirm "Continue?" || true
    after=$(trap -p EXIT)
    [[ $before == "$after" ]]
  ' _ "${JSH_ROOT}" 2> /dev/null

  [[ ${status} -eq 0 ]]
}

@test "spinner returns the tracked process status" {
  run bash -c '
    source "$1/lib/ui/gum.sh"
    (exit 7) &
    pid=$!
    ui::spin "$pid" "Expected failure" >/dev/null 2>&1
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 7 ]]
}

@test "all modules parse and render consistently in Zsh" {
  command -v zsh > /dev/null || skip 'zsh is unavailable'

  run zsh -f -c '
    source "$1/lib/ui/gum.sh"
    [[ $(ui::token ACCENT_PRIMARY) == "#0039A6" ]]
    [[ $(ui::box --border double --padding-x 0 --width 2 -- ok) == $'"'"'╔══╗\n║ok║\n╚══╝'"'"' ]]
    exec 3<<<$'"'"'\033[B\n'"'"'
    UI_INPUT_FD=3
    [[ $(ui::choose Pick one two) == two ]]
  ' _ "${JSH_ROOT}" 2> /dev/null

  [[ ${status} -eq 0 ]]
}

@test "modules resolve siblings when sourced by bare filename" {
  run bash -c '
    cd "$1/lib/ui"
    source gum.sh
    [[ $(ui::token SUCCESS) == "#00933C" ]]
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}
