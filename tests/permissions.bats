#!/usr/bin/env bats

setup() {
  [[ $(uname -s) == Darwin ]] || skip 'macOS only'

  project_root=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  test_root=$(mktemp -d "${BATS_TEST_TMPDIR}/permissions.XXXXXX")
  home_root=${test_root}/home
  bin_root=${test_root}/bin
  app_path=/System/Applications/Utilities/Terminal.app

  [[ -f ${app_path}/Contents/Info.plist ]] || skip 'Terminal.app not found'

  mkdir -p "${home_root}/Library/Application Support/com.apple.TCC" "${bin_root}"
  : >"${home_root}/Library/Application Support/com.apple.TCC/TCC.db"
  cat >"${bin_root}/sqlite3" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod 755 "${bin_root}/sqlite3"
}

run_permissions() {
  run env \
    "PATH=${bin_root}:${PATH}" \
    "HOME=${home_root}" \
    JSH_COLOR=never \
    JSH_PLAIN_OUTPUT=1 \
    bash "${project_root}/scripts/macos/permissions.sh" "${app_path}" "$@"
}

@test "guided setup continues when privacy records are unreadable" {
  run_permissions

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Cannot inspect macOS privacy records; continuing configuration."* ]]
}

@test "guided setup retries after the first protected-data denial" {
  cat >"${bin_root}/sqlite3" <<'EOF'
#!/bin/sh
if [[ ! -e ${SQLITE_STATE} ]]; then
  : >"${SQLITE_STATE}"
  exit 1
fi
exit 0
EOF
  chmod 755 "${bin_root}/sqlite3"

  SQLITE_STATE="${test_root}/sqlite-state" run_permissions

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No registered permissions found."* ]]
  [[ "${output}" != *"Cannot inspect macOS privacy records"* ]]
}

@test "status check fails when privacy records are unreadable" {
  run_permissions --check

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot read macOS privacy records"* ]]
}
