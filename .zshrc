#
# .zshrc is sourced in interactive shells.
# Home to env vars, shell tweaks, keybindings, aliases, and functions.
#

# Default environment variables
export CLICOLORS=1 # Colorize as much as possible
export DEFAULT_REMOTE_HOST=mothership # My go-to `rcode` shortcut
export DIRENV_LOG_FORMAT= # Silence direnv for p10k
export EDITOR=vim # Line editor
export GIT_BASE=$HOME/projects
export JSH=${JSH_ROOT:-$HOME}/.jsh # Ideal location
export JSH_CUSTOM=$JSH/.jsh_local # Ideal location
export JSH_VERSION=$(cat $JSH/VERSION) # Not used
export PATH=$HOME/.local/bin:$JSH/.bin:$JSH/.fzf/bin:$HOME/go/bin:$PATH # Add included bins/scripts and ideal go path
export PYTHONDONTWRITEBYTECODE=1 # No .pyc files when importing
export SH=${SHELL##*/} # For reference
export SSHRC_EXTRAS='.inputrc .tmux.conf .vimrc' # Files to take on SSHRC sessions
export SOPS_AGE_KEY_FILE=$HOME/.sops/age.agekey # May not exist
export VISUAL=vim # Full screen editor
export WORK_DIR=$HOME/projects # Default work directory
export ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git" # Set the directory we want to store zinit and plugins

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Download Zinit, if it's not there yet
if [ ! -d "$ZINIT_HOME" ]; then
   mkdir -p "$(dirname $ZINIT_HOME)"
   git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Source/Load zinit
source "$ZINIT_HOME/zinit.zsh"

# Load Powerlevel10k theme
zinit ice depth=1; zinit light romkatv/powerlevel10k

# Lazily init zsh completions system
autoload -Uz compinit && compinit

# Load fzf
git -C $JSH submodule status .fzf &>/dev/null || git -C $JSH submodule update --init #--recursive .fzf
[[ -x $JSH/.fzf/bin/fzf && $(command -v $JSH/.fzf/bin/fzf) ]] || rm -f $JSH/.fzf/bin/fzf # Check if fzf is executable, delete if not
[[ ! -f $JSH/.fzf/bin/fzf && -f $JSH/.fzf/install ]] && chmod +x $JSH/.fzf/install && $JSH/.fzf/install --bin # Install fzf if not present

# Load zsh plugins
zinit light Aloxaf/fzf-tab
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-autosuggestions

# Pull and build direnv once
zinit as"program" make'!' atclone'./direnv hook zsh > zhook.zsh' atpull'%atclone' pick"direnv" src"zhook.zsh" for direnv/direnv

# Load snippets
zinit snippet OMZP::git
zinit snippet OMZP::archlinux
zinit snippet OMZP::aws
zinit snippet OMZP::kubectl
zinit snippet OMZP::kubectx
zinit snippet OMZP::command-not-found

# Load completions
source <(kubectl completion zsh)

# Replay cached completions
zinit cdreplay -q

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Keybindings for vim mode
bindkey -v
bindkey ^R history-incremental-search-backward
bindkey ^S history-incremental-search-forward

# Delete key bindings
bindkey -M vicmd '^[[3~' delete-char
bindkey -M viins '^[[3~' delete-char
bindkey -M visual '^?' vi-delete
bindkey -M visual '^[[3~' vi-delete

# Allow tab completion in the middle of the word
setopt COMPLETE_IN_WORD

# Keep background processes at full speed
setopt NOBGNICE

# Restart running processes on exit
setopt HUP

# For sharing history between zsh processes
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY

# Never ever beep ever
setopt NO_BEEP

# Automatically decide when to page a list of completions
LISTMAX=0

# Disable mail checking
MAILCHECK=0

# History
HISTSIZE=10000
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
abort() { echo; echo "${red}$@${reset}" 1>&2; exit 1; }
error() { echo -e ${red}$@${reset}; }
warn() { echo -e ${orange}$@${reset}; }
success() { echo -e ${green}$@${reset}; }
info() { echo -e ${blue}$@${reset}; }

# Shell integrations
[ -d ${FZF_ROOT:-$HOME/.fzf} ] && export PATH=${FZF_ROOT:-$HOME/.fzf}/bin:$PATH
[ -d ${KREW_ROOT:-$HOME/.krew} ] && export PATH=${KREW_ROOT:-$HOME/.krew}/bin:$PATH
[ -f /home/linuxbrew/.linuxbrew/bin/brew ] && source <(/home/linuxbrew/.linuxbrew/bin/brew shellenv)
[ -f /opt/homebrew/bin/brew ] && source <(/opt/homebrew/bin/brew shellenv)
command -v fzf 2>/dev/null 1>&2 && source <(fzf --zsh)
command -v zoxide 2>/dev/null 1>&2 && source <(zoxide init zsh)

# Local variables and overrides
[ -f "$JSH_CUSTOM" ] && source "$JSH_CUSTOM"

# Deduplicate PATH
export PATH=$(echo "$PATH" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')

# Import aliases
[ -f ${JSH}/.aliases.zsh ] && source $JSH/.aliases.zsh

# Import shell functions
[ -f ${JSH}/.functions.zsh ] && source $JSH/.functions.zsh
