#!/usr/bin/env bats

setup() {
  ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  TEST_HOME="${BATS_TEST_TMPDIR}/home"
  STATE="${BATS_TEST_TMPDIR}/state"
  BIN_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${TEST_HOME}" "${BIN_DIR}"
}

install_runtime() {
  env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    TERM=xterm-256color "${ROOT}/bin/jsh" install --mode runtime >/dev/null
}

@test "runtime install records its mode and launcher" {
  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    TERM=xterm-256color JSH_PLAIN_OUTPUT=1 \
    "${ROOT}/bin/jsh" install --mode runtime

  [[ ${status} -eq 0 ]]
  [[ -L ${BIN_DIR}/jsh ]]
  [[ $(<"${STATE}/mode") == runtime ]]
}

@test "install dry-run leaves state untouched" {
  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    TERM=xterm-256color JSH_PLAIN_OUTPUT=1 \
    "${ROOT}/bin/jsh" install --mode runtime --dry-run

  [[ ${status} -eq 0 ]]
  [[ ! -e ${STATE}/mode ]]
  [[ ! -e ${BIN_DIR}/jsh ]]
}

@test "status porcelain output remains byte-stable" {
  install_runtime

  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    TERM=xterm-256color "${ROOT}/bin/jsh" status --porcelain

  expected=$(printf 'jsh-status\t1\tcomponent\tstate\tname\tdetail\n%s\n%s' \
    $'shell\tcurrent\tmode\truntime' \
    "shell"$'\t'"current"$'\t'"launcher"$'\t'"${BIN_DIR}/jsh")
  [[ ${status} -eq 0 ]]
  [[ ${output} == "${expected}" ]]
}

@test "NO_COLOR suppresses terminal escapes" {
  install_runtime

  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    TERM=xterm-256color NO_COLOR=1 JSH_COLOR=always \
    "${ROOT}/bin/jsh" status

  [[ ${status} -eq 0 ]]
  [[ ${output} != *$'\033'* ]]
}

@test "unknown status options exit 2" {
  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    NO_COLOR=1 "${ROOT}/bin/jsh" status --bad

  [[ ${status} -eq 2 ]]
  [[ ${output} == *'unknown status option: --bad'* ]]
}

@test "removed setup command stays unavailable" {
  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    JSH_PLAIN_OUTPUT=1 "${ROOT}/bin/jsh" setup

  [[ ${status} -eq 2 ]]
  [[ ${output} == *'unknown command: setup'* ]]
}

@test "doctor porcelain output exposes its schema and required tools" {
  run "${ROOT}/bin/jsh" doctor --porcelain

  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'jsh-doctor\t1\tcomponent\tclassification\tname\tdetail'* ]]
  [[ ${output} == *$'base\trequired\tbash\tavailable'* ]]
}

@test "uninstall dry-run preserves install state" {
  install_runtime
  before=$(cksum "${STATE}/managed-links" "${STATE}/mode")

  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    JSH_PLAIN_OUTPUT=1 "${ROOT}/bin/jsh" uninstall --dry-run

  [[ ${status} -eq 0 ]]
  [[ $(cksum "${STATE}/managed-links" "${STATE}/mode") == "${before}" ]]
  [[ -L ${BIN_DIR}/jsh ]]
}

@test "local bootstrap delegates to runtime installation" {
  run env HOME="${TEST_HOME}" JSH_STATE_DIR="${STATE}" JSH_BIN_DIR="${BIN_DIR}" \
    JSH_MODE=runtime JSH_PLAIN_OUTPUT=1 TERM=xterm-256color sh "${ROOT}/j.sh"

  [[ ${status} -eq 0 ]]
  [[ $(<"${STATE}/mode") == runtime ]]
  [[ -L ${BIN_DIR}/jsh ]]
}
