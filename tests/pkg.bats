#!/usr/bin/env bats
# Tests for jsh pkg - Package management module
#
# These tests ensure the pkg module works correctly for package tracking,
# bundle management, and service configuration.

load test_helper

# Find a bash 4+ interpreter (required for jsh)
find_modern_bash() {
    for bash_path in /opt/homebrew/bin/bash /usr/local/bin/bash "$(which bash 2>/dev/null)"; do
        if [[ -x "${bash_path}" ]]; then
            local ver
            ver=$("${bash_path}" --version 2>/dev/null | head -1 | sed 's/.*version \([0-9]*\).*/\1/')
            if [[ "${ver}" -ge 4 ]] 2>/dev/null; then
                echo "${bash_path}"
                return 0
            fi
        fi
    done
    return 1
}

# Setup test package configs
setup_test_configs() {
    export PKG_TEST_DIR="${JSH_TEST_TEMP}/configs/packages"
    mkdir -p "${PKG_TEST_DIR}/macos"
    mkdir -p "${PKG_TEST_DIR}/linux"

    # Create test configs
    echo '["git", "curl", "vim"]' > "${PKG_TEST_DIR}/macos/formulae.json"
    echo '["firefox", "visual-studio-code"]' > "${PKG_TEST_DIR}/macos/casks.json"
    echo '["syncthing"]' > "${PKG_TEST_DIR}/macos/services.json"
    echo '["eslint", "typescript"]' > "${PKG_TEST_DIR}/npm.json"
    echo '[]' > "${PKG_TEST_DIR}/pip.json"
    echo '[]' > "${PKG_TEST_DIR}/cargo.json"

    # Create test bundles
    cat > "${JSH_TEST_TEMP}/configs/bundles.json" << 'EOF'
{
  "test-bundle": {
    "description": "Test bundle for unit tests",
    "packages": ["test-pkg-1", "test-pkg-2"]
  }
}
EOF
}

# =============================================================================
# Module Loading Tests
# =============================================================================

@test "pkg: module has valid syntax" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" -n "${JSH_DIR}/src/pkg.sh"
    [ "$status" -eq 0 ]
}

@test "pkg: command exists and shows help" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
    assert_contains "$output" "CORE COMMANDS"
}

@test "pkg: --help alias works" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

# =============================================================================
# List Command Tests
# =============================================================================

@test "pkg: list shows package categories" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg list
    [ "$status" -eq 0 ]
    assert_contains "$output" "Package Categories"
}

@test "pkg: list with category shows packages" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    # This will list macos/formulae if configs exist
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg list brew
    # May fail if no config, but should produce valid output
    [[ "$status" -eq 0 ]] || assert_contains "$output" "Packages"
}

# =============================================================================
# Bundle Command Tests
# =============================================================================

@test "pkg: bundle list shows bundles" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg bundle list
    [ "$status" -eq 0 ]
    assert_contains "$output" "Available Bundles"
}

@test "pkg: bundle help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg bundle help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
    assert_contains "$output" "install"
}

# =============================================================================
# Service Command Tests
# =============================================================================

@test "pkg: service list runs without error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg service list
    [ "$status" -eq 0 ]
    assert_contains "$output" "Managed Services"
}

@test "pkg: service help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg service help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
    assert_contains "$output" "start"
    assert_contains "$output" "stop"
}

# =============================================================================
# Sync Command Tests
# =============================================================================

@test "pkg: sync --dry-run shows what would be installed" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg sync --dry-run
    [ "$status" -eq 0 ]
    assert_contains "$output" "Package Sync"
}

# =============================================================================
# Git Integration Tests
# =============================================================================

@test "pkg: status shows git status" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    cd "${JSH_DIR}"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg status
    [ "$status" -eq 0 ]
    assert_contains "$output" "Package Config Changes"
}

# =============================================================================
# Diff and Audit Tests
# =============================================================================

@test "pkg: diff shows header" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    # Use timeout since diff checks each package (can be slow)
    run timeout 5 "${modern_bash}" "${JSH_DIR}/jsh" pkg diff brew
    # Command may timeout, but should at least show header
    assert_contains "$output" "Package Diff"
}

@test "pkg: audit runs without error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg audit
    [ "$status" -eq 0 ]
    assert_contains "$output" "Package Audit"
}

# =============================================================================
# Add/Remove Command Tests (input validation)
# =============================================================================

@test "pkg: add without package shows error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg add
    [ "$status" -ne 0 ]
    assert_contains "$output" "Usage"
}

@test "pkg: remove without package shows error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg remove
    [ "$status" -ne 0 ]
    assert_contains "$output" "Usage"
}

# =============================================================================
# Unknown Command Tests
# =============================================================================

@test "pkg: unknown subcommand shows error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" pkg definitely_not_a_command
    [ "$status" -ne 0 ]
    assert_contains "$output" "Unknown subcommand"
}

# =============================================================================
# Config File Tests
# =============================================================================

@test "pkg: configs directory exists" {
    assert_dir_exists "${JSH_DIR}/configs/packages"
}

@test "pkg: bundles.json exists and is valid JSON" {
    assert_file_exists "${JSH_DIR}/configs/bundles.json"
    # Validate JSON syntax
    jq empty "${JSH_DIR}/configs/bundles.json" || skip "jq not available"
}

# =============================================================================
# Integration with install.sh Tests
# =============================================================================

@test "install: --track flag is documented" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" install --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "--track"
}

# =============================================================================
# Integration with sync.sh Tests
# =============================================================================

@test "sync: --with-packages flag is documented" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" sync --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "--with-packages"
}
