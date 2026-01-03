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

# Add zsh-completions (submodule preferred, core fallback for offline)
if [[ -d "${JSH_DIR}/lib/zsh-completions/src" ]]; then
    # Full zsh-completions submodule available
    fpath=("${JSH_DIR}/lib/zsh-completions/src" $fpath)
elif [[ -d "${JSH_DIR}/lib/zsh-plugins/completions-core" ]]; then
    # Fallback to minimal core completions (offline/no submodule)
    fpath=("${JSH_DIR}/lib/zsh-plugins/completions-core" $fpath)
fi

autoload -Uz compinit

# Only regenerate completion dump once a day
_zsh_compdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-${ZSH_VERSION}"
# Use absolute paths - PATH may not be fully set during early init
/bin/mkdir -p "$(/usr/bin/dirname "${_zsh_compdump}" 2>/dev/null || dirname "${_zsh_compdump}")" 2>/dev/null || mkdir -p "$(dirname "${_zsh_compdump}")"

# shellcheck disable=SC1009,SC1036,SC1072,SC1073
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
# Use absolute paths for pipeline commands - PATH may not be fully set during early init
zstyle ':completion:*:(ssh|scp|sftp|rsync):*' hosts ${(f)"$(/bin/cat ~/.ssh/known_hosts 2>/dev/null | /usr/bin/cut -f1 -d' ' | /usr/bin/tr ',' '\n' | /usr/bin/grep -v '^#' | /usr/bin/grep -v '^\[')"}

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

# Delete/Backspace (handle both DEL and ^H for compatibility)
bindkey '^[[3~' delete-char
bindkey '^?' backward-delete-char   # DEL (0x7F) - most modern terminals
bindkey '^H' backward-delete-char   # BS (0x08) - some terminals/SSH

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
# FZF Key Bindings (shell-specific; config in tools.sh)
# =============================================================================

# Source fzf key-bindings and completion (embedded in src/fzf/)
if has fzf && [[ -f "${JSH_DIR}/src/fzf/key-bindings.zsh" ]]; then
    source "${JSH_DIR}/src/fzf/key-bindings.zsh"
    source "${JSH_DIR}/src/fzf/completion.zsh"
else
    # Fallback: Standard zsh incremental history search
    # Use history-incremental-search (searches anywhere in command, not just prefix)
    bindkey '^R' history-incremental-search-backward
    bindkey '^S' history-incremental-search-forward

    # One-time warning in SSH sessions
    if [[ "${JSH_ENV:-}" == "ssh" ]] && [[ -z "${_JSH_FZF_WARNED:-}" ]]; then
        export _JSH_FZF_WARNED=1
        printf '%s\n' "${C_MUTED:-\033[2m}[jsh] fzf not found - using standard history search (Ctrl+R)${RST:-\033[0m}" >&2
    fi
fi

# =============================================================================
# Prompt - Lightning-fast native prompt with git caching
# =============================================================================

if [[ -f "${JSH_DIR}/src/prompt.sh" ]]; then
    source "${JSH_DIR}/src/prompt.sh"
    prompt_init
fi

# =============================================================================
# Zsh Plugins (embedded in lib/zsh-plugins/)
# =============================================================================

# fzf-tab - FZF-powered completion menu (submodule)
# NOTE: Must be sourced AFTER compinit and BEFORE autosuggestions
if [[ -f "${JSH_DIR}/lib/fzf-tab/fzf-tab.plugin.zsh" ]]; then
    source "${JSH_DIR}/lib/fzf-tab/fzf-tab.plugin.zsh"
    # Preview directory contents
    zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath'
    # Disable sort for git checkout
    zstyle ':completion:*:git-checkout:*' sort false
    # Use tmux popup if in tmux
    zstyle ':fzf-tab:*' fzf-command ftb-tmux-popup
fi

# zsh-autosuggestions - Fish-like autosuggestions
if [[ -f "${JSH_DIR}/lib/zsh-plugins/zsh-autosuggestions.zsh" ]]; then
    source "${JSH_DIR}/lib/zsh-plugins/zsh-autosuggestions.zsh"
    # Configuration
    ZSH_AUTOSUGGEST_STRATEGY=(history completion)
    ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=244"
    # Accept suggestion with right arrow or end key
    bindkey '^[[C' forward-char  # Right arrow accepts char
    bindkey '^[f' forward-word   # Alt+f accepts word
fi

# zsh-syntax-highlighting - Fish-like syntax highlighting
# NOTE: Must be sourced AFTER all other plugins and before history-substring-search
if [[ -f "${JSH_DIR}/lib/zsh-plugins/zsh-syntax-highlighting.zsh" ]]; then
    source "${JSH_DIR}/lib/zsh-plugins/zsh-syntax-highlighting.zsh"
    # Optional: customize highlighter styles
    ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
    # Customize colors (optional)
    typeset -A ZSH_HIGHLIGHT_STYLES
    ZSH_HIGHLIGHT_STYLES[command]='fg=green,bold'
    ZSH_HIGHLIGHT_STYLES[alias]='fg=green,bold'
    ZSH_HIGHLIGHT_STYLES[builtin]='fg=green,bold'
    ZSH_HIGHLIGHT_STYLES[function]='fg=green,bold'
    ZSH_HIGHLIGHT_STYLES[path]='fg=cyan,underline'
    ZSH_HIGHLIGHT_STYLES[globbing]='fg=magenta'
fi

# zsh-history-substring-search - Fish-like history search
# NOTE: Must be sourced AFTER zsh-syntax-highlighting
if [[ -f "${JSH_DIR}/lib/zsh-plugins/zsh-history-substring-search.zsh" ]]; then
    source "${JSH_DIR}/lib/zsh-plugins/zsh-history-substring-search.zsh"
    # Bind up/down arrows to substring search
    bindkey '^[[A' history-substring-search-up
    bindkey '^[[B' history-substring-search-down
    # Bind in vi mode as well
    bindkey -M vicmd 'k' history-substring-search-up
    bindkey -M vicmd 'j' history-substring-search-down
    # Configuration
    HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND='fg=green,bold,underline'
    HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND='fg=red,bold,underline'
    HISTORY_SUBSTRING_SEARCH_FUZZY=1
fi

# =============================================================================
# Local Overrides
# =============================================================================

source_if "${HOME}/.zshrc.local"
