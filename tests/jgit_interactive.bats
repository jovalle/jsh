#!/usr/bin/env bats
# Tests for jgit interactive mode
# Tests timestamp parsing, UI utilities, and command routing

load test_helper

# =============================================================================
# Setup
# =============================================================================

setup() {
    # Call parent setup
    mkdir -p "${JSH_TEST_TEMP}"

    # Source libraries
    source "${JSH_DIR}/lib/jgit-timestamp.sh"
    source "${JSH_DIR}/lib/jgit-ui.sh"
}

# =============================================================================
# Timestamp Parsing Tests
# =============================================================================

@test "timestamp: _ts_now returns epoch" {
    local now
    now=$(_ts_now)

    # Should be a number
    [[ "$now" =~ ^[0-9]+$ ]]

    # Should be reasonable (after year 2020)
    [[ "$now" -gt 1577836800 ]]
}

@test "timestamp: _ts_parse_relative handles positive minutes" {
    local result
    result=$(_ts_parse_relative "+30m")
    assert_equals "1800" "$result"
}

@test "timestamp: _ts_parse_relative handles negative hours" {
    local result
    result=$(_ts_parse_relative "-2h")
    assert_equals "-7200" "$result"
}

@test "timestamp: _ts_parse_relative handles days" {
    local result
    result=$(_ts_parse_relative "+1d")
    assert_equals "86400" "$result"
}

@test "timestamp: _ts_parse_relative handles compound expressions" {
    local result
    result=$(_ts_parse_relative "+1h30m")
    assert_equals "5400" "$result"  # 3600 + 1800
}

@test "timestamp: _ts_parse_relative handles negative compound" {
    local result
    result=$(_ts_parse_relative "-2h15m")
    assert_equals "-8100" "$result"  # -(7200 + 900)
}

@test "timestamp: _ts_is_relative detects relative formats" {
    _ts_is_relative "+30m"
    _ts_is_relative "-2h"
    _ts_is_relative "+1d"
    _ts_is_relative "1h30m"  # No sign defaults to positive
}

@test "timestamp: _ts_is_relative rejects absolute formats" {
    ! _ts_is_relative "2024-01-15 14:30"
    ! _ts_is_relative "14:30"
    ! _ts_is_relative "now"
}

@test "timestamp: _ts_parse handles 'now' keyword" {
    local now result
    now=$(_ts_now)
    result=$(_ts_parse "now")

    # Should be within 2 seconds of now
    local diff=$((result - now))
    [[ "$diff" -ge -2 ]] && [[ "$diff" -le 2 ]]
}

@test "timestamp: _ts_parse handles relative with base" {
    local base=1704067200  # 2024-01-01 00:00:00 UTC
    local result

    result=$(_ts_parse "+1h" "$base")
    assert_equals "1704070800" "$result"  # +3600
}

@test "timestamp: _ts_to_git_format produces valid format" {
    local epoch=1704067200
    local result

    result=$(_ts_to_git_format "$epoch")

    # Should match pattern: YYYY-MM-DD HH:MM:SS +ZZZZ
    assert_matches "$result" "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}$"
}

@test "timestamp: _ts_random_range produces values in range" {
    local min=10
    local max=20
    local result

    for _ in {1..20}; do
        result=$(_ts_random_range "$min" "$max")
        [[ "$result" -ge "$min" ]] || fail "Result $result < $min"
        [[ "$result" -le "$max" ]] || fail "Result $result > $max"
    done
}

@test "timestamp: _ts_randomize_seconds modifies seconds only" {
    local epoch=1704067200  # Has seconds = 0
    local result

    result=$(_ts_randomize_seconds "$epoch")

    # Result should be in same minute (within 60 seconds)
    local diff=$((result - epoch))
    [[ "$diff" -ge -59 ]] && [[ "$diff" -le 59 ]]
}

