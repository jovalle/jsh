# lib/jgit-interactive.sh - Interactive flows for commit and push
# Main orchestration layer for jgit interactive mode
# shellcheck shell=bash

# =============================================================================
# Dependencies
# =============================================================================

JSH_DIR="${JSH_DIR:-${HOME}/.jsh}"

# Source libraries if not already loaded
[[ -z "${_UI_RESET:-}" ]] && source "${JSH_DIR}/lib/jgit-ui.sh"
# Check if timestamp library is loaded (associative array exists and has entries)
if ! declare -p _TS_PRESETS &>/dev/null; then
    source "${JSH_DIR}/lib/jgit-timestamp.sh"
fi

# =============================================================================
# Global State
# =============================================================================

declare -g JGIT_DRY_RUN="${JGIT_DRY_RUN:-0}"
declare -g JGIT_VERBOSE="${JGIT_VERBOSE:-0}"

# =============================================================================
# Utility Functions
# =============================================================================

# Execute or simulate command based on dry-run mode
_execute() {
    if [[ "$JGIT_DRY_RUN" == "1" ]]; then
        printf '%s[dry-run]%s %s\n' "$_UI_DIM" "$_UI_RESET" "$*"
        return 0
    else
        "$@"
    fi
}

# Debug logging
_verbose() {
    [[ "$JGIT_VERBOSE" == "1" ]] && printf '%s[debug]%s %s\n' "$_UI_DIM" "$_UI_RESET" "$*" >&2
}

# =============================================================================
# Safety: Backup System
# =============================================================================

# Create backup ref before destructive operations
# Args: [description]
# Output: backup ref name
_backup_create() {
    local desc="${1:-manual}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local ref="refs/jgit-backup/${timestamp}-${desc}"

    if _execute git update-ref "$ref" HEAD; then
        _verbose "Backup created: $ref"
        echo "$ref"
        return 0
    else
        return 1
    fi
}

# Restore from backup ref
# Args: ref_name
_backup_restore() {
    local ref="$1"

    if ! git show-ref --verify --quiet "$ref"; then
        _ui_error "Backup not found: $ref"
        return 1
    fi

    _ui_warn "Restoring from backup: $ref"
    if _ui_confirm "This will discard current HEAD. Continue?"; then
        _execute git reset --hard "$ref"
        return $?
    fi
    return 1
}

# List recent backups
_backup_list() {
    printf '%s%s\n' "$_UI_BOLD" "Recent backups:"
    printf '%s' "$_UI_RESET"

    git for-each-ref --sort=-creatordate --format='  %(refname:short)  %(creatordate:relative)' \
        'refs/jgit-backup/' 2>/dev/null | head -10

    local count
    count=$(git for-each-ref --format='x' 'refs/jgit-backup/' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 10 ]]; then
        printf '%s  ... and %d more%s\n' "$_UI_DIM" "$((count - 10))" "$_UI_RESET"
    fi
}

# =============================================================================
# Safety: Protected Branch Check
# =============================================================================

# Check if current branch is protected
# Returns: 0 if protected, 1 otherwise
_is_protected_branch() {
    local branch
    branch=$(git branch --show-current 2>/dev/null)

    case "$branch" in
        main|master|develop|production|staging)
            return 0
            ;;
    esac
    return 1
}

# Warn and confirm for protected branches
_check_protected_branch() {
    if _is_protected_branch; then
        local branch
        branch=$(git branch --show-current)
        _ui_warn "You are on protected branch: $branch"
        _ui_confirm "Force push to $branch?" || return 1
    fi
    return 0
}

# =============================================================================
# Git Helpers
# =============================================================================

# Get list of unpushed commits
# Output: hash|subject|author_date (one per line, oldest first)
_git_unpushed_commits() {
    # shellcheck disable=SC1083
    local upstream
    upstream=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null)

    if [[ -z "$upstream" ]]; then
        # No upstream, show all commits on current branch
        git log --reverse --format='%h|%s|%ai' 2>/dev/null
    else
        git log --reverse --format='%h|%s|%ai' '@{u}..HEAD' 2>/dev/null
    fi
}

