# functions.sh - Utility functions
# Pure shell, portable across bash/zsh
# shellcheck disable=SC2034,SC2001,SC2004,SC2016
# SC2001: sed preferred for complex patterns; SC2004/SC2016: Style preferences

[[ -n "${_JSH_FUNCTIONS_LOADED:-}" ]] && return 0
_JSH_FUNCTIONS_LOADED=1

# =============================================================================
# Directory Navigation
# =============================================================================

# Enhanced cd: creates directory if it doesn't exist, auto-cleans empty dirs on leave
# shellcheck disable=SC2164  # cd failures are intentional for error propagation
#
# Auto-cleanup behavior:
#   When cd auto-creates a directory and you later cd out of it,
#   the empty directory is automatically removed (via rmdir, which is safe).
#   If you create any files/subdirs, the directory is kept.
#
# Variable: _JSH_AUTOCREATED_DIR - tracks the last auto-created directory

cd() {
    local prev_dir="${PWD}"

    # Helper: attempt cleanup of auto-created dir if we're leaving it
    _jsh_cleanup_autocreated() {
        if [[ -n "${_JSH_AUTOCREATED_DIR:-}" ]]; then
            # Only cleanup if we're leaving the auto-created dir
            if [[ "${prev_dir}" == "${_JSH_AUTOCREATED_DIR}" ]]; then
                # rmdir only removes empty dirs - safe to always try
                if rmdir "${_JSH_AUTOCREATED_DIR}" 2>/dev/null; then
                    echo "Removed empty directory: ${_JSH_AUTOCREATED_DIR}"
                fi
                # Clear tracking regardless (we're done with this dir)
                unset _JSH_AUTOCREATED_DIR
            fi
        fi
    }

    # Handle no args (go home) and special cases like cd -
    if [[ $# -eq 0 ]] || [[ "$1" == "-" ]]; then
        _jsh_cleanup_autocreated
        builtin cd "$@" || return
        return
    fi

    # Try normal cd first
    if builtin cd "$@" 2>/dev/null; then
        _jsh_cleanup_autocreated
        return 0
    fi

    # If target doesn't exist and isn't a special arg, create and cd
    if [[ ! -e "$1" ]]; then
        # Cleanup before creating new auto-dir (in case nested typos)
        _jsh_cleanup_autocreated

        echo "Creating directory: $1"
        if mkdir -p "$1" && builtin cd "$1"; then
            # Track this as auto-created for potential cleanup
            _JSH_AUTOCREATED_DIR="${PWD}"
        else
            return 1
        fi
    else
        # Exists but cd failed (permission denied, not a directory, etc.)
        _jsh_cleanup_autocreated
        builtin cd "$@" || return
    fi
}

# Go up N directories
up() {
    local count="${1:-1}"
    local _dir=""
    for ((i = 0; i < count; i++)); do
        _dir="../${_dir}"
    done
    cd "${_dir:-.}" || return 1
}

# Quick cd to parent with matching name
# Usage: bd foo -> cd to nearest parent containing "foo"
bd() {
    local target="$1"
    local _dir="${PWD}"

    while [[ "${_dir}" != "/" ]]; do
        if [[ "$(basename "${_dir}")" == *"${target}"* ]]; then
            cd "${_dir}" || return 1
            return 0
        fi
        _dir="$(dirname "${_dir}")"
    done

    echo "No parent directory matching '${target}'" >&2
    return 1
}

# =============================================================================
# File Operations
# =============================================================================

# Create backup with timestamp
bak() {
    local file="$1"
    [[ -z "${file}" ]] && { echo "Usage: bak <file>" >&2; return 1; }
    [[ -e "${file}" ]] || { echo "File not found: ${file}" >&2; return 1; }

    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    cp -a "${file}" "${file}.${timestamp}.bak"
    echo "Backed up: ${file}.${timestamp}.bak"
}

# Batch backup multiple files
backup() {
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    for file in "$@"; do
        if [[ -e "${file}" ]]; then
            cp -a "${file}" "${file}.${timestamp}.bak"
            echo "Backed up: ${file}.${timestamp}.bak"
        else
            echo "Skipped (not found): ${file}" >&2
        fi
    done
}

# Extract any archive format
extract() {
    local file="$1"
    [[ -z "${file}" ]] && { echo "Usage: extract <file>" >&2; return 1; }
    [[ -f "${file}" ]] || { echo "File not found: ${file}" >&2; return 1; }

    case "${file,,}" in
        *.tar.bz2|*.tbz2)   tar xjf "${file}" ;;
        *.tar.gz|*.tgz)     tar xzf "${file}" ;;
        *.tar.xz|*.txz)     tar xJf "${file}" ;;
        *.tar.zst)          tar --zstd -xf "${file}" ;;
        *.tar)              tar xf "${file}" ;;
        *.bz2)              bunzip2 "${file}" ;;
        *.gz)               gunzip "${file}" ;;
        *.xz)               unxz "${file}" ;;
        *.zst)              unzstd "${file}" ;;
        *.zip)              unzip "${file}" ;;
        *.rar)              unrar x "${file}" ;;
        *.7z)               7z x "${file}" ;;
        *.z)                uncompress "${file}" ;;
        *.deb)              ar x "${file}" ;;
        *.rpm)              rpm2cpio "${file}" | cpio -idmv ;;
        *)
            echo "Unknown archive format: ${file}" >&2
            return 1
            ;;
    esac
}

