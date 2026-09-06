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
export TERM=xterm-256color                       # Terminal type for 256 colors
export SH=${SHELL##*/}                           # Shell type reference

# Project/work directories
export GIT_BASE=${HOME}/projects                 # Git projects base
export WORK_DIR=${GIT_BASE}                      # Default work directory
export JSH=${${(%):-%N}:A:h:h}                   # Jsh repository root

typeset _jsh_rc
if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
  for _jsh_rc in "${HOME}/.jshrc" "${HOME}/.local/.jshrc" "${JSH}/local/.jshrc"; do
    [[ ! -r ${_jsh_rc} ]] || source "${_jsh_rc}"
  done
fi
unset _jsh_rc

# Silence/optimize specific tools
export DIRENV_LOG_FORMAT=                        # Silence direnv
export DIRENV_WARN_TIMEOUT=30s                   # Direnv timeout
export PYTHONDONTWRITEBYTECODE=1                 # No .pyc files on import

# Shell environment
export LANG=${JSH_LANG:-en_US.UTF-8}             # Default locale
export LC_ALL=${JSH_LANG:-en_US.UTF-8}           # Override all locales
export XDG_CONFIG_HOME="${HOME}/.config"         # Wwhere apps should store config files, cache files, and data files

# Vendored shell dependencies
export JSH_VENDOR="${JSH}/local/vendor"
export FZF_BASE="${JSH}/local/vendor/fzf"

# Terminal optimizations
export LESS="-RXE"                          # No wrapping, no clearing, exit on EOF
setopt NO_PROMPT_CR                         # Don't add CR before prompt

# ============================================================================
# 2. PLUGIN SYSTEM
# ============================================================================

typeset -a jsh_plugins=(fzf fzf-tab zsh-autosuggestions zsh-completions zsh-syntax-highlighting)
if [[ ${JSH_LOAD_CONFIG:-1} == 1 ]]; then
  for plugin in ${jsh_plugins}; do
    if [[ ! -d "${JSH_VENDOR}/${plugin}" ]]; then
      print -u2 -- "jsh submodules are missing. Run: git submodule update --init --recursive"
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

# Add repository, user, and vendored completions to fpath.
fpath=("${JSH}/dotfiles/.zsh/completions" ~/.zsh/completions \
  "${JSH_VENDOR}/zsh-completions/src" "${fpath[@]}")
typeset -gUa fpath

# Initialize completion system
typeset _jsh_compdump=${ZDOTDIR:-${HOME}}/.zcompdump
(( _jsh_runtime_active )) && _jsh_compdump=${JSH_RUNTIME_DIR}/cache/.zcompdump
autoload -Uz compinit && compinit -d "${_jsh_compdump}"
unset _jsh_compdump

# shellcheck disable=SC1090  # Pinned repository submodule
[[ -r "${JSH_VENDOR}/fzf-tab/fzf-tab.plugin.zsh" && -n ${commands[fzf]:-} ]] && \
  source "${JSH_VENDOR}/fzf-tab/fzf-tab.plugin.zsh"

# Register commands that declare completion metadata with a ##% comment.
typeset -g JSH_COMPLETION_PATHS=${JSH_COMPLETION_PATHS:-${JSH}/bin}
typeset -gA JSH_COMPLETION_SOURCES
autoload -Uz _jsh
for completion_dir in ${(s.:.)JSH_COMPLETION_PATHS}; do
  for completion_source in "${completion_dir}"/*(N); do
    [[ -f ${completion_source} && -x ${completion_source} ]] || continue
    completion_command=
    completion_line_count=0
    while IFS= read -r completion_line; do
      completion_line_count=$((completion_line_count + 1))
      (( completion_line_count <= 80 )) || break
      [[ ${completion_line} == '##% '* ]] || continue
      completion_command=${${completion_line#'##% '}%% *}
      break
    done < "${completion_source}"
    [[ -n ${completion_command} ]] || continue
    JSH_COMPLETION_SOURCES[${completion_command}]=${completion_source}
    compdef _jsh "${completion_command}"
  done
done
unset completion_command completion_dir completion_line completion_line_count completion_source

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'  # Case insensitive
# shellcheck disable=SC2296  # Zsh-specific parameter expansion syntax
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}" # Use LS_COLORS
zstyle ':completion:*' menu no                          # Don't show menu by default

# Fzf-tab preview settings
zstyle ':fzf-tab:complete:cd:*' fzf-preview "ls --color \$realpath"

# ---- Tool Completions ----

command -v brew &>/dev/null && eval "$(brew shellenv)"
command -v direnv &>/dev/null && eval "$(direnv hook zsh)"
command -v docker &>/dev/null && eval "$(docker completion zsh)"
# shellcheck disable=SC1090  # Dynamic source from fzf
command -v fzf &>/dev/null && source <(command fzf --zsh 2>/dev/null)
# shellcheck disable=SC1090  # Dynamic source from kubectl
command -v kubectl &>/dev/null && source <(kubectl completion zsh)
# shellcheck disable=SC1090  # Dynamic source from task
command -v task &>/dev/null && source <(task --completion zsh)
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

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
    *) JSH_OS=unknown ;;
  esac
fi
export JSH_OS

has() { whence -p -- "$1" >/dev/null 2>&1; }

_j_ui_message() {
  local level="$1" color="" reset="" mark="" output_fd=1
  shift
  case ${level} in
    success|ok) mark='✓'; color=$'\033[32m' ;;
    warn|warning) mark='!'; color=$'\033[33m'; output_fd=2 ;;
    error|fail) mark='✕'; color=$'\033[31m'; output_fd=2 ;;
    *) color=$'\033[36m' ;;
  esac

  if [[ -n ${NO_COLOR+x} || ${JSH_COLOR:-auto} == never || ${TERM:-dumb} == dumb ]] ||
    [[ ${JSH_COLOR:-auto} != always && ! -t ${output_fd} ]]; then
    color=""
  else
    reset=$'\033[0m'
  fi

  printf '%b%s%s%s%b\n' "${color}" "${mark}" "${mark:+ }" "$*" "${reset}" >&"${output_fd}"
}

# shellcheck disable=SC1090  # Repository-owned Zsh module
source "${JSH}/lib/zsh/j.zsh"

# ============================================================================
# 6. SHELL ALIASES
# ============================================================================

# ---- Directory Navigation ----

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'
alias ~='cd ~'
alias .2='cd ../../' .3='cd ../../../' .4='cd ../../../../' .5='cd ../../../../../' .6='cd ../../../../../../'

# ---- Directory Listing ----

unalias ls 2>/dev/null || true
if has eza; then
  function ls {
    local -a eza_args=(-a -l --git --icons --group-directories-first)
    local arg cluster flag

    while [[ $# -gt 0 ]]; do
      arg="$1"
      shift

      case "${arg}" in
        --)
          eza_args+=("--" "$@")
          break
          ;;
        --*|-)
          eza_args+=("${arg}")
          ;;
        -?*)
          cluster="${arg#-}"
          while [[ -n "${cluster}" ]]; do
            flag="${cluster%"${cluster#?}"}"
            cluster="${cluster#?}"
            case "${flag}" in
              t) eza_args+=("--sort=modified") ;;
              S) eza_args+=("--sort=size") ;;
              h) ;;
              *) eza_args+=("-${flag}") ;;
            esac
          done
          ;;
        *)
          eza_args+=("${arg}")
          ;;
      esac
    done

    command eza "${eza_args[@]}"
  }
  alias l='ls'
  alias ll='eza --git --icons --level=2 --long --tree'
  alias la='eza -la --group-directories-first --git --icons'
  alias lll='eza --git --icons --long --tree'
  alias lt='eza -la --sort=modified --icons'
  alias lS='eza -la --sort=size --icons'
  alias tree='eza --tree --icons'
elif has exa; then
  alias ls='exa --group-directories-first'
  alias l='exa -la --group-directories-first --git'
  alias ll='exa -l --group-directories-first'
  alias la='exa -la --group-directories-first'
  alias lt='exa -la --sort=modified'
  alias lS='exa -la --sort=size'
  alias tree='exa --tree'
else
  if command ls --color=auto --group-directories-first &>/dev/null; then
    alias ls='ls --color=auto --group-directories-first'
  else
    alias ls='ls -G'
  fi
  alias l='ls -lAh'
  alias ll='ls -lh'
  alias la='ls -lAh'
  alias lt='ls -lAht'
  alias lS='ls -lAhS'
fi

# ---- File Operations ----

alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -i'
alias mkdir='mkdir -pv'
alias ln='ln -iv'
alias t='touch'
alias dud='du -d 1 -h' duf='du -sh *'
if ! has eza; then
  alias lll='ls -laFh'
fi

# ---- Permissions ----

alias 000='chmod 000' 640='chmod 640' 644='chmod 644' 755='chmod 755' 775='chmod 775' mx='chmod a+x'

# ---- Search and Find ----

unalias grep egrep fgrep ggrep 2>/dev/null || true
unfunction grep egrep fgrep ggrep 2>/dev/null || true

_jsh_grep_backend='grep'
_jsh_grep_has_gnu=0
if has ggrep; then
  _jsh_grep_has_gnu=1
  [[ "${JSH_OS}" == macos ]] && _jsh_grep_backend='ggrep'
fi

_jsh_grep_run() {
  local executable="$1" mode="$2" argument directory explicit option_value=''
  local pattern_supplied=0 options_done=0
  local -a exclusions paths
  shift 2

  for argument in "$@"; do
    if [[ -n ${option_value} ]]; then
      [[ ${option_value} == pattern ]] && pattern_supplied=1
      option_value=''
      continue
    fi
    if [[ ${options_done} == 0 ]]; then
      case "${argument}" in
        --) options_done=1; continue ;;
        -e|-f|--regexp|--file) option_value=pattern; continue ;;
        -A|-B|-C|-D|-d|-m|--after-context|--before-context|--binary-files|--context|--devices|--directories|--exclude|--exclude-dir|--exclude-from|--group-separator|--include|--label|--max-count)
          option_value=option
          continue
          ;;
        -e?*|-f?*|--regexp=*|--file=*) pattern_supplied=1; continue ;;
        -*) continue ;;
      esac
    fi
    if [[ ${pattern_supplied} == 0 ]]; then
      pattern_supplied=1
    else
      paths+=("${argument}")
    fi
  done

  for directory in \
    .git .hg .svn \
    .venv venv .tox .nox .direnv \
    node_modules bower_components jspm_packages vendor Pods Carthage \
    __pycache__ .pytest_cache .mypy_cache .ruff_cache .hypothesis \
    .gradle .dart_tool .pub-cache .terraform \
    .cache .parcel-cache .turbo \
    build dist out target coverage htmlcov \
    .next .nuxt .svelte-kit .astro \
    zig-cache zig-out; do
    explicit=0
    for argument in "${paths[@]}"; do
      [[ -e ${argument} ]] || continue
      if [[ "/${argument#./}/" == *"/${directory}/"* ]]; then
        explicit=1
        break
      fi
    done
    [[ ${explicit} == 1 ]] || exclusions+=("--exclude-dir=${directory}")
  done

  if [[ -n ${mode} ]]; then
    command "${executable}" "${mode}" --color=auto "${exclusions[@]}" "$@"
  else
    command "${executable}" --color=auto "${exclusions[@]}" "$@"
  fi
}

grep() { _jsh_grep_run "${_jsh_grep_backend}" '' "$@"; }
egrep() { _jsh_grep_run "${_jsh_grep_backend}" -E "$@"; }
fgrep() { _jsh_grep_run "${_jsh_grep_backend}" -F "$@"; }
if [[ ${_jsh_grep_has_gnu} == 1 ]]; then
  ggrep() { _jsh_grep_run ggrep '' "$@"; }
fi
alias g='grep -i'

# ---- Quick Commands ----

alias c='clear'
alias clr='clear'
alias cls='clear'
alias now='date "+%Y-%m-%d %H:%M:%S"'
alias path='echo "$PATH" | tr ":" "\n"'
alias q='exit'
alias ts='date +%F-%H%M'
alias week='date +%V'
alias ccd='clear && cd' e='exit' fix_stty='stty sane' epochtime='date +%s'
alias timestamp='date "+%Y%m%dT%H%M%S"'

# ---- Editors ----

if has nvim; then
  alias vim='nvim'
  alias vi='nvim'
elif has vim; then
  alias vi='vim'
  alias v='vim'
fi

# ---- Disk and System ----

alias df='df -h'
alias du='du -h'
alias funcdef='declare -f' which='type -a'

# ---- Process Management ----

alias psg='ps aux | grep -v grep | grep'
alias psa='ps aux'
alias psl='ps aux | less'
has watch && alias w='watch -n1 -d -t '
has glances && alias glances='glances -1 -t 0.5'

# ---- Network ----

alias ports='listening'
alias myip='whatsmyip'

# ---- History ----

alias hist='history'
alias hg='history | grep'
alias h='history'

# ---- Superuser ----

alias _='sudo' please='sudo'

# ---- Git ----

if has git; then
  alias gs='git status -sb'
  alias gst='git status'
  alias ga='git add'
  alias gaa='git add --all'
  alias gap='git add -p'
  alias gc='git commit'
  alias gcm='git commit -m'
  alias gca='git commit --amend'
  alias gcan='git commit --amend --no-edit'
  alias gco='git checkout'
  alias gcb='git checkout -b'
  alias gb='git branch'
  alias gba='git branch -a'
  alias gbd='git branch -d'
  alias gd='git diff'
  alias gds='git diff --staged'
  alias gdw='git diff --word-diff'
  alias gl='git log --oneline -20'
  alias gla='git log --oneline --all --graph --decorate'
  alias glg='git log --graph --pretty=format:"%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset" --abbrev-commit'
  alias gp='git push'
  alias gpf='git push --force-with-lease'
  alias gpu='git push -u origin HEAD'
  alias gpl='git pull'
  alias gpr='git pull --rebase'
  alias gf='git fetch'
  alias gfa='git fetch --all --prune'
  alias gm='git merge'
  alias grb='git rebase'
  alias grbi='git rebase -i'
  alias grbc='git rebase --continue'
  alias grba='git rebase --abort'
  alias grs='git reset'
  alias grsh='git reset --hard'
  alias grss='git reset --soft'
  alias gss='git stash'
  alias gsp='git stash pop'
  alias gsl='git stash list'
  alias gsd='git stash drop'
  alias gcp='git cherry-pick'
  alias gcpc='git cherry-pick --continue'
  alias gcpa='git cherry-pick --abort'
  alias gwip='git add -A && git commit -m "WIP"'
  alias gunwip='git log -1 --format="%s" | grep -q "WIP" && git reset HEAD~1'
  alias gundo='git reset --soft HEAD~1'
  alias gclean='git clean -fd'
  alias gremote='git remote -v'
  alias gtag='git tag'
  alias gcount='git rev-list --count HEAD'
  alias gdiff='git diff --name-only master'
  alias gvimdiff='git difftool --tool=vimdiff --no-prompt'
fi

# ---- Docker ----

if has docker; then
  alias d='docker'
  alias dc='docker compose'
  alias dps='docker ps'
  alias dpsa='docker ps -a'
  alias di='docker images'
  alias dex='docker exec -it'
  alias drun='docker run -it --rm'
  alias dlogs='docker logs -f'
  alias dstop='docker stop $(docker ps -q) 2>/dev/null'
  alias drm='docker rm $(docker ps -aq) 2>/dev/null'
  alias drmi='docker rmi $(docker images -q) 2>/dev/null'
  alias dprune='docker system prune -af'
  alias dvol='docker volume ls'
  alias dnet='docker network ls'
fi

# ---- Kubernetes ----

if has kubectl; then
  alias k='kubectl'
  alias kx='kubectx 2>/dev/null || kubectl config get-contexts'
  alias kn='kubens 2>/dev/null || kubectl config set-context --current --namespace'
  alias kci='kubectl cluster-info'
  alias kg='kubectl get'
  alias kgg='kubectl get events --sort-by=".metadata.creationTimestamp"'
  alias kgp='kubectl get pods'
  alias kgpa='kubectl get pods --all-namespaces'
  alias kgd='kubectl get deployments'
  alias kgs='kubectl get services'
  alias kgn='kubectl get nodes'
  alias kgns='kubectl get namespaces'
  alias kgi='kubectl get ingress'
  alias kgcm='kubectl get configmaps'
  alias kgsec='kubectl get secrets'
  alias kd='kubectl describe'
  alias kdp='kubectl describe pod'
  alias kdd='kubectl describe deployment'
  alias kds='kubectl describe service'
  alias kl='kubectl logs -f'
  alias klp='kubectl logs -f --previous'
  alias kex='kubectl exec -it'
  alias kaf='kubectl apply -f'
  alias kdf='kubectl delete -f'
  alias kns='kubectl config view --minify -o jsonpath="{..namespace}"'
  alias ktop='kubectl top'
  alias ktopp='kubectl top pods'
  alias ktopn='kubectl top nodes'
  alias kpf='kubectl port-forward'
  alias kroll='kubectl rollout'
  alias krollr='kubectl rollout restart'
  alias krolls='kubectl rollout status'
  alias kav='kubectl api-versions'
  alias kctx='kubectx' kctx+='kubectx --add' kctx-='kubectx --delete'
  alias kexec='kubectl exec -it'
  alias netshoot='kubectl run tmp-shell --rm -i --tty --image nicolaka/netshoot'
fi

if has helm; then
  alias hl='helm list'
  alias hla='helm list -A'
  alias hi='helm install'
  alias hu='helm upgrade'
  alias hd='helm delete'
  alias hs='helm search repo'
  alias hr='helm repo'
  alias hra='helm repo add'
  alias hru='helm repo update'
fi

# ---- Infrastructure ----

if has tofu; then
  alias tf='tofu'
elif has terraform; then
  alias tf='terraform'
fi
if alias tf &>/dev/null; then
  alias tfi='tf init'
  alias tfp='tf plan'
  alias tfa='tf apply'
  alias tfaa='tf apply -auto-approve'
  alias tfd='tf destroy'
  alias tff='tf fmt'
  alias tfv='tf validate'
  alias tfo='tf output'
  alias tfs='tf state'
  alias tfsl='tf state list'
  alias tfw='tf workspace'
  alias tfwl='tf workspace list'
  alias tfws='tf workspace select'
fi

if has terragrunt; then
  alias tg='terragrunt'
  alias tgi='terragrunt init'
  alias tgp='terragrunt plan'
  alias tga='terragrunt apply'
  alias tgaa='terragrunt apply -auto-approve'
  alias tgd='terragrunt destroy'
  alias tgra='terragrunt run-all'
fi

if has ansible; then
  alias a='ansible' ap='ansible-playbook' av='ansible-vault'
fi

# ---- Tmux ----

if has tmux; then
  alias ta='tmux attach -t'
  alias tn='tmux new -s'
  alias tl='tmux ls'
  alias tk='tmux kill-session -t'
  alias tka='tmux kill-server'
fi

# ---- Languages and Package Managers ----

if has python3; then
  py() { command python3 "$@"; }
  pip() {
    if has pip3; then
      command pip3 "$@"
    else
      command python3 -m pip "$@"
    fi
  }
  alias py3='python3'
  alias venv='python3 -m venv'
elif has python; then
  py() { command python "$@"; }
  pip() { command python -m pip "$@"; }
  alias venv='python -m venv'

fi

if has python3 || has python; then
  alias deact='deactivate'

  unalias activate 2>/dev/null || true
  function activate {
    local activate_file="${PWD}/.venv/bin/activate"
    [[ -r "${activate_file}" ]] || return 0
    source "${activate_file}"
  }
fi

if has npm; then
  alias ni='npm install'
  alias nid='npm install --save-dev'
  alias nig='npm install -g'
  alias nr='npm run'
  alias ns='npm start'
  alias nt='npm test'
  alias nb='npm run build'
  alias nci='npm ci'
  alias nu='npm update'
  alias nout='npm outdated'
fi

if has yarn; then
  alias y='yarn'
  alias ya='yarn add'
  alias yad='yarn add -D'
  alias yr='yarn run'
  alias ys='yarn start'
  alias yt='yarn test'
  alias yb='yarn build'
fi

if has pnpm; then
  alias pn='pnpm'
  alias pni='pnpm install'
  alias pna='pnpm add'
  alias pnad='pnpm add -D'
  alias pnr='pnpm run'
fi

if has go; then
  alias gor='go run'
  alias gob='go build'
  alias got='go test'
  alias gotv='go test -v'
  alias gom='go mod'
  alias gomt='go mod tidy'
  alias gof='go fmt ./...'
  alias gol='golangci-lint run 2>/dev/null || go vet ./...'
fi

if has cargo; then
  alias cb='cargo build'
  alias cr='cargo run'
  alias ct='cargo test'
  alias cc='cargo check'
  alias cf='cargo fmt'
  alias ccl='cargo clippy'
fi

# ---- Misc Tools ----

if has aws; then
  alias awsw='aws sts get-caller-identity'
  alias awsp='export AWS_PROFILE=$(aws configure list-profiles | fzf)'
fi
has lazygit && alias lg='lazygit'
has lazydocker && alias lzd='lazydocker'
has k9s && alias k9='k9s'

# ---- SSH and Proxy ----

alias sshx='eval $(ssh-agent) && ssh-add 2>/dev/null'

# ---- Platform Specific ----

if [[ "${JSH_OS}" == macos ]]; then
  alias o='open'
  alias oo='open .'
  alias finder='open -a Finder'
  alias flushdns='sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder'
  alias showfiles='defaults write com.apple.finder AppleShowAllFiles YES; killall Finder'
  alias hidefiles='defaults write com.apple.finder AppleShowAllFiles NO; killall Finder'
  alias cpwd='pwd | pbcopy'
  has gawk && alias awk='gawk'
  has gsed && alias sed='gsed'
  has gtar && alias tar='gtar'
elif [[ "${JSH_OS}" == linux ]]; then
  alias pbcopy='xclip -selection clipboard 2>/dev/null || xsel --clipboard'
  alias pbpaste='xclip -selection clipboard -o 2>/dev/null || xsel --clipboard -o'
  alias cpwd='pwd | xclip -selection clipboard'
  [[ -x "${JSH}/bin/cafe" ]] && alias caffeinate='cafe'
fi

# ---- Colorized Output ----

if has grc; then
  alias colorize='grc -es --colour=auto'

  # shellcheck disable=SC1073,SC1072
  () {
    local grc_conf_dir=""
    for dir in /opt/homebrew/share/grc /usr/share/grc /usr/local/share/grc; do
      [[ -d "$dir" ]] && { grc_conf_dir="$dir"; break; }
    done

    if [[ -n "$grc_conf_dir" ]]; then
      local -a available_configs=($grc_conf_dir/conf.*(N:t:s/conf.//))

      for cmd in "${available_configs[@]}"; do
        case "$cmd" in
          common|dummy|esperanto|log|lolcat) continue ;;
          configure)
            configure() { command grc -es --colour=auto ./configure "$@"; }
            ;;
          make)
            make() { command grc -es --colour=auto make "$@"; }
            ;;
          *)
            if ! alias "$cmd" &>/dev/null && (( ! $+functions[$cmd] )); then
              alias "$cmd"="colorize $cmd"
            fi
            ;;
        esac
      done
    fi
  }
fi

# ---- File Viewing and Development ----

if has bat; then
  alias cat='bat'
elif has batcat; then
  alias cat='batcat'
fi
if has nvim || has vim; then
  alias edit='vim' vz='vim ~/.zshrc'
fi
alias show_options='setopt'

# ============================================================================
# 7. SHELL FUNCTIONS
# ============================================================================

# ---- Directory Navigation ----

up() {
  local count="${1:-1}"
  local _dir="" i
  [[ "${count}" == <1-> ]] || { _j_ui_message error "Usage: up <positive-count>"; return 1; }
  for ((i = 0; i < count; i++)); do
    _dir="../${_dir}"
  done
  cd "${_dir:-.}" || return 1
}

take() {
  [[ -z "${1:-}" ]] && { _j_ui_message error "Usage: take <dir>"; return 1; }
  command mkdir -p "$1" && builtin cd "$1" || return 1
}

bd() {
  local target="${1:-}"
  local _dir="${PWD}"
  [[ -n "${target}" ]] || { _j_ui_message error "Usage: bd <parent-name>"; return 1; }

  while [[ "${_dir}" != "/" ]]; do
    if [[ "$(basename "${_dir}")" == *"${target}"* ]]; then
      cd "${_dir}" || return 1
      return 0
    fi
    _dir="$(dirname "${_dir}")"
  done

  _j_ui_message error "No parent directory matching '${target}'"
  return 1
}

# ---- System & Process Management ----

ffpid() {
  [[ $# -gt 0 ]] || { _j_ui_message error "Usage: ffpid <process>"; return 1; }
  if has pgrep; then
    command pgrep -f -- "$*"
  elif has lsof; then
    command lsof -t -c "$1"
  else
    _j_ui_message error "pgrep or lsof is required"
    return 1
  fi
}

unalias free top 2>/dev/null || true
free() {
  if has free; then
    command free -h "$@"
  elif has vm_stat; then
    command vm_stat "$@"
  else
    _j_ui_message error "No supported memory reporting tool found"
    return 1
  fi
}

top() {
  if has htop; then
    command htop "$@"
  else
    command top "$@"
  fi
}

if [[ "${JSH_OS}" == linux ]]; then
  unalias open 2>/dev/null || true
  open() {
    if has xdg-open; then
      command xdg-open "$@"
    elif has sensible-browser; then
      command sensible-browser "$@"
    else
      _j_ui_message error "xdg-open or sensible-browser is required"
      return 1
    fi
  }
fi

quiet() {
  if [[ $# -eq 0 ]]; then
    return
  else
    "$@" &> /dev/null
  fi
}

# ---- Directory & File Operations ----

duh() {
  if [[ "${JSH_OS}" == macos ]]; then
    command du -hd 1 "${1:-.}"
  else
    command du -h --max-depth=1 "${1:-.}"
  fi | sort -h
}

bak() {
  [[ $# -eq 1 ]] || { _j_ui_message error "Usage: bak <file>"; return 1; }
  backup "$1"
}

backup() {
  local timestamp file destination source suffix result=0
  [[ $# -gt 0 ]] || { _j_ui_message error "Usage: backup <file...>"; return 1; }
  timestamp="$(date +%Y%m%d_%H%M%S)"

  for file in "$@"; do
    if [[ -e "${file}" ]]; then
      destination="${file}.${timestamp}.bak"
      suffix=1
      while [[ -e "${destination}" || -L "${destination}" ]]; do
        destination="${file}.${timestamp}.${suffix}.bak"
        ((suffix++))
      done
      source="${file:a}"
      if command cp -a "${source}" "${destination:a}"; then
        _j_ui_message success "Backed up: ${destination}"
      else
        _j_ui_message error "Backup failed: ${file}"
        result=1
      fi
    else
      _j_ui_message warn "Skipped (not found): ${file}"
      result=1
    fi
  done
  return "${result}"
}

extract() {
  local file="$1"
  [[ -z "${file}" ]] && { _j_ui_message error "Usage: extract <file>"; return 1; }
  [[ -f "${file}" ]] || { _j_ui_message error "File not found: ${file}"; return 1; }

  case "${file:l}" in
    *.tar.bz2|*.tbz2) tar xjf "${file}" ;;
    *.tar.gz|*.tgz) tar xzf "${file}" ;;
    *.tar.xz|*.txz) tar xJf "${file}" ;;
    *.tar.zst) tar --zstd -xf "${file}" ;;
    *.tar) tar xf "${file}" ;;
    *.bz2) bunzip2 "${file}" ;;
    *.gz) gunzip "${file}" ;;
    *.xz) unxz "${file}" ;;
    *.zst) unzstd "${file}" ;;
    *.zip) unzip "${file}" ;;
    *.rar) unrar x "${file}" ;;
    *.7z) 7z x "${file}" ;;
    *.z) uncompress "${file}" ;;
    *.deb) ar x "${file}" ;;
    *.rpm) rpm2cpio "${file}" | cpio -idmv ;;
    *)
      _j_ui_message error "Unknown archive format: ${file}"
      return 1
      ;;
  esac
}

compress() {
  local archive="$1"
  shift
  [[ -z "${archive}" ]] && { _j_ui_message error "Usage: compress <archive> <files...>"; return 1; }
  [[ $# -eq 0 ]] && { _j_ui_message error "No files specified"; return 1; }

  case "${archive:l}" in
    *.tar.bz2|*.tbz2) tar cjf "${archive}" "$@" ;;
    *.tar.gz|*.tgz) tar czf "${archive}" "$@" ;;
    *.tar.xz|*.txz) tar cJf "${archive}" "$@" ;;
    *.tar.zst) tar --zstd -cf "${archive}" "$@" ;;
    *.tar) tar cf "${archive}" "$@" ;;
    *.zip) zip -r "${archive}" "$@" ;;
    *.7z) 7z a "${archive}" "$@" ;;
    *)
      _j_ui_message error "Unknown archive format: ${archive}"
      return 1
      ;;
  esac
}

ff() {
  local pattern="${1:-}"
  local dir="${2:-.}"
  [[ -n "${pattern}" ]] || { _j_ui_message error "Usage: ff <pattern> [directory]"; return 1; }

  if has fd; then
    command fd --type f --fixed-strings --ignore-case -- "${pattern}" "${dir}"
  elif has find; then
    command find "${dir}" -type f -print 2>/dev/null | awk -v pattern="${pattern}" '
      index(tolower($0), tolower(pattern)) { print }
    '
  else
    _j_ui_message error "fd or find is required"
    return 1
  fi
}

ffd() {
  local pattern="${1:-}"
  local dir="${2:-.}"
  [[ -n "${pattern}" ]] || { _j_ui_message error "Usage: ffd <pattern> [directory]"; return 1; }

  if has fd; then
    command fd --type d --fixed-strings --ignore-case -- "${pattern}" "${dir}"
  elif has find; then
    command find "${dir}" -type d -print 2>/dev/null | awk -v pattern="${pattern}" '
      index(tolower($0), tolower(pattern)) { print }
    '
  else
    _j_ui_message error "fd or find is required"
    return 1
  fi
}

gr() {
  local pattern="$1"
  local dir="${2:-.}"

  if has rg; then
    rg "${pattern}" "${dir}"
  else
    grep -r --color=auto "${pattern}" "${dir}"
  fi
}

listening() {
  if has ss; then
    command ss -tuln
  elif has lsof; then
    command lsof -iTCP -sTCP:LISTEN -P -n
  elif has netstat; then
    command netstat -tuln
  else
    _j_ui_message error "No supported socket inspection tool found"
    return 1
  fi
}

killport() {
  local port="$1"
  [[ -z "${port}" ]] && { _j_ui_message error "Usage: killport <port>"; return 1; }
  [[ "${port}" == <1-65535> ]] || { _j_ui_message error "Invalid port: ${port}"; return 1; }

  local pids
  if has lsof; then
    pids=$(command lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null)
  elif has fuser; then
    pids=$(command fuser "${port}/tcp" 2>/dev/null)
  else
    _j_ui_message error "lsof or fuser is required"
    return 1
  fi

  if [[ -n "${pids}" ]]; then
    _j_ui_message info "Stopping PID(s) ${pids//$'\n'/, } on port ${port}"
    kill ${=pids}
  else
    _j_ui_message warn "No process found on port ${port}"
    return 1
  fi
}

whatsmyip() {
  command curl -fsS https://wtfismyip.com/text
}

localip() {
  local interface address

  if has ip; then
    address=$(command ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
  elif [[ "${JSH_OS}" == macos ]]; then
    interface=$(command route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
    [[ -n "${interface}" ]] && address=$(command ipconfig getifaddr "${interface}" 2>/dev/null)
  fi

  if [[ -z "${address}" ]] && has hostname; then
    address=$(command hostname -I 2>/dev/null | awk '{ print $1 }')
  fi
  [[ -n "${address}" ]] || {
    _j_ui_message error "Could not determine the primary local IPv4 address"
    return 1
  }
  printf '%s\n' "${address}"
}

perm() {
  [[ $# -gt 0 ]] || { _j_ui_message error "Usage: perm <path...>"; return 1; }
  if [[ "${JSH_OS}" == macos ]]; then
    command stat -f '%Lp %N' "$@"
  else
    command stat -c '%a %n' "$@"
  fi
}

function proxy+ {
  local endpoint="${1:-${PROXY_ENDPOINT:-}}"
  local bypass="${2:-${NO_PROXY_LIST:-localhost,127.0.0.1,::1}}"
  case "${endpoint}" in
    http://*|https://*) ;;
    *)
      _j_ui_message error "Usage: proxy+ <http-or-https-url> [no-proxy-list]"
      return 1
      ;;
  esac
  [[ "${endpoint}" != *[[:space:]]* ]] || {
    _j_ui_message error "Proxy URL cannot contain whitespace"
    return 1
  }

  export http_proxy="${endpoint}" https_proxy="${endpoint}"
  export HTTP_PROXY="${endpoint}" HTTPS_PROXY="${endpoint}"
  export NO_PROXY="${bypass}" no_proxy="${bypass}"
}

function proxy- {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
}

# ---- Development Utilities ----

git-stage-range() {
  local file="${1:-}" start="${2:-}" end="${3:-}" patch
  [[ -n "${file}" && "${start}" == <1-> && "${end}" == <1-> && ${start} -le ${end} ]] || {
    _j_ui_message error "Usage: git-stage-range <file> <start-line> <end-line>"
    return 1
  }

  patch="$(git diff -U0 -- "${file}" | awk -v start="${start}" -v end="${end}" '
    function emit_hunk() {
      if (hunk != "" && hunk_start <= end && hunk_end >= start) selected = selected hunk
    }
    /^@@ / {
      emit_hunk()
      hunk = $0 ORS
      range = $3
      sub(/^\+/, "", range)
      split(range, parts, ",")
      hunk_start = parts[1] + 0
      hunk_end = hunk_start + (parts[2] == "" ? 1 : parts[2]) - 1
      next
    }
    {
      if (hunk == "") header = header $0 ORS
      else hunk = hunk $0 ORS
    }
    END {
      emit_hunk()
      if (selected != "") printf "%s%s", header, selected
    }
  ')" || return 1

  [[ -n "${patch}" ]] || {
    _j_ui_message error "No unstaged changes overlap lines ${start}-${end}"
    return 1
  }
  printf '%s\n' "${patch}" | git apply --cached --unidiff-zero
}

git-stage-pattern() {
  local file="${1:-}" pattern="${2:-}" patch
  [[ -n "${file}" && -n "${pattern}" ]] || {
    _j_ui_message error "Usage: git-stage-pattern <file> <pattern>"
    return 1
  }

  patch="$(git diff -U0 -- "${file}" | awk -v pattern="${pattern}" '
    function emit_hunk() {
      if (hunk != "" && content ~ pattern) selected = selected hunk
    }
    /^@@ / {
      emit_hunk()
      hunk = $0 ORS
      content = ""
      next
    }
    {
      if (hunk == "") header = header $0 ORS
      else {
        hunk = hunk $0 ORS
        content = content $0 ORS
      }
    }
    END {
      emit_hunk()
      if (selected != "") printf "%s%s", header, selected
    }
  ')" || return 1

  [[ -n "${patch}" ]] || {
    _j_ui_message error "No unstaged lines match: ${pattern}"
    return 1
  }
  printf '%s\n' "${patch}" | git apply --cached --unidiff-zero
}

serve() {
  local port="${1:-8000}"
  local dir="${2:-.}"

  _j_ui_message info "Serving ${dir} on http://localhost:${port}"

  if has python3; then
    command python3 -m http.server "${port}" --directory "${dir}"
  elif has python; then
    (builtin cd "${dir}" && command python -m SimpleHTTPServer "${port}")
  elif has ruby; then
    command ruby -run -ehttpd "${dir}" -p"${port}"
  elif has php; then
    command php -S "localhost:${port}" -t "${dir}"
  else
    _j_ui_message error "No suitable HTTP server found (python, ruby, php)"
    return 1
  fi
}

jsonpp() {
  if has jq; then
    jq '.' "$@"
  elif has python3; then
    python3 -m json.tool "$@"
  elif has python; then
    python -m json.tool "$@"
  else
    _j_ui_message error "No JSON parser available (jq, python)"
    return 1
  fi
}

genpass() {
  local length="${1:-32}"
  local password
  [[ "${length}" == <1-> ]] || { _j_ui_message error "Usage: genpass <positive-length>"; return 1; }

  if has openssl; then
    password=$(command openssl rand -base64 "$((length * 2))" | command tr -dc 'a-zA-Z0-9' | command head -c "${length}")
  else
    password=$(LC_ALL=C command tr -dc 'a-zA-Z0-9' < /dev/urandom | command head -c "${length}")
  fi
  [[ ${#password} -eq ${length} ]] || { _j_ui_message error "Could not generate ${length} characters"; return 1; }
  printf '%s\n' "${password}"
}

urlencode() {
  local string="$1"
  if has python3; then
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$string"
  else
    echo "${string}" | sed 's/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g'
  fi
}

urldecode() {
  local string="$1"
  if has python3; then
    python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$string"
  else
    echo "${string}" | sed 's/%20/ /g; s/%21/!/g; s/%22/"/g; s/%23/#/g; s/%24/$/g; s/%26/\&/g'
  fi
}

# ---- Git Utilities ----

_git_confirm() {
  local action="$1"
  local reply

  printf '%s [y/N] ' "${action}"
  read -r reply || return 1

  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *)
      _j_ui_message info "Cancelled"
      return 1
      ;;
  esac
}

function git+ {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    _j_ui_message error "Detached HEAD: checkout a branch first"
    return 1
  }

  _git_confirm "Push '${branch}' to origin?" || return 1
  git push --set-upstream "$@" origin "${branch}"
}

function git+++ {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    _j_ui_message error "Detached HEAD: checkout a branch first"
    return 1
  }

  _git_confirm "Force-push '${branch}' to origin with --force-with-lease?" || return 1
  git push --set-upstream --force-with-lease "$@" origin "${branch}"
}

function git++ { git+++ "$@"; }

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

git_() {
  if [[ $# -eq 0 ]]; then
    git commit
  else
    git commit -m "$*"
  fi
}

gclone() {
  local repo="$1"
  [[ -z "${repo}" ]] && { _j_ui_message error "Usage: gclone <repo-url>"; return 1; }

  local dir
  dir="$(basename "${repo}" .git)"
  git clone "${repo}" && cd "${dir}" || return 1
}

http2ssh() {
  local remote="${1:-origin}" url ssh_url
  url=$(git remote get-url "${remote}" 2>/dev/null) || {
    _j_ui_message error "Git remote not found: ${remote}"
    return 1
  }

  case "${url}" in
    https://github.com/*) ssh_url="git@github.com:${url#https://github.com/}" ;;
    https://gitlab.com/*) ssh_url="git@gitlab.com:${url#https://gitlab.com/}" ;;
    https://bitbucket.org/*) ssh_url="git@bitbucket.org:${url#https://bitbucket.org/}" ;;
    git@*|ssh://*)
      _j_ui_message info "Remote '${remote}' already uses SSH"
      return 0
      ;;
    *)
      _j_ui_message error "Unsupported remote URL: ${url}"
      return 1
      ;;
  esac

  git remote set-url "${remote}" "${ssh_url}" || return 1
  _j_ui_message success "Updated '${remote}' to ${ssh_url}"
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

# ---- Remote Development ----

rcode() {
  [[ $# -ne 2 ]] && { echo "Usage: rcode <ssh_host> <remote_path>"; return 1; }
  code --remote "ssh-remote+${1}" "${2}"
}

# ---- Miscellaneous ----

weather() {
  local location="${1:-}"
  command curl -fsS "https://wttr.in/${location}?F"
}

cheat() {
  local topic="$1"
  [[ -z "${topic}" ]] && { _j_ui_message error "Usage: cheat <topic>"; return 1; }
  command curl -fsS "https://cheat.sh/${topic}"
}

timer() {
  local seconds="${1:-60}"
  local msg="${2:-Timer done!}"
  [[ "${seconds}" == <1-> ]] || { _j_ui_message error "Usage: timer <positive-seconds> [message]"; return 1; }

  echo "Timer: ${seconds} seconds"
  while [[ "${seconds}" -gt 0 ]]; do
    printf "\r%02d:%02d " $((seconds / 60)) $((seconds % 60))
    sleep 1
    ((seconds--))
  done
  printf "\r%s\n" "${msg}"

  if has osascript; then
    command osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Timer"' -e 'end run' "${msg}"
  elif has notify-send; then
    command notify-send "Timer" "${msg}"
  fi
}

calc() {
  local expr="$*"
  if [[ ! "$expr" =~ ^[0-9+\-*/\(\)\.\ %^]+$ ]]; then
    _j_ui_message error "calc: invalid characters in expression"
    return 1
  fi
  if has bc; then
    echo "scale=4; ${expr}" | bc -l
  else
    echo $(($expr))
  fi
}

