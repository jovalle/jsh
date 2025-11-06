#
# .zshrc - Zsh Configuration
#
# Load Order:
#   1. Essential Exports
#   2. Plugin System (Zinit + theme)
#   3. Shell Options & Keybindings
#   4. Completion System
#   5. Fast Integrations
#   6. Lazy-Load Infrastructure
#   7. Helper Functions
#   8. Shell Functions
#   9. Shell Aliases
#  10. Theme Customization
#  11. Local Customizations
#

# ============================================================================
# 1. ESSENTIAL EXPORTS
# ============================================================================

# Core paths and editors
export CLICOLORS=1                          # Colorize output
export EDITOR=vim                           # Default CLI editor
export VISUAL=vim                           # Default full-screen editor
export TERM=xterm-256color                  # Terminal type for 256 colors
export SH=${SHELL##*/}                      # Shell type reference

# Project/work directories
export GIT_BASE=$HOME/projects              # Git projects base
export WORK_DIR=$HOME/projects              # Default work directory
export JSH=${JSH_ROOT:-$HOME}/.jsh          # Ideal JSH location
export JSH_CUSTOM=$JSH/.jsh_local           # Local overrides (optional)

# Paths - ORDER MATTERS (priority: local > jsh > system)
export PATH=$HOME/.local/bin:$JSH/.bin:$JSH/.fzf/bin:$HOME/go/bin:$PATH

# Tool roots
export FZF_ROOT=${FZF_ROOT:-$HOME/.fzf}
export KREW_ROOT=${KREW_ROOT:-$HOME/.krew}

# Silence/optimize specific tools
export DIRENV_LOG_FORMAT=                   # Silence direnv for p10k
export GITSTATUS_RESPONSE_TIMEOUT=5         # Quick timeout for git status
export DIRENV_WARN_TIMEOUT=30s              # Direnv timeout
export PYTHONDONTWRITEBYTECODE=1            # No .pyc files on import
export SOPS_AGE_KEY_FILE=$HOME/.sops/age.agekey
export SSHRC_EXTRAS='.inputrc .tmux.conf .vimrc'

# Zinit
export ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Terminal optimizations
export LESS="-RXE"                          # No wrapping, no clearing, exit on EOF
setopt NO_PROMPT_CR                         # Don't add CR before prompt

# ============================================================================
# 2. PLUGIN SYSTEM - Zinit (must be early for theme)
# ============================================================================

# Download Zinit if missing
if [[ ! -d "$ZINIT_HOME" ]]; then
  mkdir -p "$(dirname "$ZINIT_HOME")"
  git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Initialize Zinit
source "$ZINIT_HOME/zinit.zsh"

# Load theme (Powerlevel10k - instant prompt must be here)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

zinit ice depth=1
zinit light romkatv/powerlevel10k

# Load plugins
zinit light Aloxaf/fzf-tab                  # Enhanced tab completion with fzf
zinit light zsh-users/zsh-completions      # Additional completions
zinit light zsh-users/zsh-autosuggestions  # Command suggestions from history
zinit light zsh-users/zsh-syntax-highlighting  # Syntax highlighting

# ============================================================================
# 3. SHELL OPTIONS & KEYBINDINGS
# ============================================================================

# Vi mode with sensible keybindings
bindkey -v

# Incremental search in vi mode
bindkey -M vicmd '^R' history-incremental-search-backward
bindkey -M vicmd '^S' history-incremental-search-forward
bindkey -M viins '^R' history-incremental-search-backward
bindkey -M viins '^S' history-incremental-search-forward

# Delete key fixes for vi mode
bindkey -M vicmd '^[[3~' delete-char
bindkey -M viins '^[[3~' delete-char

# Shell options (all at once)
setopt COMPLETE_IN_WORD extended_history hist_find_no_dups hist_ignore_all_dups \
        hist_ignore_dups hist_ignore_space hist_save_no_dups INTERACTIVE_COMMENTS \
        NO_BEEP NOBGNICE HUP INC_APPEND_HISTORY SHARE_HISTORY

# History configuration
export HISTSIZE=50000                           # Number of commands to keep in memory
export HISTFILE="$JSH/.zsh_history"             # Store in syncthing-synced directory
export SAVEHIST=50000                           # Number of commands to save to file
export HISTDUP=erase                            # Erase duplicates
export HIST_STAMPS=iso                          # Timestamp format

# Completion options
LISTMAX=0                                   # Automatically paginate completions
MAILCHECK=0                                 # Disable mail checking

# ============================================================================
# 4. COMPLETION SYSTEM
# ============================================================================

# Initialize completion system
autoload -Uz compinit && compinit

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'  # Case insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"  # Use LS_COLORS
zstyle ':completion:*' menu no                           # Don't show menu by default

# Fzf-tab preview settings
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

# Replay cached completions from plugins
zinit cdreplay -q

# ============================================================================
# 5. FAST INTEGRATIONS
# ============================================================================

# FZF
if [[ -x "$FZF_ROOT/bin/fzf" ]]; then
  export PATH="$FZF_ROOT/bin:$PATH"
  source <(fzf --zsh) 2>/dev/null
fi

# Homebrew
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
  source <(/home/linuxbrew/.linuxbrew/bin/brew shellenv)
elif [[ -x /opt/homebrew/bin/brew ]]; then
  source <(/opt/homebrew/bin/brew shellenv)
fi

# Krew (Kubernetes plugin manager)
if [[ -d "$KREW_ROOT" ]]; then
  export PATH="${KREW_ROOT}/bin:$PATH"
fi

# ============================================================================
# 6. LAZY-LOAD INFRASTRUCTURE
# ============================================================================

# Helper: Lazy-load eval-based initializers (zoxide, direnv, etc.)
_lazy_load_eval() {
  local cmd="$1" init="$2"
  command -v "$cmd" &>/dev/null && eval "$(eval "$init")" 2>/dev/null
}

# Helper: Lazy-load completion-based tools (kubectl, helm, etc.)
_lazy_load_completion() {
  local cmd="$1" completion_args="$2"
  command -v "$cmd" &>/dev/null && eval "
    $cmd() {
      unfunction $cmd
      source <(command $cmd $completion_args)
      $cmd \"\$@\"
    }
  "
}

# Helper: Lazy-load activation-based tools (mise, nvm, etc.)
_lazy_load_function() {
  local cmd="$1" activate="$2"
  command -v "$cmd" &>/dev/null && eval "
    $cmd() {
      unfunction $cmd
      eval \"\$($activate)\"
      $cmd \"\$@\"
    }
  "
}

# ============================================================================
# 6a. LAZY-LOAD CONFIGURATION
# ============================================================================
# Add expensive operations here - they only initialize on first use
#
# For eval-based init (outputs shell commands):
#   _lazy_load_eval "command" "command init zsh"
#
# For completion-based (generates completions):
#   _lazy_load_completion "command" "completion zsh"
#
# For activation-based (runs activate script):
#   _lazy_load_function "command" "command activate zsh"
#

# Directory jumping - Zoxide
_lazy_load_eval "zoxide" "zoxide init zsh"

# Runtime version manager - Mise
_lazy_load_function "mise" "command mise activate zsh"

# Kubernetes CLI - kubectl
_lazy_load_completion "kubectl" "completion zsh"

# Directory environment manager - direnv
_lazy_load_eval "direnv" "direnv hook zsh"

# Helm chart manager - helm
_lazy_load_completion "helm" "completion zsh"

# Node Version Manager - nvm
_lazy_load_function "nvm" "command nvm"

# Cleanup helper functions
unfunction _lazy_load_eval _lazy_load_completion _lazy_load_function 2>/dev/null

# ============================================================================
# 7. HELPER FUNCTIONS - Color Output
# ============================================================================

# Color palette for output formatting
if command -v tput &>/dev/null; then
  error() { echo -e "$(tput setaf 1)$*$(tput sgr0)"; }      # Red
  warn() { echo -e "$(tput setaf 3)$*$(tput sgr0)"; }       # Yellow/Orange
  success() { echo -e "$(tput setaf 2)$*$(tput sgr0)"; }    # Green
  info() { echo -e "$(tput setaf 4)$*$(tput sgr0)"; }       # Blue
else
  error() { echo -e "\033[31m$*\033[0m"; }                  # Red
  warn() { echo -e "\033[33m$*\033[0m"; }                   # Yellow
  success() { echo -e "\033[32m$*\033[0m"; }                # Green
  info() { echo -e "\033[34m$*\033[0m"; }                   # Blue
fi

# ============================================================================
# 8. SHELL FUNCTIONS - Core Utilities
# ============================================================================

# ---- System & Process Management ----

caffeinate() { gnome-session-inhibit --inhibit idle:sleep sleep infinity; }
ffpid() { lsof -t -c "$@"; }
quiet() { [[ $# == 0 ]] && &> /dev/null || "$*" &> /dev/null; }

# ---- Directory & File Operations ----

duh() {
  if [[ $(uname) == "Darwin" ]]; then
    du -hd 1 "${1:-.}" | sort -h
  else
    du -h --max-depth=1 "${1:-.}" | sort -h
  fi
}

extract() {
  if [[ ! -f "$1" ]]; then
    error "'$1' is not a valid file"
    return 1
  fi
  case "$1" in
    *.tar.bz2)   tar xjf "$1"     ;;
    *.tar.gz)    tar xzf "$1"     ;;
    *.bz2)       bunzip2 "$1"     ;;
    *.rar)       unrar e "$1"     ;;
    *.gz)        gunzip "$1"      ;;
    *.tar)       tar xf "$1"      ;;
    *.tbz2)      tar xjf "$1"     ;;
    *.tgz)       tar xzf "$1"     ;;
    *.zip)       unzip "$1"       ;;
    *.Z)         uncompress "$1"  ;;
    *.7z)        7z x "$1"        ;;
    *)           error "'$1' cannot be extracted"; return 1 ;;
  esac
}

