# bash.sh - Bash-specific configuration
# Pure bash, no plugins
# shellcheck disable=SC2034

[[ -n "${_JSH_BASH_LOADED:-}" ]] && return 0
_JSH_BASH_LOADED=1

# =============================================================================
# Shell Options
# =============================================================================

# Navigation
shopt -s autocd 2>/dev/null         # cd by typing directory name
shopt -s cdspell 2>/dev/null        # Correct cd typos
shopt -s dirspell 2>/dev/null       # Correct directory typos in completion
shopt -s cdable_vars 2>/dev/null    # cd to shell variables

# Globbing
shopt -s globstar 2>/dev/null       # ** recursive glob
shopt -s extglob 2>/dev/null        # Extended pattern matching
shopt -s dotglob 2>/dev/null        # Include dotfiles in globs
shopt -s nocaseglob 2>/dev/null     # Case-insensitive globbing
shopt -s nullglob 2>/dev/null       # No match returns empty

# History
shopt -s histappend                 # Append to history
shopt -s cmdhist                    # Save multi-line as one
shopt -s lithist 2>/dev/null        # Preserve newlines in history

# Completion
shopt -s complete_fullquote 2>/dev/null
shopt -s force_fignore 2>/dev/null
shopt -s hostcomplete 2>/dev/null
shopt -s no_empty_cmd_completion 2>/dev/null

# Misc
shopt -s checkwinsize               # Update LINES/COLUMNS after commands
shopt -s checkhash 2>/dev/null      # Check hash before executing
shopt -s expand_aliases             # Expand aliases

# =============================================================================
# History Settings
# =============================================================================

HISTFILE="${HISTFILE:-${HOME}/.bash_history}"
HISTSIZE=50000
HISTFILESIZE=50000
HISTCONTROL=ignoreboth:erasedups
HISTIGNORE="ls:ll:la:cd:pwd:exit:clear:c:e:q:history"
HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "

# Append to history immediately
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }history -a"

# =============================================================================
# Completion
# =============================================================================

# Source system completions (bash-completion@2 only)
# NOTE: Skip legacy bash-completion 1.x - it breaks filename completion
# Only source if bash-completion@2 is installed (check for _init_completion function)
_jsh_source_bash_completion() {
    local bc_file=""

    # Find bash-completion file
    for f in \
        /etc/bash_completion \
        /usr/share/bash-completion/bash_completion \
        /opt/homebrew/share/bash-completion/bash_completion \
        /usr/local/share/bash-completion/bash_completion
    do
        [[ -f "$f" ]] && bc_file="$f" && break
    done

    # Only source if it's bash-completion@2 (has _init_completion)
    # Legacy 1.x versions break default filename completion
    if [[ -n "$bc_file" ]]; then
        # Check if it's version 2.x by looking for specific file
        local bc_dir="${bc_file%/*}"
        if [[ -f "${bc_dir}/completions/bash-completion" ]] || \
           grep -q '_init_completion' "$bc_file" 2>/dev/null; then
            source "$bc_file"
        fi
    fi
}
_jsh_source_bash_completion
unset -f _jsh_source_bash_completion

# Case-insensitive completion
bind 'set completion-ignore-case on' 2>/dev/null

# Show all if ambiguous (but complete unique matches first)
bind 'set show-all-if-ambiguous on' 2>/dev/null
bind 'set show-all-if-unmodified on' 2>/dev/null

# Color completions
bind 'set colored-stats on' 2>/dev/null
bind 'set colored-completion-prefix on' 2>/dev/null

# =============================================================================
# Key Bindings
# =============================================================================

# History search with arrows
bind '"\e[A": history-search-backward' 2>/dev/null
bind '"\e[B": history-search-forward' 2>/dev/null

# Word navigation
bind '"\e[1;5D": backward-word' 2>/dev/null  # Ctrl+Left
bind '"\e[1;5C": forward-word' 2>/dev/null   # Ctrl+Right
bind '"\eb": backward-word' 2>/dev/null      # Alt+b
bind '"\ef": forward-word' 2>/dev/null       # Alt+f

# Home/End
bind '"\e[H": beginning-of-line' 2>/dev/null
bind '"\e[F": end-of-line' 2>/dev/null

# Clear screen
bind '"\C-l": clear-screen' 2>/dev/null

# =============================================================================
# Prompt (Fallback - uses built-in prompt instead of zsh theme)
# =============================================================================

