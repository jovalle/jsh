# shellcheck shell=zsh
# zsh.sh - Zsh-specific configuration
# No plugins required, pure zsh
# shellcheck disable=SC2034,SC1090,SC2154

[[ -n "${_JSH_ZSH_LOADED:-}" ]] && return 0
_JSH_ZSH_LOADED=1

# =============================================================================
# Zsh Options
# =============================================================================

# Navigation
setopt AUTO_CD              # cd by typing directory name
setopt AUTO_PUSHD           # Push directories to stack
setopt PUSHD_IGNORE_DUPS    # No duplicates in dir stack
setopt PUSHD_SILENT         # Don't print dir stack
setopt CDABLE_VARS          # cd to named directories

# Globbing
setopt EXTENDED_GLOB        # Extended pattern matching
setopt GLOB_DOTS            # Include dotfiles in globs
setopt NO_CASE_GLOB         # Case-insensitive globbing
setopt NUMERIC_GLOB_SORT    # Sort numerically when relevant
setopt GLOB_COMPLETE        # Generate globs on completion

# History
setopt EXTENDED_HISTORY     # Record timestamp in history
setopt HIST_EXPIRE_DUPS_FIRST  # Expire duplicates first
setopt HIST_IGNORE_DUPS     # Don't record duplicates
setopt HIST_IGNORE_ALL_DUPS # Delete old duplicate
setopt HIST_IGNORE_SPACE    # Don't record if starts with space
setopt HIST_FIND_NO_DUPS    # Don't display duplicates
setopt HIST_REDUCE_BLANKS   # Remove excess blanks
setopt HIST_VERIFY          # Don't execute immediately
setopt SHARE_HISTORY        # Share history across sessions (implies INC_APPEND)
setopt HIST_SAVE_NO_DUPS    # Don't save duplicates

# Completion
setopt COMPLETE_IN_WORD     # Complete from cursor
setopt ALWAYS_TO_END        # Move cursor to end after complete
setopt AUTO_MENU            # Auto menu on double tab
setopt AUTO_LIST            # List choices on ambiguous
setopt AUTO_PARAM_KEYS      # Auto insert parameter keys
setopt AUTO_PARAM_SLASH     # Add slash to directories
setopt AUTO_REMOVE_SLASH    # Remove slash if next char is word delimiter
setopt LIST_PACKED          # Compact completion list
setopt LIST_ROWS_FIRST      # Rows before columns

# Correction
setopt CORRECT              # Spell check commands
unsetopt CORRECT_ALL        # Don't correct arguments (too annoying)

# Misc
setopt INTERACTIVE_COMMENTS # Allow comments in interactive
setopt NO_BEEP              # No beep
setopt NO_FLOW_CONTROL      # Disable Ctrl-S/Ctrl-Q
setopt PROMPT_SUBST         # Enable prompt substitution

# =============================================================================
# History Settings
# =============================================================================

HISTFILE="${HISTFILE:-${HOME}/.zsh_history}"
HISTSIZE=50000
SAVEHIST=50000

# =============================================================================
# Completion System
# =============================================================================

# Add custom completions (jsh, make)
[[ -d "${JSH_DIR}/src/completions" ]] && fpath=("${JSH_DIR}/src/completions" $fpath)

autoload -Uz compinit

# Only regenerate completion dump once a day
_zsh_compdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-${ZSH_VERSION}"
mkdir -p "$(dirname "${_zsh_compdump}")"

