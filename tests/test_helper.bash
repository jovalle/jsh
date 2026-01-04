#!/usr/bin/env bash
# Test helper functions for Jsh test suite
# shellcheck disable=SC2034,SC2154

export JSH_DIR="${BATS_TEST_DIRNAME}/.."
export JSH_TEST_TEMP="${BATS_TMPDIR:-/tmp}/jsh_test_$$"

# Setup function called before each test
setup() {
    mkdir -p "${JSH_TEST_TEMP}"
}

# Teardown function called after each test
teardown() {
    rm -rf "${JSH_TEST_TEMP}" 2>/dev/null || true
}

# =============================================================================
# Module Loaders
# =============================================================================

load_jsh_core() {
    # Reset cached values
    unset _JSH_CORE_LOADED JSH_OS JSH_ARCH JSH_SHELL JSH_PLATFORM
    source "${JSH_DIR}/src/core.sh"
}

load_jsh_git() {
    load_jsh_core
    source "${JSH_DIR}/src/git.sh"
}

load_jsh_projects() {
    load_jsh_core
    source "${JSH_DIR}/src/projects.sh"
}

load_jsh() {
    # Load the main jsh script (for function testing)
    source "${JSH_DIR}/jsh"
}

# =============================================================================
# Assert Helpers
# =============================================================================

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    [[ "${actual}" == "${expected}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected: '${expected}'"
        echo "  Actual:   '${actual}'"
        return 1
    }
}

assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local msg="${3:-}"

    [[ "${actual}" != "${unexpected}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Did not expect: '${unexpected}'"
        return 1
    }
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-}"

    [[ -n "${value}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected non-empty value"
        return 1
    }
}

assert_empty() {
    local value="$1"
    local msg="${2:-}"

    [[ -z "${value}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected empty value, got: '${value}'"
        return 1
    }
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    [[ "${haystack}" == *"${needle}"* ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected '${haystack}' to contain '${needle}'"
        return 1
    }
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    [[ "${haystack}" != *"${needle}"* ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected '${haystack}' to NOT contain '${needle}'"
        return 1
    }
}

assert_matches() {
    local actual="$1"
    local pattern="$2"
    local msg="${3:-}"

    [[ "${actual}" =~ ${pattern} ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected '${actual}' to match pattern '${pattern}'"
        return 1
    }
}

assert_file_exists() {
    local path="$1"
    local msg="${2:-}"

    [[ -f "${path}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected file to exist: ${path}"
        return 1
    }
}

assert_dir_exists() {
    local path="$1"
    local msg="${2:-}"

    [[ -d "${path}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected directory to exist: ${path}"
        return 1
    }
}

assert_symlink() {
    local path="$1"
    local target="$2"
    local msg="${3:-}"

    [[ -L "${path}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected symlink at: ${path}"
        return 1
    }

    local actual_target
    actual_target=$(readlink "${path}")
    [[ "${actual_target}" == "${target}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected symlink to point to: ${target}"
        echo "  Actual target: ${actual_target}"
        return 1
    }
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    [[ "${actual}" -eq "${expected}" ]] || {
        echo "Assertion failed${msg:+: ${msg}}"
        echo "  Expected exit code: ${expected}"
        echo "  Actual exit code: ${actual}"
        return 1
    }
}

# =============================================================================
# Test Fixtures
# =============================================================================

# Create a temporary git repository for testing
create_test_repo() {
    local repo_dir="${JSH_TEST_TEMP}/test_repo"
    mkdir -p "${repo_dir}"
    cd "${repo_dir}" || return 1

    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    echo "test content" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    echo "${repo_dir}"
}

# Create a test dotfile in temp directory
create_test_dotfile() {
    local name="$1"
    local content="${2:-test content}"
    local path="${JSH_TEST_TEMP}/${name}"

    echo "${content}" > "${path}"
    echo "${path}"
}

# =============================================================================
# Skip Helpers
# =============================================================================

skip_if_no_git() {
    command -v git >/dev/null 2>&1 || skip "git not available"
}

skip_if_no_zsh() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not available"
}

skip_if_ci() {
    [[ -z "${CI:-}" ]] || skip "Skipped in CI environment"
}

skip_if_root() {
    [[ "${EUID}" -ne 0 ]] || skip "Cannot run as root"
}
