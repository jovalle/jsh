# Minimal Bash fallback managed by this repository.
case $- in
*i*) ;;
*) return ;;
esac

if [[ ${JSH_BASHRC_LOADED:-0} == 1 ]]; then
  return
fi
JSH_BASHRC_LOADED=1

# Keep startup commands available even when Bash inherits a restricted PATH.
if [[ -z ${PATH:-} ]] || [[ ":${PATH}:" != *:/usr/bin:* ]]; then
  PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"
fi

if [[ -z ${JSH_DIR:-} ]]; then
  _jsh_bashrc=${BASH_SOURCE[0]}
  while [[ -L ${_jsh_bashrc} ]]; do
    _jsh_bashrc_dir=$(cd -P "$(dirname "${_jsh_bashrc}")" >/dev/null 2>&1 && pwd)
    _jsh_bashrc_link=$(readlink "${_jsh_bashrc}")
    case ${_jsh_bashrc_link} in
    /*) _jsh_bashrc=${_jsh_bashrc_link} ;;
    *) _jsh_bashrc=${_jsh_bashrc_dir}/${_jsh_bashrc_link} ;;
    esac
  done
  _jsh_bashrc_dir=$(cd -P "$(dirname "${_jsh_bashrc}")" >/dev/null 2>&1 && pwd)
  _jsh_candidate=$(cd -P "${_jsh_bashrc_dir}/.." >/dev/null 2>&1 && pwd)
  if [[ -d ${_jsh_candidate}/bin && -d ${_jsh_candidate}/dotfiles ]]; then
    JSH_DIR=${_jsh_candidate}
  else
    JSH_DIR=${HOME}/.jsh
  fi
  unset _jsh_bashrc _jsh_bashrc_dir _jsh_bashrc_link _jsh_candidate
fi
export JSH_DIR

_jsh_path_prepend() {
  local entry
  local -a updated_path=("$1")

  IFS=: read -r -a _jsh_path_entries <<<"${PATH:-}"
  for entry in "${_jsh_path_entries[@]}"; do
    [[ -z ${entry} || ${entry} == "$1" ]] || updated_path+=("${entry}")
  done
  PATH=$(
    IFS=:
    printf '%s' "${updated_path[*]}"
  )
  export PATH
}

for _jsh_path in "${HOME}/.local/bin" "${JSH_DIR}/local/bin" "${JSH_DIR}/bin"; do
  _jsh_path_prepend "${_jsh_path}"
done
unset _jsh_path _jsh_path_entries

if [[ ${JSH_MODE:-} == runtime && -r ${JSH_DIR}/dotfiles/.config/shell/runtime.sh ]]; then
  source "${JSH_DIR}/dotfiles/.config/shell/runtime.sh"
fi

export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-${EDITOR}}"
if [[ -z ${RIPGREP_CONFIG_PATH+x} ]]; then
  export RIPGREP_CONFIG_PATH="${HOME}/.ripgreprc"
fi

HISTCONTROL=ignoreboth:erasedups
HISTFILE=${HISTFILE:-${HOME}/.bash_history}
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s checkwinsize cmdhist histappend

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias l='ls -lah'
alias ll='ls -lh'
alias la='ls -lAh'

alias g='git'
alias gs='git status -sb'
alias ga='git add'
alias gc='git commit'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git push'

if [[ -n ${NO_COLOR:-} || ${JSH_PLAIN_OUTPUT:-0} == 1 || ${TERM:-dumb} == dumb ]]; then
  PS1='\u@\h:\w\$ '
else
  PS1='\[\033[36m\]\u@\h\[\033[0m\]:\[\033[34m\]\w\[\033[0m\]\$ '
fi

if command -v task >/dev/null 2>&1; then
  eval "$(task --completion bash 2>/dev/null)"
fi
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook bash)"
fi

if [[ -z ${JSH_BASH_FALLBACK_NOTICE_SHOWN:-} ]]; then
  export JSH_BASH_FALLBACK_NOTICE_SHOWN=1
  case $(uname -s 2>/dev/null) in
  Darwin)
    printf '%s\n' 'jsh: Bash is the fallback. Zsh ships with macOS; switch with: chsh -s /bin/zsh' >&2
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      _jsh_zsh_install='sudo apt-get install zsh'
    elif command -v dnf >/dev/null 2>&1; then
      _jsh_zsh_install='sudo dnf install zsh'
    elif command -v pacman >/dev/null 2>&1; then
      _jsh_zsh_install='sudo pacman -S zsh'
    elif command -v apk >/dev/null 2>&1; then
      _jsh_zsh_install='sudo apk add zsh'
    else
      _jsh_zsh_install='install zsh with your package manager'
    fi
    printf 'jsh: Bash is the fallback. Install Zsh: %s; then: chsh -s "$(command -v zsh)"\n' "${_jsh_zsh_install}" >&2
    unset _jsh_zsh_install
    ;;
  *)
    printf '%s\n' 'jsh: Bash is the fallback. Install Zsh, then run: chsh -s "$(command -v zsh)"' >&2
    ;;
  esac
fi

[[ ! -r ${HOME}/.bashrc.local ]] || source "${HOME}/.bashrc.local"
_jsh_path_prepend "${JSH_DIR}/bin"
unset _jsh_path_entries
unset -f _jsh_path_prepend
