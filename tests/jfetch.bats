#!/usr/bin/env bats

setup() {
  project_root=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  command_path=${project_root}/bin/jfetch
  mock_bin=${BATS_TEST_TMPDIR}/jfetch-bin
  mkdir -p "${mock_bin}"
}

write_linux_commands() {
  cat >"${mock_bin}/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'test64\n' ;;
  -r) printf '6.8.0-test\n' ;;
  *) printf 'Linux\n' ;;
esac
EOF
  cat >"${mock_bin}/id" <<'EOF'
#!/bin/sh
printf 'test-user\n'
EOF
  cat >"${mock_bin}/hostname" <<'EOF'
#!/bin/sh
printf 'test-host\n'
EOF
  cat >"${mock_bin}/brew" <<'EOF'
#!/bin/sh
case "$1:$2" in
  list:--formula) printf 'alpha\nbeta\n' ;;
  list:--cask) printf 'gamma\n' ;;
  *) exit 2 ;;
esac
EOF
  cat >"${mock_bin}/ip" <<'EOF'
#!/bin/sh
printf '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.8 uid 1000\n'
EOF
  cat >"${mock_bin}/testsh" <<'EOF'
#!/bin/sh
printf 'testsh 1.0\n'
EOF
  chmod +x "${mock_bin}/"*
}

@test "Linux output includes the graffiti J and core system fields" {
  write_linux_commands

  run env \
    PATH="${mock_bin}:/usr/bin:/bin" \
    SHELL="${mock_bin}/testsh" \
    TERM_PROGRAM=TestTerm \
    TERM_PROGRAM_VERSION=9.0 \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${command_path}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *':%@@@@@@@@@#*#@%-'* ]]
  [[ "${output}" == *'test-user@test-host'* ]]
  [[ "${output}" == *'OS: '*' test64'* ]]
  [[ "${output}" == *'Kernel: 6.8.0-test'* ]]
  [[ "${output}" == *'Packages: 2 (brew), 1 (brew-cask)'* ]]
  [[ "${output}" == *'Shell: testsh'* ]]
  [[ "${output}" == *'Terminal: TestTerm 9.0'* ]]
  [[ "${output}" == *'Local IP: 10.0.0.8'* ]]
  [[ "${output}" == *'Locale: '* ]]
  [[ "${output}" != *$'\033['* ]]
}

@test "always color renders the J in jsh cyan" {
  write_linux_commands

  run env -u NO_COLOR \
    PATH="${mock_bin}:/usr/bin:/bin" \
    SHELL="${mock_bin}/testsh" \
    TERM=xterm-256color \
    JSH_PLAIN_OUTPUT=0 \
    JSH_COLOR=always \
    "${command_path}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == $'\033[36m'* ]]
  [[ "${output}" == *$'\033[1;36mtest-user@test-host\033[0m'* ]]
}

@test "arguments are rejected" {
  run "${command_path}" --help

  [ "${status}" -eq 2 ]
  [ "${output}" = 'jfetch: this command takes no arguments' ]
}

@test "unsupported operating systems are rejected" {
  cat >"${mock_bin}/uname" <<'EOF'
#!/bin/sh
printf 'Plan9\n'
EOF
  chmod +x "${mock_bin}/uname"

  run env PATH="${mock_bin}:/usr/bin:/bin" "${command_path}"

  [ "${status}" -eq 1 ]
  [ "${output}" = 'jfetch: unsupported operating system: Plan9' ]
}
