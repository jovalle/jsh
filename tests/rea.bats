#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  local root="${BATS_TEST_TMPDIR}/rea-root"
  mkdir -p "${root}/scripts/unix/configure" "${root}/lib" "${root}/bin"
  cp "${BATS_TEST_DIRNAME}/../scripts/unix/configure/rea.sh" "${root}/scripts/unix/configure/rea.sh"
  cat > "${root}/lib/output.sh" << 'SH'
#!/bin/bash
jsh::log_note() { printf '%s\n' "$*"; }
jsh::log_success() { printf '%s\n' "$*"; }
SH
  chmod +x "${root}/lib/output.sh"
  export REA_TEST_ROOT=${root}
  export REA_TEST_CALLS="${root}/calls"
}

@test "REA configuration skips when its CLI is absent" {
  run env PATH=/usr/bin:/bin /bin/bash "${REA_TEST_ROOT}/scripts/unix/configure/rea.sh"
  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Skipping REA configuration:'* ]]
  [[ ! -e ${REA_TEST_CALLS} ]]
}

@test "REA configuration scopes setup to Codex and propagates failure" {
  local calls
  cat > "${REA_TEST_ROOT}/bin/rea" << 'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${REA_TEST_CALLS}"
exit "${REA_TEST_STATUS:-0}"
SH
  cp "${REA_TEST_ROOT}/bin/rea" "${REA_TEST_ROOT}/bin/codex"
  chmod +x "${REA_TEST_ROOT}/bin/"*

  run env PATH="${REA_TEST_ROOT}/bin:${PATH}" bash "${REA_TEST_ROOT}/scripts/unix/configure/rea.sh"
  [[ ${status} -eq 0 ]]
  calls=$(cat "${REA_TEST_CALLS}")
  [[ ${calls} == 'setup --client codex --yes' ]]
  [[ ${output} == *'REA is configured for Codex.'* ]]

  run env PATH="${REA_TEST_ROOT}/bin:${PATH}" REA_TEST_STATUS=7 bash "${REA_TEST_ROOT}/scripts/unix/configure/rea.sh"
  [[ ${status} -eq 7 ]]
  [[ ${output} != *'REA is configured for Codex.'* ]]
}
