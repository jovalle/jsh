#!/usr/bin/env bats

setup() {
  project_root=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  test_root=$(mktemp -d "${BATS_TEST_TMPDIR}/j.XXXXXX")
  exact_dir=${test_root}/baremetal
  nested_dir=${exact_dir}/opa
  database=${test_root}/j.db
  now=$(($(date +%s) / 3600))

  mkdir -p "${nested_dir}" "${test_root}/home"
  printf '%s|1|%s\n%s|100|%s\n' \
    "${exact_dir}" "${now}" "${nested_dir}" "${now}" >"${database}"
}

@test "query prefers an exact directory name over a higher-frecency substring" {
  run env \
    HOME="${test_root}/home" \
    J_DATA="${database}" \
    PROJECT_ROOT="${project_root}" \
    zsh -dfc 'source "${PROJECT_ROOT}/dotfiles/.zshrc" >/dev/null 2>&1; _j_query baremetal'

  [ "${status}" -eq 0 ]
  [ "${lines[0]#*|}" = "${exact_dir}" ]
  [ "${lines[1]#*|}" = "${nested_dir}" ]
}

@test "missing directory message is colored and starts in column one" {
  run env \
    HOME="${test_root}/home" \
    J_DATA="${database}" \
    JSH_COLOR=always \
    TERM=xterm-256color \
    PROJECT_ROOT="${project_root}" \
    zsh -dfc 'source "${PROJECT_ROOT}/dotfiles/.zshrc" >/dev/null 2>&1; j nientienod'

  [ "${status}" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == $'\033['*'✕ No matching directory: nientienod'$'\033[0m' ]]
}

@test "NO_COLOR suppresses forced color in shell messages" {
  run env \
    HOME="${test_root}/home" \
    J_DATA="${database}" \
    JSH_COLOR=always \
    NO_COLOR=1 \
    TERM=xterm-256color \
    PROJECT_ROOT="${project_root}" \
    zsh -dfc 'source "${PROJECT_ROOT}/dotfiles/.zshrc" >/dev/null 2>&1; j nientienod'

  [ "${status}" -eq 1 ]
  [ "${output}" = '✕ No matching directory: nientienod' ]
}

@test "shell utility errors use the standalone message renderer" {
  run env \
    HOME="${test_root}/home" \
    JSH_COLOR=always \
    TERM=xterm-256color \
    PROJECT_ROOT="${project_root}" \
    zsh -dfc 'source "${PROJECT_ROOT}/dotfiles/.zshrc" >/dev/null 2>&1; bak missing-file'

  [ "${status}" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == $'\033['*'✕ File not found: missing-file'$'\033[0m' ]]
}

@test "setup script messages use semantic forced color" {
  run env -u NO_COLOR \
    JSH_COLOR=always \
    TERM=xterm-256color \
    PROJECT_ROOT="${project_root}" \
    sh -c '. "${PROJECT_ROOT}/scripts/ui.sh"; jsh_error "setup failed"'

  [ "${status}" -eq 0 ]
  [[ "${output}" == $'\033['*'✖'$'\033[0m'' setup failed' ]]
}

@test "setup script messages honor NO_COLOR" {
  run env \
    JSH_COLOR=always \
    NO_COLOR=1 \
    TERM=xterm-256color \
    PROJECT_ROOT="${project_root}" \
    sh -c '. "${PROJECT_ROOT}/scripts/ui.sh"; jsh_error "setup failed"'

  [ "${status}" -eq 0 ]
  [ "${output}" = '[error] setup failed' ]
}
