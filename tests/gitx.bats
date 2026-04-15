#!/usr/bin/env bats

setup() {
  project_root=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  test_root=$(mktemp -d "${BATS_TEST_TMPDIR}/gitx.XXXXXX")
  repo_root=${test_root}/repo
  profiles_file=${test_root}/missing-profiles.json
  ssh_key=${test_root}/id_test

  git init -q -b main "${repo_root}"
  git -C "${repo_root}" config jsh.profile personal
  git -C "${repo_root}" config commit.gpgsign false
}

write_profile() {
  printf '%s\n' \
    '{' \
    '  "profiles": {' \
    '    "personal": {' \
    '      "name": "Test User",' \
    '      "email": "test@example.invalid",' \
    '      "user": "test-user",' \
    "      \"ssh_key\": \"${ssh_key}\"," \
    '      "gpgsign": false' \
    '    }' \
    '  }' \
    '}' >"${profiles_file}"
  touch "${ssh_key}"
}

@test "commit reports a missing profiles file" {
  cd "${repo_root}"

  run env \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t +6m -m "test commit"

  [ "${status}" -eq 1 ]
  [ "${output}" = "[error] Profiles file not found: ${profiles_file}" ]
}

@test "commit shows details and preserves native Git output" {
  write_profile
  git -C "${repo_root}" config user.name "Setup User"
  git -C "${repo_root}" config user.email setup@example.invalid
  printf '%s\n' initial >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  git -C "${repo_root}" commit -qm initial
  previous_epoch=$(git -C "${repo_root}" log -1 --format=%at)
  printf '%s\n' changed >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  cd "${repo_root}"

  run env \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t +6m -m "test commit"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'Commit\n'* ]]
  [[ "${output}" == *"Profile"*"personal"* ]]
  [[ "${output}" == *"Author"*"Test User <test@example.invalid>"* ]]
  [[ "${output}" == *"Timestamp"* ]]
  [[ "${output}" == *"Signing"*"off"* ]]
  [[ "${output}" == *"test commit"* ]]
  [ "$(git log -1 --format=%an)" = "Test User" ]
  new_epoch=$(git log -1 --format=%at)
  expected_minute=$(((previous_epoch + 360) / 60))
  [ "$((new_epoch / 60))" -eq "${expected_minute}" ]
  [ "${new_epoch}" -gt "${previous_epoch}" ]
}

@test "commit randomizes seconds omitted from a relative timestamp" {
  write_profile
  git -C "${repo_root}" config user.name "Setup User"
  git -C "${repo_root}" config user.email setup@example.invalid
  printf '%s\n' initial >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  GIT_AUTHOR_DATE='2026-04-15 18:14:27 -0400' \
    GIT_COMMITTER_DATE='2026-04-15 18:14:27 -0400' \
    git -C "${repo_root}" commit -qm initial
  previous_epoch=$(git -C "${repo_root}" log -1 --format=%at)
  printf '%s\n' changed >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  cd "${repo_root}"

  run env \
    RANDOM=42 \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t +6m -m "random seconds"

  [ "${status}" -eq 0 ]
  new_epoch=$(git log -1 --format=%at)
  [ "$((new_epoch % 60))" -ne 27 ]
  [ "${new_epoch}" -gt "${previous_epoch}" ]
}

@test "commit remains after its parent when the randomization window is exhausted" {
  write_profile
  git -C "${repo_root}" config user.name "Setup User"
  git -C "${repo_root}" config user.email setup@example.invalid
  printf '%s\n' initial >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  GIT_AUTHOR_DATE='2026-04-15 18:14:59 -0400' \
    GIT_COMMITTER_DATE='2026-04-15 18:14:59 -0400' \
    git -C "${repo_root}" commit -qm initial
  previous_epoch=$(git -C "${repo_root}" log -1 --format=%at)
  printf '%s\n' changed >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  cd "${repo_root}"

  run env \
    RANDOM=42 \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t +0m -m "ordered commit"

  [ "${status}" -eq 0 ]
  [ "$(git log -1 --format=%at)" -gt "${previous_epoch}" ]
}

@test "commit accepts a negative relative timestamp" {
  write_profile
  git -C "${repo_root}" config user.name "Setup User"
  git -C "${repo_root}" config user.email setup@example.invalid
  printf '%s\n' initial >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  git -C "${repo_root}" commit -qm initial
  previous_epoch=$(git -C "${repo_root}" log -1 --format=%at)
  printf '%s\n' changed >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  cd "${repo_root}"

  run env \
    RANDOM=42 \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t -2h -m "earlier commit"

  [ "${status}" -eq 0 ]
  new_epoch=$(git log -1 --format=%at)
  expected_hour=$(((previous_epoch - 7200) / 3600))
  [ "$((new_epoch / 3600))" -eq "${expected_hour}" ]
}

@test "commit preserves explicitly supplied seconds" {
  write_profile
  git -C "${repo_root}" config user.name "Setup User"
  git -C "${repo_root}" config user.email setup@example.invalid
  printf '%s\n' initial >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  git -C "${repo_root}" commit -qm initial
  previous_epoch=$(git -C "${repo_root}" log -1 --format=%at)
  printf '%s\n' changed >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  cd "${repo_root}"

  run env \
    RANDOM=42 \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t +6m13s -m "exact seconds"

  [ "${status}" -eq 0 ]
  [ "$(git log -1 --format=%at)" -eq "$((previous_epoch + 373))" ]
}

@test "commit randomizes time omitted from a day-relative timestamp" {
  write_profile
  git -C "${repo_root}" config user.name "Setup User"
  git -C "${repo_root}" config user.email setup@example.invalid
  printf '%s\n' initial >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  GIT_AUTHOR_DATE='2026-04-15 18:14:27 -0400' \
    GIT_COMMITTER_DATE='2026-04-15 18:14:27 -0400' \
    git -C "${repo_root}" commit -qm initial
  previous_epoch=$(git -C "${repo_root}" log -1 --format=%at)
  printf '%s\n' changed >"${repo_root}/tracked"
  git -C "${repo_root}" add tracked
  cd "${repo_root}"

  run env \
    RANDOM=42 \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" commit -t +1d -m "random time"

  [ "${status}" -eq 0 ]
  new_epoch=$(git log -1 --format=%at)
  [ "$((new_epoch % 86400))" -ne "$(((previous_epoch + 86400) % 86400))" ]
  [ "${new_epoch}" -gt "${previous_epoch}" ]
}

@test "profiles aliases profile list" {
  write_profile
  cd "${repo_root}"

  run env \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" profile list
  [ "${status}" -eq 0 ]
  profile_list_output=${output}

  run env \
    JSH_PROFILES="${profiles_file}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${project_root}/bin/gitx" profiles

  [ "${status}" -eq 0 ]
  [ "${output}" = "${profile_list_output}" ]
}
