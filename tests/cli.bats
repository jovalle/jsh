#!/usr/bin/env bats
# Tests for lib/cli.sh - Self-documenting CLI framework

load test_helper

# =============================================================================
# Setup
# =============================================================================

setup() {
    mkdir -p "${JSH_TEST_TEMP}"

    # Create a minimal test script with metadata
    cat > "${JSH_TEST_TEMP}/test_cli.sh" << 'EOF'
#!/usr/bin/env bash
# @name testcli
# @version 2.0.0
# @desc A test CLI for unit testing
# @usage testcli [options] <command>
#
# @cmd start   Start the service
# @cmd stop    Stop the service
# @cmd status  Show service status
#
# @option -v,--verbose       Enable verbose output
# @option -c,--config <FILE> Config file path
# @option -h,--help          Show this help
#
# @example testcli start
# @example testcli -c /etc/app.conf status

source "${JSH_DIR}/lib/cli.sh"

cmd_start() { echo "Starting..."; }
cmd_stop() { echo "Stopping..."; }
cmd_status() { echo "Status: running"; }

main() {
    echo "Main called with: $*"
}

# Don't auto-run in tests
if [[ "${1:-}" == "--run" ]]; then
    shift
    cli_main main "$@"
elif [[ "${1:-}" == "--dispatch" ]]; then
    shift
    cli_dispatch "" "$@"
fi
EOF
    chmod +x "${JSH_TEST_TEMP}/test_cli.sh"

    # Create a simple (non-multi-command) test script
    cat > "${JSH_TEST_TEMP}/simple_cli.sh" << 'EOF'
#!/usr/bin/env bash
# @name simplecli
# @version 1.0.0
# @desc A simple single-command CLI
# @usage simplecli [options] [args...]
#
# @option -t,--time <DURATION> Time duration
# @option -d,--debug           Enable debug mode
# @option -h,--help            Show help

source "${JSH_DIR}/lib/cli.sh"

main() { echo "Simple main: $*"; }

if [[ "${1:-}" == "--run" ]]; then
    shift
    cli_main main "$@"
fi
EOF
    chmod +x "${JSH_TEST_TEMP}/simple_cli.sh"
}

teardown() {
    rm -rf "${JSH_TEST_TEMP}" 2>/dev/null || true
}

load_cli() {
    source "${JSH_DIR}/lib/cli.sh"
}

# =============================================================================
# Metadata Parsing Tests
# =============================================================================

@test "cli_parse: extracts @name tag" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals "testcli" "${_CLI_META[name]}"
}

@test "cli_parse: extracts @version tag" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals "2.0.0" "${_CLI_META[version]}"
}

@test "cli_parse: extracts @desc tag" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals "A test CLI for unit testing" "${_CLI_META[desc]}"
}

@test "cli_parse: extracts @usage tag" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals "testcli [options] <command>" "${_CLI_META[usage]}"
}

@test "cli_parse: extracts all @option tags" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals 3 "${#_CLI_OPTIONS[@]}"
    assert_contains "${_CLI_OPTIONS[0]}" "-v,--verbose"
    assert_contains "${_CLI_OPTIONS[1]}" "-c,--config"
    assert_contains "${_CLI_OPTIONS[2]}" "-h,--help"
}

@test "cli_parse: extracts all @cmd tags" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals 3 "${#_CLI_COMMANDS[@]}"
    assert_contains "${_CLI_COMMANDS[0]}" "start"
    assert_contains "${_CLI_COMMANDS[1]}" "stop"
    assert_contains "${_CLI_COMMANDS[2]}" "status"
}

@test "cli_parse: extracts all @example tags" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    assert_equals 2 "${#_CLI_EXAMPLES[@]}"
    assert_equals "testcli start" "${_CLI_EXAMPLES[0]}"
    assert_contains "${_CLI_EXAMPLES[1]}" "-c /etc/app.conf"
}

@test "cli_parse: handles options with argument placeholders" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    # The -c,--config option should have <FILE> captured
    assert_contains "${_CLI_OPTIONS[1]}" "<FILE>"
}

# =============================================================================
# Help Generation Tests
# =============================================================================

@test "cli_help: outputs command name" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "testcli"
}

@test "cli_help: outputs version" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "2.0.0"
}

@test "cli_help: outputs description" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "A test CLI for unit testing"
}

@test "cli_help: outputs USAGE section" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "USAGE"
    assert_contains "$output" "testcli [options] <command>"
}

@test "cli_help: outputs COMMANDS section for multi-command CLIs" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "COMMANDS"
    assert_contains "$output" "start"
    assert_contains "$output" "stop"
    assert_contains "$output" "status"
}

@test "cli_help: outputs OPTIONS section" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "OPTIONS"
    assert_contains "$output" "--verbose"
    assert_contains "$output" "--config"
}

@test "cli_help: outputs EXAMPLES section" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_help
    assert_contains "$output" "EXAMPLES"
    assert_contains "$output" "testcli start"
}

@test "cli_help: simple CLI does not show COMMANDS section" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/simple_cli.sh"
    run cli_help
    assert_not_contains "$output" "COMMANDS"
}