@test "timestamp: _ts_ensure_after enforces minimum gap" {
    local min_epoch=1704067200
    local proposed=$((min_epoch + 30))  # Only 30 seconds after
    local result

    result=$(_ts_ensure_after "$proposed" "$min_epoch" 60)

    # Should be at least 60 seconds after min_epoch
    [[ "$result" -ge $((min_epoch + 60)) ]]
}

@test "timestamp: _ts_ensure_after allows valid timestamps" {
    local min_epoch=1704067200
    local proposed=$((min_epoch + 120))  # 2 minutes after
    local result

    result=$(_ts_ensure_after "$proposed" "$min_epoch" 60)

    # Should be the same as proposed (already valid)
    assert_equals "$proposed" "$result"
}

# =============================================================================
# Preset Tests
# =============================================================================

@test "timestamp: presets are defined" {
    [[ -n "${_TS_PRESETS[work-hours]}" ]]
    [[ -n "${_TS_PRESETS[quick-fix]}" ]]
    [[ -n "${_TS_PRESETS[deep-work]}" ]]
    [[ -n "${_TS_PRESETS[irl]}" ]]
}

@test "timestamp: _ts_preset_list returns all presets" {
    local presets
    presets=$(_ts_preset_list)

    assert_contains "$presets" "work-hours"
    assert_contains "$presets" "quick-fix"
    assert_contains "$presets" "irl"
}

@test "timestamp: _ts_preset_description returns descriptions" {
    local desc

    desc=$(_ts_preset_description "work-hours")
    assert_contains "$desc" "9-5"

    desc=$(_ts_preset_description "quick-fix")
    assert_contains "$desc" "5-15m"
}

@test "timestamp: _ts_apply_preset generates future timestamp" {
    local base=1704067200
    local result

    result=$(_ts_apply_preset "irl" "$base" 0)

    # Should be after base
    [[ "$result" -gt "$base" ]]
}

@test "timestamp: _ts_apply_preset respects gap ranges" {
    local base=1704067200

    for _ in {1..10}; do
        local result
        result=$(_ts_apply_preset "quick-fix" "$base" 0)

        # quick-fix has gap_min=300, gap_max=900
        local diff=$((result - base))
        [[ "$diff" -ge 300 ]] || fail "Gap $diff < 300"
        [[ "$diff" -le 960 ]] || fail "Gap $diff > 960 (900 + 60 for seconds)"
    done
}

# =============================================================================
# Batch Operations Tests
# =============================================================================

@test "timestamp: _ts_batch_offset applies offset to all" {
    local -a results
    mapfile -t results < <(_ts_batch_offset "+1h" 1000 2000 3000)

    assert_equals "4600" "${results[0]}"
    assert_equals "5600" "${results[1]}"
    assert_equals "6600" "${results[2]}"
}

@test "timestamp: _ts_batch_offset handles negative offset" {
    local -a results
    mapfile -t results < <(_ts_batch_offset "-30m" 5000 6000)

    assert_equals "3200" "${results[0]}"
    assert_equals "4200" "${results[1]}"
}

# =============================================================================
# Validation Tests
# =============================================================================

@test "timestamp: _ts_validate accepts recent timestamps" {
    local now
    now=$(_ts_now)

    _ts_validate "$now"
    _ts_validate "$((now - 86400))"   # Yesterday
    _ts_validate "$((now + 86400))"   # Tomorrow
}

@test "timestamp: _ts_validate rejects far past" {
    local now very_old
    now=$(_ts_now)
    very_old=$((now - 63072000))  # 2 years ago

    ! _ts_validate "$very_old"
}

@test "timestamp: _ts_validate rejects far future" {
    local now very_future
    now=$(_ts_now)
    very_future=$((now + 63072000))  # 2 years from now

    ! _ts_validate "$very_future"
}

@test "timestamp: _ts_relative_display formats correctly" {
    local now result
    now=$(_ts_now)

    result=$(_ts_relative_display "$((now - 120))")
    assert_contains "$result" "minutes ago"

    result=$(_ts_relative_display "$((now - 7200))")
    assert_contains "$result" "hours ago"

    result=$(_ts_relative_display "$((now + 3600))")
    assert_contains "$result" "from now"
}