# Get commit date as epoch
# Args: commit_hash
_git_commit_epoch() {
    local hash="$1"
    git log -1 --format='%at' "$hash" 2>/dev/null
}

# Get current staged status
_git_has_staged() {
    ! git diff --cached --quiet
}

# Get current unstaged status
_git_has_unstaged() {
    ! git diff --quiet
}

# =============================================================================
# Commit Interactive Flow
# =============================================================================

# Main entry point for interactive commit
# Args: [git commit args...]
cmd_commit_interactive() {
    local -a passthrough_args=()
    local amend_mode=0

    # Parse our flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                JGIT_DRY_RUN=1
                shift
                ;;
            --verbose|-v)
                JGIT_VERBOSE=1
                shift
                ;;
            --amend)
                amend_mode=1
                shift
                ;;
            *)
                passthrough_args+=("$1")
                shift
                ;;
        esac
    done

    # Reset UI state
    _ui_reset

    # Quick amend mode - just update timestamp
    if [[ "$amend_mode" == 1 ]]; then
        _commit_amend_timestamp
        return $?
    fi

    # Full interactive mode
    _commit_interview "${passthrough_args[@]}"
}

# Quick amend mode - update last commit's timestamp
_commit_amend_timestamp() {
    local last_hash last_msg last_date last_epoch

    last_hash=$(git rev-parse HEAD 2>/dev/null)
    if [[ -z "$last_hash" ]]; then
        _ui_error "No commits in repository"
        return 1
    fi

    last_msg=$(git log -1 --format='%s')
    last_date=$(git log -1 --format='%ai')
    last_epoch=$(_git_commit_epoch HEAD)

    _ui_section "Amend Last Commit"

    _ui_kv "Commit" "${last_hash:0:7}"
    _ui_kv "Message" "$last_msg"
    _ui_kv "Current" "$last_date"
    printf '\n'

    # Get new timestamp
    if ! _ui_timestamp_input "New timestamp" "$last_epoch" "new_timestamp"; then
        _ui_info "Cancelled"
        return 1
    fi

    local new_epoch="${_UI_ANSWERS[new_timestamp]}"
    local new_date
    new_date=$(_ts_to_git_format "$new_epoch")

    printf '\n'
    _ui_kv "New date" "$new_date"

    if ! _ui_confirm "Amend commit with new timestamp?"; then
        _ui_info "Cancelled"
        return 1
    fi

    # Create backup
    _backup_create "amend" >/dev/null

    # Perform amend
    export GIT_AUTHOR_DATE="$new_date"
    export GIT_COMMITTER_DATE="$new_date"

    if _execute git commit --amend --no-edit --date="$new_date"; then
        _ui_success "Commit amended"
        printf '  %sNew hash:%s %s\n' "$_UI_DIM" "$_UI_RESET" "$(git rev-parse --short HEAD)"
        return 0
    else
        _ui_error "Failed to amend commit"
        return 1
    fi
}

