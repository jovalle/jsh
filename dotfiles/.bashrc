# shellcheck shell=bash
# Bash fallback for the jsh runtime and conventional interactive shells.
[[ $- == *i* ]] || return

_jsh_rc=${BASH_SOURCE[0]}
while [[ -L ${_jsh_rc} ]]; do
  _jsh_parent=$(CDPATH='' cd -P "${_jsh_rc%/*}" && pwd)
  _jsh_target=$(readlink "${_jsh_rc}")
  case ${_jsh_target} in
  /*) _jsh_rc=${_jsh_target} ;;
  *) _jsh_rc=${_jsh_parent}/${_jsh_target} ;;
  esac
done
export JSH=${JSH_ROOT:-$(CDPATH='' cd -P "${_jsh_rc%/*}/.." && pwd)}
unset _jsh_rc _jsh_parent _jsh_target
export EDITOR=${EDITOR:-vim} VISUAL=${VISUAL:-vim}
export GIT_BASE=${GIT_BASE:-${HOME}/Projects} WORK_DIR=${WORK_DIR:-${HOME}/Projects}
export JSH_VENDOR=${JSH_VENDOR:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/vendor}
[[ -d ${JSH_VENDOR} || ! -d ${JSH}/local/vendor ]] || JSH_VENDOR=${JSH}/local/vendor
export FZF_BASE=${JSH_VENDOR}/fzf
for _jsh_path in "${HOME}/.cargo/bin" "${HOME}/go/bin" "${FZF_BASE}/bin" \
  "${JSH}/bin" "${JSH}/local/bin" "${HOME}/.local/bin"; do
  case :${PATH}: in *:"${_jsh_path}":*) ;; *) PATH=${_jsh_path}:${PATH} ;; esac
done
export PATH
unset _jsh_path

export HISTFILE=${JSH_RUNTIME_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/runtime}/bash_history
mkdir -p -- "${HISTFILE%/*}"
[[ -z ${JSH_RUNTIME_DIR:-} ]] || export JSH_RELOAD_PID=$$
HISTSIZE=50000
HISTFILESIZE=50000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend checkwinsize
set -o vi
has() { type -P -- "$1" >/dev/null 2>&1; }
case ${OSTYPE:-} in
darwin*) export JSH_OS=macos ;;
linux*) export JSH_OS=linux ;;
*) export JSH_OS=unknown ;;
esac
_jsh_agent_shell=0
[[ -z ${COPILOT_AGENT:-}${CLAUDECODE:-}${GEMINI_CLI:-} ]] || _jsh_agent_shell=1
export LESS=-FR VIRTUAL_ENV_DISABLE_PROMPT=1 DIRENV_LOG_FORMAT='' DIRENV_WARN_TIMEOUT=30s
export CLICOLOR=1
# Discover Homebrew even when Bash was started from a clean login environment.
for _jsh_path in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin; do
  if [[ -x ${_jsh_path}/brew ]]; then
    case :${PATH}: in *:"${_jsh_path}":*) ;; *) PATH=${PATH}:${_jsh_path} ;; esac
  fi
done
unset _jsh_path

# shellcheck source=lib/shell/output.sh
. "${JSH}/lib/shell/output.sh"
# shellcheck source=lib/shell/navigation.sh
. "${JSH}/lib/shell/navigation.sh"
# shellcheck source=lib/shell/commands.sh
. "${JSH}/lib/shell/commands.sh"
# shellcheck source=lib/shell/prompt.sh
. "${JSH}/lib/shell/prompt.sh"

# Initialize integrations once: repeated sourcing must not stack prompt hooks or bindings.
if [[ ${_JSH_BASH_TOOLS_LOADED:-0} != 1 ]]; then
  _JSH_BASH_TOOLS_LOADED=1
  # Some installed completion files request nosort even on Bash versions without it.
  if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]] &&
    ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))) &&
    ! declare -F complete >/dev/null; then
    _JSH_BASH_COMPLETION_SHIM=1
    complete() {
      local -a args=()
      while (($#)); do
        if [[ $1 == -o && ${2:-} == nosort ]]; then
          shift 2
        else
          args+=("$1")
          shift
        fi
      done
      builtin complete "${args[@]}"
    }
  fi
  if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
    if has brew; then
      _jsh_path=${PATH}
      eval "$(command brew shellenv)"
      # Keep jsh wrappers such as bin/git ahead of Homebrew, and Homebrew ahead of system tools.
      _jsh_path=${HOME}/.local/bin:${JSH}/local/bin:${JSH}/bin:${FZF_BASE}/bin:${HOME}/go/bin:${HOME}/.cargo/bin:${HOMEBREW_PREFIX:-/opt/homebrew}/bin:${HOMEBREW_PREFIX:-/opt/homebrew}/sbin:${_jsh_path}
      IFS=: read -ra _jsh_dirs <<<"${_jsh_path}"
      _jsh_path=
      for _jsh_dir in "${_jsh_dirs[@]}"; do
        case :${_jsh_path}: in *:"${_jsh_dir}":*) ;; *) _jsh_path=${_jsh_path:+${_jsh_path}:}${_jsh_dir} ;; esac
      done
      export PATH=${_jsh_path}
      unset _jsh_path _jsh_dirs _jsh_dir
    fi
    # Version 1 completion supports Bash 3.2; version 2 requires a newer shell.
    if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))); then
      for _jsh_rc in "${HOMEBREW_PREFIX:-/opt/homebrew}/share/bash-completion/bash_completion" \
        /usr/local/share/bash-completion/bash_completion /usr/share/bash-completion/bash_completion; do
        [[ -r ${_jsh_rc} ]] || continue
        # shellcheck disable=SC1090 # Platform completion path checked above.
        . "${_jsh_rc}"
        break
      done
    fi
    if ! type _init_completion >/dev/null 2>&1; then
      for _jsh_rc in "${HOMEBREW_PREFIX:-/opt/homebrew}/etc/bash_completion" /usr/local/etc/bash_completion /etc/bash_completion; do
        [[ -r ${_jsh_rc} ]] || continue
        # shellcheck disable=SC1090 # Platform completion path checked above.
        . "${_jsh_rc}"
        break
      done
    fi
  fi
  [[ ! -r ${JSH_VENDOR}/fzf/shell/key-bindings.bash ]] || . "${JSH_VENDOR}/fzf/shell/key-bindings.bash"
  [[ ! -r ${JSH_VENDOR}/fzf/shell/completion.bash ]] || . "${JSH_VENDOR}/fzf/shell/completion.bash"
  if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
    # Tool-generated hooks are evaluated only from installed executables.
    has direnv && eval "$(command direnv hook bash)"
    has docker && eval "$(command docker completion bash)"
    has kubectl && eval "$(command kubectl completion bash)"
    has task && eval "$(command task --completion bash)"
    has zoxide && eval "$(command zoxide init bash)"
    has atuin && eval "$(command atuin init bash)"
  fi
  if [[ ${_JSH_BASH_COMPLETION_SHIM:-0} == 1 ]]; then
    unset -f complete
    unset _JSH_BASH_COMPLETION_SHIM
  fi
fi
# shellcheck source=lib/shell/completion.sh
. "${JSH}/lib/shell/completion.sh"

jsh() {
  case ${1:-} in
  -r | reload)
    shift
    [[ $# == 0 ]] || {
      printf 'Usage: jsh -r | jsh reload\n' >&2
      return 2
    }
    . "${JSH}/dotfiles/.bashrc"
    ;;
  *) command "${JSH}/bin/jsh" "$@" ;;
  esac
}
if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
  for _jsh_rc in "${HOME}/.bashrc.local" "${JSH}/local/.bashrc"; do
    # shellcheck disable=SC1090 # Optional machine-local shell configuration.
    [[ ! -r ${_jsh_rc} ]] || . "${_jsh_rc}"
  done
  unset _jsh_rc
fi

_jsh_bash_install_prompt
