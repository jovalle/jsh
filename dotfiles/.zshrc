# .zshrc - Zsh Configuration

# Source common configuration
if [[ -f "${HOME}/.jsh/dotfiles/.jshrc" ]]; then
  source "${HOME}/.jsh/dotfiles/.jshrc"
elif [[ -f "${HOME}/.jshrc" ]]; then
  source "${HOME}/.jshrc"
fi

# ============================================================================
# PLUGIN SYSTEM
# ============================================================================

# Zinit
export ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Download Zinit if missing
if [[ ! -d "${ZINIT_HOME}" ]]; then
    # Minimal mode: Don't download, just warn and skip
    warn "Zinit not found. Skipping plugins."
else
    # Initialize Zinit
    source "${ZINIT_HOME}/zinit.zsh"

    # Load theme (Powerlevel10k)
    if [[ -r "${XDG_CACHE_HOME:-${HOME}/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
      source "${XDG_CACHE_HOME:-${HOME}/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
    fi

    zinit ice depth=1
    zinit light romkatv/powerlevel10k

    # Load plugins
    zinit light Aloxaf/fzf-tab
    zinit light zsh-users/zsh-completions
    zinit light zsh-users/zsh-autosuggestions
    zinit light zdharma-continuum/fast-syntax-highlighting
    zinit light akarzim/zsh-docker-aliases
    zinit light MichaelAquilina/zsh-you-should-use
    zinit light wfxr/forgit
    zinit light lukechilds/zsh-nvm
    zinit light mafredri/zsh-async
    zinit light supercrabtree/k
fi

# ============================================================================
# SHELL OPTIONS & KEYBINDINGS
# ============================================================================

# Vi mode
bindkey -v

# Incremental search
bindkey -M vicmd '^R' history-incremental-search-backward
bindkey -M vicmd '^S' history-incremental-search-forward
bindkey -M viins '^R' history-incremental-search-backward
bindkey -M viins '^S' history-incremental-search-forward

# Delete key fixes
bindkey -M vicmd '^[[3~' delete-char
bindkey -M viins '^[[3~' delete-char

# Word navigation (cross-platform support)
# macOS Terminal (Option+Arrow sends escape sequences)
bindkey -M viins '^[b' backward-word         # Option+Left (macOS)
bindkey -M viins '^[f' forward-word          # Option+Right (macOS)
bindkey -M vicmd '^[b' backward-word         # Option+Left (macOS)
bindkey -M vicmd '^[f' forward-word          # Option+Right (macOS)
# Alternative sequences for other terminals
bindkey -M viins '^[^[[C' forward-word       # Alt+Right
bindkey -M viins '^[^[[D' backward-word      # Alt+Left
bindkey -M vicmd '^[^[[C' forward-word       # Alt+Right
bindkey -M vicmd '^[^[[D' backward-word      # Alt+Left
bindkey -M viins '^[[1;3C' forward-word      # Alt+Right (xterm)
bindkey -M viins '^[[1;3D' backward-word     # Alt+Left (xterm)
bindkey -M vicmd '^[[1;3C' forward-word      # Alt+Right (xterm)
bindkey -M vicmd '^[[1;3D' backward-word     # Alt+Left (xterm)
bindkey -M viins '^[[1;5C' forward-word      # Ctrl+Right (Linux)
bindkey -M viins '^[[1;5D' backward-word     # Ctrl+Left (Linux)
bindkey -M vicmd '^[[1;5C' forward-word      # Ctrl+Right (Linux)
bindkey -M vicmd '^[[1;5D' backward-word     # Ctrl+Left (Linux)

# Word deletion
bindkey -M viins '^H' backward-kill-word
bindkey -M viins '^W' backward-kill-word
bindkey -M viins '^[^?' backward-kill-word

# Shell options
setopt AUTO_CD COMPLETE_IN_WORD extended_history hist_find_no_dups hist_ignore_all_dups \
        hist_ignore_dups hist_ignore_space hist_save_no_dups INTERACTIVE_COMMENTS \
        NO_BEEP NOBGNICE HUP INC_APPEND_HISTORY SHARE_HISTORY CORRECT

# Magic space (!!<space> to expand last command)
bindkey ' ' magic-space

# History configuration
export HISTDUP=erase
export HISTFILE="${JSH}/.zsh_history"
export HISTSIZE=50000
export HIST_STAMPS=iso
export SAVEHIST=50000

# Completion options
LISTMAX=0
export LISTMAX
MAILCHECK=0

# ============================================================================
# COMPLETION SYSTEM
# ============================================================================

fpath=(~/.zsh/completions "${fpath[@]}")
autoload -Uz compinit && compinit

zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview "${LS_PREVIEW} \$realpath"
zstyle ':fzf-tab:*' fzf-bindings 'tab:accept'
zstyle ':fzf-tab:*' accept-line enter
zstyle ':fzf-tab:*' continuous-trigger 'tab'

if command -v zinit >/dev/null 2>&1; then
    zinit cdreplay -q
fi

# Tool Completions
command -v brew >/dev/null 2>&1 && eval "$(brew shellenv)"
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
command -v docker >/dev/null 2>&1 && eval "$(docker completion zsh)"
command -v fzf >/dev/null 2>&1 && source <(command fzf --zsh)
command -v kubectl >/dev/null 2>&1 && source <(kubectl completion zsh)
command -v task >/dev/null 2>&1 && source <(task --completion zsh)
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

# ============================================================================
# MINIMAL PROMPT (Fallback)
# ============================================================================

# If p10k is not loaded, set a minimal prompt
if [[ -z "$P9K_VERSION" ]]; then
    # Mimic p10k style: dir git_status
    setopt PROMPT_SUBST
    autoload -Uz vcs_info
    zstyle ':vcs_info:*' enable git
    zstyle ':vcs_info:git:*' formats ' %b'

    precmd() {
        vcs_info
    }

    # Simple colored prompt
    # %F{blue}%~%f: Current directory in blue
    # %F{green}${vcs_info_msg_0_}%f: Git branch in green
    # %#: Prompt char
    PROMPT='%F{blue}%~%f%F{green}${vcs_info_msg_0_}%f %# '
fi

# Load p10k config if available
[[ ! -f ${ZDOTDIR:-$HOME}/.p10k.zsh ]] || source ${ZDOTDIR:-$HOME}/.p10k.zsh

# ---- Colorized Output (grc) ----
if command -v grc >/dev/null 2>&1; then
  alias colorize='command grc -es --colour=auto'

  # Find grc config directory (cross-platform)
  # shellcheck disable=SC1073,SC1072  # Anonymous function syntax is zsh-specific
  () {
    local grc_conf_dir=""
    for dir in /opt/homebrew/share/grc /usr/share/grc /usr/local/share/grc /home/linuxbrew/.linuxbrew/share/grc; do
      [[ -d "$dir" ]] && { grc_conf_dir="$dir"; break; }
    done

    if [[ -n "$grc_conf_dir" ]]; then
      # Auto-discover all available grc configurations and create aliases for them
      # shellcheck disable=SC2206  # Zsh globbing with qualifiers
      local -a available_configs=($grc_conf_dir/conf.*(N:t:s/conf.//))

      for cmd in "${available_configs[@]}"; do
        case "$cmd" in
          # Skip configs that aren't actual commands
          common|dummy|esperanto|log|lolcat) continue ;;
          # Special cases that need custom handling
          configure)
            configure() { command grc -es --colour=auto ./configure "$@"; }
            ;;
          make)
            # Function wrapper to preserve completion
            make() { command grc -es --colour=auto make "$@"; }
            ;;
          *)
            # Skip if command already has an alias (e.g., ls=eza)
            if ! alias "$cmd" >/dev/null 2>&1; then
              # Standard alias for all other commands
              # shellcheck disable=SC2139  # Intentional expansion at definition time
              alias "$cmd"="colorize $cmd"
            fi
            ;;
        esac
      done
    fi
  }
fi