# Full commit interview flow
_commit_interview() {
    local -a passthrough_args=("$@")

    # Check for staged changes
    if ! _git_has_staged; then
        _ui_warn "No staged changes"

        if _git_has_unstaged; then
            if _ui_confirm "Stage all changes?"; then
                git add -A
            else
                _ui_info "Use 'git add' to stage changes first"
                return 1
            fi
        else
            _ui_error "Nothing to commit"
            return 1
        fi
    fi

    _ui_section "Interactive Commit"

    # Show what's staged
    printf '%s%sStaged changes:%s\n' "$_UI_DIM" "$_UI_BOLD" "$_UI_RESET"
    git diff --cached --stat | head -10
    printf '\n'

    # Option selection
    local -a options=(
        "Message"
        "Timestamp"
        "Author"
        "Sign (GPG)"
    )
    local -a descriptions=(
        "Edit commit message"
        "Override author/committer date"
        "Change author identity"
        "GPG sign the commit"
    )
    local -a defaults=("1" "0" "0" "0")

    if ! _ui_smart_multiselect "What would you like to configure?" \
        options descriptions defaults "selected_options"; then
        _ui_info "Cancelled"
        return 1
    fi

    local selected="${_UI_ANSWERS[selected_options]}"
    local -a selected_arr
    IFS=' ' read -ra selected_arr <<< "$selected"

    # Build commit command
    local -a commit_args=()
    local custom_message=""
    local custom_timestamp=""
    local custom_author=""
    local do_sign=0

    for idx in "${selected_arr[@]}"; do
        case "$idx" in
            0)  # Message
                printf '\n'
                if ! _ui_input "Commit message" "" "commit_message"; then
                    _ui_info "Cancelled"
                    return 1
                fi
                custom_message="${_UI_ANSWERS[commit_message]}"
                ;;
            1)  # Timestamp
                printf '\n'
                local now_epoch
                now_epoch=$(_ts_now)
                if ! _ui_timestamp_input "Timestamp" "$now_epoch" "commit_timestamp"; then
                    _ui_info "Cancelled"
                    return 1
                fi
                custom_timestamp="${_UI_ANSWERS[commit_timestamp]}"
                ;;
            2)  # Author
                printf '\n'
                local current_author
                current_author="$(git config user.name) <$(git config user.email)>"
                if ! _ui_input "Author" "$current_author" "commit_author"; then
                    _ui_info "Cancelled"
                    return 1
                fi
                custom_author="${_UI_ANSWERS[commit_author]}"
                ;;
            3)  # Sign
                do_sign=1
                ;;
        esac
    done

    # Build final command
    if [[ -n "$custom_message" ]]; then
        commit_args+=(-m "$custom_message")
    fi

    if [[ -n "$custom_author" ]]; then
        commit_args+=(--author="$custom_author")
    fi

    if [[ "$do_sign" == 1 ]]; then
        commit_args+=(-S)
    fi

    # Add passthrough args
    commit_args+=("${passthrough_args[@]}")

    # Review
    printf '\n'
    _ui_section "Review"

    if [[ -n "$custom_message" ]]; then
        _ui_kv "Message" "$custom_message"
    else
        _ui_kv "Message" "(will open editor)"
    fi

    if [[ -n "$custom_timestamp" ]]; then
        _ui_kv "Timestamp" "$(_ts_to_display "$custom_timestamp")"
    fi

    if [[ -n "$custom_author" ]]; then
        _ui_kv "Author" "$custom_author"
    fi

    if [[ "$do_sign" == 1 ]]; then
        _ui_kv "GPG Sign" "Yes"
    fi

    printf '\n'
    if ! _ui_confirm "Create commit?"; then
        _ui_info "Cancelled"
        return 1
    fi

    # Execute
    if [[ -n "$custom_timestamp" ]]; then
        local date_str
        date_str=$(_ts_to_git_format "$custom_timestamp")
        export GIT_AUTHOR_DATE="$date_str"
        export GIT_COMMITTER_DATE="$date_str"
    fi

    if _execute git commit "${commit_args[@]}"; then
        _ui_success "Commit created"
        printf '  %sHash:%s %s\n' "$_UI_DIM" "$_UI_RESET" "$(git rev-parse --short HEAD)"
        return 0
    else
        _ui_error "Commit failed"
        return 1
    fi
}

# =============================================================================
# Push Interactive Flow
# =============================================================================

