#!/usr/bin/env bats
# Tests for jsh CLI - Main entry point and all subcommands
#
# These tests ensure the jsh script works correctly.
# jsh requires bash 4+ (use 'jsh deps fix-bash' on macOS).

load test_helper

# Find a bash 4+ interpreter
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

# =============================================================================
# Bash Version Requirement Tests
# =============================================================================
# jsh requires bash 4+ for modern features like associative arrays.
# On macOS, users must install Homebrew bash and configure PATH.

@test "bash: version 4+ is available somewhere" {
    local modern_bash
    modern_bash=$(find_modern_bash)
    [[ -n "${modern_bash}" ]]
}

@test "bash: jsh script has valid syntax" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" -n "${JSH_DIR}/jsh"
    [ "$status" -eq 0 ]
}

@test "bash: jsh help runs successfully" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

@test "bash: jsh version runs successfully" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" --version
    [ "$status" -eq 0 ]
    assert_matches "$output" "[0-9]+\.[0-9]+\.[0-9]+"
}

@test "bash: jsh status runs successfully" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" status
    [ "$status" -eq 0 ]
    assert_contains "$output" "Installation"
}

@test "bash: jsh upgrade runs successfully" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" upgrade
    [ "$status" -eq 0 ]
    assert_contains "$output" "Jsh Upgrade"
}

@test "bash: jsh deps fix-bash command exists" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" deps fix-bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "Bash Version Check"
}

# =============================================================================
# CLI Help and Version Tests
# =============================================================================
# These tests use modern bash to ensure jsh works correctly

@test "cli: --help shows usage information" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
    assert_contains "$output" "COMMANDS"
}

@test "cli: -h is alias for --help" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" -h
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

@test "cli: --version shows version number" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" --version
    [ "$status" -eq 0 ]
    assert_matches "$output" "[0-9]+\.[0-9]+\.[0-9]+"
}

@test "cli: -v is alias for --version" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" -v
    [ "$status" -eq 0 ]
    assert_matches "$output" "[0-9]+\.[0-9]+\.[0-9]+"
}

# =============================================================================
# Command Existence Tests
# =============================================================================

@test "cli: status command exists" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" status
    [ "$status" -eq 0 ]
}

@test "cli: upgrade command exists" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" upgrade
    [ "$status" -eq 0 ]
}

@test "cli: link command exists" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    # Just check that it runs (may prompt for confirmation, so use --help if available)
    run "${modern_bash}" "${JSH_DIR}/jsh" link --help
    # Either success or shows help
    [[ "$status" -eq 0 ]] || [[ "$output" =~ "link" ]]
}

@test "cli: deps command shows status" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" deps status
    # deps status may return non-zero if optional components are missing
    # but it should produce valid output
    assert_contains "$output" "Platform"
}

@test "cli: deps help shows fix-bash command" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" deps help
    [ "$status" -eq 0 ]
    assert_contains "$output" "fix-bash"
}

# =============================================================================
# Tools Command Tests
# =============================================================================

@test "cli: tools list shows categories" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" tools list
    [ "$status" -eq 0 ]
    # Should show at least one tool category
    assert_contains "$output" "Tools"
}

@test "cli: tools list --missing filters correctly" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" tools list --missing
    [ "$status" -eq 0 ]
}

@test "cli: tools --help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" tools --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

# =============================================================================
# Clean Command Tests
# =============================================================================

@test "cli: clean --dry-run shows what would be cleaned" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" clean --dry-run
    [ "$status" -eq 0 ]
    # Should mention dry run or scanning
    assert_contains "$output" "Scanning"
}

@test "cli: clean --help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" clean --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

# =============================================================================
# Install Command Tests
# =============================================================================

@test "cli: install --help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" install --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
    assert_contains "$output" "--brew"
}

# =============================================================================
# Sync Command Tests
# =============================================================================

@test "cli: sync --check shows sync status" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    # Run in jsh directory which is a git repo
    cd "${JSH_DIR}"
    run "${modern_bash}" "${JSH_DIR}/jsh" sync --check
    # May fail if not a git repo or no remote, but should run
    [[ "$status" -eq 0 ]] || assert_contains "$output" "Branch"
}

@test "cli: sync --help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" sync --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
    assert_contains "$output" "SAFETY"
}

# =============================================================================
# Configure Command Tests
# =============================================================================

@test "cli: configure list shows available configs" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" configure list
    [ "$status" -eq 0 ]
    assert_contains "$output" "Configuration Modules"
}

@test "cli: configure --help shows usage" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" configure --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

@test "cli: configure --check shows dry run" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    # --check requires a subcommand (all, macos, dock, etc.)
    run "${modern_bash}" "${JSH_DIR}/jsh" configure all --check
    [ "$status" -eq 0 ]
    # Should show dry-run indicator
    assert_contains "$output" "dry-run"
}

# =============================================================================
# Invalid Input Tests
# =============================================================================

@test "cli: unknown command shows error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" definitely_not_a_command
    [ "$status" -ne 0 ]
}

@test "cli: unknown flag shows error" {
    local modern_bash
    modern_bash=$(find_modern_bash) || skip "No bash 4+ found"
    run "${modern_bash}" "${JSH_DIR}/jsh" --not-a-real-flag
    [ "$status" -ne 0 ]
}
