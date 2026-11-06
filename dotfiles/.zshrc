#
# .zshrc - Zsh Configuration
#
# Load Order:
#   1. Essential Exports
#   2. Plugin System
#   3. Shell Options & Keybindings
#   4. Completion System
#   5. Helper Functions
#   6. Shell Aliases
#   7. Shell Functions
#   8. Theme Customization
#   9. Path Prioritization / Deduplication
#   10. Local Customizations
#

typeset -i _jsh_runtime_active=0
if [[ -n ${JSH_RUNTIME_DIR:-} ]]; then
  _jsh_runtime_active=1
  export JSH_RELOAD_PID=$$
  zmodload -F zsh/files b:mkdir 2>/dev/null || return 1
  builtin mkdir -p -- "${JSH_RUNTIME_DIR}" "${JSH_RUNTIME_DIR}/cache"

  export JSH_HISTFILE="${JSH_RUNTIME_DIR}/history"
  typeset _jsh_runtime_xdg_cache=${XDG_CACHE_HOME-}
  typeset -i _jsh_runtime_had_xdg_cache=$+XDG_CACHE_HOME
  export XDG_CACHE_HOME="${JSH_RUNTIME_DIR}/cache"
fi

# ============================================================================
# 1. ESSENTIAL EXPORTS
# ============================================================================

# Core paths and editors
export CLICOLORS=1                               # Colorize output
export EDITOR=vim                                # Default CLI editor
export VISUAL=vim                                # Default full-screen editor
export SH=${SHELL##*/}                           # Shell type reference
export VIRTUAL_ENV_DISABLE_PROMPT=1              # Python environment appears in prompt info

# Project/work directories
export GIT_BASE=${HOME}/Projects                 # Git projects base
export WORK_DIR=${GIT_BASE}                      # Default work directory
export JSH=${${(%):-%N}:A:h:h}                   # Repository root through symlinks

typeset _jsh_rc
if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
  for _jsh_rc in "${HOME}/.jshrc" "${HOME}/.local/.jshrc" "${JSH}/local/.jshrc"; do
    [[ ! -r ${_jsh_rc} ]] || source "${_jsh_rc}"
  done
fi
unset _jsh_rc

if [[ ${functions_source[command_not_found_handler]:-} == /etc/profile.d/PackageKit.sh ]]; then
  unfunction command_not_found_handler
fi

# Silence/optimize specific tools
export DIRENV_LOG_FORMAT=                        # Silence direnv
export DIRENV_WARN_TIMEOUT=30s                   # Direnv timeout
export PYTHONDONTWRITEBYTECODE=1                 # No .pyc files on import

# Shell environment
if [[ -n ${JSH_LANG:-} ]]; then
  export LANG=${JSH_LANG}
fi
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"         # Wwhere apps should store config files, cache files, and data files

# Vendored shell dependencies
export JSH_VENDOR=${JSH_VENDOR:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/vendor}
if [[ ! -d ${JSH_VENDOR} && -d ${JSH}/local/vendor ]]; then
  export JSH_VENDOR=${JSH}/local/vendor
fi
export FZF_BASE=${JSH_VENDOR}/fzf

# Paths - ORDER MATTERS (priority: local > jsh local > jsh > vendored fzf > go > cargo)
export PATH=${HOME}/.local/bin:${JSH}/local/bin:${JSH}/bin:${FZF_BASE}/bin:${HOME}/go/bin:${PATH}:${HOME}/.cargo/bin
# Locate an existing Homebrew installation before shell hooks and completions.
for _jsh_brew_bin in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin; do
  [[ ! -x ${_jsh_brew_bin}/brew ]] || path+=(${_jsh_brew_bin})
done
unset _jsh_brew_bin


# Terminal optimizations
# Without -X, less uses the alternate screen, so VS Code passes PageUp/PageDown to it.
export LESS="-FR"                           # Colors, skip paging when output fits
# AI agent terminals cannot answer interactive pager or confirmation prompts.
typeset -i _jsh_agent_shell=0
if [[ -n ${COPILOT_AGENT:-}${CLAUDECODE:-}${GEMINI_CLI:-} ]]; then
  _jsh_agent_shell=1
  export PAGER=cat GIT_PAGER=cat BAT_PAGING=never
  setopt RM_STAR_SILENT
fi

# ============================================================================
# 2. PLUGIN SYSTEM
# ============================================================================

typeset -a jsh_plugins=(fzf fzf-tab zsh-autosuggestions zsh-completions zsh-syntax-highlighting)
if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
  for plugin in ${jsh_plugins}; do
    if [[ ! -d "${JSH_VENDOR}/${plugin}" ]]; then
      print -u2 -- "jsh shell plugins are missing. Run: ./scripts/shell.sh"
      break
    fi
  done
fi
unset jsh_plugins plugin

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
bindkey -M viins '^[[1;5D' backward-word
bindkey -M viins '^[[1;5C' forward-word

# Shell options (all at once)
setopt COMPLETE_IN_WORD extended_history hist_find_no_dups hist_ignore_all_dups \
        hist_ignore_dups hist_ignore_space hist_save_no_dups INTERACTIVE_COMMENTS \
        NO_BEEP NOBGNICE HUP INC_APPEND_HISTORY SHARE_HISTORY

# History configuration
export HISTDUP=erase                  # Erase duplicates
export HISTFILE="${JSH_HISTFILE:-${HOME}/.zsh_history}" # Keep mutable history outside the repository
export HISTSIZE=50000                 # Number of commands to keep in memory
export HIST_STAMPS=iso                # Timestamp format
export SAVEHIST=50000                 # Number of commands to save to file

# Completion options
LISTMAX=0                           # Automatically paginate completions
export LISTMAX                      # Used by zsh completion system
MAILCHECK=0                         # Disable mail checking

# ============================================================================
# 4. COMPLETION SYSTEM
# ============================================================================

# brew shellenv prepends site-functions to fpath, so run it before the repo entries.
if command -v brew &>/dev/null; then
  _jsh_path=${PATH}
  eval "$(brew shellenv)"
  # Keep jsh wrappers such as bin/git ahead of Homebrew, and Homebrew ahead of system tools.
  export PATH=${HOME}/.local/bin:${JSH}/local/bin:${JSH}/bin:${FZF_BASE}/bin:${HOME}/go/bin:${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:${_jsh_path}
  unset _jsh_path
fi

# Add user and vendored completions to fpath.
fpath=(~/.zsh/completions "${JSH_VENDOR}/zsh-completions/src" "${fpath[@]}")
typeset -gUa fpath

# Initialize completion system
typeset _jsh_cache=${XDG_CACHE_HOME:-${HOME}/.cache}/jsh
command mkdir -p -- "${_jsh_cache}"
typeset _jsh_compdump=${_jsh_cache}/.zcompdump
unset _jsh_cache
(( _jsh_runtime_active )) && _jsh_compdump=${JSH_RUNTIME_DIR}/cache/.zcompdump
autoload -Uz compinit
# Skip the fpath audit and rebuild when the dump is under a day old.
if [[ -n ${_jsh_compdump}(#qN.mh-24) ]]; then
  compinit -C -u -d "${_jsh_compdump}"
else
  compinit -u -d "${_jsh_compdump}"
fi
unset _jsh_compdump
(( ${+functions[_jsh_after_compinit]} )) && _jsh_after_compinit
_jsh() {
  if [[ ${words[2]} == init ]]; then
    shift words
    (( CURRENT-- ))
    _arguments \
      '(-n --dry-run)'{-n,--dry-run}'[preview without changing anything]' \
      '(-y --yes)'{-y,--yes}'[never prompt]'
    return
  fi
  _arguments \
    '(-h --help)'{-h,--help}'[show runtime help]' \
    '-r[reload this shell configuration]' \
    '-c[run a shell command]:command:' \
    '-i[open an interactive shell]' \
    '-l[open a login shell]' \
    '1::command:((init\:"run local/init scripts" reload\:"reload this shell configuration"))'
}
compdef _jsh jsh

_jsh_profiles() {
  local -a names expl
  names=(${(f)"$("${JSH}/bin/git" __complete profile 2>/dev/null)"})
  _wanted profiles expl profile compadd -a names
}

# Complete arguments of jsh's own git subcommands.
_jsh_git_extra() {
  local -a expl
  case ${words[2]} in
    profile)
      (( CURRENT == 3 )) || return 1
      _jsh_profiles
      _wanted options expl option compadd -- --list -h --help
      ;;
    create)
      (( CURRENT == 4 )) && _jsh_profiles
      ;;
    load) _wanted options expl option compadd -- -f --force -h --help ;;
    handoff) _wanted options expl option compadd -- -n --dry-run --clean -h --help ;;
    amend)
      if [[ ${PREFIX} != -* ]] && (( ${+functions[__git_recent_commits]} )); then
        __git_recent_commits
      else
        _wanted options expl option compadd -- -x -t -h --help
      fi
      ;;
    *) _wanted options expl option compadd -- -h --help ;;
  esac
}