# Create archive (auto-detect format from name)
compress() {
    local archive="$1"
    shift
    [[ -z "${archive}" ]] && { echo "Usage: compress <archive> <files...>" >&2; return 1; }
    [[ $# -eq 0 ]] && { echo "No files specified" >&2; return 1; }

    case "${archive,,}" in
        *.tar.bz2|*.tbz2)   tar cjf "${archive}" "$@" ;;
        *.tar.gz|*.tgz)     tar czf "${archive}" "$@" ;;
        *.tar.xz|*.txz)     tar cJf "${archive}" "$@" ;;
        *.tar.zst)          tar --zstd -cf "${archive}" "$@" ;;
        *.tar)              tar cf "${archive}" "$@" ;;
        *.zip)              zip -r "${archive}" "$@" ;;
        *.7z)               7z a "${archive}" "$@" ;;
        *)
            echo "Unknown archive format: ${archive}" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# Search Functions
# =============================================================================

# Find files by name
ff() {
    local pattern="$1"
    local dir="${2:-.}"

    if has fd; then
        fd "${pattern}" "${dir}"
    elif has find; then
        find "${dir}" -type f -iname "*${pattern}*" 2>/dev/null
    fi
}

# Find directories by name
ffd() {
    local pattern="$1"
    local dir="${2:-.}"

    if has fd; then
        fd -t d "${pattern}" "${dir}"
    elif has find; then
        find "${dir}" -type d -iname "*${pattern}*" 2>/dev/null
    fi
}

# Grep recursively (uses rg if available)
gr() {
    local pattern="$1"
    local dir="${2:-.}"

    if has rg; then
        rg "${pattern}" "${dir}"
    else
        grep -r --color=auto "${pattern}" "${dir}"
    fi
}

# =============================================================================
# System Information
# =============================================================================

