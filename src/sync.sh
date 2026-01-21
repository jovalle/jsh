# sync.sh - Safe bidirectional git sync
# Provides: jsh sync [--pull|--push|--check|--force]
# SAFETY: Always stashes ALL changes (staged, unstaged, untracked) before operations
# shellcheck disable=SC2034,SC2154

# Load guard
[[ -n "${_JSH_SYNC_LOADED:-}" ]] && return 0
_JSH_SYNC_LOADED=1

# =============================================================================
# Safety Functions
# =============================================================================

# Create a stash of all changes (staged, unstaged, untracked)
# Returns: 0 if stash created, 1 if nothing to stash
_sync_stash_all() {
    local stash_msg="jsh-sync-$(date +%Y%m%d-%H%M%S)"

    # Check if there's anything to stash
    if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
        return 1  # Nothing to stash
    fi

    # Stash everything including untracked files
    if git stash push -u -m "${stash_msg}" >/dev/null 2>&1; then
        echo "${stash_msg}"
        return 0
    fi

    return 1
}

# Pop stash and handle conflicts
_sync_stash_pop() {
    local stash_msg="$1"

    if [[ -z "${stash_msg}" ]]; then
        return 0
    fi

    # Find the stash by message
    local stash_ref
    stash_ref=$(git stash list | grep "${stash_msg}" | head -1 | cut -d: -f1)

    if [[ -z "${stash_ref}" ]]; then
        warn "Could not find stash: ${stash_msg}"
        return 1
    fi

    # Try to pop the stash
    if git stash pop "${stash_ref}" >/dev/null 2>&1; then
        prefix_success "Restored local changes"
        return 0
    else
        warn "Stash pop had conflicts"
        prefix_info "Your changes are preserved in: git stash list"
        prefix_info "Resolve conflicts then run: git stash drop"
        return 1
    fi
}

# =============================================================================
# Sync Operations
# =============================================================================

# Check sync status without making changes
_sync_check() {
    local repo_dir="$1"

    cd "${repo_dir}" || return 1

    # Verify it's a git repo
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        error "Not a git repository: ${repo_dir}"
        return 1
    fi

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Check for remote tracking
    local upstream
    upstream=$(git rev-parse --abbrev-ref "@{u}" 2>/dev/null) || {
        warn "No upstream configured for branch: ${branch}"
        return 1
    }

    # Fetch to get latest remote state
    git fetch --quiet 2>/dev/null || {
        warn "Could not fetch from remote"
        return 1
    }

    # Check ahead/behind counts
    local ahead behind
    ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)
    behind=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)

    # Check local changes
    local staged unstaged untracked
    staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
    unstaged=$(git diff --name-only | wc -l | tr -d ' ')
    untracked=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')

    echo ""
    echo "${BOLD}Sync Status: ${CYN}${repo_dir}${RST}"
    echo ""
    echo "  Branch:   ${branch} -> ${upstream}"
    echo ""

    if [[ ${ahead} -gt 0 ]] || [[ ${behind} -gt 0 ]]; then
        echo "  Remote:"
        [[ ${ahead} -gt 0 ]] && echo "    ${GRN}↑${RST} ${ahead} commit(s) ahead (need push)"
        [[ ${behind} -gt 0 ]] && echo "    ${YLW}↓${RST} ${behind} commit(s) behind (need pull)"
    else
        echo "  Remote:   ${GRN}✓${RST} Up to date"
    fi

    echo ""

    if [[ ${staged} -gt 0 ]] || [[ ${unstaged} -gt 0 ]] || [[ ${untracked} -gt 0 ]]; then
        echo "  Local changes:"
        [[ ${staged} -gt 0 ]] && echo "    ${GRN}*${RST} ${staged} staged"
        [[ ${unstaged} -gt 0 ]] && echo "    ${YLW}!${RST} ${unstaged} modified"
        [[ ${untracked} -gt 0 ]] && echo "    ${RED}?${RST} ${untracked} untracked"
    else
        echo "  Local:    ${GRN}✓${RST} Clean working tree"
    fi

    echo ""
}