_jsh_git() {
  local result=1
  if (( CURRENT >= 3 )) && [[ ${words[2]} == (profile|create|load|handoff|amend|save|refresh|get|commits) ]]; then
    _jsh_git_extra
    return
  fi
  if (( CURRENT == 2 )); then
    local -a commands=(
      'create:create a project' 'get:clone a project' 'commits:browse history'
      'amend:move commit timestamps' 'profile:select a profile' 'save:save changes'
      'load:load changes' 'refresh:rebase onto the default branch' 'handoff:transfer commits'
    )
    _describe -t commands 'jsh Git command' commands && result=0
  fi
  _git "$@" && result=0
  return ${result}
}
autoload -Uz _git
compdef _jsh_git git

_jsh_kube_contexts() {
  command kubectl config get-contexts -o name --request-timeout=2s 2>/dev/null
  return 0
}

_jsh_kube_namespaces() {
  command kubectl --request-timeout=2s get namespaces \
    -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
  return 0
}

_jsh_kubectx() {
  local -a contexts expl opts=(- -a --add -c --current -d --delete -u --unset -h --help)
  contexts=(${(f)"$(_jsh_kube_contexts)"})
  if (( CURRENT == 2 )); then
    _wanted contexts expl context compadd -a contexts
    # A literal '-' word would be taken as _all_labels' slot for its own options.
    _wanted options expl option compadd -a opts
  elif [[ ${words[2]} == (-d|--delete) ]]; then
    _wanted contexts expl context compadd -a contexts
  elif [[ ${words[2]} == (-a|--add) ]] && (( CURRENT == 3 )); then
    _files
  fi
}
compdef _jsh_kubectx kubectx

_jsh_kubens() {
  local -a namespaces expl opts=(- -c --current -h --help)
  (( CURRENT == 2 )) || return 1
  namespaces=(${(f)"$(_jsh_kube_namespaces)"})
  _wanted namespaces expl namespace compadd -a namespaces
  _wanted options expl option compadd -a opts
}
compdef _jsh_kubens kubens

_jsh_nukem() {
  local -a names expl
  local -A opt_args
  local context state
  _arguments -s \
    '(-l --list)'{-l,--list}'[list namespaces stuck in Terminating]' \
    '(-f --force)'{-f,--force}'[skip confirmation]' \
    '(-n --dry-run)'{-n,--dry-run}'[preview finalizer removal]' \
    '(-c --context)'{-c,--context}'[use a kubectl context]:context:->context' \
    '(-v --verbose)'{-v,--verbose}'[show debug output]' \
    '(- *)'{-h,--help}'[show help]' \
    '(- *)--version[show version]' \
    '1:namespace:->namespace' && return 0
  case ${state} in
    context)
      names=(${(f)"$(_jsh_kube_contexts)"})
      _wanted contexts expl context compadd -a names
      ;;
    namespace)
      context=${opt_args[-c]:-${opt_args[--context]:-}}
      # _arguments stores opt_args with \: and \\ escaped.
      context=${${context//\\:/:}//\\\\/\\}
      names=(${(f)"$(NUKEM_TIMEOUT=2 "${JSH}/bin/nukem" __complete namespace ${context:+${context}} 2>/dev/null)"})
      _wanted namespaces expl namespace compadd -a names
      ;;
  esac
}
compdef _jsh_nukem nukem

# Turn "NAME<TAB>DESCRIPTION" hook lines into _describe's NAME:DESCRIPTION.
_jsh_hook_pairs() {
  local line name desc
  reply=()
  for line in ${(f)"$("${JSH}/bin/$1" __complete "$2" 2>/dev/null)"}; do
    name=${line%%$'\t'*}
    desc=''
    [[ ${line} != *$'\t'* ]] || desc=${line#*$'\t'}
    name=${${name//\\/\\\\}//:/\\:}
    reply+=("${name}:${desc}")
  done
}

_jsh_jssh() {
  local -a flags reply
  if (( CURRENT == 2 )) && [[ ${PREFIX} == -* ]]; then
    flags=(
      '--check:check local requirements' '--rebuild:clear generated payloads'
      '-r:run plain ssh' '--raw:run plain ssh' '-h:show help' '--help:show help'
      '--version:show version'
    )
    _describe -t options 'option' flags
    return
  fi
  _jsh_hook_pairs jssh host
  _describe -t hosts 'ssh host' reply
}
compdef _jsh_jssh jssh

_jsh_jump() {
  local -a names flags expl
  local project
  if [[ ${PREFIX} == -* ]]; then
    flags=(
      '-c:open the match in VS Code' '-v:show search details'
      '-a:add the current directory' '--add:add the current directory'
      '--remove:remove the current directory' '--db:show tracked directories and scores'
      '--clean:remove missing directories' '--help:show help'
    )
    _describe -t options 'option' flags
    return
  fi
  for project in ${(f)"$(_j_get_projects 2>/dev/null)"}; do names+=("${project:t}"); done
  _wanted projects expl project compadd -a names
}
compdef _jsh_jump j p

_jsh_proxy_presets() {
  local -a reply
  _jsh_hook_pairs proxy preset
  _describe -t presets 'preset' reply
}

_jsh_proxy() {
  local i
  for (( i = 2; i < CURRENT; i++ )); do
    case ${words[i]} in
      -p|--preset|-u|--url|-s|--socks|-n|--no-proxy) (( i++ )) ;;
      --)
        words=("${(@)words[i + 1,-1]}")
        (( CURRENT -= i ))
        _normal
        return
        ;;
      -*) ;;
      *) break ;;
    esac
  done
  _arguments -S -A '-*' \
    '(-p --preset)'{-p,--preset}'[use a built-in proxy preset]:preset:_jsh_proxy_presets' \
    '(-u --url)'{-u,--url}'[set the HTTP proxy URL]:url: ' \
    '(-s --socks)'{-s,--socks}'[set the SOCKS proxy URL]:url: ' \
    '(-n --no-proxy)'{-n,--no-proxy}'[set hosts that bypass the proxy]:hosts: ' \
    '--shell[start a shell with the proxy]' \
    '--env[print the proxy exports]' \
    '--test[test the proxy]' \
    '--list[list presets]' \
    '(-v --verbose)'{-v,--verbose}'[show debug output]' \
    '(- *)'{-h,--help}'[show help]' \
    '(- *)--version[show version]' \
    '*::command:_normal'
}
compdef _jsh_proxy proxy

# shellcheck disable=SC1090  # Vendored repository
[[ -r "${JSH_VENDOR}/fzf-tab/fzf-tab.plugin.zsh" && -n ${commands[fzf]:-} ]] && \
  source "${JSH_VENDOR}/fzf-tab/fzf-tab.plugin.zsh"

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'  # Case insensitive
# shellcheck disable=SC2296  # Zsh-specific parameter expansion syntax
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}" # Use LS_COLORS
zstyle ':completion:*' menu no                          # Don't show menu by default

# Fzf-tab preview settings
zstyle ':fzf-tab:complete:cd:*' fzf-preview "ls --color \$realpath"

# ---- Tool Completions ----

command -v direnv &>/dev/null && eval "$(direnv hook zsh)"
command -v docker &>/dev/null && eval "$(docker completion zsh)"
# shellcheck disable=SC1090  # Dynamic source from fzf
command -v fzf &>/dev/null && source <(command fzf --zsh 2>/dev/null)
# shellcheck disable=SC1090  # Dynamic source from kubectl
command -v kubectl &>/dev/null && source <(kubectl completion zsh)
(( $+_comps[kubectl] )) && compdef kubecolor=kubectl
# shellcheck disable=SC1090  # Dynamic source from task
command -v task &>/dev/null && source <(task --completion zsh)
# shellcheck disable=SC1090  # Technis vault and just recipe arguments
[[ -r "${GIT_BASE}/technis/tools/completion.zsh" ]] && \
  source "${GIT_BASE}/technis/tools/completion.zsh"
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"
command -v atuin &>/dev/null && eval "$(atuin init zsh)"

# ============================================================================
# 5. HELPER FUNCTIONS
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

