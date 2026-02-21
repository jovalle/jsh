#!/usr/bin/env bats
# Tests for core.sh - Core utilities, platform detection, colors

load test_helper

# =============================================================================
# Platform Detection Tests
# =============================================================================

@test "core: JSH_OS is set and valid" {
    load_jsh_core
    assert_not_empty "$JSH_OS" "JSH_OS should be set"
    assert_matches "$JSH_OS" "^(macos|linux|freebsd|unknown)$" "JSH_OS should be a valid value"
}

@test "core: JSH_ARCH is set and valid" {
    load_jsh_core
    assert_not_empty "$JSH_ARCH" "JSH_ARCH should be set"
    assert_matches "$JSH_ARCH" "^(x64|arm64|armv7|unknown)$" "JSH_ARCH should be a valid value"
}

@test "core: JSH_SHELL is set" {
    load_jsh_core
    assert_not_empty "$JSH_SHELL" "JSH_SHELL should be set"
    assert_matches "$JSH_SHELL" "^(bash|zsh|sh)$" "JSH_SHELL should be bash, zsh, or sh"
}

@test "core: JSH_PLATFORM is well-formed" {
    load_jsh_core
    assert_not_empty "$JSH_PLATFORM" "JSH_PLATFORM should be set"
    assert_matches "$JSH_PLATFORM" "^[a-z]+-[a-z0-9]+$" "JSH_PLATFORM should match os-arch format"
}

@test "core: JSH_ENV detects environment type" {
    load_jsh_core
    assert_not_empty "$JSH_ENV" "JSH_ENV should be set"
    assert_matches "$JSH_ENV" "^(local|ssh|container|ephemeral)$" "JSH_ENV should be valid"
}

# =============================================================================
# has() Function Tests
# =============================================================================

@test "core: has() returns true for existing commands" {
    load_jsh_core
    has bash
    has ls
    has echo
}

@test "core: has() returns false for nonexistent command" {
    load_jsh_core
    run has definitely_not_a_real_command_xyz_12345
    [ "$status" -eq 1 ]
}

@test "core: has() detects git when installed" {
    skip_if_no_git
    load_jsh_core
    has git
}

# =============================================================================
# Color Variable Tests
# =============================================================================

@test "core: color reset variable is defined" {
    load_jsh_core
    [[ -n "${RST+set}" ]]
}

@test "core: basic colors are defined" {
    load_jsh_core
    [[ -n "${RED+set}" ]]
    [[ -n "${GRN+set}" ]]
    [[ -n "${BLU+set}" ]]
    [[ -n "${YLW+set}" ]]
}

@test "core: semantic colors are defined" {
    load_jsh_core
    [[ -n "${C_OK+set}" ]]
    [[ -n "${C_ERR+set}" ]]
    [[ -n "${C_WARN+set}" ]]
    [[ -n "${C_INFO+set}" ]]
}

# =============================================================================
# Path Utility Tests
# =============================================================================

@test "core: path_prepend adds directory to PATH" {
    load_jsh_core
    local test_dir="${JSH_TEST_TEMP}/bin"
    mkdir -p "$test_dir"

    local original_path="$PATH"
    path_prepend "$test_dir"

    assert_matches "$PATH" "^${test_dir}:" "Directory should be prepended to PATH"

    PATH="$original_path"
}

@test "core: path_prepend doesn't duplicate existing path" {
    load_jsh_core
    local test_dir="${JSH_TEST_TEMP}/bin"
    mkdir -p "$test_dir"

    local original_path="$PATH"
    path_prepend "$test_dir"
    path_prepend "$test_dir"

    local count
    count=$(echo "$PATH" | tr ':' '\n' | grep -c "^${test_dir}$" || true)
    assert_equals "1" "$count" "Directory should only appear once in PATH"

    PATH="$original_path"
}

@test "core: path_prepend ignores non-existent directories" {
    load_jsh_core
    local original_path="$PATH"
    path_prepend "/this/directory/does/not/exist"

    assert_equals "$original_path" "$PATH" "PATH should not change for non-existent directory"
}

# =============================================================================
# Environment Setup Tests
# =============================================================================

@test "core: XDG directories are set" {
    load_jsh_core
    assert_not_empty "$XDG_CONFIG_HOME"
    assert_not_empty "$XDG_DATA_HOME"
    assert_not_empty "$XDG_CACHE_HOME"
}

@test "core: JSH_DIR is set" {
    load_jsh_core
    assert_not_empty "$JSH_DIR"
    assert_dir_exists "$JSH_DIR"
}

@test "core: JSH_CACHE_DIR is set" {
    load_jsh_core
    assert_not_empty "$JSH_CACHE_DIR"
}

# =============================================================================
# Logging Function Tests
# =============================================================================

@test "core: info() outputs message to stderr" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && info "test message" 2>&1'
    assert_contains "$output" "test message"
}

@test "core: error() outputs to stderr" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && error "error message" 2>&1'
    assert_contains "$output" "error message"
}

@test "core: prefix_success() includes message" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && prefix_success "done" 2>&1'
    assert_contains "$output" "done"
}

# =============================================================================
# Optional UI Helper Tests
# =============================================================================

@test "core: ui_confirm accepts yes response in fallback mode" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && JSH_NO_GUM=1 && printf "y\n" | ui_confirm "Proceed?" "n"'
    [ "$status" -eq 0 ]
}

@test "core: ui_confirm honors default yes on empty response" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && JSH_NO_GUM=1 && printf "\n" | ui_confirm "Proceed?" "y"'
    [ "$status" -eq 0 ]
}

@test "core: ui_confirm_token requires exact token" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && JSH_NO_GUM=1 && printf "force\n" | ui_confirm_token "Type force:" "force"'
    [ "$status" -eq 0 ]

    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && JSH_NO_GUM=1 && printf "nope\n" | ui_confirm_token "Type force:" "force"'
    [ "$status" -eq 1 ]
}

@test "core: ui_input returns default when empty in fallback mode" {
    load_jsh_core
    run bash -c 'source '"${JSH_DIR}"'/src/core.sh && JSH_NO_GUM=1 && printf "\n" | ui_input "Editor: " "vim"'
    [ "$status" -eq 0 ]
    assert_equals "vim" "$output"
}

# =============================================================================
# Source-if Utility Tests
# =============================================================================

@test "core: source_if() sources existing file" {
    load_jsh_core
    local test_file="${JSH_TEST_TEMP}/sourceable.sh"
    echo 'export TEST_VAR="sourced"' > "$test_file"

    source_if "$test_file"
    assert_equals "sourced" "$TEST_VAR"
}

@test "core: source_if() silently ignores missing file" {
    load_jsh_core
    # Should not error
    source_if "/nonexistent/file.sh"
}

# =============================================================================
# ensure_dir Tests
# =============================================================================

@test "core: ensure_dir creates directory" {
    load_jsh_core
    local test_dir="${JSH_TEST_TEMP}/new/nested/dir"

    ensure_dir "$test_dir"
    assert_dir_exists "$test_dir"
}

@test "core: ensure_dir is idempotent" {
    load_jsh_core
    local test_dir="${JSH_TEST_TEMP}/existing"
    mkdir -p "$test_dir"

    ensure_dir "$test_dir"
    assert_dir_exists "$test_dir"
}