# Pull changes from remote (rebase)
_sync_pull() {
    local repo_dir="$1"
    local stash_msg=""

    cd "${repo_dir}" || return 1

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Check if we're behind
    git fetch --quiet 2>/dev/null
    local behind
    behind=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)

    if [[ ${behind} -eq 0 ]]; then
        prefix_success "Already up to date"
        return 0
    fi

    info "Pulling ${behind} commit(s) from remote..."

    # Stash all changes
    stash_msg=$(_sync_stash_all) && prefix_info "Stashed local changes"

    # Track configs before pull to detect changes
    local configs_before=""
    if [[ -d "configs/packages" ]]; then
        configs_before=$(git log -1 --format=%H -- configs/packages 2>/dev/null || true)
    fi

    # Pull with rebase
    if git pull --rebase --quiet 2>/dev/null; then
        prefix_success "Pulled and rebased successfully"

        # Check if package configs changed
        if [[ -d "configs/packages" ]]; then
            local configs_after
            configs_after=$(git log -1 --format=%H -- configs/packages 2>/dev/null || true)
            if [[ -n "${configs_before}" ]] && [[ "${configs_before}" != "${configs_after}" ]]; then
                echo ""
                info "Package configs changed. Run '${CYN}jsh pkg sync${RST}' to install new packages."
            fi
        fi

        # Restore stash if we created one
        [[ -n "${stash_msg}" ]] && _sync_stash_pop "${stash_msg}"
        return 0
    else
        # Rebase failed - abort and restore
        error "Rebase failed - conflicts detected"
        git rebase --abort 2>/dev/null

        if [[ -n "${stash_msg}" ]]; then
            prefix_info "Your changes are preserved in stash: ${stash_msg}"
        fi

        echo ""
        echo "${YLW}Recovery steps:${RST}"
        echo "  1. git stash list    # Find your stash"
        echo "  2. git pull          # Pull with merge instead"
        echo "  3. git stash pop     # Restore your changes"
        echo ""

        return 1
    fi
}

# Push changes to remote
_sync_push() {
    local repo_dir="$1"

    cd "${repo_dir}" || return 1

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Check if we're ahead
    local ahead
    ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)

    if [[ ${ahead} -eq 0 ]]; then
        prefix_success "Nothing to push"
        return 0
    fi

    info "Pushing ${ahead} commit(s) to remote..."

    if git push --quiet 2>/dev/null; then
        prefix_success "Pushed successfully"
        return 0
    else
        error "Push failed"
        prefix_info "You may need to pull first: jsh sync --pull"
        return 1
    fi
}

# Full bidirectional sync
_sync_full() {
    local repo_dir="$1"
    local stash_msg=""

    cd "${repo_dir}" || return 1

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    echo ""
    info "Syncing ${CYN}${branch}${RST} in ${repo_dir}"

    # Fetch first
    git fetch --quiet 2>/dev/null || {
        warn "Could not fetch from remote"
        return 1
    }

    local ahead behind
    ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)
    behind=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)

    # Stash all changes
    stash_msg=$(_sync_stash_all) && prefix_info "Stashed local changes"

    # Pull if behind
    if [[ ${behind} -gt 0 ]]; then
        info "Pulling ${behind} commit(s)..."
        if ! git pull --rebase --quiet 2>/dev/null; then
            error "Rebase failed - aborting"
            git rebase --abort 2>/dev/null

            if [[ -n "${stash_msg}" ]]; then
                prefix_info "Your changes preserved in stash: ${stash_msg}"
            fi
            return 1
        fi
        prefix_success "Pulled successfully"
    fi

    # Push if ahead (re-check after pull)
    ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)
    if [[ ${ahead} -gt 0 ]]; then
        info "Pushing ${ahead} commit(s)..."
        if git push --quiet 2>/dev/null; then
            prefix_success "Pushed successfully"
        else
            warn "Push failed (may need to pull again)"
        fi
    fi

    # Restore stash
    [[ -n "${stash_msg}" ]] && _sync_stash_pop "${stash_msg}"

    echo ""
    success "Sync complete"
}