if [[ -z "${JSH_OS:-}" ]]; then
  case "${OSTYPE:-}" in
    darwin*) JSH_OS=macos ;;
    linux*) JSH_OS=linux ;;
    cygwin* | msys* | win32*) JSH_OS=windows ;;
    *) JSH_OS=unknown ;;
  esac
fi
export JSH_OS

has() { whence -p -- "$1" >/dev/null 2>&1; }

# shellcheck source=lib/shell/output.sh
source "${JSH}/lib/shell/output.sh"


# shellcheck source=lib/shell/navigation.sh
source "${JSH}/lib/shell/navigation.sh"

_j_lowercase() { print -rn -- "${(L)1}"; }

_j_track_directory() {
  [[ -z ${J_NO_HOOK:-} ]] || return 0
  local track_path=$1
  setopt localoptions no_bg_nice
  (_j_add "${track_path}") >/dev/null 2>&1 &!
}

_j_chpwd() {
  [[ -z ${OLDPWD:-} ]] || _J_PREV_DIR=${OLDPWD}
  _j_track_directory "${PWD}"
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _j_chpwd

git() {
  command git "$@" || return
  if [[ ${1:-} == create && $# -ge 2 && ${2} != -h && ${2} != --help ]]; then
    cd -- "${GIT_BASE:-${HOME}/Projects}/${2}"
  fi
}


# ============================================================================
# 6. SHELL ALIASES
# ============================================================================

# shellcheck source=lib/shell/commands.sh
source "${JSH}/lib/shell/commands.sh"
alias show_options='setopt'
  # Extra subcommands from bin/git.
  zstyle ':completion:*:*:git:*' user-commands \
    save:'back up uncommitted changes to a secret gist' \
    load:'apply changes saved with git save' \
    refresh:'fetch origin and rebase onto its default branch' \
    profile:'use a local/git.json identity, SSH key, and SSH remotes'

# ============================================================================
# 7. ZSH-SPECIFIC FUNCTIONS
# ============================================================================

_git_confirm() {
  local reply
  printf '%s [y/N] ' "$1"
  read -r -s -k 1 reply || return 1
  if [[ ${reply} == [yY] ]]; then
    print y
    return 0
  fi
  print n
  _j_ui_message info "Cancelled"
  return 1
}

_git_require_origin() {
  git remote get-url origin >/dev/null 2>&1 && return 0
  _j_ui_message error "No origin remote: add one with git remote add origin URL"
  return 1
}

function git+ {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    _j_ui_message error "Detached HEAD: checkout a branch first"
    return 1
  }

  _git_require_origin || return 1
  _git_confirm "Push '${branch}' to origin?" || return 1
  git push --set-upstream "$@" origin "${branch}"
}

_git_force_push() {
  local confirm=$1
  local branch
  shift

  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    _j_ui_message error "Detached HEAD: checkout a branch first"
    return 1
  }

  _git_require_origin || return 1
  if [[ ${confirm} == 1 ]]; then
    _git_confirm "Force-push '${branch}' to origin with --force-with-lease?" || return 1
  fi
  git push --set-upstream --force-with-lease "$@" origin "${branch}"
}

function git+++ {
  _git_force_push 0 "$@"
}

function git++ {
  _git_force_push 1 "$@"
}

function git- {
  _git_confirm "Reset HEAD to undo last commit ($(git log -1 --pretty=format:'%s'))?" || return 1
  git reset HEAD~1
}

function git-+ {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _j_ui_message error "Not a git repository"
    return 1
  fi

  local current_branch remote upstream_ref default_ref default_branch candidate
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    _j_ui_message error "Detached HEAD: checkout a branch first"
    return 1
  }

  upstream_ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || true
  if [[ -n "${upstream_ref}" ]]; then
    remote="${upstream_ref%%/*}"
  else
    remote=$(git config --get "branch.${current_branch}.remote" 2>/dev/null) || true
  fi

  if [[ -z "${remote}" ]]; then
    if git remote get-url origin >/dev/null 2>&1; then
      remote="origin"
    else
      remote=$(git remote | head -n 1)
    fi
  fi

  if [[ -z "${remote}" ]]; then
    _j_ui_message error "No git remote configured"
    return 1
  fi

  default_ref=$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null) || true
  default_branch="${default_ref#"${remote}"/}"

  if [[ -z "${default_branch}" || "${default_branch}" == "${default_ref}" ]]; then
    default_branch=$(git remote show "${remote}" 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p' | head -n 1)
  fi

  if [[ -z "${default_branch}" ]]; then
    for candidate in main master trunk develop; do
      if git show-ref --verify --quiet "refs/remotes/${remote}/${candidate}"; then
        default_branch="${candidate}"
        break
      fi
    done
  fi

  if [[ -z "${default_branch}" ]]; then
    _j_ui_message error "Could not determine default branch for remote '${remote}'"
    return 1
  fi

  _git_confirm "Fetch '${remote}' and rebase '${current_branch}' onto '${remote}/${default_branch}'?" || return 1

  git fetch "${remote}" --prune || return 1
  _j_ui_message info "Rebasing ${current_branch} onto ${remote}/${default_branch}"
  git rebase --autostash "$@" "${remote}/${default_branch}"
}

# ---- IPMI & Hardware Management ----

ipmi() {
  [[ -z "${IPMI_HOST:-}" || -z "${IPMI_USER:-}" || -z "${IPMI_CRED_FILE:-}" ]] && \
    { error "IPMI env vars not set"; return 1; }
  has ipmitool || { error "ipmitool is required"; return 1; }
  [[ "${1:-}" == fan ]] || {
    command ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" "$@"
    return
  }
  if [[ $# -ne 2 || "$2" != <-> ]]; then
    error "Usage: ipmi fan <speed_0-255>"
    return 1
  fi

  local speed=$((10#$2)) hex_speed
  if (( speed > 255 )); then
    error "Usage: ipmi fan <speed_0-255>"
    return 1
  fi
  hex_speed=$(printf '%02x\n' "${speed}") || return 1
  command ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x01 0x00 || return 1
  if ! command ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x02 0xff "0x${hex_speed}"; then
    if command ipmitool -I lanplus -H "${IPMI_HOST}" -U "${IPMI_USER}" -f "${IPMI_CRED_FILE}" raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; then
      error "Failed to set fan speed; restored automatic control"
    else
      error "Failed to set fan speed and restore automatic control"
    fi
    return 1
  fi
}

# ============================================================================
# 8. THEME CUSTOMIZATION
# ============================================================================

unsetopt PROMPT_SUBST
zmodload zsh/datetime 2>/dev/null || true
autoload -Uz add-zsh-hook

typeset -g _JSH_PROMPT_MODE=${JSH_PROMPT_MODE:-nerdfont-v3}
case ${_JSH_PROMPT_MODE} in
	nerdfont-v3|unicode|ascii) ;;
	*)
		print -u2 -- "jsh: unsupported JSH_PROMPT_MODE: ${JSH_PROMPT_MODE}"
		print -u2 -- 'jsh: expected nerdfont-v3, unicode, or ascii'
		_JSH_PROMPT_MODE=nerdfont-v3
		;;
esac
case ${${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}:l} in
	*utf-8*|*utf8*) ;;
	*) [[ ${_JSH_PROMPT_MODE} == ascii ]] || _JSH_PROMPT_MODE=ascii ;;
esac

typeset -gA _JSH_PROMPT_ICON
case ${_JSH_PROMPT_MODE} in
	nerdfont-v3)
		_JSH_PROMPT_ICON=(
			apple $'\uf179' linux $'\uf17c' branch $'\uf126 '
			prompt '❯' command '❮' visual 'V' overwrite '▶'
			fail '✘' ahead '⇡' behind '⇣' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs $'\uf013' python $'\ue73c' node $'\ue718' kube '⎈'
		)
		;;
	unicode)
		_JSH_PROMPT_ICON=(
			apple 'mac' linux 'linux' branch 'git:'
			prompt '❯' command '❮' visual 'V' overwrite '▶'
			fail '✘' ahead '⇡' behind '⇣' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs '⚙' python 'py:' node 'node:' kube '⎈'
		)
		;;
	ascii)
		_JSH_PROMPT_ICON=(
			apple 'mac' linux 'linux' branch 'git:'
			prompt '>' command '<' visual 'V' overwrite '>>'
			fail 'x' ahead '^' behind 'v' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs 'jobs:' python 'py:' node 'node:' kube 'kube:'
		)
		;;
esac