# =============================================================================
# UI Utility Tests
# =============================================================================

@test "ui: colors initialize without error" {
    _ui_init_colors
    # Should not error - colors may or may not be set depending on terminal
    [[ -v _UI_RESET ]]
}

@test "ui: _ui_term_width returns number" {
    local width
    width=$(_ui_term_width)
    [[ "$width" =~ ^[0-9]+$ ]]
    [[ "$width" -gt 0 ]]
}

@test "ui: _ui_reset clears state" {
    _UI_ANSWERS[test]="value"
    _UI_CANCELLED=1

    _ui_reset

    [[ -z "${_UI_ANSWERS[test]:-}" ]]
    assert_equals "0" "$_UI_CANCELLED"
}

# =============================================================================
# jgit Command Routing Tests
# =============================================================================

@test "jgit: help shows interactive options" {
    run "${JSH_DIR}/bin/jgit" --help

    assert_contains "$output" "commit -i"
    assert_contains "$output" "push -i"
    assert_contains "$output" "interactive"
}

@test "jgit: help shows timestamp formats" {
    run "${JSH_DIR}/bin/jgit" --help

    assert_contains "$output" "+30m"
    assert_contains "$output" "-2h"
    assert_contains "$output" "Relative"
}

@test "jgit: help shows preset patterns" {
    run "${JSH_DIR}/bin/jgit" --help

    assert_contains "$output" "work-hours"
    assert_contains "$output" "quick-fix"
    assert_contains "$output" "irl"
}

@test "jgit: commit without -i passes through to git" {
    skip_if_no_git

    local repo_dir
    repo_dir=$(create_test_repo)
    cd "$repo_dir" || fail "Failed to cd to test repo"

    # Make a change
    echo "new line" >> README.md
    git add README.md

    # Commit without -i should work like regular git commit
    run "${JSH_DIR}/bin/jgit" commit -m "Test commit"

    [[ "$status" -eq 0 ]] || fail "Expected success, got: $output"
}

@test "jgit: push without -i passes through to git" {
    skip_if_no_git

    local repo_dir
    repo_dir=$(create_test_repo)
    cd "$repo_dir" || fail "Failed to cd to test repo"

    # Push without remote should fail with git's error
    run "${JSH_DIR}/bin/jgit" push 2>&1

    # Should fail because no remote (but proves it passed through to git)
    [[ "$status" -ne 0 ]]
    # Git's error message about no remote
    assert_contains "$output" "remote"
}

@test "jgit: backup list works" {
    skip_if_no_git

    local repo_dir
    repo_dir=$(create_test_repo)
    cd "$repo_dir" || fail "Failed to cd to test repo"

    run "${JSH_DIR}/bin/jgit" backup list

    # Should succeed even with no backups
    [[ "$status" -eq 0 ]]
    assert_contains "$output" "backups"
}

# =============================================================================
# Integration Tests (require git repo)
# =============================================================================

@test "integration: interactive libraries load without error" {
    source "${JSH_DIR}/lib/jgit-interactive.sh"

    # Should have defined functions
    declare -f cmd_commit_interactive >/dev/null
    declare -f cmd_push_interactive >/dev/null
    declare -f _backup_create >/dev/null
}

@test "integration: dry-run mode prevents changes" {
    skip_if_no_git

    local repo_dir
    repo_dir=$(create_test_repo)
    cd "$repo_dir" || fail "Failed to cd to test repo"

    source "${JSH_DIR}/lib/jgit-interactive.sh"

    # Get original HEAD
    local original_head
    original_head=$(git rev-parse HEAD)

    # Set dry-run mode
    JGIT_DRY_RUN=1

    # Try to create a backup (should be simulated)
    local result
    result=$(_backup_create "test")

    # HEAD should be unchanged
    local new_head
    new_head=$(git rev-parse HEAD)
    assert_equals "$original_head" "$new_head"
}
