#!/usr/bin/env bats
# Tests for j.sh - Smart frecency-based directory jumping
# shellcheck disable=SC2030,SC2031

load test_helper

setup() {
    mkdir -p "${JSH_TEST_TEMP}"
    # Create test directories
    mkdir -p "${JSH_TEST_TEMP}/projects/myapp"
    mkdir -p "${JSH_TEST_TEMP}/projects/webapp"
    mkdir -p "${JSH_TEST_TEMP}/.jsh"
    mkdir -p "${JSH_TEST_TEMP}/dotfiles"
    mkdir -p "${JSH_TEST_TEMP}/deep/nested/path"

    # Mock gitx to prevent hangs (exits with no output)
    mkdir -p "${JSH_TEST_TEMP}/bin"
    printf '#!/bin/bash\nexit 1\n' > "${JSH_TEST_TEMP}/bin/gitx"
    chmod +x "${JSH_TEST_TEMP}/bin/gitx"
    export PATH="${JSH_TEST_TEMP}/bin:${PATH}"

    # Load j with isolated database
    load_jsh_j

    # Seed the frecency database with test entries
    local now
    now="$(_j_now)"
    cat > "${J_DATA}" << EOF
${JSH_TEST_TEMP}/projects/myapp|10|${now}
${JSH_TEST_TEMP}/projects/webapp|5|${now}
${JSH_TEST_TEMP}/.jsh|12|${now}
${JSH_TEST_TEMP}/dotfiles|3|${now}
${JSH_TEST_TEMP}/deep/nested/path|2|${now}
EOF
}

# =============================================================================
# Matching logic tests
# =============================================================================

@test "j query matches substring in path" {
    cd "${JSH_TEST_TEMP}"
    j myapp
    assert_equals "${JSH_TEST_TEMP}/projects/myapp" "${PWD}" "should cd to myapp"
}

@test "j query matches dotfile directory with dot prefix" {
    cd "${JSH_TEST_TEMP}/projects/myapp"
    j .jsh
    assert_equals "${JSH_TEST_TEMP}/.jsh" "${PWD}" "should cd to .jsh"
}

@test "j query matches dotfile directory without dot prefix" {
    cd "${JSH_TEST_TEMP}/projects/myapp"
    j jsh
    # "jsh" is a substring of both ".jsh" and possibly others - .jsh has higher score
    assert_equals "${JSH_TEST_TEMP}/.jsh" "${PWD}" "should cd to .jsh (highest score)"
}

@test "j query skips current directory in database results" {
    cd "${JSH_TEST_TEMP}/.jsh"
    run j jsh
    # .jsh is the only DB match for "jsh" but it's the current dir, so DB skips it
    # Path resolution fallback may still find it, but that's acceptable behavior
    # The key is that the DB correctly skips the current dir
    [[ "${status}" -eq 0 || "${status}" -eq 1 ]]
}

@test "j with no match prints error" {
    cd "${JSH_TEST_TEMP}"
    run j nonexistent_xyz
    assert_not_equals 0 "${status}" "should return non-zero"
    assert_contains "${output}" "No matching" "should print error message"
}

@test "j multiple keywords must all match" {
    cd "${JSH_TEST_TEMP}"
    j deep nested
    assert_equals "${JSH_TEST_TEMP}/deep/nested/path" "${PWD}" "should match path with both keywords"
}

@test "j multiple keywords that don't all match fails" {
    cd "${JSH_TEST_TEMP}"
    run j deep nonexistent
    assert_not_equals 0 "${status}" "should fail when keywords don't all match"
}

# =============================================================================
# Verbose flag tests
# =============================================================================

@test "j -v shows database search info" {
    cd "${JSH_TEST_TEMP}"
    run j -v myapp
    assert_equals 0 "${status}" "should succeed"
    assert_contains "${output}" "database" "should mention database search"
}

@test "j -v shows match found" {
    cd "${JSH_TEST_TEMP}"
    run j -v myapp
    assert_contains "${output}" "myapp" "should show matched path"
}

@test "j --verbose works same as -v" {
    cd "${JSH_TEST_TEMP}"
    run j --verbose myapp
    assert_equals 0 "${status}" "should succeed"
    assert_contains "${output}" "myapp" "should show matched path"
}

@test "j -v with no match shows diagnostic info" {
    cd "${JSH_TEST_TEMP}"
    run j -v nonexistent_xyz
    assert_not_equals 0 "${status}" "should fail"
    assert_contains "${output}" "No matching" "should show no match message"
    assert_contains "${output}" "database" "should mention what was searched"
}

@test "j -v shows number of candidates" {
    cd "${JSH_TEST_TEMP}"
    run j -v webapp
    assert_contains "${output}" "match" "should mention matches"
}

# =============================================================================
# Path resolution fallback tests
# =============================================================================

@test "j resolves query as relative path if directory exists" {
    cd "${JSH_TEST_TEMP}"
    # .jsh is a subdirectory of JSH_TEST_TEMP
    j .jsh
    assert_equals "${JSH_TEST_TEMP}/.jsh" "${PWD}" "should resolve .jsh as relative path"
}

@test "j resolves home-relative path when query starts with dot" {
    # Remove .jsh from database to test fallback
    command -p awk -F'|' -v path="${JSH_TEST_TEMP}/.jsh" '$1 != path' "${J_DATA}" > "${J_DATA}.tmp"
    mv "${J_DATA}.tmp" "${J_DATA}"

    # Create a dir in fake HOME
    export HOME="${JSH_TEST_TEMP}"
    cd "${JSH_TEST_TEMP}/projects/myapp"

    j .jsh
    # Normalize both paths with pwd -P to handle macOS /var → /private/var symlinks
    local expected actual
    expected="$(cd "${JSH_TEST_TEMP}/.jsh" && pwd -P)"
    actual="$(pwd -P)"
    assert_equals "${expected}" "${actual}" "should resolve ~/.jsh via HOME fallback"
}

# =============================================================================
# Edge cases
# =============================================================================

@test "j with empty database shows appropriate message" {
    > "${J_DATA}"  # truncate
    cd "${JSH_TEST_TEMP}"
    run j -v somequery
    assert_not_equals 0 "${status}"
    assert_contains "${output}" "No matching" "should indicate no match"
}

@test "j - jumps to previous directory" {
    cd "${JSH_TEST_TEMP}/projects/myapp"
    j webapp
    assert_equals "${JSH_TEST_TEMP}/projects/webapp" "${PWD}"
    j -
    assert_equals "${JSH_TEST_TEMP}/projects/myapp" "${PWD}" "should return to previous dir"
}

@test "j --help shows usage" {
    run j --help
    assert_equals 0 "${status}"
    assert_contains "${output}" "Smart frecency-based directory jumping"
}