typeset -g _JSH_DISTRO_ID=linux
if [[ ${OSTYPE} == linux* && -r ${JSH_OS_RELEASE:-/etc/os-release} ]]; then
    while IFS='=' read -r key value; do
        if [[ ${key} == ID ]]; then
            _JSH_DISTRO_ID=${value//[\"\']/}
            break
        fi
    done < "${JSH_OS_RELEASE:-/etc/os-release}"
fi
if [[ ${_JSH_PROMPT_MODE} == nerdfont-v3 ]]; then
    case ${_JSH_DISTRO_ID} in
        debian) _JSH_PROMPT_ICON[linux]=$'\uf306' ;;
        ubuntu) _JSH_PROMPT_ICON[linux]=$'\uf31b' ;;
        arch|endeavouros|manjaro) _JSH_PROMPT_ICON[linux]=$'\uf303' ;;
        fedora) _JSH_PROMPT_ICON[linux]=$'\uf30a' ;;
        linuxmint) _JSH_PROMPT_ICON[linux]=$'\uf30e' ;;
        opensuse*) _JSH_PROMPT_ICON[linux]=$'\uf314' ;;
    esac
else
    _JSH_PROMPT_ICON[linux]=${_JSH_DISTRO_ID}
fi

typeset -ga JSH_PROMPT_LEFT JSH_PROMPT_RIGHT
(( ${#JSH_PROMPT_LEFT} )) || JSH_PROMPT_LEFT=(os directory git)
(( ${#JSH_PROMPT_RIGHT} )) || \
	JSH_PROMPT_RIGHT=(status duration jobs direnv node python kube aws time)
[[ ${JSH_PROMPT_ASYNC:-1} == (0|1) ]] || JSH_PROMPT_ASYNC=1
[[ ${JSH_PROMPT_DURATION_MS:-3000} == <-> ]] || JSH_PROMPT_DURATION_MS=3000
[[ ${JSH_PROMPT_DIR_MIN:-14} == <-> ]] || JSH_PROMPT_DIR_MIN=14
typeset -gi JSH_PROMPT_ASYNC=${JSH_PROMPT_ASYNC:-1}
typeset -gi JSH_PROMPT_DURATION_MS=${JSH_PROMPT_DURATION_MS:-3000}
typeset -gi JSH_PROMPT_DIR_MIN=${JSH_PROMPT_DIR_MIN:-14}
typeset -g JSH_PROMPT_KUBE=${JSH_PROMPT_KUBE:-auto}

if [[ ${JSH_PLAIN_OUTPUT:-0} != 1 && ${JSH_COLOR:-auto} != never && \
	-z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
	typeset -g _JSH_C_RESET=$'%{\e[0m%}'
	typeset -g _JSH_C_OS=$'%{\e[1;97m%}'
	typeset -g _JSH_C_DIR=$'%{\e[1;38;2;0;191;255m%}'
	typeset -g _JSH_C_CLEAN=$'%{\e[38;2;95;255;0m%}'
	typeset -g _JSH_C_MODIFIED=$'%{\e[38;2;255;215;0m%}'
	typeset -g _JSH_C_UNTRACKED=$'%{\e[38;2;0;215;255m%}'
	typeset -g _JSH_C_ERROR=$'%{\e[38;2;255;59;48m%}'
	typeset -g _JSH_C_STATUS_ERROR=$'%{\e[38;2;255;69;58m%}'
	typeset -g _JSH_C_DURATION=$'%{\e[38;2;245;245;67m%}'
	typeset -g _JSH_C_JOBS=$'%{\e[38;2;35;209;139m%}'
	typeset -g _JSH_C_ENV=$'%{\e[38;2;41;184;219m%}'
	typeset -g _JSH_C_KUBE=$'%{\e[38;2;214;112;214m%}'
	typeset -g _JSH_C_AWS=$'%{\e[38;2;255;149;0m%}'
	typeset -g _JSH_C_CONTEXT=$'%{\e[38;2;255;215;175m%}'
	typeset -g _JSH_C_CONTEXT_ROOT=$'%{\e[38;2;255;215;0m%}'
	typeset -g _JSH_C_TIME=$'%{\e[38;2;128;128;128m%}'
else
	typeset -g _JSH_C_RESET='' _JSH_C_OS='' _JSH_C_DIR='' _JSH_C_CLEAN=''
	typeset -g _JSH_C_MODIFIED='' _JSH_C_UNTRACKED='' _JSH_C_ERROR=''
	typeset -g _JSH_C_STATUS_ERROR='' _JSH_C_DURATION='' _JSH_C_JOBS=''
	typeset -g _JSH_C_ENV='' _JSH_C_KUBE='' _JSH_C_AWS=''
	typeset -g _JSH_C_CONTEXT='' _JSH_C_CONTEXT_ROOT='' _JSH_C_TIME=''
fi

typeset -g _JSH_PROMPT_EXIT='' _JSH_PROMPT_STARTED='' _JSH_PROMPT_DURATION=0
typeset -g _JSH_PROMPT_GIT_PWD='' _JSH_PROMPT_GIT_BRANCH='' _JSH_PROMPT_GIT_STATE=''
typeset -gi _JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_GIT_DIRTY=1 _JSH_PROMPT_GIT_FD=-1
typeset -gi _JSH_PROMPT_GIT_STAGED=0 _JSH_PROMPT_GIT_UNSTAGED=0
typeset -gi _JSH_PROMPT_GIT_UNTRACKED=0 _JSH_PROMPT_GIT_CONFLICTED=0
typeset -gi _JSH_PROMPT_GIT_AHEAD=0 _JSH_PROMPT_GIT_BEHIND=0 _JSH_PROMPT_GIT_STASH=0
typeset -g _JSH_PROMPT_NODE='' _JSH_PROMPT_NODE_PWD='' _JSH_PROMPT_KUBE_CACHE=''
typeset -g _JSH_PROMPT_KUBE_SIGNATURE=''
typeset -gi _JSH_PROMPT_KUBE_DIRTY=1 _JSH_PROMPT_DIR_MAX=0 _JSH_PROMPT_BRANCH_MAX=0
typeset -gi _JSH_PROMPT_HIDE_OS=0 _JSH_PROMPT_HIDE_GIT=0
# Segments may render a shorter form while this is 1.
typeset -gi _JSH_PROMPT_COMPACT=0
# Integrations (e.g. jkp) set this to show $PWD relative to a project root.
typeset -g _JSH_PROMPT_DIR_ROOT=''
# Prompt-formatted text that stands in for the root when _JSH_PROMPT_DIR_ROOT is set.
typeset -g _JSH_PROMPT_DIR_LABEL=''
typeset -g _JSH_PROMPT_TIME_MODE=full

_jsh_prompt_escape() {
	REPLY=${1//\%/%%}
}

_jsh_prompt_visible_length() {
	emulate -L zsh -o extended_glob
	local text=${1//\%\{/}
	text=${text//\%\}/}
	text=${text//$'\e'\[[0-9;]##m/}
	text=${text//\%\%/\%}
	REPLY=${#text}
}

_jsh_prompt_clip() {
	emulate -L zsh -o extended_glob
	local text=$1 max=$2
	_jsh_prompt_visible_length "${text}"
	(( REPLY <= max )) && { REPLY=${text}; return; }
	text=${text//\%\{/}
	text=${text//\%\}/}
	text=${text//$'\e'\[[0-9;]##m/}
	text=${text//\%\%/\%}
	(( max > 1 )) && text="${text[1,$((max - 1))]}…" || text=''
	_jsh_prompt_escape "${text}"
}

_jsh_prompt_directory() {
	local root=${_JSH_PROMPT_DIR_ROOT:-}
	if [[ -n ${root} && ${PWD} == ${root}/* ]]; then
		REPLY=${PWD#${root}/}
	elif [[ -n ${root} && -n ${_JSH_PROMPT_DIR_LABEL} && ${PWD} == ${root} ]]; then
		REPLY=''
	elif [[ ${PWD} == ${HOME} ]]; then
		REPLY='~'
	elif [[ ${PWD} == ${HOME}/* ]]; then
		REPLY="~/${PWD#${HOME}/}"
	else
		REPLY=${PWD}
	fi
}

_jsh_prompt_abbreviate() {
	local value=$1 max=$2 leaf keep
	REPLY=${value}
	(( max > 0 && ${#value} > max )) || return
	leaf=${value:t}
	keep=$((max - 2))
	(( keep > 0 )) || keep=1
	if (( ${#leaf} >= max )); then
		REPLY="…${leaf[-${keep},-1]}"
	else
		REPLY="…/${leaf}"
	fi
}

_jsh_prompt_join() {
	local separator=$1 name function part result=''
	shift
	for name in "$@"; do
		function=_jsh_prompt_segment_${name}
		(( $+functions[${function}] )) || continue
		${function} || continue
		part=${REPLY}
		[[ -n ${part} ]] || continue
		[[ -z ${result} ]] || result+=${separator}
		result+=${part}
	done
	REPLY=${result}
}

_jsh_prompt_segment_os() {
	(( !_JSH_PROMPT_HIDE_OS )) || { REPLY=''; return; }
	case ${OSTYPE} in
		darwin*) REPLY="${_JSH_C_OS}${_JSH_PROMPT_ICON[apple]}${_JSH_C_RESET}" ;;
		*) REPLY="${_JSH_C_OS}${_JSH_PROMPT_ICON[linux]}${_JSH_C_RESET}" ;;
	esac
}

_jsh_prompt_segment_directory() {
	local directory context='' label=''
	local -i max=${_JSH_PROMPT_DIR_MAX}
	if _jsh_prompt_segment_context; then
		context="${REPLY}:"
		_jsh_prompt_visible_length "${context}"
		(( max == 0 )) || { max=$((max - REPLY)); (( max > 0 )) || max=1; }
	fi
	if [[ -n ${_JSH_PROMPT_DIR_ROOT} && ( ${PWD} == ${_JSH_PROMPT_DIR_ROOT} || ${PWD} == ${_JSH_PROMPT_DIR_ROOT}/* ) ]]; then
		label=${_JSH_PROMPT_DIR_LABEL}
		_jsh_prompt_visible_length "${label}/"
		(( max == 0 )) || { max=$((max - REPLY)); (( max > 0 )) || max=1; }
	fi
	_jsh_prompt_directory
	directory=${REPLY}
	(( max == 0 )) || [[ -z ${directory} ]] || {
		_jsh_prompt_abbreviate "${directory}" ${max}
		directory=${REPLY}
	}
	_jsh_prompt_escape "${directory}"
	directory=${REPLY}
	if [[ -n ${label} ]]; then
		REPLY="${context}${label}${_JSH_C_DIR}/${directory}${_JSH_C_RESET}"
	else
		REPLY="${context}${_JSH_C_DIR}${directory}${_JSH_C_RESET}"
	fi
}

_jsh_prompt_segment_git() {
	local branch=${_JSH_PROMPT_GIT_BRANCH} result
	REPLY=''
	(( !_JSH_PROMPT_HIDE_GIT )) && [[ -n ${branch} ]] || return
	(( _JSH_PROMPT_BRANCH_MAX == 0 )) || {
		_jsh_prompt_abbreviate "${branch}" ${_JSH_PROMPT_BRANCH_MAX}
		branch=${REPLY}
	}
	_jsh_prompt_escape "${branch}"
	result="${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[branch]}${REPLY}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_BEHIND )) && \
		result+=" ${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[behind]}${_JSH_PROMPT_GIT_BEHIND}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_AHEAD && !_JSH_PROMPT_GIT_BEHIND )) && result+=' '
	(( _JSH_PROMPT_GIT_AHEAD )) && \
		result+="${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[ahead]}${_JSH_PROMPT_GIT_AHEAD}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_STASH )) && \
		result+=" ${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[stash]}${_JSH_PROMPT_GIT_STASH}${_JSH_C_RESET}"
	[[ -z ${_JSH_PROMPT_GIT_STATE} ]] || \
		result+=" ${_JSH_C_ERROR}${_JSH_PROMPT_GIT_STATE}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_CONFLICTED )) && \
		result+=" ${_JSH_C_ERROR}${_JSH_PROMPT_ICON[conflict]}${_JSH_PROMPT_GIT_CONFLICTED}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_STAGED )) && \
		result+=" ${_JSH_C_MODIFIED}${_JSH_PROMPT_ICON[staged]}${_JSH_PROMPT_GIT_STAGED}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_UNSTAGED )) && \
		result+=" ${_JSH_C_MODIFIED}${_JSH_PROMPT_ICON[unstaged]}${_JSH_PROMPT_GIT_UNSTAGED}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_UNTRACKED )) && \
		result+=" ${_JSH_C_UNTRACKED}${_JSH_PROMPT_ICON[untracked]}${_JSH_PROMPT_GIT_UNTRACKED}${_JSH_C_RESET}"
	REPLY=${result}
}

_jsh_prompt_segment_status() {
	local exit_code=${_JSH_PROMPT_EXIT}
	REPLY=''
	[[ -n ${exit_code} && ${exit_code} != 0 ]] || return
	case ${exit_code} in
		129) exit_code=HUP ;; 130) exit_code=INT ;; 131) exit_code=QUIT ;;
		137) exit_code=KILL ;; 143) exit_code=TERM ;;
	esac
	REPLY="${_JSH_C_STATUS_ERROR}${_JSH_PROMPT_ICON[fail]} ${exit_code}${_JSH_C_RESET}"
}

_jsh_prompt_segment_duration() {
	local milliseconds=${_JSH_PROMPT_DURATION} seconds result=''
	REPLY=''
	(( milliseconds >= JSH_PROMPT_DURATION_MS )) || return
	seconds=$((milliseconds / 1000))
	(( seconds < 86400 )) || { result+="$((seconds / 86400))d"; seconds=$((seconds % 86400)); }
	(( seconds < 3600 )) || { result+="$((seconds / 3600))h"; seconds=$((seconds % 3600)); }
	(( seconds < 60 )) || { result+="$((seconds / 60))m"; seconds=$((seconds % 60)); }
	[[ -n ${result} && ${seconds} == 0 ]] || result+="${seconds}s"
	REPLY="${_JSH_C_DURATION}${result}${_JSH_C_RESET}"
}

_jsh_prompt_segment_jobs() {
	REPLY=''
	(( ${#jobstates} )) || return
	REPLY="${_JSH_C_JOBS}${_JSH_PROMPT_ICON[jobs]} ${#jobstates}${_JSH_C_RESET}"
}

_jsh_prompt_segment_direnv() {
	REPLY=''
	[[ -n ${DIRENV_DIR:-} ]] || return
	REPLY="${_JSH_C_MODIFIED}direnv${_JSH_C_RESET}"
}

_jsh_prompt_segment_node() {
	REPLY=''
	[[ -n ${_JSH_PROMPT_NODE} ]] || return
	_jsh_prompt_escape "${_JSH_PROMPT_NODE}"
	REPLY="${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[node]} ${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_python() {
	local environment=${VIRTUAL_ENV:-${CONDA_DEFAULT_ENV:-}}
	REPLY=''
	[[ -n ${environment} ]] || return
	environment=${environment:t}
	_jsh_prompt_escape "${environment}"
	REPLY="${_JSH_C_ENV}${_JSH_PROMPT_ICON[python]} ${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_kube() {
	REPLY=''
	[[ -n ${_JSH_PROMPT_KUBE_CACHE} ]] || return
	_jsh_prompt_escape "${_JSH_PROMPT_KUBE_CACHE}"
	REPLY="${_JSH_C_KUBE}${_JSH_PROMPT_ICON[kube]} ${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_aws() {
	local profile=${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}}
	REPLY=''
	[[ -n ${profile} ]] || return
	_jsh_prompt_escape "${profile}"
	REPLY="${_JSH_C_AWS}aws:${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_context() {
	local color=${_JSH_C_CONTEXT}
	REPLY=''
	[[ -n ${SSH_CONNECTION:-} || ${EUID} == 0 ]] || return
	(( EUID != 0 )) || color=${_JSH_C_CONTEXT_ROOT}
	_jsh_prompt_escape "${USER:-?}@${HOST%%.*}"
	REPLY="${color}${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_time() {
	local value format='%H:%M:%S'
	REPLY=''
	[[ ${_JSH_PROMPT_TIME_MODE} != none ]] || return
	[[ ${_JSH_PROMPT_TIME_MODE} != compact ]] || format='%H:%M'
	if (( $+builtins[strftime] )); then
		strftime -s value "${format}" ${EPOCHSECONDS:-0}
	elif [[ ${_JSH_PROMPT_TIME_MODE} == compact ]]; then
		value=${(%):-%D{%H:%M}}
	else
		value=${(%):-%D{%H:%M:%S}}
	fi
	REPLY="${_JSH_C_TIME}${value}${_JSH_C_RESET}"
}

_jsh_prompt_segment_character() {
	local icon
	case ${KEYMAP:-viins} in
		vicmd) icon=${_JSH_PROMPT_ICON[command]} ;;
		vivis) icon=${_JSH_PROMPT_ICON[visual]} ;;
		viopp) icon=${_JSH_PROMPT_ICON[overwrite]} ;;
		*) icon=${_JSH_PROMPT_ICON[prompt]} ;;
	esac
	if [[ -n ${_JSH_PROMPT_EXIT} && ${_JSH_PROMPT_EXIT} != 0 ]]; then
		REPLY="${_JSH_C_ERROR}${icon}${_JSH_C_RESET} "
	else
		REPLY="${_JSH_C_CLEAN}${icon}${_JSH_C_RESET} "
	fi
}

_jsh_prompt_build_left() {
	local width=$1 full git full_length git_length room indicators
	_JSH_PROMPT_DIR_MAX=0 _JSH_PROMPT_BRANCH_MAX=0
	_JSH_PROMPT_HIDE_OS=0 _JSH_PROMPT_HIDE_GIT=0
	_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
	_jsh_prompt_visible_length "${full}"; full_length=${REPLY}
	(( full_length < width )) && { REPLY=${full}; return; }
	_jsh_prompt_segment_git; git=${REPLY}
	_jsh_prompt_visible_length "${git}"; git_length=${REPLY}
	room=$((width - git_length - 1))
	if (( room >= JSH_PROMPT_DIR_MIN )); then
		_JSH_PROMPT_DIR_MAX=${room}
	else
		_JSH_PROMPT_DIR_MAX=$((width / 2))
		(( _JSH_PROMPT_DIR_MAX >= 4 )) || _JSH_PROMPT_DIR_MAX=4
		indicators=$((git_length - ${#_JSH_PROMPT_GIT_BRANCH}))
		(( indicators >= 0 )) || indicators=0
		room=$((width - _JSH_PROMPT_DIR_MAX - indicators - 1))
		(( room >= 4 )) && _JSH_PROMPT_BRANCH_MAX=${room} || _JSH_PROMPT_BRANCH_MAX=1
	fi
	_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
	_jsh_prompt_visible_length "${full}"; full_length=${REPLY}
	if (( full_length > width )); then
		_JSH_PROMPT_HIDE_GIT=1
		_JSH_PROMPT_DIR_MAX=$((width - 4))
		(( _JSH_PROMPT_DIR_MAX > 0 )) || _JSH_PROMPT_DIR_MAX=1
		_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
		_jsh_prompt_visible_length "${full}"; full_length=${REPLY}
	fi
	if (( full_length > width )); then
		_JSH_PROMPT_HIDE_OS=1
		_JSH_PROMPT_DIR_MAX=${width}
		_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
	fi
	REPLY=${full}
}

_jsh_prompt_git_clear() {
	_JSH_PROMPT_GIT_BRANCH='' _JSH_PROMPT_GIT_STATE=''
	_JSH_PROMPT_GIT_STAGED=0 _JSH_PROMPT_GIT_UNSTAGED=0 _JSH_PROMPT_GIT_UNTRACKED=0
	_JSH_PROMPT_GIT_CONFLICTED=0 _JSH_PROMPT_GIT_AHEAD=0 _JSH_PROMPT_GIT_BEHIND=0
	_JSH_PROMPT_GIT_STASH=0
}

_jsh_prompt_git_parse() {
	local data=$1
	_jsh_prompt_git_clear
	[[ -n ${data} && ${data} != - ]] || return
	IFS='|' read -r _JSH_PROMPT_GIT_BRANCH _JSH_PROMPT_GIT_STAGED \
		_JSH_PROMPT_GIT_UNSTAGED _JSH_PROMPT_GIT_UNTRACKED _JSH_PROMPT_GIT_AHEAD \
		_JSH_PROMPT_GIT_BEHIND _JSH_PROMPT_GIT_STASH _JSH_PROMPT_GIT_CONFLICTED \
		_JSH_PROMPT_GIT_STATE <<< "${data}"
	_JSH_PROMPT_GIT_BRANCH=${_JSH_PROMPT_GIT_BRANCH//\%7C/|}
	_JSH_PROMPT_GIT_BRANCH=${_JSH_PROMPT_GIT_BRANCH//\%25/\%}
}

_jsh_prompt_git_operation() {
	local directory=$1 git_directory current='' total=''
	REPLY=''
	git_directory=$(command git -C "${directory}" rev-parse --absolute-git-dir 2>/dev/null) || return
	if [[ -d ${git_directory}/rebase-merge ]]; then
		REPLY=REBASE
		IFS= read -r current < "${git_directory}/rebase-merge/msgnum" 2>/dev/null || true
		IFS= read -r total < "${git_directory}/rebase-merge/end" 2>/dev/null || true
	elif [[ -d ${git_directory}/rebase-apply ]]; then
		[[ -f ${git_directory}/rebase-apply/applying ]] && REPLY=AM || REPLY=REBASE
		IFS= read -r current < "${git_directory}/rebase-apply/next" 2>/dev/null || true
		IFS= read -r total < "${git_directory}/rebase-apply/last" 2>/dev/null || true
	elif [[ -f ${git_directory}/MERGE_HEAD ]]; then REPLY=MERGE
	elif [[ -f ${git_directory}/CHERRY_PICK_HEAD ]]; then REPLY=CHERRY-PICK
	elif [[ -f ${git_directory}/REVERT_HEAD ]]; then REPLY=REVERT
	elif [[ -f ${git_directory}/BISECT_LOG ]]; then REPLY=BISECT
	fi
	if [[ -n ${REPLY} && ${current} == <-> && ${total} == <-> ]]; then
		REPLY+=" ${current}/${total}"
	fi
}

_jsh_prompt_git_worker() {
	emulate -L zsh
	local directory=$1 output line head='' oid='' xy state=''
	local -i staged=0 unstaged=0 untracked=0 conflicted=0 ahead=0 behind=0 stash=0
	output=$(GIT_OPTIONAL_LOCKS=0 command git -c core.fsmonitor=false -C "${directory}" status \
		--porcelain=v2 --branch --show-stash --untracked-files=normal \
		--ignore-submodules=dirty 2>/dev/null) || { print -r -- -; return; }
	for line in ${(f)output}; do
		case ${line} in
			'# branch.oid '*) oid=${line#\# branch.oid } ;;
			'# branch.head '*) head=${line#\# branch.head } ;;
			'# branch.ab '* )
				line=${line#\# branch.ab }
				ahead=${${line%% *}#+}
				behind=${${line##* }#-}
				;;
			'# stash '*) stash=${line#\# stash } ;;
			'1 '*|'2 '*)
				xy=${line[3,4]}
				[[ ${xy[1]} == . ]] || (( staged++ ))
				[[ ${xy[2]} == . ]] || (( unstaged++ ))
				;;
			'u '*) (( conflicted++ )) ;;
			'? '*) (( untracked++ )) ;;
		esac
	done
	[[ -n ${head} && ${head} != '(detached)' ]] || head="@${oid[1,7]}"
	_jsh_prompt_git_operation "${directory}"; state=${REPLY}
	head=${head//\%/%25}
	head=${head//|/%7C}
	print -r -- "${head}|${staged}|${unstaged}|${untracked}|${ahead}|${behind}|${stash}|${conflicted}|${state}"
}

_jsh_prompt_git_async_stop() {
	(( _JSH_PROMPT_GIT_FD >= 0 )) || return
	zle -F ${_JSH_PROMPT_GIT_FD} 2>/dev/null || true
	exec {_JSH_PROMPT_GIT_FD}<&-
	_JSH_PROMPT_GIT_FD=-1
}

_jsh_prompt_git_async_callback() {
	emulate -L zsh
	local descriptor=$1 data directory=${_JSH_PROMPT_GIT_PWD}
	IFS= read -r data <&${descriptor} || data=-
	zle -F ${descriptor} 2>/dev/null || true
	exec {descriptor}<&-
	_JSH_PROMPT_GIT_FD=-1
	[[ ${directory} == ${PWD} ]] || return
	_jsh_prompt_git_parse "${data}"
	_JSH_PROMPT_GIT_VALID=1 _JSH_PROMPT_GIT_DIRTY=0
	_jsh_prompt_render
	zle reset-prompt
}

_jsh_prompt_git_async_start() {
	_jsh_prompt_git_async_stop
	_JSH_PROMPT_GIT_PWD=${PWD}
	exec {_JSH_PROMPT_GIT_FD}< <(_jsh_prompt_git_worker "${PWD}") || return
	zle -F -w ${_JSH_PROMPT_GIT_FD} _jsh_prompt_git_async_callback 2>/dev/null || {
		exec {_JSH_PROMPT_GIT_FD}<&-
		_JSH_PROMPT_GIT_FD=-1
		return 1
	}
}

_jsh_prompt_git_update() {
	local data
	(( $+commands[git] )) || { _jsh_prompt_git_clear; return; }
	if [[ ${_JSH_PROMPT_GIT_PWD} != ${PWD} ]]; then
		_jsh_prompt_git_clear
		_JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_GIT_DIRTY=1
	fi
	(( _JSH_PROMPT_GIT_DIRTY || !_JSH_PROMPT_GIT_VALID )) || return
	if (( JSH_PROMPT_ASYNC )) && _jsh_prompt_git_async_start; then
		return
	fi
	data=$(_jsh_prompt_git_worker "${PWD}")
	_jsh_prompt_git_parse "${data}"
	_JSH_PROMPT_GIT_PWD=${PWD} _JSH_PROMPT_GIT_VALID=1 _JSH_PROMPT_GIT_DIRTY=0
}

_jsh_prompt_find_up() {
	local name=$1 directory=${PWD}
	REPLY=''
	while [[ -n ${directory} ]]; do
		[[ ! -r ${directory}/${name} ]] || { REPLY=${directory}/${name}; return; }
		[[ ${directory} != / ]] || break
		directory=${directory:h}
	done
	return 1
}

_jsh_prompt_node_update() {
	local file version
	[[ ${_JSH_PROMPT_NODE_PWD} != ${PWD} ]] || return
	_JSH_PROMPT_NODE_PWD=${PWD} _JSH_PROMPT_NODE=''
	if _jsh_prompt_find_up .nvmrc || _jsh_prompt_find_up .node-version; then
		file=${REPLY}
		IFS= read -r version < "${file}" || true
		version=${version#v}
		[[ -z ${version} ]] || _JSH_PROMPT_NODE=${version}
	elif [[ -n ${NODE_VERSION:-} ]]; then
		_JSH_PROMPT_NODE=${NODE_VERSION#v}
	fi
}

_jsh_prompt_kube_update() {
	_JSH_PROMPT_KUBE_CACHE=''
	[[ ${JSH_PROMPT_KUBE} != 0 ]] || return
	(( $+commands[kubectl] )) || return
	_JSH_PROMPT_KUBE_CACHE=$(command kubectl config current-context 2>/dev/null) || \
		_JSH_PROMPT_KUBE_CACHE=''
}

_jsh_prompt_kube_signature() {
	emulate -L zsh
	local config signature=${KUBECONFIG:-${HOME}/.kube/config}
	local -a configs
	local -A metadata

	zmodload -F zsh/stat b:zstat 2>/dev/null || { REPLY=''; return 1; }
	if [[ -n ${KUBECONFIG:-} ]]; then
		configs=("${(@s.:.)KUBECONFIG}")
	else
		configs=("${HOME}/.kube/config")
	fi
	for config in ${configs}; do
		metadata=()
		if zstat -F '%s.%N' -H metadata -- "${config}" 2>/dev/null; then
			signature+="|${metadata[inode]}:${metadata[size]}:${metadata[mtime]}:${metadata[ctime]}"
		else
			signature+='|missing'
		fi
	done
	REPLY=${signature}
}

_jsh_prompt_now() {
	if [[ -n ${EPOCHREALTIME:-} ]]; then
		printf -v REPLY '%.0f' "$((EPOCHREALTIME * 1000))"
	else
		REPLY=$((SECONDS * 1000))
	fi
}

_jsh_prompt_preexec() {
	_jsh_prompt_now
	_JSH_PROMPT_STARTED=${REPLY}
	_JSH_PROMPT_GIT_DIRTY=1
	case ${1%% *} in
		kubectl | kubectx | kubens) _JSH_PROMPT_KUBE_DIRTY=1 ;;
	esac
}

_jsh_prompt_precmd() {
	local exit_code=$? now
	jsh::reload_pending
	_JSH_PROMPT_EXIT=${exit_code}
	if [[ -n ${_JSH_PROMPT_STARTED} ]]; then
		_jsh_prompt_now; now=${REPLY}
		_JSH_PROMPT_DURATION=$((now - _JSH_PROMPT_STARTED))
	else
		_JSH_PROMPT_DURATION=0
	fi
	_JSH_PROMPT_STARTED=''
	_jsh_prompt_git_update
	_jsh_prompt_node_update
	if _jsh_prompt_kube_signature && [[ ${REPLY} != ${_JSH_PROMPT_KUBE_SIGNATURE} ]]; then
		_JSH_PROMPT_KUBE_SIGNATURE=${REPLY}
		_JSH_PROMPT_KUBE_DIRTY=1
	fi
	if (( _JSH_PROMPT_KUBE_DIRTY )); then
		_jsh_prompt_kube_update
		_JSH_PROMPT_KUBE_DIRTY=0
	fi
	_jsh_prompt_render
}

_jsh_prompt_expand() {
	local width=${COLUMNS:-80} left right overflow padding name
	local -a pinned extras
	local -i left_length right_length spaces left_budget max
	[[ ${width} == <-> && ${width} -gt 0 ]] || width=80
	max=${width}
	_JSH_PROMPT_TIME_MODE=full _JSH_PROMPT_COMPACT=0
	for name in ${JSH_PROMPT_RIGHT}; do
		case ${name} in
			duration|time) pinned+=(${name}) ;;
			*) extras+=(${name}) ;;
		esac
	done
	_jsh_prompt_join '  ' ${JSH_PROMPT_RIGHT}; right=${REPLY}
	_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
	# Compact the right side before abbreviating the directory.
	_jsh_prompt_build_left 100000
	_jsh_prompt_visible_length "${REPLY}"
	if (( REPLY + right_length >= max )); then
		_JSH_PROMPT_COMPACT=1
		_jsh_prompt_join '  ' ${JSH_PROMPT_RIGHT}; right=${REPLY}
		_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
	fi
	left_budget=$((width - right_length - 1))
	(( left_budget > 0 )) || left_budget=1
	_jsh_prompt_build_left ${left_budget}; left=${REPLY}
	_jsh_prompt_visible_length "${left}"; left_length=${REPLY}
	if (( left_length + right_length >= max )); then
		_jsh_prompt_join '  ' ${pinned}; right=${REPLY}
		_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
		if (( right_length > max )); then
			_JSH_PROMPT_TIME_MODE=compact
			_jsh_prompt_join '  ' ${pinned}; right=${REPLY}
			_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
		fi
		if (( right_length > max && ${pinned[(Ie)duration]} )); then
			pinned=(${pinned:#duration})
			extras=(duration ${extras})
			_jsh_prompt_join '  ' ${pinned}; right=${REPLY}
			_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
		fi
		if (( right_length > max )); then
			_jsh_prompt_clip "${right}" ${max}; right=${REPLY}
			_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
		fi
		left_budget=$((max - right_length - 1))
		(( left_budget > 0 )) || left_budget=1
		_jsh_prompt_build_left ${left_budget}; left=${REPLY}
		_jsh_prompt_clip "${left}" ${left_budget}; left=${REPLY}
		_JSH_PROMPT_COMPACT=0
		_jsh_prompt_join '  ' ${extras}; overflow=${REPLY}
		_jsh_prompt_visible_length "${overflow}"
		if (( REPLY > max )); then
			_JSH_PROMPT_COMPACT=1
			_jsh_prompt_join '  ' ${extras}; overflow=${REPLY}
		fi
		_jsh_prompt_clip "${overflow}" ${max}; overflow=${REPLY}
	fi
	_jsh_prompt_visible_length "${left}"; left_length=${REPLY}
	spaces=$((width - left_length - right_length))
	(( spaces > 0 )) || spaces=0
	printf -v padding '%*s' ${spaces} ''
	print -rn -- "${left}${padding}${right}"
	[[ -z ${overflow} ]] || print -rn -- $'\n'"${overflow}"
}

_jsh_prompt_character() {
	_jsh_prompt_segment_character
	print -rn -- "${REPLY}"
}

_jsh_prompt_render() {
	PROMPT="$(_jsh_prompt_expand)"$'\n'"$(_jsh_prompt_character)"
	RPROMPT=''
}

_jsh_prompt_chpwd() {
	_JSH_PROMPT_GIT_DIRTY=1 _JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_KUBE_DIRTY=1
	_jsh_prompt_git_clear
	_jsh_prompt_node_update
}

jsh_prompt_refresh() {
	_JSH_PROMPT_GIT_DIRTY=1 _JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_KUBE_DIRTY=1
	_jsh_prompt_precmd
}

jsh_prompt_status() {
	print -r -- "runtime=jsh glyphs=${_JSH_PROMPT_MODE} async=${JSH_PROMPT_ASYNC}"
}

add-zsh-hook preexec _jsh_prompt_preexec
add-zsh-hook precmd _jsh_prompt_precmd
add-zsh-hook chpwd _jsh_prompt_chpwd
add-zsh-hook zshexit _jsh_prompt_git_async_stop
zle -N _jsh_prompt_git_async_callback
_jsh_prompt_node_update
_jsh_prompt_render


# ============================================================================
# 9. PATH PRIORITIZATION / DEDUPLICATION
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
# 10. SHELL LIFECYCLE
# ============================================================================

jsh() {
  case ${1:-} in
    -r|reload)
      shift
      if (( $# )); then
        print -u2 -- 'Usage: jsh -r | jsh reload'
        return 2
      fi
      (( $+functions[_jsh_prompt_git_async_stop] )) && _jsh_prompt_git_async_stop
      setopt LOCAL_OPTIONS GLOBAL_EXPORT
      local JSH_RELOADING=1
      source "${JSH}/dotfiles/.zshrc"
      return
      ;;
    init)
      shift
      _jsh_init "$@"
      return
      ;;
  esac
  command "${JSH}/bin/jsh" "$@"
}

# These plugins must load after widgets and local customizations are defined.
typeset -gA ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[command]='fg=green'
ZSH_HIGHLIGHT_STYLES[hashed-command]='fg=green'

# Re-sourcing on reload makes the two plugins wrap each other's widgets into a loop.
# shellcheck disable=SC1090  # Vendored repositories
(( $+functions[_zsh_autosuggest_start] )) || \
  [[ ! -r "${JSH_VENDOR}/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] || \
  source "${JSH_VENDOR}/zsh-autosuggestions/zsh-autosuggestions.zsh"
(( $+functions[_zsh_highlight] )) || \
  [[ ! -r "${JSH_VENDOR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] || \
  source "${JSH_VENDOR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# Use the Git profile account for GitHub CLI commands in this repository.
gh() {
  local config=${JSH_GIT_PROFILES:-${JSH}/local/git.json} email users user token
  if { [[ ${1:-} == auth && ${2:-} != status ]]; } || ! command git rev-parse --git-dir >/dev/null 2>&1; then
    command gh "$@"
    return
  fi
  [[ -n ${JSH_GIT_PROFILES:-} || -e ${config} ]] || config=${XDG_CONFIG_HOME:-${HOME}/.config}/jsh/git.json
  [[ -r ${config} ]] || { command gh "$@"; return; }
  email=$(command git config --get user.email) || { command gh "$@"; return; }
  users=$(command jq -er --arg email "${email}" '[.profiles[] | select(.email == $email) | .user | select(type == "string" and length > 0)] | unique | if length > 1 then error("multiple GitHub users match Git profile") else .[0] // "" end' "${config}") || return 1
  user=${users}
  [[ -n ${user} ]] || { command gh "$@"; return; }
  token=$(command env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --hostname github.com --user "${user}") || {
    print -u2 -- "gh: cannot get credentials for Git profile account ${user}; run gh auth login"
    return 1
  }
  [[ -n ${token} ]] || { print -u2 -- "gh: empty credentials for Git profile account ${user}"; return 1; }
  GH_TOKEN=${token} command gh "$@"
}

# Interactive shell start: load Git profile SSH keys and run local/init.d scripts.

# Loads each Git profile ssh_key into the agent unless it is already loaded.
_jsh_load_keys() {
  local config=${JSH_GIT_PROFILES:-${JSH}/local/git.json} key public fingerprint loaded
  local -a keys ssh_add=(ssh-add) added failed
  [[ -n ${JSH_GIT_PROFILES:-} || -r ${config} ]] ||
    config=${XDG_CONFIG_HOME:-${HOME}/.config}/jsh/git.json
  [[ -r ${config} ]] || return 0
  (( $+commands[jq] )) || return 0
  keys=("${(@f)$(command jq -r '.profiles[]? | .ssh_key // empty' "${config}" 2>/dev/null)}")
  keys=(${(u)keys:#})
  (( ${#keys} )) || return 0
  loaded=$(command ssh-add -l 2>/dev/null)
  (( $? != 2 )) || return 0
  [[ ${OSTYPE} != darwin* || ! -x /usr/bin/ssh-add ]] ||
    ssh_add=(/usr/bin/ssh-add --apple-use-keychain)
  for key in "${keys[@]}"; do
    key=${key/#\~\//${HOME}/}
    [[ ${key} == */* ]] || key=${HOME}/.ssh/${key}
    if [[ ! -r ${key} ]]; then
      failed+=("${key:t} (missing)")
      continue
    fi
    public=${key}.pub
    [[ -r ${public} ]] || public=${key}
    fingerprint=${${(z)$(command ssh-keygen -lf "${public}" 2>/dev/null)}[2]}
    [[ -n ${fingerprint} && ${loaded} == *" ${fingerprint} "* ]] && continue
    if command "${ssh_add[@]}" -q "${key}"; then
      added+=("${key:t}")
    else
      failed+=("${key:t}")
    fi
  done
  (( ! ${#added} )) || jsh::log_success "ssh: added ${(j:, :)added}"
  (( ! ${#failed} )) || jsh::log_warn "ssh: could not load ${(j:, :)failed}"
}

# Runs each executable in JSH_INIT in name order, reporting only failures.
_jsh_run_init() {
  local script
  for script in "${JSH_INIT:-${JSH}/local/init.d}"/*(N.x); do
    "${script}" || jsh::log_error "init: ${script:t} failed"
  done
}

# Sources each local/init/*.zsh in name order so they can change this shell (e.g. SSH_AUTH_SOCK).
_jsh_init() {
  local script dir=${JSH}/local/init
  # Init scripts read J_INIT_DRY and J_INIT_YES.
  local -i J_INIT_DRY=0 J_INIT_YES=0 _jinit_status failed=0 tilde=0
  while (( $# )); do
    case $1 in
      -n|--dry-run) J_INIT_DRY=1 ;;
      -y|--yes) J_INIT_YES=1 ;;
      -h|--help)
        print -r -- 'Usage: jsh init [-n|--dry-run] [-y|--yes]'
        print -r -- 'Run local/init/*.zsh in this shell; -n previews, -y never prompts.'
        return 0
        ;;
      *)
        print -u2 -r -- "jsh init: unknown option: $1"
        return 2
        ;;
    esac
    shift
  done
  local -a scripts=("${dir}"/*.zsh(N.))
  if (( ! ${#scripts} )); then
    _j_ui_message info "No init scripts in ${(D)dir}"
    return 0
  fi
  # Init scripts written for the old j init expect this helper.
  (( $+functions[_j_stack_tilde] )) || { tilde=1; _j_stack_tilde() { print -rn -- "${(D)1}" } }
  for script in "${scripts[@]}"; do
    # Never source a script under -n unless it honors J_INIT_DRY.
    if (( J_INIT_DRY )) && [[ $(<"${script}") != *J_INIT_DRY* ]]; then
      _j_ui_message info "init: would run ${script:t:r}"
      continue
    fi
    _jinit_status=0
    source "${script}" || _jinit_status=$?
    (( _jinit_status == 0 )) && continue
    (( ++failed ))
    _j_ui_message error "init: ${script:t:r} failed"
  done
  (( ! tilde )) || unfunction _j_stack_tilde
  # Old j init scripts may leave this global behind.
  unset _jinit_key
  (( ! failed ))
}

# Agent shells and reloads skip start-up work.
if [[ -o interactive && ${JSH_RELOADING:-0} != 1 && ${JSH_LOAD_CONFIG:-1} == 1 ]] &&
  (( ! _jsh_agent_shell )); then
  _jsh_load_keys
  _jsh_run_init
fi

if (( _jsh_runtime_active )); then
  if (( _jsh_runtime_had_xdg_cache )); then
    export XDG_CACHE_HOME=${_jsh_runtime_xdg_cache}
  else
    unset XDG_CACHE_HOME
  fi
fi
unset _jsh_runtime_active _jsh_runtime_had_xdg_cache _jsh_runtime_xdg_cache

# jsh runtime path: begin
case ":${PATH}:" in
  *:"${HOME}/.local/bin":*) ;;
  *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac
# jsh runtime path: end
