# .bashrc - Bash Configuration

# Source common configuration
if [[ -f "${HOME}/.jsh/dotfiles/.jshrc" ]]; then
  source "${HOME}/.jsh/dotfiles/.jshrc"
elif [[ -f "${HOME}/.jshrc" ]]; then
  source "${HOME}/.jshrc"
fi

# ============================================================================
# SHELL OPTIONS & KEYBINDINGS
# ============================================================================

# Vi mode
set -o vi

# History configuration
export HISTCONTROL=ignoreboth:erasedups
# shellcheck disable=SC2154
export HISTFILE="${JSH}/.bash_history"
export HISTSIZE=50000
export HISTFILESIZE=50000
export HISTTIMEFORMAT="%F %T "
shopt -s histappend

# Shell options
shopt -s autocd
shopt -s cdspell
shopt -s checkwinsize
shopt -s cmdhist
shopt -s dirspell
shopt -s dotglob
shopt -s expand_aliases
shopt -s extglob
shopt -s globstar

# Record each line as it gets issued
export PROMPT_COMMAND='history -a'

# Enable history expansion with space (!!<space> to expand last command)
bind Space:magic-space

# ============================================================================
# COMPLETION SYSTEM
# ============================================================================

if [[ -r /usr/share/bash-completion/bash_completion ]]; then
  source /usr/share/bash-completion/bash_completion
elif [[ -r /etc/bash_completion ]]; then
  source /etc/bash_completion
elif [[ -r /opt/homebrew/etc/profile.d/bash_completion.sh ]]; then
  source /opt/homebrew/etc/profile.d/bash_completion.sh
fi

# Tool Completions
command -v brew > /dev/null 2>&1 && eval "$(brew shellenv)"
command -v direnv > /dev/null 2>&1 && eval "$(direnv hook bash)"
command -v docker > /dev/null 2>&1 && eval "$(docker completion bash)"
command -v fzf > /dev/null 2>&1 && eval "$(fzf --bash)"
# shellcheck disable=SC1090
command -v kubectl > /dev/null 2>&1 && source <(kubectl completion bash)
command -v zoxide > /dev/null 2>&1 && eval "$(zoxide init bash)"

# ============================================================================
# PROMPT
# ============================================================================

if [[ -f "${HOME}/.jsh/scripts/unix/bash-powerline.sh" ]]; then
    source "${HOME}/.jsh/scripts/unix/bash-powerline.sh"
fi