# Force sync (requires explicit confirmation)
_sync_force() {
    local repo_dir="$1"

    cd "${repo_dir}" || return 1

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    local current_commit
    current_commit=$(git rev-parse HEAD 2>/dev/null)

    echo ""
    echo "${RED}${BOLD}WARNING: Force sync will reset to remote state${RST}"
    echo ""
    echo "  Branch: ${branch}"
    echo "  Current commit: ${current_commit}"
    echo ""
    echo "  ${YLW}This will discard all local commits not on remote!${RST}"
    echo ""
    echo "  Recovery: git reflog | head"
    echo "            git reset --hard ${current_commit}"
    echo ""

    read -r -p "Type 'force' to confirm: " confirm
    if [[ "${confirm}" != "force" ]]; then
        info "Cancelled"
        return 0
    fi

    # Stash local changes first
    local stash_msg
    stash_msg=$(_sync_stash_all) && prefix_info "Stashed local changes"

    # Fetch and reset
    git fetch --quiet 2>/dev/null
    if git reset --hard "@{u}" >/dev/null 2>&1; then
        prefix_success "Reset to remote state"
        prefix_info "Previous HEAD: ${current_commit}"

        # Restore stash
        [[ -n "${stash_msg}" ]] && _sync_stash_pop "${stash_msg}"

        return 0
    else
        error "Force reset failed"
        return 1
    fi
}

# =============================================================================
# Main Command
# =============================================================================

# @jsh-cmd sync Sync git repo with remote (safe bidirectional)
# @jsh-opt --pull Pull only (rebase)
# @jsh-opt --push Push only
# @jsh-opt -c,--check Dry run - show sync status
# @jsh-opt -f,--force Force sync (requires confirmation)
# @jsh-opt --no-stash Fail if local changes exist
# @jsh-opt --with-packages Auto-sync packages after pull
cmd_sync() {
    local mode="full"
    local no_stash=false
    local with_packages=false
    local repo_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pull)
                mode="pull"
                shift
                ;;
            --push)
                mode="push"
                shift
                ;;
            --check|-c)
                mode="check"
                shift
                ;;
            --force|-f)
                mode="force"
                shift
                ;;
            --no-stash)
                no_stash=true
                shift
                ;;
            --with-packages|-p)
                with_packages=true
                shift
                ;;
            -h|--help)
                echo "${BOLD}jsh sync${RST} - Safe bidirectional git sync"
                echo ""
                echo "${BOLD}USAGE:${RST}"
                echo "    jsh sync [options]"
                echo ""
                echo "${BOLD}OPTIONS:${RST}"
                echo "    --pull            Pull only (rebase)"
                echo "    --push            Push only"
                echo "    --check, -c       Dry run - show sync status"
                echo "    --force, -f       Force sync (requires confirmation)"
                echo "    --no-stash        Fail if local changes exist"
                echo "    --with-packages   Auto-sync packages after pull"
                echo ""
                echo "${BOLD}SAFETY:${RST}"
                echo "    • All local changes are auto-stashed before operations"
                echo "    • On conflict: rebase aborts, stash preserved"
                echo "    • Force mode requires typing 'force' to confirm"
                echo ""
                echo "${BOLD}TARGET:${RST}"
                echo "    Current git repo, or \$JSH_DIR if not in a repo"
                echo ""
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done

    # Determine target directory
    if git rev-parse --git-dir >/dev/null 2>&1; then
        repo_dir=$(git rev-parse --show-toplevel 2>/dev/null)
    else
        repo_dir="${JSH_DIR:-${HOME}/.jsh}"
    fi

    if [[ ! -d "${repo_dir}/.git" ]]; then
        error "Not a git repository: ${repo_dir}"
        return 1
    fi

    # Check for --no-stash with local changes
    if [[ "${no_stash}" == true ]]; then
        cd "${repo_dir}" || return 1
        if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
            error "Local changes exist and --no-stash specified"
            prefix_info "Commit or stash your changes first"
            return 1
        fi
    fi

    # Execute sync mode
    local sync_result=0
    case "${mode}" in
        check)  _sync_check "${repo_dir}" ;;
        pull)   _sync_pull "${repo_dir}" || sync_result=$? ;;
        push)   _sync_push "${repo_dir}" || sync_result=$? ;;
        force)  _sync_force "${repo_dir}" || sync_result=$? ;;
        full)   _sync_full "${repo_dir}" || sync_result=$? ;;
    esac

    # Auto-sync packages if requested and sync succeeded
    if [[ "${with_packages}" == true ]] && [[ ${sync_result} -eq 0 ]]; then
        if [[ "${mode}" == "pull" || "${mode}" == "full" ]]; then
            if declare -f _pkg_sync >/dev/null 2>&1; then
                echo ""
                info "Syncing packages..."
                _pkg_sync
            else
                warn "Package sync not available (pkg.sh not loaded)"
            fi
        fi
    fi

    return ${sync_result}
}
