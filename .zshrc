# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Default environment variables
export CLICOLORS=1 # Colorize as much as possible
export DEFAULT_REMOTE_HOST=mothership # My go-to `rcode` shortcut
export DIRENV_LOG_FORMAT= # Silence direnv for p10k
export EDITOR=vim # Line editor
export JSH=$HOME/.jsh # Ideal location
export JSH_CUSTOM=$HOME/.jsh_local # Ideal location
export JSH_VERSION=$(cat $JSH/VERSION) # Not used
export PATH=$JSH/.bin:$HOME/go/bin:$PATH # Add included bins/scripts and ideal go path
export PYTHONDONTWRITEBYTECODE=1 # No .pyc files when importing
export SH=${SHELL##*/} # For reference
export SSHRC_EXTRAS='.inputrc .tmux.conf .vimrc' # Files to take on SSHRC sessions
export SOPS_AGE_KEY_FILE=$HOME/.sops/age.agekey # May not exist
export VISUAL=vim # Full screen editor

# Local variables and overrides
[ -f "$JSH_CUSTOM" ] && source "$JSH_CUSTOM"

# Set the directory we want to store zinit and plugins
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Download Zinit, if it's not there yet
if [ ! -d "$ZINIT_HOME" ]; then
   mkdir -p "$(dirname $ZINIT_HOME)"
   git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Source/Load zinit
source "$ZINIT_HOME/zinit.zsh"

# Load Powerlevel10k theme
zinit ice depth=1; zinit light romkatv/powerlevel10k

# Load zsh plugins
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-autosuggestions
zinit light Aloxaf/fzf-tab

# Pull and build direnv once
zinit as"program" make'!' atclone'./direnv hook zsh > zhook.zsh' \
    atpull'%atclone' pick"direnv" src"zhook.zsh" for \
        direnv/direnv

# Load snippets
zinit snippet OMZP::git
zinit snippet OMZP::archlinux
zinit snippet OMZP::aws
zinit snippet OMZP::kubectl
zinit snippet OMZP::kubectx
zinit snippet OMZP::command-not-found

# Load completions
autoload -Uz compinit && compinit
source <(kubectl completion zsh)

# Replay cached completions
zinit cdreplay -q

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Keybindings for vim mode
bindkey -v
bindkey ^R history-incremental-search-backward
bindkey ^S history-incremental-search-forward

# History
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

# Color palette
if [[ $(uname) == 'Darwin' || $(command -v tput &>/dev/null) ]]; then
  black="\001$(tput setaf 0)\002"
  red="\001$(tput setaf 1)\002"
  green="\001$(tput setaf 2)\002"
  orange="\001$(tput setaf 3)\002"
  blue="\001$(tput setaf 4)\002"
  purple="\001$(tput setaf 5)\002"
  cyan="\001$(tput setaf 6)\002"
  lightgray="\001$(tput setaf 7)\002"
  darkgray="\001$(tput setaf 8)\002"
  pink="\001$(tput setaf 9)\002"
  lime="\001$(tput setaf 10)\002"
  yellow="\001$(tput setaf 11)\002"
  aqua="\001$(tput setaf 12)\002"
  lavender="\001$(tput setaf 13)\002"
  ice="\001$(tput setaf 14)\002"
  white="\001$(tput setaf 15)\002"
  bold="\001$(tput bold)\002"
  underline="\001$(tput smul)\002"
  reset="\001$(tput sgr0)\002"
else
  black="\033[30m"
  red="\033[31m"
  green="\033[32m"
  orange="\033[33m"
  blue="\033[34m"
  purple="\033[35m"
  cyan="\033[36m"
  lightgray="\033[37m"
  darkgray="\033[90m"
  pink="\033[91m"
  lime="\033[92m"
  yellow="\033[93m"
  aqua="\033[94m"
  lavender="\033[95m"
  ice="\033[96m"
  white="\033[97m"
  bold="\033[1m"
  underline="\033[4m"
  reset="\033[0m"
fi

# Color helper functions
abort() { echo; echo "${red}$@${reset}" 1>&2; exit 1; } # show
error() { echo -e ${red}$@${reset}; return 1; }
warn() { echo -e ${orange}$@${reset}; }
success() { echo -e ${green}$@${reset}; }
info() { echo -e ${blue}$@${reset}; }

# More elaborate coloring
if [[ $(which grc 2>/dev/null) == 0 ]]; then
  alias colorize="$(which grc) -es --colour=auto"
  alias as='colorize as'
  alias configure='colorize ./configure'
  alias df='colorize df'
  alias diff='colorize diff'
  alias dig='colorize dig'
  alias g++='colorize g++'
  alias gas='colorize gas'
  alias gcc='colorize gcc'
  alias head='colorize head'
  alias ld='colorize ld'
  alias make='colorize make'
  alias mount='colorize mount'
  alias mtr='colorize mtr'
  alias netstat='colorize netstat'
  alias ping='colorize ping'
  alias ps='colorize ps'
  alias tail='colorize tail'
  alias traceroute='colorize /usr/sbin/traceroute'
fi

# Aliases
alias ..='cd ../' # Go back 1 directory level
alias .2='cd ../../' # Go back 2 directory levels
alias .3='cd ../../../' # Go back 3 directory levels
alias .4='cd ../../../../' # Go back 4 directory levels
alias .5='cd ../../../../../' # Go back 5 directory levels
alias .6='cd ../../../../../../' # Go back 6 directory levels
alias 000='chmod 000' # ---------- (nobody)
alias 640='chmod 640' # -rw-r----- (user: rw, group: r, other: -)
alias 644='chmod 644' # -rw-r--r-- (user: rw, group: r, other: -)
alias 755='chmod 755' # -rwxr-xr-x (user: rwx, group: rx, other: x)
alias 775='chmod 775' # -rwxrwxr-x (user: rwx, group: rwx, other: rx)
alias _='sudo' # Evolve into superuser
alias a='ansible' # Abbreviation
alias ap='ansible-playbook' # Abbreviation
alias av='ansible-vault' # Abbreviation
alias c='clear' # c: Clear terminal display
alias ccd='clear && cd' # Reset shell
alias cd..='cd ../' # Go back 1 directory level (for fast typers)
alias cp='cp -iv' # Preferred 'cp' implementation
alias curl='curl -w "\n"' # Preferred 'curl' implementation
alias d='dirs -v | head -10' # Display dir
alias dud='du -d 1 -h' # Short and human-readable file listing
alias duf='du -sh *' # Short and human-readable directory listing
alias e="exit" # e: Exit
alias edit='vim' # edit: Open any file in vim
alias epochtime='date +%s' # Current epoch time
alias fix_stty='stty sane' # fix_stty: Restore terminal settings when screwed up
alias g='grep --color=auto -i' # grep > git
alias g_="git commit -m" # Git commit
alias gdiff='git diff --name-only master' # List files changed in this branch compared to master
alias gdiffcp='gdiff | xargs -I{} rsync --relative {}' # Copy modified files to another dir
alias gl="git log --graph --oneline" # Easy commit history
alias glances='glances -1 -t 0.5' # Faster output from glances
alias grep='grep --color=auto -i' # Preferred 'grep' implementation
alias gvimdiff='git difftool --tool=vimdiff --no-prompt' # Open all git changes in vimdiff
alias h='history'
alias k='kubectl' # Abbreviate kube control
alias kav='kubectl api-versions' # List all APIs
alias kctx='kubectx' # Change kube context
alias kenc="sops --age \$(cat \${SOPS_AGE_KEY_FILE} | grep -oP \"public key: \K(.*)\") --encrypt --encrypted-regex '^(data|stringData)$' --in-place"
alias kexec='kubectl exec -it' # Open terminal into pod
alias kns='kubens' # Change kube namespace
alias l='ls -la' # Long, show hidden files
alias ls='ls --color' # Show colors
alias less='less -FSRXc' # Preferred 'less' implementation
alias md='mkdir -p' # Create directory
alias mkdir='mkdir -pv' # Preferred 'mkdir' implementation
alias mountReadWrite='/sbin/mount -uw /' # mountReadWrite: For use when booted into single-user
alias mv='mv -iv' # Preferred 'mv' implementation
alias mx='chmod a+x' # ---x--x--x (user: --x, group: --x, other: --x)
alias nano='nano -W' # Preferred 'nano' implementation
alias netshoot='kubectl run tmp-shell --rm -i --tty --image nicolaka/netshoot' # quick pod for troubleshooting
alias passgen='openssl passwd -1' # pass: Generate salted hash for passwords
alias path='echo -e ${PATH//:/\\n}' # path: Echo all executable Paths
alias perm='stat --printf "%a %n \n "' # perm: Show permission of target in number
alias please='sudo ' # Politely ask for superuser
alias pn='pnpm' # Abbreviate pnpm
alias proxy='http_proxy=$PROXY_ENDPOINT https_proxy=$PROXY_ENDPOINT no_proxy=$PROXY_EXCEPTION' # proxy: set as per env and on command
alias rm='rm -i' # Always prompt before deleting
alias show_options='shopt' # Show_options: display bash options settings
alias sshx='eval $(ssh-agent) && ssh-add 2>/dev/null' # sshx: Import SSH keys
alias stowrm='find $HOME -maxdepth 1 -type l | xargs -I {} unlink {}' # stowrm: Remove all symlinks (`stow -D` only removes existing matches)
alias sudo='sudo ' # Enable aliases to be sudo’ed
alias t="touch" # Create file
alias tf='terraform' # Abbreviation
alias timestamp='date "+%Y%m%dT%H%M%S"' # Filename ready complete time format
alias tmux="tmux -2" # Force 256 color support
alias vscode='open -a "Visual Studio Code"' # VSCode shortcut
alias vi='vim' # Preferred 'vi' implementation
alias vz='vi ~/.zshrc' # Open zshrc
alias w='watch -n1 -d -t ' # Faster watch, highlight changes and no title
alias wget='wget -c' # Preferred 'wget' implementation (resume download)
alias whatis='declare -f' # Print function definition
alias which='type -a' # Preferred 'which' implementation

# Conditional aliases (order-specific)
command -v eza >/dev/null 2>&1 && alias ls='eza --git --color=always --icons=always'
command -v nvim >/dev/null 2>&1 && alias vim='nvim'
command -v hx >/dev/null 2>&1 && alias vim='hx'

# Prioritize upstream fzf
export PATH=$HOME/.fzf/bin:$PATH

# Add krew plugins
[ -d ${KREW_ROOT:-$HOME/.krew} ] && export PATH=${KREW_ROOT:-$HOME/.krew}/bin:$PATH

# Shell integrations
[ -f "/opt/homebrew/bin/brew" ] && source <(/opt/homebrew/bin/brew shellenv)
command -v fzf 2>/dev/null 1>&2 && source <(fzf --zsh)
command -v zoxide 2>/dev/null 1>&2 && source <(zoxide init zsh)

# Functions
duh() { # duh: Disk usage per directory, sorted by ascending size
  if [[ $(uname) == "Darwin" ]]; then
    if [[ -n $1 ]]; then
      du -hd 1 "$1" | sort -h
    else
      du -hd 1 | sort -h
    fi
  elif [[ $(uname) == "Linux" ]]; then
    if [[ -n $1 ]]; then
      du -h --max-depth=1 "$1" | sort -h
    else
      du -h --max-depth=1 | sort -h
    fi
  fi
}
extract() { # extract: Extract most know archives with one command
  if [ -f "$1" ]
  then
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
      *)     echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}
