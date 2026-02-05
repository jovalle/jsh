#!/usr/bin/env bats
# Tests for setup --adopt / --decom flows

load test_helper

setup() {
    mkdir -p "${JSH_TEST_TEMP}"
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    export HOME="${JSH_TEST_TEMP}/home"
    export JSH_DIR="${JSH_TEST_TEMP}/jsh"
    mkdir -p "${HOME}" "${JSH_DIR}/dotfiles"

    unset _JSH_CORE_LOADED_bash _JSH_CORE_LOADED_zsh _JSH_CORE_LOADED_sh
    unset _JSH_COMMANDS_COMMON_LOADED _JSH_SETUP_LOADED

    source "${REPO_ROOT}/src/core.sh"
    source "${REPO_ROOT}/src/commands/common.sh"
    source "${REPO_ROOT}/src/commands/setup.sh"
}

@test "setup adopt: moves file into dotfiles and links back" {
    local original="${HOME}/.wezterm.lua"
    local managed="${JSH_DIR}/dotfiles/.wezterm.lua"
    echo "return {}" > "${original}"

    run cmd_setup --adopt "${original}"
    [ "${status}" -eq 0 ]
    assert_symlink "${original}" "${managed}"
    assert_file_exists "${managed}"
    assert_contains "$(cat "${managed}")" "return {}"
}

@test "setup decom: restores adopted file to original path" {
    local original="${HOME}/.wezterm.lua"
    local managed="${JSH_DIR}/dotfiles/.wezterm.lua"
    echo "return {a=1}" > "${original}"

    run cmd_setup --adopt "${original}"
    [ "${status}" -eq 0 ]
    assert_symlink "${original}" "${managed}"

    run cmd_setup --decom "${original}" --yes
    [ "${status}" -eq 0 ]
    [ ! -L "${original}" ]
    assert_file_exists "${original}"
    [ ! -e "${managed}" ]
    assert_contains "$(cat "${original}")" "return {a=1}"
}

@test "setup decom: requires explicit confirmation without --yes" {
    local original="${HOME}/.wezterm.lua"
    local managed="${JSH_DIR}/dotfiles/.wezterm.lua"
    echo "return {b=2}" > "${original}"

    run cmd_setup --adopt "${original}"
    [ "${status}" -eq 0 ]
    assert_symlink "${original}" "${managed}"

    run bash -c '
        source "$REPO_ROOT/src/core.sh"
        source "$REPO_ROOT/src/commands/common.sh"
        source "$REPO_ROOT/src/commands/setup.sh"
        printf "no\n" | cmd_setup --decom "$HOME/.wezterm.lua"
    '
    [ "${status}" -eq 0 ]
    assert_contains "${output}" "Decommission cancelled."
    assert_symlink "${original}" "${managed}"
}

@test "setup adopt: dry-run previews and does not modify files" {
    local original="${HOME}/.wezterm.lua"
    local managed="${JSH_DIR}/dotfiles/.wezterm.lua"
    echo "return {c=3}" > "${original}"

    run cmd_setup --adopt "${original}" --dry-run
    [ "${status}" -eq 0 ]
    assert_contains "${output}" "Would move"
    [ ! -L "${original}" ]
    assert_file_exists "${original}"
    [ ! -e "${managed}" ]
}

@test "setup adopt: rejects paths outside HOME" {
    local outside="${JSH_TEST_TEMP}/outside.conf"
    echo "x=1" > "${outside}"

    run cmd_setup --adopt "${outside}"
    [ "${status}" -eq 1 ]
    assert_contains "${output}" "supports only paths under"
}
