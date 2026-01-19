#!/usr/bin/env bash
# upgrade.sh - Version management and upgrade functionality
# Provides cmd_upgrade for updating jsh to latest version
#
# Dependencies: core.sh (colors, helpers)
# shellcheck disable=SC2034

# Load guard
[[ -n "${_JSH_UPGRADE_LOADED:-}" ]] && return 0
_JSH_UPGRADE_LOADED=1

# =============================================================================
# Upgrade Command
# =============================================================================

# @jsh-cmd upgrade Check for plugin/binary updates and manage versions
# @jsh-opt -c,--check Dry run - show what would be done
# @jsh-opt --no-brew Skip brew upgrade
# @jsh-opt --no-submodules Skip submodule update
cmd_upgrade() {
    local check_only=false
    local skip_brew=false
    local skip_submodules=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|-c) check_only=true; shift ;;
            --no-brew) skip_brew=true; shift ;;
            --no-submodules) skip_submodules=true; shift ;;
            -h|--help)
                echo "${BOLD}jsh upgrade${RST} - Update jsh to latest version"
                echo ""
                echo "${BOLD}USAGE:${RST}"
                echo "    jsh upgrade [options]"
                echo ""
                echo "${BOLD}OPTIONS:${RST}"
                echo "    ${CYN}-c, --check${RST}       Dry run - show what would be done"
                echo "    ${CYN}--no-brew${RST}         Skip brew upgrade"
                echo "    ${CYN}--no-submodules${RST}   Skip submodule update"
                echo ""
                echo "${BOLD}BEHAVIOR:${RST}"
                echo "    1. Stash any local changes (preserved safely)"
                echo "    2. Fetch and rebase onto upstream"
                echo "    3. Update git submodules"
                echo "    4. Upgrade Homebrew dependencies (macOS)"
                echo "    5. Restore local changes from stash"
                return 0
                ;;
            *) shift ;;
        esac
    done

    info "Jsh Upgrade"
    echo ""

    cd "${JSH_DIR}" || { error "Cannot cd to ${JSH_DIR}"; return 1; }

    # Check current state
    local current_branch current_commit has_changes stash_created=false
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    current_commit=$(git rev-parse --short HEAD 2>/dev/null)

    prefix_info "Current: ${current_branch} @ ${current_commit}"

    # Check for local changes (staged, unstaged, untracked)
    if ! git diff --quiet HEAD 2>/dev/null || [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        has_changes=true
        local staged unstaged untracked
        staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
        unstaged=$(git diff --name-only | wc -l | tr -d ' ')
        untracked=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
        prefix_warn "Local changes detected: ${staged} staged, ${unstaged} modified, ${untracked} untracked"
    else
        has_changes=false
        prefix_success "Working tree is clean"
    fi
    echo ""

    # Fetch upstream
    info "Fetching upstream..."
    if [[ "${check_only}" == true ]]; then
        prefix_info "[dry-run] Would fetch from origin"
    else
        if git fetch origin 2>/dev/null; then
            prefix_success "Fetched latest from origin"
        else
            prefix_warn "Failed to fetch (offline or no remote?)"
        fi
    fi

    # Check if we're behind
    local behind=0
    behind=$(git rev-list --count "HEAD..origin/${current_branch}" 2>/dev/null || echo "0")
    if [[ "${behind}" -gt 0 ]]; then
        prefix_info "${behind} commit(s) behind origin/${current_branch}"
    else
        prefix_success "Already up to date with origin/${current_branch}"
    fi
    echo ""

    # Stash local changes if needed
    if [[ "${has_changes}" == true ]] && [[ "${behind}" -gt 0 ]]; then
        info "Preserving local changes..."
        if [[ "${check_only}" == true ]]; then
            prefix_info "[dry-run] Would stash changes"
        else
            local stash_msg="jsh-upgrade-$(date +%Y%m%d-%H%M%S)"
            if git stash push -u -m "${stash_msg}" 2>/dev/null; then
                stash_created=true
                prefix_success "Stashed as: ${stash_msg}"
            else
                error "Failed to stash changes - aborting"
                return 1
            fi
        fi
        echo ""
    fi

    # Rebase onto upstream
    if [[ "${behind}" -gt 0 ]]; then
        info "Updating to latest..."
        if [[ "${check_only}" == true ]]; then
            prefix_info "[dry-run] Would rebase onto origin/${current_branch}"
        else
            if git rebase "origin/${current_branch}" 2>/dev/null; then
                local new_commit
                new_commit=$(git rev-parse --short HEAD 2>/dev/null)
                prefix_success "Updated: ${current_commit} → ${new_commit}"
            else
                error "Rebase failed - restoring state"
                git rebase --abort 2>/dev/null
                if [[ "${stash_created}" == true ]]; then
                    git stash pop 2>/dev/null
                fi
                return 1
            fi
        fi
        echo ""
    fi

    # Update submodules
    if [[ "${skip_submodules}" != true ]]; then
        info "Updating submodules..."
        if [[ "${check_only}" == true ]]; then
            prefix_info "[dry-run] Would update submodules"
        else
            if git submodule update --init --recursive 2>/dev/null; then
                prefix_success "Submodules updated"
            else
                prefix_warn "Submodule update had issues (may be OK)"
            fi
        fi
        echo ""
    fi

    # Homebrew upgrades (macOS only)
    if [[ "${skip_brew}" != true ]] && [[ "$(uname)" == "Darwin" ]] && has brew; then
        info "Checking Homebrew dependencies..."

        local brew_deps=("bash" "fzf" "jq" "fd" "ripgrep" "bat" "eza")
        local outdated=()

        for dep in "${brew_deps[@]}"; do
            if brew list "${dep}" &>/dev/null; then
                if brew outdated "${dep}" &>/dev/null; then
                    outdated+=("${dep}")
                fi
            fi
        done

        if [[ ${#outdated[@]} -gt 0 ]]; then
            prefix_info "Outdated: ${outdated[*]}"
            if [[ "${check_only}" == true ]]; then
                prefix_info "[dry-run] Would run: brew upgrade ${outdated[*]}"
            else
                if brew upgrade "${outdated[@]}" 2>/dev/null; then
                    prefix_success "Upgraded: ${outdated[*]}"
                else
                    prefix_warn "Some upgrades may have failed"
                fi
            fi
        else
            prefix_success "All Homebrew dependencies up to date"
        fi
        echo ""
    fi

    # Restore stashed changes
    if [[ "${stash_created}" == true ]]; then
        info "Restoring local changes..."
        if git stash pop 2>/dev/null; then
            prefix_success "Local changes restored"
        else
            prefix_warn "Stash pop had conflicts - resolve manually"
            prefix_info "Your changes are in: git stash list"
        fi
        echo ""
    fi

    # Summary
    if [[ "${check_only}" == true ]]; then
        success "Dry run complete - no changes made"
    else
        success "Upgrade complete!"
    fi
}