if [[ -n "${_zsh_compdump}"(#qN.mh+24) ]]; then
    compinit -i -d "${_zsh_compdump}"
else
    compinit -C -d "${_zsh_compdump}"
fi

# Process deferred completions (registered before compinit loaded)
if [[ -n "${_JSH_DEFERRED_COMPLETIONS[*]:-}" ]]; then
    for _fn in "${_JSH_DEFERRED_COMPLETIONS[@]}"; do
        "${_fn}"
    done
    unset _JSH_DEFERRED_COMPLETIONS _fn
fi

# Completion options
zstyle ':completion:*' completer _complete _match _approximate
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu select=2
zstyle ':completion:*' verbose yes
zstyle ':completion:*' group-name ''
zstyle ':completion:*' use-cache yes
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"

# Group formatting
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*:corrections' format '%F{green}-- %d (errors: %e) --%f'
zstyle ':completion:*:messages' format '%F{purple}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{red}-- no matches found --%f'

# Completion for specific commands
zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# SSH/SCP completion from known_hosts
zstyle ':completion:*:(ssh|scp|sftp|rsync):*' hosts ${(f)"$(cat ~/.ssh/known_hosts 2>/dev/null | cut -f1 -d' ' | tr ',' '\n' | grep -v '^#' | grep -v '^\[')"}

# =============================================================================
# Key Bindings (Zsh-specific)
# =============================================================================

# History search
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

bindkey '^[[A' up-line-or-beginning-search    # Up
bindkey '^[[B' down-line-or-beginning-search  # Down
bindkey '^P' up-line-or-beginning-search
bindkey '^N' down-line-or-beginning-search

# Home/End
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[1~' beginning-of-line
bindkey '^[[4~' end-of-line

# Delete
bindkey '^[[3~' delete-char
bindkey '^?' backward-delete-char

# Word navigation
bindkey '^[[1;5D' backward-word  # Ctrl+Left
bindkey '^[[1;5C' forward-word   # Ctrl+Right
bindkey '^[b' backward-word      # Alt+b
bindkey '^[f' forward-word       # Alt+f

# =============================================================================
# Directory Hashing (Quick cd)
# =============================================================================

# Named directories (cd ~projects)
hash -d projects="${HOME}/projects" 2>/dev/null
hash -d dl="${HOME}/Downloads" 2>/dev/null
hash -d docs="${HOME}/Documents" 2>/dev/null
hash -d jsh="${JSH_DIR}" 2>/dev/null

# =============================================================================
# Magic Space (History Expansion)
# =============================================================================

# Space expands history (!!, !$, etc.)
bindkey ' ' magic-space

# =============================================================================
# Hooks
# =============================================================================

autoload -Uz add-zsh-hook

# Terminal title
_jsh_set_title() {
    local title="${PWD/#$HOME/~}"
    printf '\e]2;%s\a' "${title}"
}
add-zsh-hook precmd _jsh_set_title

# =============================================================================
# FZF Integration (if fzf is available)
# =============================================================================

if has fzf; then
    # FZF default options (VS Code Dark+ theme)
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --inline-info"
    export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS} --color=bg+:#264F78,bg:#1E1E1E,spinner:#569CD6,hl:#DCDCAA"
    export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS} --color=fg:#D4D4D4,header:#569CD6,info:#6A9955,pointer:#569CD6"
    export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS} --color=marker:#569CD6,fg+:#FFFFFF,prompt:#DCDCAA,hl+:#DCDCAA"

    # Use fd if available
    if has fd; then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="${FZF_DEFAULT_COMMAND}"
        export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
    fi

    # Source fzf key-bindings and completion (bundled with jsh)
    if [[ -f "${JSH_DIR}/src/fzf/key-bindings.zsh" ]]; then
        source "${JSH_DIR}/src/fzf/key-bindings.zsh"
        source "${JSH_DIR}/src/fzf/completion.zsh"
    fi
else
    # Bind Ctrl+R to history search (compatible with multi-line prompts like p10k)
    # Note: vi-mode.sh also sets these; this covers emacs mode
    bindkey '^R' history-beginning-search-backward
    bindkey '^S' history-beginning-search-forward
fi

# =============================================================================
# Direnv Integration
# =============================================================================

if has direnv; then
    eval "$(direnv hook zsh)"
fi

# =============================================================================
# Local Overrides
# =============================================================================

source_if "${HOME}/.zshrc.local"