ff() { /usr/bin/find . -name "$@"; }
ffs() { /usr/bin/find . -name "$@"'*'; }
ffe() { /usr/bin/find . -name '*'"$@"; }

# ---- Git Utilities ----

http2ssh() {
  REPO_URL=$(git remote -v | grep -m1 '^origin' | sed -Ene's#.*(https://[^[:space:]]*).*#\1#p')
  [[ -z "$REPO_URL" ]] && { error "Could not identify repo URL"; return 1; }

  USER=$(echo "$REPO_URL" | sed -Ene's#https://github.com/([^/]*)/(.*)#\1#p')
  [[ -z "$USER" ]] && { error "Could not identify user"; return 2; }

  REPO=$(echo "$REPO_URL" | sed -Ene's#https://github.com/([^/]*)/(.*)#\2#p')
  [[ -z "$REPO" ]] && { error "Could not identify repo"; return 3; }

  NEW_URL="git@github.com:$USER/$REPO"
  warn "Changing repo URL from: '$REPO_URL' to: '$NEW_URL'"

  git remote set-url origin "$NEW_URL" && success "New URL set" || error "Failed to set URL"
}

# ---- Kubernetes Utilities ----

nukem() {
  [[ -z "$1" ]] && { echo "Usage: $0 <namespace>"; return 1; }
  warn "Removing finalizers from namespace: $1"
  kubectl get namespace "$1" -o json | tr -d "\n" | \
    sed "s/\"finalizers\": \[[^]]\+\]/\"finalizers\": []/" | \
    kubectl replace --raw "/api/v1/namespaces/$1/finalize" -f - && \
    success "Finalizers removed" || error "Failed"
}

