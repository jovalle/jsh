#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_PLAIN_OUTPUT=1
  JSH_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  fixture="${BATS_TEST_TMPDIR}/jsh-root"
  remote="${BATS_TEST_TMPDIR}/remote.git"
  seed="${BATS_TEST_TMPDIR}/seed"
  mkdir -p "${fixture}/conf" "${fixture}/lib" "${seed}"
  cp "${JSH_ROOT}/lib/output.sh" "${fixture}/lib/output.sh"
  git init -q -b main "${seed}"
  git init -q --bare -b main "${remote}"
  printf 'first\n' > "${seed}/file"
  git -C "${seed}" add file
  git -C "${seed}" -c user.name=Test -c user.email=test@example.com commit -qm first
  git -C "${seed}" remote add origin "${remote}"
  git -C "${seed}" push -q -u origin main
  printf 'vendor/repo %s\n' "${remote}" > "${fixture}/conf/vendor.list"
  mkdir -p "${fixture}/vendor"
  git clone -q "${remote}" "${fixture}/vendor/repo"
}

@test "vendor update preview and update run under sh" {
  local original updated
  original=$(git -C "${fixture}/vendor/repo" rev-parse HEAD)
  printf 'second\n' > "${seed}/file"
  git -C "${seed}" add file
  git -C "${seed}" -c user.name=Test -c user.email=test@example.com commit -qm second
  git -C "${seed}" push -q origin main
  updated=$(git -C "${seed}" rev-parse HEAD)

  run /bin/sh "${JSH_ROOT}/lib/unix/vendor.sh" --update --dry-run "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" = 'Would update vendor/repo' ]]
  [[ "$(git -C "${fixture}/vendor/repo" rev-parse HEAD)" = "${original}" ]]

  run /bin/sh "${JSH_ROOT}/lib/unix/vendor.sh" --update "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" = '✓ Updated vendor/repo' ]]
  [[ "$(git -C "${fixture}/vendor/repo" rev-parse HEAD)" = "${updated}" ]]
}

@test "broken submodule metadata is replaced after preserving the checkout" {
  local backup_file
  mkdir -p "${fixture}/vendor/broken"
  printf 'gitdir: ../missing-git-dir\n' > "${fixture}/vendor/broken/.git"
  printf 'local data\n' > "${fixture}/vendor/broken/local.txt"
  printf 'vendor/broken %s\n' "${remote}" > "${fixture}/conf/vendor.list"

  run /bin/sh "${JSH_ROOT}/lib/unix/vendor.sh" --update --dry-run "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" = 'Would back up and reclone vendor/broken (broken Git metadata)' ]]
  [[ -f "${fixture}/vendor/broken/local.txt" ]]

  run /bin/sh "${JSH_ROOT}/lib/unix/vendor.sh" --update "${fixture}"
  [[ "${status}" -eq 0 ]]
  [[ "$(git -C "${fixture}/vendor/broken" rev-parse HEAD)" = "$(git -C "${seed}" rev-parse HEAD)" ]]
  backup_file=$(find "${fixture}/tmp" -path '*/vendor/broken/local.txt' -print -quit)
  [[ -n "${backup_file}" ]]
  [[ "$(cat "${backup_file}")" = 'local data' ]]
  [[ -f "$(dirname "${backup_file}")/.git" ]]
}
