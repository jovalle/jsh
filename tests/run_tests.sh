#!/usr/bin/env bash
# Jsh Test Runner
# Run all bats tests for the jsh project
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
if [[ -t 1 ]]; then
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    CYAN=$'\e[36m'
    BOLD=$'\e[1m'
    RST=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RST=""
fi

# Usage
usage() {
    cat << EOF
${BOLD}Jsh Test Runner${RST}

${BOLD}USAGE:${RST}
    ./run_tests.sh [options] [test_file...]

${BOLD}OPTIONS:${RST}
    -h, --help      Show this help
    -v, --verbose   Verbose output (show all test details)
    -f, --filter    Filter tests by pattern
    --tap           Output in TAP format
    --junit         Output in JUnit XML format (requires bats-core 1.5+)

${BOLD}EXAMPLES:${RST}
    ./run_tests.sh                    # Run all tests
    ./run_tests.sh core.bats          # Run specific test file
    ./run_tests.sh -f "platform"      # Run tests matching "platform"

EOF
}

# Check for bats
check_bats() {
    if ! command -v bats &>/dev/null; then
        echo "${RED}Error: bats-core not found${RST}"
        echo ""
        echo "Install bats-core:"
        echo "  macOS:  ${CYAN}brew install bats-core${RST}"
        echo "  Ubuntu: ${CYAN}sudo apt install bats${RST}"
        echo "  npm:    ${CYAN}npm install -g bats${RST}"
        echo ""
        echo "Or clone from: https://github.com/bats-core/bats-core"
        exit 1
    fi

    local bats_version
    bats_version=$(bats --version 2>/dev/null | head -1)
    echo "${CYAN}Using: ${bats_version}${RST}"
}

# Main
main() {
    local verbose=""
    local filter=""
    local tap_format=""
    local junit_format=""
    local test_files=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                verbose="--verbose-run"
                shift
                ;;
            -f|--filter)
                filter="--filter $2"
                shift 2
                ;;
            --tap)
                tap_format="--tap"
                shift
                ;;
            --junit)
                junit_format="--formatter junit"
                shift
                ;;
            *.bats)
                test_files+=("${SCRIPT_DIR}/$1")
                shift
                ;;
            *)
                echo "${RED}Unknown option: $1${RST}"
                usage
                exit 1
                ;;
        esac
    done

    # Default to all test files if none specified
    if [[ ${#test_files[@]} -eq 0 ]]; then
        test_files=("${SCRIPT_DIR}"/*.bats)
    fi

    # Check bats is installed
    check_bats
    echo ""

    # Count test files
    local file_count=${#test_files[@]}
    echo "${BOLD}Running ${file_count} test file(s)...${RST}"
    echo ""

    # Build bats command
    local bats_cmd="bats"
    [[ -n "${verbose}" ]] && bats_cmd+=" ${verbose}"
    [[ -n "${filter}" ]] && bats_cmd+=" ${filter}"
    [[ -n "${tap_format}" ]] && bats_cmd+=" ${tap_format}"
    [[ -n "${junit_format}" ]] && bats_cmd+=" ${junit_format}"

    # Run tests
    local exit_code=0
    ${bats_cmd} "${test_files[@]}" || exit_code=$?

    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        echo "${GREEN}${BOLD}All tests passed!${RST}"
    else
        echo "${RED}${BOLD}Some tests failed${RST}"
    fi

    return ${exit_code}
}

main "$@"
