# clean.sh - Cache and temporary file cleanup
# Provides: jsh clean [--dry-run] [-y|--yes]
# shellcheck disable=SC2034,SC2154

# Load guard
[[ -n "${_JSH_CLEAN_LOADED:-}" ]] && return 0
_JSH_CLEAN_LOADED=1

# =============================================================================
# Cleanup Targets
# =============================================================================
# Format: CLEAN_TARGETS[name]="description|check_func|size_func|clean_func"

declare -A CLEAN_TARGETS

# =============================================================================
# Helper Functions
# =============================================================================

# Get directory size in human-readable format
_clean_dir_size() {
    local dir="$1"
    if [[ -d "${dir}" ]]; then
        du -sh "${dir}" 2>/dev/null | cut -f1
    else
        echo "0B"
    fi
}

# Get directory size in bytes
_clean_dir_size_bytes() {
    local dir="$1"
    if [[ -d "${dir}" ]]; then
        du -s "${dir}" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# =============================================================================
# Cleanup Definitions
# =============================================================================

# Homebrew cache
_clean_check_brew() {
    command -v brew >/dev/null 2>&1 && [[ -d "$(brew --cache 2>/dev/null)" ]]
}

_clean_size_brew() {
    local cache_dir
    cache_dir=$(brew --cache 2>/dev/null)
    _clean_dir_size "${cache_dir}"
}

_clean_run_brew() {
    brew cleanup --prune=all 2>/dev/null
}

# npm cache
_clean_check_npm() {
    command -v npm >/dev/null 2>&1
}

_clean_size_npm() {
    local cache_dir="${HOME}/.npm/_cacache"
    _clean_dir_size "${cache_dir}"
}

_clean_run_npm() {
    npm cache clean --force 2>/dev/null
}

# pip cache
_clean_check_pip() {
    command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1
}

_clean_size_pip() {
    local cache_dir="${HOME}/.cache/pip"
    [[ "$(uname -s)" == "Darwin" ]] && cache_dir="${HOME}/Library/Caches/pip"
    _clean_dir_size "${cache_dir}"
}

_clean_run_pip() {
    if command -v pip3 >/dev/null 2>&1; then
        pip3 cache purge 2>/dev/null
    elif command -v pip >/dev/null 2>&1; then
        pip cache purge 2>/dev/null
    fi
}

# cargo cache
_clean_check_cargo() {
    command -v cargo >/dev/null 2>&1 && [[ -d "${HOME}/.cargo/registry/cache" ]]
}

_clean_size_cargo() {
    local cache_dir="${HOME}/.cargo/registry/cache"
    _clean_dir_size "${cache_dir}"
}

_clean_run_cargo() {
    if command -v cargo-cache >/dev/null 2>&1; then
        cargo cache -a 2>/dev/null
    else
        rm -rf "${HOME}/.cargo/registry/cache"/* 2>/dev/null
    fi
}

# Go build cache
_clean_check_go() {
    command -v go >/dev/null 2>&1
}

_clean_size_go() {
    local cache_dir
    cache_dir=$(go env GOCACHE 2>/dev/null)
    _clean_dir_size "${cache_dir}"
}

_clean_run_go() {
    go clean -cache 2>/dev/null
}

# Vim undo files
_clean_check_vim() {
    [[ -d "${HOME}/.vim/undodir" ]]
}

_clean_size_vim() {
    _clean_dir_size "${HOME}/.vim/undodir"
}

_clean_run_vim() {
    rm -rf "${HOME}/.vim/undodir"/* 2>/dev/null
}

# Sync conflict files in JSH_DIR
_clean_check_sync() {
    local jsh_dir="${JSH_DIR:-${HOME}/.jsh}"
    [[ -d "${jsh_dir}" ]] && find "${jsh_dir}" -name "*.sync-conflict-*" 2>/dev/null | grep -q .
}

_clean_size_sync() {
    local jsh_dir="${JSH_DIR:-${HOME}/.jsh}"
    local total=0
    while IFS= read -r file; do
        [[ -f "${file}" ]] && total=$((total + $(stat -f%z "${file}" 2>/dev/null || stat -c%s "${file}" 2>/dev/null || echo 0)))
    done < <(find "${jsh_dir}" -name "*.sync-conflict-*" 2>/dev/null)
    if [[ ${total} -gt 0 ]]; then
        echo "$((total / 1024))K"
    else
        echo "0B"
    fi
}

_clean_run_sync() {
    local jsh_dir="${JSH_DIR:-${HOME}/.jsh}"
    find "${jsh_dir}" -name "*.sync-conflict-*" -delete 2>/dev/null
}

# Broken symlinks in HOME
_clean_check_broken() {
    find "${HOME}" -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null | grep -q .
}

_clean_size_broken() {
    local count
    count=$(find "${HOME}" -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l | tr -d ' ')
    echo "${count} links"
}

_clean_run_broken() {
    find "${HOME}" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null
}

# Docker (if available)
_clean_check_docker() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

_clean_size_docker() {
    docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "?"
}

_clean_run_docker() {
    docker system prune -f 2>/dev/null
}

# macOS system caches
_clean_check_macos() {
    [[ "$(uname -s)" == "Darwin" ]] && [[ -d "${HOME}/Library/Caches" ]]
}

_clean_size_macos() {
    _clean_dir_size "${HOME}/Library/Caches"
}

_clean_run_macos() {
    # Only clean specific safe caches, not all of Library/Caches
    local safe_caches=(
        "com.apple.dt.Xcode"
        "com.apple.Safari"
        "Homebrew"
    )
    for cache in "${safe_caches[@]}"; do
        rm -rf "${HOME}/Library/Caches/${cache}" 2>/dev/null
    done
}

# =============================================================================
# Main Command
# =============================================================================

cmd_clean() {
    local dry_run=false
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                echo "${BOLD}jsh clean${RST} - Clean caches and temporary files"
                echo ""
                echo "${BOLD}USAGE:${RST}"
                echo "    jsh clean [options]"
                echo ""
                echo "${BOLD}OPTIONS:${RST}"
                echo "    --dry-run, -n   Show what would be cleaned without doing it"
                echo "    -y, --yes       Skip confirmation prompts"
                echo ""
                echo "${BOLD}CLEANS:${RST}"
                echo "    • Homebrew cache (brew cleanup)"
                echo "    • npm cache"
                echo "    • pip cache"
                echo "    • cargo registry cache"
                echo "    • Go build cache"
                echo "    • Vim undo files"
                echo "    • Sync-conflict files in \$JSH_DIR"
                echo "    • Broken symlinks in \$HOME"
                echo "    • Docker unused data"
                echo ""
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done

    echo ""
    echo "${BOLD}jsh clean${RST}"
    echo ""

    # Define all cleanup targets
    local -a targets=(
        "brew:Homebrew cache"
        "npm:npm cache"
        "pip:pip cache"
        "cargo:Cargo registry cache"
        "go:Go build cache"
        "vim:Vim undo files"
        "sync:Sync-conflict files"
        "broken:Broken symlinks"
        "docker:Docker unused data"
    )

    local -a available_targets=()
    local total_savings=0

    # Check which targets are available
    echo "${CYAN}Scanning for cleanup targets...${RST}"
    echo ""

    for target in "${targets[@]}"; do
        local name="${target%%:*}"
        local desc="${target#*:}"
        local check_func="_clean_check_${name}"
        local size_func="_clean_size_${name}"

        if ${check_func} 2>/dev/null; then
            local size
            size=$(${size_func} 2>/dev/null)
            available_targets+=("${name}")
            printf "  ${GRN}✔${RST} %-25s %s\n" "${desc}" "${DIM}(${size})${RST}"
        fi
    done

    if [[ ${#available_targets[@]} -eq 0 ]]; then
        echo "  ${DIM}No cleanup targets found${RST}"
        echo ""
        return 0
    fi

    echo ""

    if [[ "${dry_run}" == true ]]; then
        info "Dry run - no changes will be made"
        echo ""
        return 0
    fi

    # Confirm unless -y flag
    if [[ "${skip_confirm}" != true ]]; then
        read -r -p "Clean all targets? [y/N] " confirm
        if [[ ! "${confirm}" =~ ^[Yy] ]]; then
            info "Cancelled"
            return 0
        fi
        echo ""
    fi

    # Run cleanup
    echo "${CYAN}Cleaning...${RST}"
    echo ""

    local errors=0
    for name in "${available_targets[@]}"; do
        local clean_func="_clean_run_${name}"
        local desc=""

        # Get description
        for target in "${targets[@]}"; do
            if [[ "${target%%:*}" == "${name}" ]]; then
                desc="${target#*:}"
                break
            fi
        done

        printf "  Cleaning %-25s" "${desc}..."
        if ${clean_func} 2>/dev/null; then
            echo " ${GRN}done${RST}"
        else
            echo " ${YLW}skipped${RST}"
        fi
    done

    echo ""
    success "Cleanup complete"
}