# Main entry point for interactive push
# Args: [git push args...]
cmd_push_interactive() {
    local -a passthrough_args=()

    # Parse our flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                JGIT_DRY_RUN=1
                shift
                ;;
            --verbose|-v)
                JGIT_VERBOSE=1
                shift
                ;;
            *)
                passthrough_args+=("$1")
                shift
                ;;
        esac
    done

    # Reset UI state
    _ui_reset

    # Get unpushed commits
    local -a commits=()
    local -a subjects=()
    local -a dates=()
    local -a epochs=()

    while IFS='|' read -r hash subject date; do
        [[ -z "$hash" ]] && continue
        commits+=("$hash")
        subjects+=("$subject")
        dates+=("$date")
        epochs+=("$(_git_commit_epoch "$hash")")
    done < <(_git_unpushed_commits)

    local commit_count=${#commits[@]}

    if [[ "$commit_count" -eq 0 ]]; then
        _ui_info "No unpushed commits"
        _ui_info "Running: git push ${passthrough_args[*]}"
        _execute git push "${passthrough_args[@]}"
        return $?
    fi

    _ui_section "Interactive Push"

    # Display unpushed commits
    printf '%s%sUnpushed commits (%d):%s\n\n' "$_UI_DIM" "$_UI_BOLD" "$commit_count" "$_UI_RESET"

    for i in "${!commits[@]}"; do
        printf '  %s%s%s  %-40s  %s%s%s\n' \
            "$_UI_CYAN" "${commits[$i]}" "$_UI_RESET" \
            "${subjects[$i]:0:40}" \
            "$_UI_DIM" "${dates[$i]}" "$_UI_RESET"
    done
    printf '\n'

    # Operation selection
    local -a options=(
        "Push as-is"
        "Rewrite timestamps"
        "Batch offset"
        "Apply preset pattern"
    )
    local -a descriptions=(
        "Push without modifications"
        "Interactively set each commit's timestamp"
        "Shift all commits by same amount"
        "Auto-generate realistic timing"
    )

    if ! _ui_smart_singleselect "Select operation:" options descriptions 0 "operation"; then
        _ui_info "Cancelled"
        return 1
    fi

    local operation="${_UI_ANSWERS[operation]}"

    case "$operation" in
        0)  # Push as-is
            _check_protected_branch || return 1
            _execute git push "${passthrough_args[@]}"
            return $?
            ;;
        1)  # Rewrite timestamps
            _push_rewrite_individual commits subjects epochs
            ;;
        2)  # Batch offset
            _push_batch_offset commits subjects epochs
            ;;
        3)  # Apply preset
            _push_apply_preset commits subjects epochs
            ;;
    esac

    # After rewriting, offer to push
    if [[ "${_UI_CANCELLED:-0}" == "1" ]]; then
        return 1
    fi

    printf '\n'
    if _ui_confirm "Push changes?"; then
        _check_protected_branch || return 1

        # Use force-with-lease for safety after rewrite
        if _execute git push --force-with-lease "${passthrough_args[@]}"; then
            _ui_success "Pushed successfully"
            return 0
        else
            _ui_error "Push failed"
            return 1
        fi
    fi

    _ui_info "Changes rewritten locally but not pushed"
    return 0
}