# Disk usage summary, sorted
duh() {
    du -cksh "${1:-.}"/* 2>/dev/null | sort -rh | head -20
}

# What's listening on ports
listening() {
    if [[ "${JSH_OS}" == "macos" ]]; then
        lsof -iTCP -sTCP:LISTEN -P -n
    else
        ss -tuln 2>/dev/null || netstat -tuln
    fi
}

# Kill process on specific port
killport() {
    local port="$1"
    [[ -z "${port}" ]] && { echo "Usage: killport <port>" >&2; return 1; }

    local pid
    if [[ "${JSH_OS}" == "macos" ]]; then
        pid=$(lsof -ti ":${port}" 2>/dev/null)
    else
        pid=$(fuser "${port}/tcp" 2>/dev/null)
    fi

    if [[ -n "${pid}" ]]; then
        echo "Killing PID ${pid} on port ${port}"
        kill -9 "${pid}"
    else
        echo "No process found on port ${port}"
    fi
}

# Show external IP
whatsmyip() {
    curl -s https://api.ipify.org && echo
}

# =============================================================================
# Development Utilities
# =============================================================================

# Git stage specific lines in a file
git-stage-range() { git diff -U0 "$1" | awk -v s="$2" -v e="$3" '/^@@/{match($0,/\+([0-9]+)/,a);in_range=(a[1]>=s&&a[1]<=e)}in_range||/^(diff|index|---|\+\+\+)/' | git apply --cached; }
git-stage-pattern() { git diff -U0 "$1" | grep -B999 -A999 "$2" | git apply --cached --recount 2>/dev/null || git diff -U0 "$1" | git apply --cached; }

# Quick HTTP server
serve() {
    local port="${1:-8000}"
    local dir="${2:-.}"

    echo "Serving ${dir} on http://localhost:${port}"

    if has python3; then
        python3 -m http.server "${port}" --directory "${dir}"
    elif has python; then
        (cd "${dir}" && python -m SimpleHTTPServer "${port}")
    elif has ruby; then
        ruby -run -ehttpd "${dir}" -p"${port}"
    elif has php; then
        php -S "localhost:${port}" -t "${dir}"
    else
        echo "No suitable HTTP server found (python, ruby, php)" >&2
        return 1
    fi
}

# JSON pretty print
jsonpp() {
    if has jq; then
        jq '.' "$@"
    elif has python3; then
        python3 -m json.tool "$@"
    elif has python; then
        python -m json.tool "$@"
    else
        echo "No JSON parser available (jq, python)" >&2
        return 1
    fi
}

# Generate random password
genpass() {
    local length="${1:-32}"

    if has openssl; then
        openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${length}"
        echo
    else
        LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${length}"
        echo
    fi
}

# URL encode
urlencode() {
    local string="$1"
    if has python3; then
        python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$string"
    else
        echo "${string}" | sed 's/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g'
    fi
}

# URL decode
urldecode() {
    local string="$1"
    if has python3; then
        python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$string"
    else
        echo "${string}" | sed 's/%20/ /g; s/%21/!/g; s/%22/"/g; s/%23/#/g; s/%24/$/g; s/%26/\&/g'
    fi
}

# =============================================================================
# Git Utilities
# =============================================================================

# Shared confirmation prompt for git+ helpers
_git_confirm() {
    local action="$1"
    local reply

    printf '%s [y/N] ' "${action}"
    read -r reply || return 1

    case "${reply}" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            echo "Cancelled"
            return 1
            ;;
    esac
}

# Push to origin on the current branch
git+() {
    local branch
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
        echo "Detached HEAD: checkout a branch first" >&2
        return 1
    }

    _git_confirm "Push '${branch}' to origin?" || return 1
    git push origin "${branch}"
}

git+++() {
    local branch
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
        echo "Detached HEAD: checkout a branch first" >&2
        return 1
    }

    _git_confirm "Force-push '${branch}' to origin with --force-with-lease?" || return 1
    git push --force-with-lease origin "${branch}"
}

# Backward-compat convenience alias
git++() { git+++ "$@"; }

# Reset HEAD to undo last commit (soft reset, keeps changes in working directory)
git-() {
    _git_confirm "Reset HEAD to undo last commit ($(git log -1 --pretty=format:'%s'))?" || return 1
    git reset HEAD~1
}

# Rebase current branch onto latest remote default branch (origin/main, origin/master, etc.)
# Usage: git-+ [git rebase args...]
git-+() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Not a git repository" >&2
        return 1
    fi

    local current_branch remote upstream_ref default_ref default_branch candidate
    current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
        echo "Detached HEAD: checkout a branch first" >&2
        return 1
    }

    upstream_ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || true
    if [[ -n "${upstream_ref}" ]]; then
        remote="${upstream_ref%%/*}"
    else
        remote=$(git config --get "branch.${current_branch}.remote" 2>/dev/null) || true
    fi

    if [[ -z "${remote}" ]]; then
        if git remote get-url origin >/dev/null 2>&1; then
            remote="origin"
        else
            remote=$(git remote | head -n 1)
        fi
    fi

    if [[ -z "${remote}" ]]; then
        echo "No git remote configured" >&2
        return 1
    fi

    default_ref=$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null) || true
    default_branch="${default_ref#${remote}/}"

    if [[ -z "${default_branch}" || "${default_branch}" == "${default_ref}" ]]; then
        default_branch=$(git remote show "${remote}" 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p' | head -n 1)
    fi

    if [[ -z "${default_branch}" ]]; then
        for candidate in main master trunk develop; do
            if git show-ref --verify --quiet "refs/remotes/${remote}/${candidate}"; then
                default_branch="${candidate}"
                break
            fi
        done
    fi

    if [[ -z "${default_branch}" ]]; then
        echo "Could not determine default branch for remote '${remote}'" >&2
        return 1
    fi

    _git_confirm "Fetch '${remote}' and rebase '${current_branch}' onto '${remote}/${default_branch}'?" || return 1

    git fetch "${remote}" --prune || return 1

    echo "Rebasing ${current_branch} onto ${remote}/${default_branch}"
    git rebase --autostash "$@" "${remote}/${default_branch}"
}

# Commit with optional inline message
# Usage: git_ "message" or just git_ to open editor
git_() {
    if [[ $# -eq 0 ]]; then
        git commit
    else
        git commit -m "$*"
    fi
}

# Clone and cd into repo
gclone() {
    local repo="$1"
    [[ -z "${repo}" ]] && { echo "Usage: gclone <repo-url>" >&2; return 1; }

    local dir
    dir="$(basename "${repo}" .git)"

    git clone "${repo}" && cd "${dir}" || return 1
}

# Convert HTTPS git URL to SSH
http2ssh() {
    local url="$1"
    echo "${url}" | sed -e 's|https://github.com/|git@github.com:|' \
                        -e 's|https://gitlab.com/|git@gitlab.com:|' \
                        -e 's|https://bitbucket.org/|git@bitbucket.org:|'
}

# =============================================================================
# Fun / Misc
# =============================================================================

# Weather
weather() {
    local location="${1:-}"
    curl -s "wttr.in/${location}?F"
}

# Cheat sheet lookup
cheat() {
    local topic="$1"
    [[ -z "${topic}" ]] && { echo "Usage: cheat <topic>" >&2; return 1; }
    curl -s "cheat.sh/${topic}"
}

# Countdown timer
timer() {
    local seconds="${1:-60}"
    local msg="${2:-Timer done!}"

    echo "Timer: ${seconds} seconds"
    while [[ "${seconds}" -gt 0 ]]; do
        printf "\r%02d:%02d " $((seconds / 60)) $((seconds % 60))
        sleep 1
        ((seconds--))
    done
    printf "\r%s\n" "${msg}"

    # Notification
    if has osascript; then
        osascript -e "display notification \"${msg}\" with title \"Timer\""
    elif has notify-send; then
        notify-send "Timer" "${msg}"
    fi
}

# Simple calculator
# Uses bc for floating-point, falls back to bash arithmetic (integers only)
calc() {
    local expr="$*"
    # Validate input: only allow numbers, operators, parentheses, decimal points, spaces
    if [[ ! "$expr" =~ ^[0-9+\-*/\(\)\.\ %^]+$ ]]; then
        echo "calc: invalid characters in expression" >&2
        return 1
    fi
    if has bc; then
        echo "scale=4; ${expr}" | bc -l
    else
        # Bash arithmetic (integers only)
        echo $(($expr))
    fi
}

