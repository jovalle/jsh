#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export TEST_HOME="${BATS_TEST_TMPDIR}/home"
  export TEST_RUNTIME="${BATS_TEST_TMPDIR}/runtime"
  mkdir -p -- "${TEST_HOME}" "${TEST_RUNTIME}"
}

@test "uses Projects as the canonical project directory" {
  run env HOME="${TEST_HOME}" JSH_LOAD_CONFIG=0 JSH_RUNTIME_DIR="${TEST_RUNTIME}" \
    zsh -f -c 'unset GIT_BASE WORK_DIR J_PATHS
      source "$1/dotfiles/.zshrc" >/dev/null 2>&1
      printf "%s\n" "$GIT_BASE" "$WORK_DIR" "$J_PATHS"' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} == "${TEST_HOME}/Projects" ]]
  [[ ${lines[1]} == "${TEST_HOME}/Projects" ]]
  [[ ${lines[2]} == "${TEST_HOME}/Projects" ]]
}

@test "jgit create enters an existing project under Projects" {
  mkdir -p -- "${TEST_HOME}/Projects/example"

  run env HOME="${TEST_HOME}" JSH_LOAD_CONFIG=0 JSH_RUNTIME_DIR="${TEST_RUNTIME}" \
    zsh -f -c 'source "$1/dotfiles/.zshrc" >/dev/null 2>&1
      jgit create example
      print -r -- "$PWD"' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == "${TEST_HOME}/Projects/example" ]]
}

@test "j directory selection uses stable IDs from the shared chooser" {
  run env HOME="${TEST_HOME}" JSH_LOAD_CONFIG=0 JSH_RUNTIME_DIR="${TEST_RUNTIME}" \
    zsh -f -c '
      source "$1/dotfiles/.zshrc" >/dev/null 2>&1
      _j_query() { printf "%s\n" "2|/projects/one" "1|/projects/two"; }
      _j_get_projects() { return 0; }
      jsh::choose_one() {
        [[ $1 == Directory && $2 == /projects/one && $4 == /projects/two ]] || return 2
        print -rn -- "$4"
      }
      _j_interactive
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == /projects/two ]]
}

@test "j prefers a hidden exact basename over a higher-scored descendant" {
  local database="${BATS_TEST_TMPDIR}/j.db"
  local now
  mkdir -p -- "${TEST_HOME}/.jsh/lib"
  now=$(($(date +%s) / 3600))
  printf '%s|1|%s\n%s|10|%s\n' \
    "${TEST_HOME}/.jsh" "${now}" "${TEST_HOME}/.jsh/lib" "${now}" >"${database}"

  run env HOME="${TEST_HOME}" JSH="${JSH_ROOT}" J_DATA="${database}" \
    J_PATHS="${BATS_TEST_TMPDIR}/missing" J_NO_HOOK=1 \
    zsh -f -c 'source "$JSH/lib/zsh/j.zsh"
      j jsh
      print -r -- "$PWD"'

  [[ ${status} -eq 0 ]]
  [[ ${output} == "${TEST_HOME}/.jsh" ]]
}