note() {
  local notes_file="${HOME}/.notes"

  if [[ $# -eq 0 ]]; then
    [[ -f "${notes_file}" ]] && command cat "${notes_file}"
  else
    echo "$(date '+%Y-%m-%d %H:%M') $*" >> "${notes_file}"
    echo "Note added."
  fi
}

# ---- FZF Integration ----

if has fzf; then
  fcd() {
    local dir
    dir=$(find "${1:-.}" -type d 2>/dev/null | fzf --preview 'ls -la {}')
    [[ -n "${dir}" ]] && cd "${dir}" || return 1
  }

  fe() {
    local file
    file=$(fzf --preview 'head -100 {}')
    [[ -n "${file}" ]] && "${EDITOR:-vim}" "${file}"
  }

  fh() {
    local cmd
    cmd=$(history | fzf --tac | sed 's/^[ ]*[0-9]*[ ]*//')
    [[ -n "${cmd}" ]] && eval "${cmd}"
  }

  fkill() {
    local signal=TERM pattern selection pid
    if [[ "${1:-}" == -9 || "${1:-}" == --force ]]; then
      signal=KILL
      shift
    fi
    pattern="$*"
    selection=$(command ps aux | command awk -v pattern="${pattern}" '
      NR == 1 || pattern == "" || index(tolower($0), tolower(pattern))
    ' | command fzf --header-lines=1)
    pid=$(printf '%s\n' "${selection}" | command awk '{print $2}')
    [[ "${pid}" == <1-> ]] || return 1
    kill -s "${signal}" "${pid}"
  }

  fco() {
    local branch
    branch=$(git branch -a | fzf | sed 's/^[ *]*//' | sed 's|remotes/origin/||')
    [[ -n "${branch}" ]] && git checkout "${branch}"
  }

  fgl() {
    git log --oneline --graph --color=always | \
      fzf --ansi --preview 'git show --color=always {1}' | \
      awk '{print $1}'
  }
else
  _jsh_pick_array_item() {
    local wanted="$1" item n=1
    shift
    REPLY=""
    for item in "$@"; do
      if [[ $n -eq $wanted ]]; then REPLY="$item"; return 0; fi
      n=$((n + 1))
    done
    return 1
  }

  fcd() {
    local dir="${1:-.}"
    local dirs=()
    local i=1 d choice

    echo "Directories in ${dir}:"
    while IFS= read -r d; do
      dirs+=("$d")
      printf "%d) %s\n" "$i" "$d"
      ((i++))
      [[ $i -gt 50 ]] && { echo "... (limited to 50)"; break; }
    done < <(find "${dir}" -maxdepth 3 -type d 2>/dev/null | head -50)

    [[ ${#dirs[@]} -eq 0 ]] && { _j_ui_message warn "No directories found"; return 1; }
    printf "\nEnter number (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#dirs[@]} ]]; then
      _jsh_pick_array_item "$choice" "${dirs[@]}" && cd "$REPLY" || return 1
    else
      _j_ui_message error "Invalid selection"
      return 1
    fi
  }

  fe() {
    local files=()
    local i=1 f choice

    echo "Files in current directory:"
    while IFS= read -r f; do
      files+=("$f")
      printf "%d) %s\n" "$i" "$f"
      ((i++))
      [[ $i -gt 50 ]] && { echo "... (limited to 50)"; break; }
    done < <(find . -maxdepth 2 -type f 2>/dev/null | head -50)

    [[ ${#files[@]} -eq 0 ]] && { _j_ui_message warn "No files found"; return 1; }
    printf "\nEnter number (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#files[@]} ]]; then
      _jsh_pick_array_item "$choice" "${files[@]}" && "${EDITOR:-vim}" "$REPLY"
    else
      _j_ui_message error "Invalid selection"
      return 1
    fi
  }

  fh() {
    local pattern="${1:-}"
    local cmds=()
    local i=1 line cmd choice

    echo "Recent commands${pattern:+ matching '$pattern'}:"
    while IFS= read -r line; do
      cmd=$(echo "$line" | sed 's/^[ ]*[0-9]*[ ]*//')
      [[ -z "$cmd" ]] && continue
      [[ -n "$pattern" ]] && [[ "$cmd" != *"$pattern"* ]] && continue
      cmds+=("$cmd")
      printf "%d) %s\n" "$i" "${cmd:0:80}"
      ((i++))
      [[ $i -gt 30 ]] && break
    done < <(history | tail -100)

    [[ ${#cmds[@]} -eq 0 ]] && { _j_ui_message warn "No matching commands"; return 1; }
    printf "\nEnter number to execute (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#cmds[@]} ]]; then
      _jsh_pick_array_item "$choice" "${cmds[@]}" || return 1
      echo "Executing: ${REPLY}"
      eval "${REPLY}"
    else
      _j_ui_message error "Invalid selection"
      return 1
    fi
  }

  fkill() {
    local signal=TERM pattern pattern_lower
    if [[ "${1:-}" == -9 || "${1:-}" == --force ]]; then
      signal=KILL
      shift
    fi
    pattern="$*"
    pattern_lower="${(L)pattern}"
    local pids=()
    local i=1 line pid user cmd choice target_pid

    echo "Running processes${pattern:+ matching '$pattern'}:"
    echo "PID USER COMMAND"
    echo "--- ---- -------"

    while IFS= read -r line; do
      [[ $i -eq 1 ]] && { ((i++)); continue; }
      pid=$(echo "$line" | awk '{print $2}')
      user=$(echo "$line" | awk '{print $1}')
      cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')

      [[ -n "$pattern" ]] && [[ "${(L)cmd}" != *"${pattern_lower}"* ]] && continue
      pids+=("$pid")
      printf "%d) %-6s %-8s %s\n" "${#pids[@]}" "$pid" "$user" "${cmd:0:60}"
      [[ ${#pids[@]} -ge 30 ]] && break
    done < <(command ps aux)

    [[ ${#pids[@]} -eq 0 ]] && { _j_ui_message warn "No matching processes"; return 1; }
    printf "\nEnter number to kill (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 1

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#pids[@]} ]]; then
      _jsh_pick_array_item "$choice" "${pids[@]}" || return 1
      target_pid="${REPLY}"
      echo "Sending SIG${signal} to PID ${target_pid}..."
      kill -s "${signal}" "${target_pid}"
    else
      _j_ui_message error "Invalid selection"
      return 1
    fi
  }

  fco() {
    local branches=()
    local i=1 branch choice

    echo "Git branches:"
    while IFS= read -r branch; do
      branch=$(echo "$branch" | sed 's/^[ *]*//' | sed 's|remotes/origin/||')
      [[ -z "$branch" ]] && continue
      [[ "$branch" == "HEAD"* ]] && continue
      branches+=("$branch")
      printf "%d) %s\n" "$i" "$branch"
      ((i++))
      [[ $i -gt 30 ]] && { echo "... (limited to 30)"; break; }
    done < <(git branch -a 2>/dev/null)

    [[ ${#branches[@]} -eq 0 ]] && { _j_ui_message warn "No branches found (not a git repo?)"; return 1; }
    printf "\nEnter number to checkout (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#branches[@]} ]]; then
      _jsh_pick_array_item "$choice" "${branches[@]}" && git checkout "$REPLY"
    else
      _j_ui_message error "Invalid selection"
      return 1
    fi
  }

  fgl() {
    local commits=()
    local i=1 line sha msg choice

    echo "Recent commits:"
    while IFS= read -r line; do
      sha=$(echo "$line" | awk '{print $1}')
      msg=$(echo "$line" | cut -d' ' -f2-)
      commits+=("$sha")
      printf "%d) %s %s\n" "$i" "${sha:0:7}" "${msg:0:65}"
      ((i++))
      [[ $i -gt 30 ]] && break
    done < <(git log --oneline -30 2>/dev/null)

    [[ ${#commits[@]} -eq 0 ]] && { _j_ui_message warn "No commits found (not a git repo?)"; return 1; }
    printf "\nEnter number to show (or 'q' to cancel): "
    read -r choice
    [[ "${choice}" == "q" ]] && return 0

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#commits[@]} ]]; then
      _jsh_pick_array_item "$choice" "${commits[@]}" && git show "$REPLY"
    else
      _j_ui_message error "Invalid selection"
      return 1
    fi
  }
fi

# ============================================================================
# 8. THEME CUSTOMIZATION
# ============================================================================

# shellcheck disable=SC1090  # Repository-owned native prompt
source "${JSH}/lib/zsh/prompt.zsh"

# ============================================================================
# 9. PATH PRIORITIZATION / DEDUPLICATION
# ============================================================================

# Paths - ORDER MATTERS (priority: local > jsh > system)
export PATH=${HOME}/.local/bin:${JSH}/bin:${FZF_BASE}/bin:${HOME}/go/bin:${PATH}

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
    install|update)
      JSH_INSTALL_RETURN=1 command "${JSH}/bin/jsh" "$@" || return
      jsh reload
      ;;
    -r|reload)
      shift
      if (( $# )); then
        print -u2 -- 'Usage: jsh -r | jsh reload'
        return 2
      fi
      (( $+functions[_jsh_prompt_git_async_stop] )) && _jsh_prompt_git_async_stop
      setopt LOCAL_OPTIONS GLOBAL_EXPORT
      source "${JSH}/dotfiles/.zshrc"
      ;;
    *) command "${JSH}/bin/jsh" "$@" ;;
  esac
}

# These plugins must load after widgets and local customizations are defined.
# shellcheck disable=SC1090  # Pinned repository submodules
[[ -r "${JSH_VENDOR}/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && \
  source "${JSH_VENDOR}/zsh-autosuggestions/zsh-autosuggestions.zsh"
[[ -r "${JSH_VENDOR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && \
  source "${JSH_VENDOR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

if (( _jsh_runtime_active )); then
  if (( _jsh_runtime_had_xdg_cache )); then
    export XDG_CACHE_HOME=${_jsh_runtime_xdg_cache}
  else
    unset XDG_CACHE_HOME
  fi
fi
unset _jsh_runtime_active _jsh_runtime_had_xdg_cache _jsh_runtime_xdg_cache