# Quick notes
note() {
    local notes_file="${HOME}/.notes"

    if [[ $# -eq 0 ]]; then
        [[ -f "${notes_file}" ]] && cat "${notes_file}"
    else
        echo "$(date '+%Y-%m-%d %H:%M') $*" >> "${notes_file}"
        echo "Note added."
    fi
}

# =============================================================================
# FZF Integration (if available)
# =============================================================================

if has fzf; then
    # Interactive cd
    fcd() {
        local dir
        dir=$(find "${1:-.}" -type d 2>/dev/null | fzf --preview 'ls -la {}')
        [[ -n "${dir}" ]] && cd "${dir}" || return 1
    }

    # Interactive file edit
    fe() {
        local file
        file=$(fzf --preview 'head -100 {}')
        [[ -n "${file}" ]] && "${EDITOR:-vim}" "${file}"
    }

    # Interactive history search
    fh() {
        local cmd
        cmd=$(history | fzf --tac | sed 's/^[ ]*[0-9]*[ ]*//')
        [[ -n "${cmd}" ]] && eval "${cmd}"
    }

    # Interactive process kill
    fkill() {
        local pid
        pid=$(ps aux | fzf --header-lines=1 | awk '{print $2}')
        [[ -n "${pid}" ]] && kill -9 "${pid}"
    }

    # Git branch checkout
    fco() {
        local branch
        branch=$(git branch -a | fzf | sed 's/^[ *]*//' | sed 's|remotes/origin/||')
        [[ -n "${branch}" ]] && git checkout "${branch}"
    }

    # Git log browser
    fgl() {
        git log --oneline --graph --color=always | \
            fzf --ansi --preview 'git show --color=always {1}' | \
            awk '{print $1}'
    }
else
    # ==========================================================================
    # Pure Shell Fallbacks (when fzf is not available)
    # Uses select menus and numbered lists for interactive selection
    # ==========================================================================

    # Interactive cd (pure shell)
    fcd() {
        local dir="${1:-.}"
        local dirs=()
        local i=1

        echo "Directories in ${dir}:"
        while IFS= read -r d; do
            dirs+=("$d")
            printf "%d) %s\n" "$i" "$d"
            ((i++))
            [[ $i -gt 50 ]] && { echo "... (limited to 50)"; break; }
        done < <(find "${dir}" -maxdepth 3 -type d 2>/dev/null | head -50)

        [[ ${#dirs[@]} -eq 0 ]] && { echo "No directories found"; return 1; }

        printf "\nEnter number (or 'q' to cancel): "
        read -r choice
        [[ "${choice}" == "q" ]] && return 0

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#dirs[@]} ]]; then
            cd "${dirs[$((choice-1))]}" || return 1
        else
            echo "Invalid selection" >&2
            return 1
        fi
    }

    # Interactive file edit (pure shell)
    fe() {
        local files=()
        local i=1

        echo "Files in current directory:"
        while IFS= read -r f; do
            files+=("$f")
            printf "%d) %s\n" "$i" "$f"
            ((i++))
            [[ $i -gt 50 ]] && { echo "... (limited to 50)"; break; }
        done < <(find . -maxdepth 2 -type f 2>/dev/null | head -50)

        [[ ${#files[@]} -eq 0 ]] && { echo "No files found"; return 1; }

        printf "\nEnter number (or 'q' to cancel): "
        read -r choice
        [[ "${choice}" == "q" ]] && return 0

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#files[@]} ]]; then
            "${EDITOR:-vim}" "${files[$((choice-1))]}"
        else
            echo "Invalid selection" >&2
            return 1
        fi
    }

    # Interactive history search (pure shell)
    fh() {
        local pattern="${1:-}"
        local cmds=()
        local i=1

        echo "Recent commands${pattern:+ matching '$pattern'}:"
        while IFS= read -r line; do
            # Strip leading spaces and history number
            local cmd
            cmd=$(echo "$line" | sed 's/^[ ]*[0-9]*[ ]*//')
            [[ -z "$cmd" ]] && continue
            [[ -n "$pattern" ]] && [[ "$cmd" != *"$pattern"* ]] && continue
            cmds+=("$cmd")
            printf "%d) %s\n" "$i" "${cmd:0:80}"
            ((i++))
            [[ $i -gt 30 ]] && break
        done < <(history | tail -100)

        [[ ${#cmds[@]} -eq 0 ]] && { echo "No matching commands"; return 1; }

        printf "\nEnter number to execute (or 'q' to cancel): "
        read -r choice
        [[ "${choice}" == "q" ]] && return 0

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#cmds[@]} ]]; then
            echo "Executing: ${cmds[$((choice-1))]}"
            eval "${cmds[$((choice-1))]}"
        else
            echo "Invalid selection" >&2
            return 1
        fi
    }

    # Interactive process kill (pure shell)
    fkill() {
        local pattern="${1:-}"
        local pids=()
        local i=1

        echo "Running processes${pattern:+ matching '$pattern'}:"
        echo "PID USER COMMAND"
        echo "--- ---- -------"

        while IFS= read -r line; do
            [[ $i -eq 1 ]] && { ((i++)); continue; }  # Skip header
            local pid user cmd
            pid=$(echo "$line" | awk '{print $2}')
            user=$(echo "$line" | awk '{print $1}')
            cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')

            [[ -n "$pattern" ]] && [[ "$cmd" != *"$pattern"* ]] && continue
            pids+=("$pid")
            printf "%d) %-6s %-8s %s\n" "${#pids[@]}" "$pid" "$user" "${cmd:0:60}"
            [[ ${#pids[@]} -ge 30 ]] && break
        done < <(ps aux)

        [[ ${#pids[@]} -eq 0 ]] && { echo "No matching processes"; return 1; }

        printf "\nEnter number to kill (or 'q' to cancel): "
        read -r choice
        [[ "${choice}" == "q" ]] && return 0

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#pids[@]} ]]; then
            local target_pid="${pids[$((choice-1))]}"
            echo "Killing PID ${target_pid}..."
            kill -9 "${target_pid}"
        else
            echo "Invalid selection" >&2
            return 1
        fi
    }

    # Git branch checkout (pure shell)
    fco() {
        local branches=()
        local i=1

        echo "Git branches:"
        while IFS= read -r branch; do
            branch=$(echo "$branch" | sed 's/^[ *]*//' | sed 's|remotes/origin/||')
            [[ -z "$branch" ]] && continue
            [[ "$branch" == "HEAD"* ]] && continue
            branches+=("$branch")
            printf "%d) %s\n" "$i" "$branch"
            ((i++))
            [[ $i -gt 30 ]] && { echo "... (limited to 30)"; break; }
        done < <(git branch -a 2>/dev/null)

        [[ ${#branches[@]} -eq 0 ]] && { echo "No branches found (not a git repo?)"; return 1; }

        printf "\nEnter number to checkout (or 'q' to cancel): "
        read -r choice
        [[ "${choice}" == "q" ]] && return 0

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#branches[@]} ]]; then
            git checkout "${branches[$((choice-1))]}"
        else
            echo "Invalid selection" >&2
            return 1
        fi
    }

    # Git log browser (pure shell)
    fgl() {
        local commits=()
        local i=1

        echo "Recent commits:"
        while IFS= read -r line; do
            local sha msg
            sha=$(echo "$line" | awk '{print $1}')
            msg=$(echo "$line" | cut -d' ' -f2-)
            commits+=("$sha")
            printf "%d) %s %s\n" "$i" "${sha:0:7}" "${msg:0:65}"
            ((i++))
            [[ $i -gt 30 ]] && break
        done < <(git log --oneline -30 2>/dev/null)

        [[ ${#commits[@]} -eq 0 ]] && { echo "No commits found (not a git repo?)"; return 1; }

        printf "\nEnter number to show (or 'q' to cancel): "
        read -r choice
        [[ "${choice}" == "q" ]] && return 0

        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#commits[@]} ]]; then
            git show "${commits[$((choice-1))]}"
        else
            echo "Invalid selection" >&2
            return 1
        fi
    }
fi

# =============================================================================
# Reload Function
# =============================================================================

reload_jsh() {
    # Unset load guards
    unset _JSH_CORE_LOADED _JSH_GITSTATUS_LOADED _JSH_PROMPT_LOADED
    unset _JSH_VIMODE_LOADED _JSH_ALIASES_LOADED _JSH_FUNCTIONS_LOADED
    unset _JSH_ZSH_LOADED _JSH_BASH_LOADED _JSH_INIT_LOADED _JSH_J_LOADED

    # Re-source
    source "${JSH_DIR}/src/init.sh"
    echo "Jsh reloaded"
}
