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