# ---- IPMI & Hardware Management ----

ipmi() {
  [[ -z "${IPMI_HOST}" || -z "${IPMI_USER}" || -z "${IPMI_CRED_FILE}" ]] && \
    { error "IPMI env vars not set"; return 1; }
  [[ $1 == "fan" ]] || { ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" "$@"; return; }
  ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x01 0x00
  [[ $# -eq 2 ]] && ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x02 0xff 0x$(printf '%x\n' "$2") || \
    { error "Usage: ipmi fan <speed_0-255>"; return 1; }
}

# ---- Networking & Proxy ----

proxy() {
  local PROXY="${PROXY_ENDPOINT:-go,localhost}"
  env http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" \
      NO_PROXY="$PROXY" no_proxy="$PROXY" "$@"
}

# ---- Remote Development ----

rcode() {
  [[ $# -ne 2 ]] && { echo "Usage: rcode <ssh_host> <remote_path>"; return 1; }
  code --remote "ssh-remote+${1}" "${2}"
}

# ============================================================================
# 9. SHELL ALIASES - Quick Commands
# ============================================================================

# ---- Conditional Tool Replacements ----

if command -v eza &>/dev/null; then
  alias ls='eza --git --color=always --icons=always'
else
  alias ls='ls --color=always'
fi

[[ -x /usr/bin/vim || -x /opt/homebrew/bin/vim ]] && alias vi='vim'
command -v nvim &>/dev/null && alias vim='nvim'
command -v hx &>/dev/null && alias vim='hx'

# ---- Directory Navigation ----

alias ..='cd ../' .2='cd ../../' .3='cd ../../../' .4='cd ../../../../' .5='cd ../../../../../' .6='cd ../../../../../../'
alias cd..='cd ./' l='ls -la' d='dirs -v | head -10' work='cd ${WORK_DIR:-${HOME}}'

# ---- File Operations ----

alias cp='cp -iv' mv='mv -iv' rm='rm -i' mkdir='mkdir -pv' t='touch' dud='du -d 1 -h' duf='du -sh *'

# ---- Permissions ----

alias 000='chmod 000' 640='chmod 640' 644='chmod 644' 755='chmod 755' 775='chmod 775' mx='chmod a+x'

# ---- Terminal & System ----

alias c='clear' ccd='clear && cd' e='exit' fix_stty='stty sane' epochtime='date +%s'
alias ts='date +%F-%H%M' timestamp='date "+%Y%m%dT%H%M%S"'

# ---- System Information ----

alias path='echo -e ${PATH//:/\\n}' perm='stat --printf "%a %n \n "' whatis='declare -f' which='type -a'
alias h='history' w='watch -n1 -d -t ' glances='glances -1 -t 0.5'

# ---- Networking & Utilities ----

alias curl='curl -w "\n"' wget='wget -c' less='less -FSRXc'

# ---- Superuser ----

alias _='sudo' sudo='sudo ' please='sudo '

# ---- System Commands ----

alias nano='nano -W' grep='grep --color=auto -i' g='grep --color=auto -i' edit='vim'

# ---- Git ----

alias g_='git commit -m' git+='git push --set-upstream origin $(git rev-parse --abbrev-ref HEAD)'
alias git-='git reset HEAD~1' gl='git log --graph --oneline' gdiff='git diff --name-only master'
alias gvimdiff='git difftool --tool=vimdiff --no-prompt'

# ---- Kubernetes ----

alias k='kubectl' kav='kubectl api-versions' kci='kubectl cluster-info' kctx='kubectx' kns='kubens'
alias kdf='kubectl delete -f' kexec='kubectl exec -it' netshoot='kubectl run tmp-shell --rm -i --tty --image nicolaka/netshoot'
alias kenc="sops --age $(cat ${SOPS_AGE_KEY_FILE} | grep -oP 'public key: \K(.*)') --encrypt --encrypted-regex '^(data|stringData)$' --in-place"

# ---- Infrastructure & Tools ----

alias a='ansible' ap='ansible-playbook' av='ansible-vault' tf='terraform' pn='pnpm'

# ---- SSH & Remote ----

alias sshx='eval $(ssh-agent) && ssh-add 2>/dev/null' stowrm='find $HOME -maxdepth 1 -type l | xargs -I {} unlink {}'
alias proxy+='export {{http,https}_proxy,{HTTP,HTTPS}_PROXY}=${PROXY_ENDPOINT}; export {NO_PROXY,no_proxy}=${PROXY_ENDPOINT:-go,localhost}'
alias proxy-='unset {http,https}_proxy {HTTP,HTTPS}_PROXY {NO_PROXY,no_proxy}' vscode='open -a "Visual Studio Code"'

# ---- Conditional Colorized Output (grc) ----

if command -v grc &>/dev/null; then
  alias colorize='grc -es --colour=auto'
  alias as='colorize as' configure='colorize ./configure' df='colorize df' diff='colorize diff'
  alias dig='colorize dig' g++='colorize g++' gas='colorize gas' gcc='colorize gcc' head='colorize head'
  alias ld='colorize ld' make='colorize make' mount='colorize mount' mtr='colorize mtr' netstat='colorize netstat'
  alias ping='colorize ping' ps='colorize ps' tail='colorize tail' traceroute='colorize /usr/sbin/traceroute'
fi

# ---- Development & Tmux ----

alias vz='vim ~/.zshrc' show_options='shopt' tmux='tmux -2'

# ============================================================================
# 10. THEME CUSTOMIZATION (after plugins loaded)
# ============================================================================

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ============================================================================
# 11. LOCAL CUSTOMIZATIONS (last - overrides everything)
# ============================================================================

[[ -f "${JSH_CUSTOM}" ]] && source "${JSH_CUSTOM}"