# Rewrite individual commit timestamps
_push_rewrite_individual() {
    local -n commits_ref="$1"
    local -n subjects_ref="$2"
    local -n epochs_ref="$3"

    local -a new_epochs=()
    local prev_epoch=0
    local count=${#commits_ref[@]}

    _ui_section "Timestamp Configuration"
    _ui_info "Configure each commit (oldest to newest)"
    printf '\n'

    for i in "${!commits_ref[@]}"; do
        local hash="${commits_ref[$i]}"
        local subject="${subjects_ref[$i]}"
        local current_epoch="${epochs_ref[$i]}"

        printf '%s%d/%d%s  %s%s%s  %s\n' \
            "$_UI_DIM" "$((i+1))" "$count" "$_UI_RESET" \
            "$_UI_CYAN" "$hash" "$_UI_RESET" \
            "$subject"

        _ui_kv "Current" "$(_ts_to_display "$current_epoch")"

        if ! _ui_timestamp_input "New timestamp" "$current_epoch" "ts_$i"; then
            _UI_CANCELLED=1
            return 1
        fi

        local new_epoch="${_UI_ANSWERS[ts_$i]}"

        # Ensure chronological order
        if [[ "$i" -gt 0 ]] && [[ "$new_epoch" -le "$prev_epoch" ]]; then
            new_epoch=$(_ts_ensure_after "$new_epoch" "$prev_epoch" 60)
            _ui_warn "Adjusted to maintain chronological order"
            _ui_kv "Adjusted" "$(_ts_to_display "$new_epoch")"
        fi

        new_epochs+=("$new_epoch")
        prev_epoch="$new_epoch"
        printf '\n'
    done

    # Show summary and confirm
    _ui_section "Summary"

    for i in "${!commits_ref[@]}"; do
        local old_date new_date
        old_date=$(_ts_to_display "${epochs_ref[$i]}")
        new_date=$(_ts_to_display "${new_epochs[$i]}")

        printf '  %s%s%s\n' "$_UI_CYAN" "${commits_ref[$i]}" "$_UI_RESET"
        printf '    %sOld:%s %s\n' "$_UI_DIM" "$_UI_RESET" "$old_date"
        printf '    %sNew:%s %s\n' "$_UI_DIM" "$_UI_RESET" "$new_date"
    done

    printf '\n'
    if ! _ui_confirm "Rewrite commit timestamps?"; then
        _UI_CANCELLED=1
        return 1
    fi

    # Create backup
    local backup_ref
    backup_ref=$(_backup_create "push-rewrite")
    _ui_info "Backup: $backup_ref"

    # Perform rewrite
    _rewrite_commits commits_ref new_epochs
}

# Batch offset all commits
_push_batch_offset() {
    local -n commits_ref="$1"
    local -n subjects_ref="$2"
    local -n epochs_ref="$3"

    _ui_section "Batch Offset"

    printf 'Apply same offset to all %d commits\n\n' "${#commits_ref[@]}"

    if ! _ui_input "Offset (e.g., -2h, +30m)" "" "offset"; then
        _UI_CANCELLED=1
        return 1
    fi

    local offset_str="${_UI_ANSWERS[offset]}"
    local offset_secs
    offset_secs=$(_ts_parse_relative "$offset_str")

    if [[ -z "$offset_secs" ]]; then
        _ui_error "Invalid offset format"
        return 1
    fi

    # Calculate new timestamps
    local -a new_epochs=()
    for epoch in "${epochs_ref[@]}"; do
        new_epochs+=("$((epoch + offset_secs))")
    done

    # Show preview
    _ui_section "Preview"

    for i in "${!commits_ref[@]}"; do
        local old_date new_date
        old_date=$(_ts_to_display "${epochs_ref[$i]}")
        new_date=$(_ts_to_display "${new_epochs[$i]}")

        printf '  %s%s%s  %s → %s\n' \
            "$_UI_CYAN" "${commits_ref[$i]}" "$_UI_RESET" \
            "$old_date" "$new_date"
    done

    printf '\n'
    if ! _ui_confirm "Apply offset?"; then
        _UI_CANCELLED=1
        return 1
    fi

    # Create backup
    local backup_ref
    backup_ref=$(_backup_create "push-offset")
    _ui_info "Backup: $backup_ref"

    # Perform rewrite
    _rewrite_commits commits_ref new_epochs
}

# Apply preset pattern
_push_apply_preset() {
    local -n commits_ref="$1"
    local -n subjects_ref="$2"
    local -n epochs_ref="$3"

    _ui_section "Preset Pattern"

    # Preset selection
    local -a preset_names=()
    local -a preset_descs=()

    while IFS= read -r name; do
        preset_names+=("$name")
        preset_descs+=("$(_ts_preset_description "$name")")
    done < <(_ts_preset_list)

    if ! _ui_smart_singleselect "Select pattern:" preset_names preset_descs 0 "preset"; then
        _UI_CANCELLED=1
        return 1
    fi

    local preset_idx="${_UI_ANSWERS[preset]}"
    local preset_name="${preset_names[$preset_idx]}"

    printf '\n'
    _ui_info "Selected: $preset_name - $(_ts_preset_description "$preset_name")"
    printf '\n'

    # Get base timestamp for oldest commit
    local oldest_epoch="${epochs_ref[0]}"
    _ui_info "Configure starting point for oldest commit"

    if ! _ui_timestamp_input "Base timestamp" "$oldest_epoch" "base_timestamp"; then
        _UI_CANCELLED=1
        return 1
    fi

    local base_epoch="${_UI_ANSWERS[base_timestamp]}"

    # Generate timestamps using preset
    local -a new_epochs=()
    local prev_epoch="$base_epoch"

    for i in "${!commits_ref[@]}"; do
        if [[ "$i" -eq 0 ]]; then
            # First commit uses base timestamp (with randomized seconds)
            new_epochs+=("$(_ts_randomize_seconds "$base_epoch")")
        else
            # Subsequent commits use preset pattern
            local new_epoch
            new_epoch=$(_ts_apply_preset "$preset_name" "$prev_epoch" "$i")
            new_epochs+=("$new_epoch")
        fi
        prev_epoch="${new_epochs[$i]}"
    done

    # Show preview
    _ui_section "Preview"

    for i in "${!commits_ref[@]}"; do
        local old_date new_date
        old_date=$(_ts_to_display "${epochs_ref[$i]}")
        new_date=$(_ts_to_display "${new_epochs[$i]}")

        printf '  %s%s%s  %s\n' \
            "$_UI_CYAN" "${commits_ref[$i]}" "$_UI_RESET" \
            "${subjects_ref[$i]:0:30}"
        printf '    %sOld:%s %s\n' "$_UI_DIM" "$_UI_RESET" "$old_date"
        printf '    %sNew:%s %s\n' "$_UI_DIM" "$_UI_RESET" "$new_date"
    done

    printf '\n'
    if ! _ui_confirm "Apply preset pattern?"; then
        _UI_CANCELLED=1
        return 1
    fi

    # Create backup
    local backup_ref
    backup_ref=$(_backup_create "push-preset")
    _ui_info "Backup: $backup_ref"

    # Perform rewrite
    _rewrite_commits commits_ref new_epochs
}

# =============================================================================
# History Rewriting
# =============================================================================

# Rewrite commit timestamps using filter-branch
# Args: commits_array_name, new_epochs_array_name
_rewrite_commits() {
    local -n commits_ref="$1"
    local -n epochs_ref="$2"

    local count=${#commits_ref[@]}
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    _ui_spinner_start "Rewriting commits..."

    # Build filter script
    local filter=""
    for i in "${!commits_ref[@]}"; do
        local hash="${commits_ref[$i]}"
        local full_hash
        full_hash=$(git rev-parse "$hash")
        local epoch="${epochs_ref[$i]}"
        local date_str
        date_str=$(_ts_to_git_format "$epoch")

        filter+="if [ \$GIT_COMMIT = $full_hash ]; then "
        filter+="export GIT_AUTHOR_DATE='$date_str'; "
        filter+="export GIT_COMMITTER_DATE='$date_str'; "
        filter+="fi; "
    done

    # Get oldest commit for range
    local oldest="${commits_ref[0]}"

    # Execute rewrite
    local result=0
    if [[ "$JGIT_DRY_RUN" == "1" ]]; then
        _ui_spinner_stop
        printf '%s[dry-run]%s Would rewrite %d commits\n' "$_UI_DIM" "$_UI_RESET" "$count"
    else
        # Use filter-branch (works on older git versions)
        # Suppress the warning about using filter-branch
        if git filter-branch -f --env-filter "$filter" "${oldest}^..HEAD" 2>/dev/null; then
            _ui_spinner_stop
            _ui_success "Rewrote $count commits"
        else
            _ui_spinner_stop
            _ui_error "Failed to rewrite commits"
            _ui_info "Your backup is preserved"
            result=1
        fi
    fi

    return $result
}

# =============================================================================
# Help
# =============================================================================

_interactive_help() {
    cat << 'EOF'
jgit commit -i [options]
  Interactive commit with timestamp control

  Options:
    --amend       Quick mode: only update last commit's timestamp
    --dry-run     Show what would happen without making changes
    -v, --verbose Show debug information

jgit push -i [options]
  Interactive push with timestamp rewriting

  Options:
    --dry-run     Show what would happen without making changes
    -v, --verbose Show debug information

  Operations:
    Push as-is              Push without modifications
    Rewrite timestamps      Set each commit's timestamp individually
    Batch offset           Shift all commits by same amount (e.g., -2h)
    Apply preset pattern   Auto-generate realistic timing patterns

  Presets:
    work-hours   Business hours (9-5), 30m-2h gaps
    quick-fix    Rapid iterations, 5-15m gaps
    deep-work    Focused sessions, 1-3h gaps
    irl          Realistic simulation, 15m-2h random gaps
    morning      Early bird, 6am-12pm
    evening      After work, 6pm-11pm
    night-owl    Late night, 10pm-4am

  Timestamp formats:
    Relative:    +30m, -2h, +1d, +1h30m
    Absolute:    2024-01-15 14:30, 14:30
    Keywords:    now, yesterday, tomorrow

EOF
}