# =============================================================================
# Usage and Version Tests
# =============================================================================

@test "cli_usage: outputs usage line" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_usage
    assert_contains "$output" "Usage:"
    assert_contains "$output" "testcli"
}

@test "cli_usage: suggests --help" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_usage
    assert_contains "$output" "--help"
}

@test "cli_version: outputs name and version" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_version
    assert_equals "testcli 2.0.0" "$output"
}

# =============================================================================
# cli_main Tests
# =============================================================================

@test "cli_main: --help shows help and exits" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --run --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "testcli"
    assert_contains "$output" "USAGE"
}

@test "cli_main: --version shows version and exits" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --run --version
    [ "$status" -eq 0 ]
    assert_equals "testcli 2.0.0" "$output"
}

@test "cli_main: passes through to main function" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --run arg1 arg2
    [ "$status" -eq 0 ]
    assert_contains "$output" "Main called with: arg1 arg2"
}

# =============================================================================
# cli_dispatch Tests
# =============================================================================

@test "cli_dispatch: routes to cmd_start" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --dispatch start
    [ "$status" -eq 0 ]
    assert_equals "Starting..." "$output"
}

@test "cli_dispatch: routes to cmd_stop" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --dispatch stop
    [ "$status" -eq 0 ]
    assert_equals "Stopping..." "$output"
}

@test "cli_dispatch: routes to cmd_status" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --dispatch status
    [ "$status" -eq 0 ]
    assert_equals "Status: running" "$output"
}

@test "cli_dispatch: shows help on 'help' command" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --dispatch help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

@test "cli_dispatch: shows help on --help" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --dispatch --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "USAGE"
}

@test "cli_dispatch: errors on unknown command" {
    export JSH_DIR="${JSH_DIR}"
    run "${JSH_TEST_TEMP}/test_cli.sh" --dispatch unknown_cmd_xyz
    [ "$status" -eq 1 ]
    assert_contains "$output" "Unknown command"
}

# =============================================================================
# Completion Generation Tests
# =============================================================================

@test "cli_completions: generates zsh completions" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_completions zsh
    [ "$status" -eq 0 ]
    assert_contains "$output" "_testcli"
    assert_contains "$output" "commands="
    assert_contains "$output" "options="
}

@test "cli_completions: generates bash completions" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_completions bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "_testcli"
    assert_contains "$output" "complete -F"
}

@test "cli_completions: includes commands in zsh output" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_completions zsh
    assert_contains "$output" "start"
    assert_contains "$output" "stop"
    assert_contains "$output" "status"
}

@test "cli_completions: includes options in bash output" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_completions bash
    assert_contains "$output" "--verbose"
    assert_contains "$output" "--config"
}

@test "cli_completions: errors on invalid shell type" {
    load_cli
    cli_parse "${JSH_TEST_TEMP}/test_cli.sh"
    run cli_completions fish
    [ "$status" -eq 1 ]
    assert_contains "$output" "Unknown shell type"
}

# =============================================================================
# Discovery Tests
# =============================================================================

@test "cli_discover: finds scripts with @name metadata" {
    load_cli
    run cli_discover "${JSH_TEST_TEMP}"
    [ "$status" -eq 0 ]
    assert_contains "$output" "testcli"
    assert_contains "$output" "simplecli"
}

@test "cli_discover: outputs script paths" {
    load_cli
    run cli_discover "${JSH_TEST_TEMP}"
    assert_contains "$output" "test_cli.sh"
    assert_contains "$output" "simple_cli.sh"
}

# =============================================================================
# Edge Cases
# =============================================================================

@test "cli_parse: handles script without metadata gracefully" {
    cat > "${JSH_TEST_TEMP}/no_meta.sh" << 'EOF'
#!/usr/bin/env bash
echo "Hello"
EOF
    chmod +x "${JSH_TEST_TEMP}/no_meta.sh"

    load_cli
    cli_parse "${JSH_TEST_TEMP}/no_meta.sh"
    # Should use filename as fallback name
    assert_empty "${_CLI_META[name]:-}"
    assert_equals 0 "${#_CLI_COMMANDS[@]}"
}

@test "cli_parse: handles partial metadata" {
    cat > "${JSH_TEST_TEMP}/partial.sh" << 'EOF'
#!/usr/bin/env bash
# @name partialcli
# Only name, no other metadata

echo "Hello"
EOF
    chmod +x "${JSH_TEST_TEMP}/partial.sh"

    load_cli
    cli_parse "${JSH_TEST_TEMP}/partial.sh"
    assert_equals "partialcli" "${_CLI_META[name]}"
    assert_empty "${_CLI_META[version]:-}"
}

@test "cli_help: works with minimal metadata" {
    cat > "${JSH_TEST_TEMP}/minimal.sh" << 'EOF'
#!/usr/bin/env bash
# @name minimal
# @desc Just a minimal CLI
EOF
    chmod +x "${JSH_TEST_TEMP}/minimal.sh"

    load_cli
    cli_parse "${JSH_TEST_TEMP}/minimal.sh"
    run cli_help
    [ "$status" -eq 0 ]
    assert_contains "$output" "minimal"
    assert_contains "$output" "Just a minimal CLI"
}