_jsh_bash_prompt() {
    local exit_code=$?

    # Use prompt-safe colors from core.sh (respects JSH_HAS_COLOR)
    # P_* variables are pre-wrapped with \[ \] for readline

    # User/host (show if SSH or root)
    local user_host=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        user_host="${P_YLW}⚡${P_CYN}\u${P_BBLK}@${P_CYN}\h${P_RST} "
    elif [[ "${EUID}" == "0" ]]; then
        user_host="${P_RED}#${P_RST} "
    fi

    # Directory
    local dir="${P_BLU}\w${P_RST}"

    # Git branch with ahead/behind (single git call via git_status_fast)
    local git_info=""
    if has git && git rev-parse --is-inside-work-tree &>/dev/null; then
        local info
        info="$(git_status_fast 2>/dev/null)"
        if [[ -n "${info}" ]]; then
            local branch staged unstaged untracked ahead behind stash conflicts
            IFS='|' read -r branch staged unstaged untracked ahead behind stash conflicts <<< "${info}"

            if [[ -n "${branch}" ]]; then
                local marks=""
                local is_dirty=0
                # Dirty indicator
                if [[ "${staged}" -gt 0 || "${unstaged}" -gt 0 || "${untracked}" -gt 0 ]]; then
                    marks="*"
                    is_dirty=1
                fi
                # Ahead/behind indicators
                [[ "${ahead}" -gt 0 ]] && marks+=" ↑${ahead}"
                [[ "${behind}" -gt 0 ]] && marks+=" ↓${behind}"

                if [[ "${is_dirty}" -eq 1 ]]; then
                    git_info=" ${P_YLW}${branch}${marks}${P_RST}"
                else
                    git_info=" ${P_GRN}${branch}${marks}${P_RST}"
                fi
            fi
        fi
    fi

    # Virtualenv
    local venv=""
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        venv=" ${P_BBLK}🐍$(basename "${VIRTUAL_ENV}")${P_RST}"
    fi

    # Prompt char (color by exit code)
    local char
    if [[ "${exit_code}" -eq 0 ]]; then
        char="${P_GRN}❯${P_RST}"
    else
        char="${P_RED}❯${P_RST}"
    fi

    # Build prompt (two-line)
    PS1="${user_host}${dir}${git_info}${venv}\n${char} "
}

# Set prompt command
PROMPT_COMMAND="_jsh_bash_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# =============================================================================
# Terminal Title
# =============================================================================

_jsh_bash_title() {
    local title="${PWD/#$HOME/~}"
    printf '\e]2;%s\a' "${title}"
}
PROMPT_COMMAND="_jsh_bash_title${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# =============================================================================
# Directory Shortcuts (CDPATH - like zsh hash -d)
# =============================================================================

# Named directory shortcuts via CDPATH
# Usage: cd projects -> ~/projects, cd dl -> ~/Downloads
export CDPATH=".:${HOME}"

# Create directory aliases that work with cdable_vars (shopt -s cdable_vars)
export projects="${HOME}/projects"
export dl="${HOME}/Downloads"
export docs="${HOME}/Documents"
export jsh="${JSH_DIR}"

# =============================================================================
# History Search with FZF fallback (from lib/fzf submodule)
# =============================================================================
# Runtime-safe: checks fzf availability on each invocation, not just at startup.
# Falls back to bash's native reverse-i-search if fzf goes missing.

# Store original Ctrl+R binding to restore if fzf disappears
_JSH_ORIGINAL_CTRL_R=$(bind -p 2>/dev/null | grep '\\C-r' | head -1)

_jsh_history_search() {
    if command -v fzf >/dev/null 2>&1; then
        # fzf available - use __fzf_history__ if defined, else basic fzf
        if declare -F __fzf_history__ >/dev/null 2>&1; then
            __fzf_history__
        else
            # Minimal fzf history search
            local selected
            selected=$(HISTTIMEFORMAT='' history | fzf --height=40% --reverse --tac --no-sort --exact --query="$READLINE_LINE" | sed 's/^ *[0-9]* *//')
            if [[ -n "$selected" ]]; then
                READLINE_LINE="$selected"
                READLINE_POINT=${#READLINE_LINE}
            fi
        fi
    else
        # fzf not available - restore native readline reverse-i-search
        # Unbind our function and restore original binding
        bind '"\C-r": reverse-search-history'
        # Notify user that we've restored native search
        printf '\n%s\n' "${C_MUTED:-}[jsh] fzf unavailable - restored native Ctrl+R search${RST:-}"
        READLINE_LINE=""
        READLINE_POINT=0
    fi
}

# Source fzf key-bindings and completion from submodule, then wrap with our resilient function
if has fzf && [[ -f "${JSH_DIR}/lib/fzf/shell/key-bindings.bash" ]]; then
    source "${JSH_DIR}/lib/fzf/shell/key-bindings.bash"
    source "${JSH_DIR}/lib/fzf/shell/completion.bash"
    # Override with our wrapper for runtime resilience
    bind -x '"\C-r": _jsh_history_search'
elif has fzf; then
    # fzf available but no key-bindings file - use our minimal implementation
    bind -x '"\C-r": _jsh_history_search'
fi
# If fzf not available at all, leave readline's default Ctrl+R binding intact

# One-time warning in SSH sessions when fzf not available
if ! has fzf && [[ "${JSH_ENV:-}" == "ssh" ]] && [[ -z "${_JSH_FZF_WARNED:-}" ]]; then
    export _JSH_FZF_WARNED=1
    printf '%s\n' "${C_MUTED:-\033[2m}[jsh] fzf not found - using standard history search (Ctrl+R)${RST:-\033[0m}" >&2
fi

# =============================================================================
# Custom Completions (bundled)
# =============================================================================

# Source jsh and make completions
if [[ -d "${JSH_DIR}/src/completions/bash" ]]; then
    for _comp_file in "${JSH_DIR}/src/completions/bash"/*.bash; do
        [[ -f "$_comp_file" ]] && source "$_comp_file"
    done
    unset _comp_file
fi

# =============================================================================
# Local Overrides
# =============================================================================

source_if "${HOME}/.bashrc.local"