ff() { /usr/bin/find . -name "$@" ; }     # ff: Find file under the current directory
ffs() { /usr/bin/find . -name "$@"'*' ; } # ffs: Find file whose name starts with a given string
ffe() { /usr/bin/find . -name '*'"$@" ; } # ffe: Find file whose name ends with a given string
ffpid() { lsof -t -c "$@" } # ffpid: Find pid of matching process
http2ssh() { # http2ssh: Convert gitconfig URL from HTTP(S) to SSH (Credit: github.com/m14t/fix_github_https_repo.sh)
  REPO_URL=$(git remote -v | grep -m1 '^origin' | sed -Ene's#.*(https://[^[:space:]]*).*#\1#p')
  if [ -z "$REPO_URL" ]; then
    error "Could not identify repo url."
    if [ -n "$(grep 'git@github.com' .git/config)" ]; then
      warn "SSH-like url found in gitconfig"
    fi
    return 1
  fi

  USER=$(echo $REPO_URL | sed -Ene's#https://github.com/([^/]*)/(.*)#\1#p')
  if [ -z "$USER" ]; then
    error "Could not identify user"
    return 2
  fi

  REPO=$(echo $REPO_URL | sed -Ene's#https://github.com/([^/]*)/(.*)#\2#p')
  if [ -z "$REPO" ]; then
    error "Could not identify repo"
    return 3
  fi

  NEW_URL="git@github.com:$USER/$REPO"
  warn "Changing repo url from "
  warn "  '$REPO_URL'"
  warn "      to "
  warn "  '$NEW_URL'"
  warn ""

  git remote set-url origin $NEW_URL
  [[ $# ]] && success "Success" || error "Failed to set new URL origin"
}
ipmi() { # ipmi: Common ipmitool shortcuts with no plaintext password
  if [[ $1 == "fan" ]]; then
    ipmitool -I lanplus -H ${IPMI_HOST} -U ${IPMI_USER} -f ${IPMI_CRED_FILE} raw 0x30 0x30 0x01 0x00
    if [[ $# == 2 ]]; then
      ipmitool -I lanplus -H ${IPMI_HOST} -U ${IPMI_USER} -f ${IPMI_CRED_FILE} raw 0x30 0x30 0x02 0xff 0x$(printf '%x\n' $2)
      return $?
    else
      error "example: ipmi fan 20"
    fi
  fi

  ipmitool -I lanplus -H ${IPMI_HOST} -U ${IPMI_USER} -f ${IPMI_CRED_FILE} $@
}
quiet() { [[ $# == 0 ]] && &> /dev/null || "$*" &> /dev/null ; } # quiet: Mute output of a command or redirection
rcode() { code --remote ssh-remote+${1:-${DEFAULT_REMOTE_HOST}} ${2:-/etc/${1:-${DEFAULT_REMOTE_HOST}}} } # rcode: Open remote dir in vscode
