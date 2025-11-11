#
# .zshrc - Zsh Configuration
#
# Load Order:
#   1. Essential Exports
#   2. Plugin System
#   3. Shell Options & Keybindings
#   4. Path Setup
#   5. Completion System
#   6. Helper Functions
#   7. Shell Aliases
#   8. Shell Functions
#   9. Theme Customization
#   10. Path Deduplication
#   11. Local Customizations
#

# ============================================================================
# 1. ESSENTIAL EXPORTS
# ============================================================================

# Core paths and editors
export CLICOLORS=1                               # Colorize output
export EDITOR=vim                                # Default CLI editor
export VISUAL=vim                                # Default full-screen editor
export TERM=xterm-256color                       # Terminal type for 256 colors
export SH=${SHELL##*/}                           # Shell type reference

# Project/work directories
export GIT_BASE=${HOME}/projects                 # Git projects base
export WORK_DIR=${GIT_BASE}                      # Default work directory
export JSH=${JSH_ROOT:-${HOME}}/.jsh             # Ideal JSH location
export JSH_CUSTOM=${HOME}/.jsh_local             # Local overrides (optional)

# Silence/optimize specific tools
export DIRENV_LOG_FORMAT=                        # Silence direnv for p10k
export GITSTATUS_RESPONSE_TIMEOUT=5              # Quick timeout for git status
export DIRENV_WARN_TIMEOUT=30s                   # Direnv timeout
export PYTHONDONTWRITEBYTECODE=1                 # No .pyc files on import
export SSHRC_EXTRAS='.inputrc .tmux.conf .vimrc' # Files to import on SSH

# Shell environment
export LANG=en_US.UTF-8                          # Default locale
export LC_ALL=en_US.UTF-8                        # Override all locales
export XDG_CONFIG_HOME="${HOME}/.config"         # Wwhere apps should store config files, cache files, and data files

# Zinit
export ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# fzf
export FZF_BASE="${JSH}/.fzf"

# Terminal optimizations
export LESS="-RXE"                          # No wrapping, no clearing, exit on EOF
setopt NO_PROMPT_CR                         # Don't add CR before prompt

# ============================================================================
# 2. PLUGIN SYSTEM
# ============================================================================

# Verify fzf is available (should be initialized as submodule via setup.sh)
if [[ ! -d "${FZF_BASE}" ]]; then
  warn "fzf submodule not found. Run: git submodule update --init"
fi

# Download Zinit if missing
if [[ ! -d "${ZINIT_HOME}" ]]; then
  mkdir -p "$(dirname "${ZINIT_HOME}")"
  git clone https://github.com/zdharma-continuum/zinit.git "${ZINIT_HOME}"
fi

# Initialize Zinit
# shellcheck disable=SC1091  # Dynamic source, path verified above
source "${ZINIT_HOME}/zinit.zsh"

# Load theme (Powerlevel10k - instant prompt must be here)
# shellcheck disable=SC2296  # Zsh-specific parameter expansion syntax
if [[ -r "${XDG_CACHE_HOME:-${HOME}/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  # shellcheck disable=SC1090  # Dynamic source, path depends on runtime vars
  source "${XDG_CACHE_HOME:-${HOME}/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

zinit ice depth=1
zinit light romkatv/powerlevel10k

# Load plugins
zinit light Aloxaf/fzf-tab                    # Enhanced tab completion with fzf
zinit light zsh-users/zsh-completions         # Additional completions
zinit light zsh-users/zsh-autosuggestions     # Command suggestions from history
zinit light zsh-users/zsh-syntax-highlighting # Syntax highlighting

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
export HISTDUP=erase                  # Erase duplicates
export HISTFILE="${JSH}/.zsh_history" # Store in syncthing-synced directory
export HISTSIZE=50000                 # Number of commands to keep in memory
export HIST_STAMPS=iso                # Timestamp format
export SAVEHIST=50000                 # Number of commands to save to file

# Completion options
LISTMAX=0                           # Automatically paginate completions
export LISTMAX                      # Used by zsh completion system
MAILCHECK=0                         # Disable mail checking

# ============================================================================
# 4. PATH SETUP
# ============================================================================

# Paths - ORDER MATTERS (priority: local > jsh > system)
# Must be set before tool completions to ensure binaries are found
export PATH=${HOME}/.local/bin:${JSH}/.bin:${JSH}/.fzf/bin:${HOME}/go/bin:${PATH}

# ============================================================================
# 5. COMPLETION SYSTEM
# ============================================================================

# Add custom completions directory to fpath
fpath=(~/.zsh/completions "${fpath[@]}")

# Initialize completion system
autoload -Uz compinit && compinit

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'  # Case insensitive
# shellcheck disable=SC2296  # Zsh-specific parameter expansion syntax
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}" # Use LS_COLORS
zstyle ':completion:*' menu no                          # Don't show menu by default

# Fzf-tab preview settings
zstyle ':fzf-tab:complete:cd:*' fzf-preview "ls --color \$realpath"

# Replay cached completions from plugins
zinit cdreplay -q

# ---- Tool Completions ----

command -v brew &>/dev/null && eval "$(brew shellenv)"
command -v direnv &>/dev/null && eval "$(direnv hook zsh)"
command -v docker &>/dev/null && eval "$(docker completion zsh)"
# shellcheck disable=SC1090  # Dynamic source from fzf
command -v fzf &>/dev/null && source <(command fzf --zsh)
# shellcheck disable=SC1090  # Dynamic source from kubectl
command -v kubectl &>/dev/null && source <(kubectl completion zsh)
# shellcheck disable=SC1090  # Dynamic source from task
command -v task &>/dev/null && source <(task --completion zsh)
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

# ============================================================================
# 6. HELPER FUNCTIONS
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
# 7. SHELL ALIASES
# ============================================================================

# ---- Directory Navigation ----

alias ..='cd ../' .2='cd ../../' .3='cd ../../../' .4='cd ../../../../' .5='cd ../../../../../' .6='cd ../../../../../../'

# ---- File Operations ----

alias cp='cp -iv' mv='mv -iv' rm='rm -i' mkdir='mkdir -pv' t='touch' dud='du -d 1 -h' duf='du -sh *'
alias ls='ls -a' l='ls -l' ll='ls -la' lll='ls -laFh'
alias psg='ps aux | grep -i' psl='ps aux | less'

# ---- Permissions ----

alias 000='chmod 000' 640='chmod 640' 644='chmod 644' 755='chmod 755' 775='chmod 775' mx='chmod a+x'

# ---- Terminal & System ----

alias c='clear' ccd='clear && cd' e='exit' fix_stty='stty sane' epochtime='date +%s'
alias ts='date +%F-%H%M' timestamp='date "+%Y%m%dT%H%M%S"'

# ---- System Information ----

alias path='echo -e ${PATH//:/\\n}' perm='stat --printf "%a %n \n "' whatis='declare -f' which='type -a'
alias h='history' w='watch -n1 -d -t ' glances='glances -1 -t 0.5'

# ---- Superuser ----

alias _='sudo' please='sudo'

# ---- System Commands ----

alias g='grep -i' edit='vim' v='vim'

# ---- Git ----

alias g_='git commit -m' git+='git push --set-upstream origin $(git rev-parse --abbrev-ref HEAD)'
alias git-='git reset HEAD~1' gl='git log --graph --oneline' gdiff='git diff --name-only master'
alias gvimdiff='git difftool --tool=vimdiff --no-prompt'

# ---- Kubernetes ----

alias k='kubectl' kav='kubectl api-versions' kci='kubectl cluster-info' kctx='kubectx' kns='kubens'
alias kctx+='kubectx --add' kctx-='kubectx --delete'
alias kdf='kubectl delete -f' kexec='kubectl exec -it' netshoot='kubectl run tmp-shell --rm -i --tty --image nicolaka/netshoot'

# ---- Infrastructure & Tools ----

alias a='ansible' ap='ansible-playbook' av='ansible-vault' tf='terraform' pn='pnpm'

# ---- SSH & Remote ----

alias sshx='eval $(ssh-agent) && ssh-add 2>/dev/null'
alias proxy+='export {{http,https}_proxy,{HTTP,HTTPS}_PROXY}=${PROXY_ENDPOINT}; export {NO_PROXY,no_proxy}=${PROXY_ENDPOINT:-go,localhost}'
alias proxy-='unset {http,https}_proxy {HTTP,HTTPS}_PROXY {NO_PROXY,no_proxy}'

# ---- Colorized Output ----

if command -v grc &>/dev/null; then
  alias colorize='grc -es --colour=auto'

  # Find grc config directory (cross-platform)
  # shellcheck disable=SC1073,SC1072  # Anonymous function syntax is zsh-specific
  () {
    local grc_conf_dir=""
    for dir in /opt/homebrew/share/grc /usr/share/grc /usr/local/share/grc; do
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
            if ! alias "$cmd" &>/dev/null; then
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

# ---- Development & Tmux ----

alias vz='vim ~/.zshrc' show_options='shopt' tmux='tmux -2'

# ---- Tool Replacements ----

command -v bat &>/dev/null && alias cat='bat'
command -v eza &>/dev/null && alias ls='eza -a -l --git --icons' l='ls' ll='eza --git --icons --level=2 --long --tree --long' lll='eza --git --icons --long --tree'
command -v gawk &>/dev/null && alias awk='gawk'
command -v ggrep &>/dev/null && alias grep='ggrep --color=auto -i'
command -v gsed &>/dev/null && alias sed='gsed'
command -v hx &>/dev/null && alias vim='hx'
command -v nvim &>/dev/null && alias vim='nvim'
command -v vim &>/dev/null && alias vi='vim'
command -v zoxide &>/dev/null && alias cd='z'

# ============================================================================
# 8. SHELL FUNCTIONS
# ============================================================================

# ---- System & Process Management ----

caffeinate() { gnome-session-inhibit --inhibit idle:sleep sleep infinity; }
ffpid() { lsof -t -c "$@"; }
quiet() {
  if [[ $# -eq 0 ]]; then
    return
  else
    "$@" &> /dev/null
  fi
}

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
ffs() { /usr/bin/find . -name "$*"'*'; }
ffe() { /usr/bin/find . -name '*'"$*"; }

# ---- Git Utilities ----

http2ssh() {
  REPO_URL=$(git remote -v | grep -m1 '^origin' | sed -Ene's#.*(https://[^[:space:]]*).*#\1#p')
  [[ -z "${REPO_URL}" ]] && { error "Could not identify repo URL"; return 1; }

  USER=$(echo "${REPO_URL}" | sed -Ene's#https://github.com/([^/]*)/(.*)#\1#p')
  [[ -z "${USER}" ]] && { error "Could not identify user"; return 2; }

  REPO=$(echo "${REPO_URL}" | sed -Ene's#https://github.com/([^/]*)/(.*)#\2#p')
  [[ -z "${REPO}" ]] && { error "Could not identify repo"; return 3; }

  NEW_URL="git@github.com:${USER}/${REPO}"
  warn "Changing repo URL from: '${REPO_URL}' to: '${NEW_URL}'"

  if git remote set-url origin "${NEW_URL}"; then
    success "New URL set"
  else
    error "Failed to set URL"
    return 4
  fi
}

# ---- Kubernetes Utilities ----

nukem() {
  [[ -z "$1" ]] && { echo "Usage: $0 <namespace>"; return 1; }
  warn "Removing finalizers from namespace: $1"
  if kubectl get namespace "$1" -o json | tr -d "\n" | \
    sed "s/\"finalizers\": \[[^]]\+\]/\"finalizers\": []/" | \
    kubectl replace --raw "/api/v1/namespaces/$1/finalize" -f -; then
    success "Finalizers removed"
  else
    error "Failed"
    return 2
  fi
}

# ---- IPMI & Hardware Management ----

ipmi() {
  [[ -z "${IPMI_HOST}" || -z "${IPMI_USER}" || -z "${IPMI_CRED_FILE}" ]] && \
    { error "IPMI env vars not set"; return 1; }
  [[ $1 == "fan" ]] || { ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" "$@"; return; }
  ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x01 0x00
  if [[ $# -eq 2 ]]; then
    local hex_speed
    hex_speed=$(printf '%x\n' "$2")
    ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x02 0xff "0x${hex_speed}"
  else
    error "Usage: ipmi fan <speed_0-255>"
    return 1
  fi
}

# ---- Networking & Proxy ----

proxy() {
  local PROXY="${PROXY_ENDPOINT:-go,localhost}"
  env http_proxy="${PROXY}" https_proxy="${PROXY}" HTTP_PROXY="${PROXY}" HTTPS_PROXY="${PROXY}" \
      NO_PROXY="${PROXY}" no_proxy="${PROXY}" "$@"
}

# ---- Remote Development ----

rcode() {
  [[ $# -ne 2 ]] && { echo "Usage: rcode <ssh_host> <remote_path>"; return 1; }
  code --remote "ssh-remote+${1}" "${2}"
}

# ============================================================================
# 9. THEME CUSTOMIZATION
# ============================================================================

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
# shellcheck disable=SC1090  # Dynamic source, standard p10k config
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ============================================================================
# 10. PATH DEDUPLICATION
# ============================================================================

# Function to remove duplicate PATH entries while preserving order
dedup_path() {
  # shellcheck disable=SC2296  # Zsh-specific parameter expansion syntax
  local path_array=("${(s/:/)PATH}")
  local -A seen
  local clean_path=""

  for dir in "${path_array[@]}"; do
    if [[ -n "${dir}" ]] && [[ -z "${seen[${dir}]}" ]]; then
      seen[${dir}]=1
      if [[ -z "${clean_path}" ]]; then
        clean_path="${dir}"
      else
        clean_path="${clean_path}:${dir}"
      fi
    fi
  done

  export PATH="${clean_path}"
}

# Deduplicate PATH entries
dedup_path

# ============================================================================
# 11. LOCAL CUSTOMIZATIONS
# ============================================================================

# shellcheck disable=SC1090  # Dynamic source for local customizations
[[ -f "${JSH_CUSTOM}" ]] && source "${JSH_CUSTOM}"
