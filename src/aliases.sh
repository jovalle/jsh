# aliases.sh - Tiered alias system
# Core aliases always load, extended aliases load if tools detected
# shellcheck disable=SC2139,SC2034,SC2142,SC2262,SC2263
# SC2262/SC2263: Defining and checking aliases in same file is standard for shell configs

[[ -n "${_JSH_ALIASES_LOADED:-}" ]] && return 0
_JSH_ALIASES_LOADED=1

# =============================================================================
# Core Aliases (Always Loaded)
# =============================================================================

alias p='j'
alias jj='gitx profile'
alias projects='gitx list -v'

# -----------------------------------------------------------------------------
# Navigation
# -----------------------------------------------------------------------------
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'

alias ~='cd ~'

# -----------------------------------------------------------------------------
# Directory Listing
# -----------------------------------------------------------------------------
# Smart ls: use eza if available, else ls with colors
if has eza; then
  alias ls='eza --group-directories-first'
  alias l='eza -la --group-directories-first --git'
  alias ll='eza -l --group-directories-first'
  alias la='eza -la --group-directories-first'
  alias lt='eza -la --sort=modified'
  alias lS='eza -la --sort=size'
  alias tree='eza --tree'
elif has exa; then
  alias ls='exa --group-directories-first'
  alias l='exa -la --group-directories-first --git'
  alias ll='exa -l --group-directories-first'
  alias la='exa -la --group-directories-first'
  alias lt='exa -la --sort=modified'
  alias lS='exa -la --sort=size'
  alias tree='exa --tree'
else
  # BSD vs GNU ls colors
  if ls --color=auto &>/dev/null; then
    alias ls='ls --color=auto --group-directories-first'
  else
    alias ls='ls -G' # macOS/BSD
  fi
  alias l='ls -lAh'
  alias ll='ls -lh'
  alias la='ls -lAh'
  alias lt='ls -lAht'
  alias lS='ls -lAhS'
fi

# -----------------------------------------------------------------------------
# File Operations (Safe Defaults)
# -----------------------------------------------------------------------------
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -I' # Prompt before removing more than 3 files
alias mkdir='mkdir -pv'
alias ln='ln -iv'

# -----------------------------------------------------------------------------
# Search and Find
# -----------------------------------------------------------------------------
alias grep='grep --color=auto'
alias fgrep='grep -F'
alias egrep='grep -E'

# -----------------------------------------------------------------------------
# File Viewing
# -----------------------------------------------------------------------------
# Use bat if available
if has bat; then
  alias cat='bat --paging=never'
  alias less='bat'
elif has batcat; then
  alias cat='batcat --paging=never'
  alias less='batcat'
fi

# -----------------------------------------------------------------------------
# Quick Commands
# -----------------------------------------------------------------------------
alias c='clear'
alias e='exit'
alias q='exit'
alias cls='clear'
alias clr='clear'

alias path='echo "$PATH" | tr ":" "\n"'
alias now='date "+%Y-%m-%d %H:%M:%S"'
alias ts='date +%s'
alias week='date +%V'

alias reload='exec "${SHELL}"'
alias rl='exec "${SHELL}"'

# -----------------------------------------------------------------------------
# Editors
# -----------------------------------------------------------------------------
if has nvim; then
  alias vim='nvim'
  alias vi='nvim'
elif has vim; then
  alias vi='vim'
  alias v='vim'
fi

alias e='"${EDITOR:-vi}"'

# -----------------------------------------------------------------------------
# Disk and System
# -----------------------------------------------------------------------------
alias df='df -h'
alias du='du -h'
alias free='free -h 2>/dev/null || vm_stat' # Linux vs macOS

# -----------------------------------------------------------------------------
# Process Management
# -----------------------------------------------------------------------------
alias psg='ps aux | grep -v grep | grep'
alias psa='ps aux'
alias top='htop 2>/dev/null || top'

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
alias ping='ping -c 5'
alias ports='netstat -tulanp 2>/dev/null || lsof -i -P -n'
alias myip='curl -s https://api.ipify.org && echo'
alias localip='ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk "{print \$1}"'

# -----------------------------------------------------------------------------
# History
# -----------------------------------------------------------------------------
alias hist='history'
alias hg='history | grep'

# =============================================================================
# Git Aliases
# =============================================================================

if has git; then
  alias g='git'
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
fi

# =============================================================================
# Extended Aliases (Tool Detection)
# =============================================================================

# -----------------------------------------------------------------------------
# Claude
# -----------------------------------------------------------------------------
if has claude; then
  alias claude-mem=bun "$HOME/.claude/plugins/marketplaces/thedotmack/plugin/scripts/worker-service.cjs"
  alias claudia='claude --permission-mode plan --allow-dangerously-skip-permissions'
fi

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------
if has kubectl; then
  alias k='kubectl'
  alias kx='kubectx 2>/dev/null || kubectl config get-contexts'
  alias kn='kubens 2>/dev/null || kubectl config set-context --current --namespace'
  alias kg='kubectl get'
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
  alias kctx='kubectl config current-context'
  alias kns='kubectl config view --minify -o jsonpath="{..namespace}"'
  alias ktop='kubectl top'
  alias ktopp='kubectl top pods'
  alias ktopn='kubectl top nodes'
  alias kpf='kubectl port-forward'
  alias kroll='kubectl rollout'
  alias krollr='kubectl rollout restart'
  alias krolls='kubectl rollout status'
fi

# Helm
if has helm; then
  alias h='helm'
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

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------
if has terraform; then
  alias tf='terraform'
  alias tfi='terraform init'
  alias tfp='terraform plan'
  alias tfa='terraform apply'
  alias tfaa='terraform apply -auto-approve'
  alias tfd='terraform destroy'
  alias tff='terraform fmt'
  alias tfv='terraform validate'
  alias tfo='terraform output'
  alias tfs='terraform state'
  alias tfsl='terraform state list'
  alias tfw='terraform workspace'
  alias tfwl='terraform workspace list'
  alias tfws='terraform workspace select'
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

# -----------------------------------------------------------------------------
# Tmux
# -----------------------------------------------------------------------------
if has tmux; then
  alias t='tmux'
  alias ta='tmux attach -t'
  alias tn='tmux new -s'
  alias tl='tmux ls'
  alias tk='tmux kill-session -t'
  alias tka='tmux kill-server'
fi

# -----------------------------------------------------------------------------
# Python
# -----------------------------------------------------------------------------
if has python3 || has python; then
  alias py='python3 2>/dev/null || python'
  alias py3='python3'
  alias pip='pip3 2>/dev/null || pip'
  alias venv='python3 -m venv'
  alias activate='source venv/bin/activate 2>/dev/null || source .venv/bin/activate'
  alias deact='deactivate'
fi

# -----------------------------------------------------------------------------
# Node.js
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Go
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Rust
# -----------------------------------------------------------------------------
if has cargo; then
  alias cb='cargo build'
  alias cr='cargo run'
  alias ct='cargo test'
  alias cc='cargo check'
  alias cf='cargo fmt'
  alias ccl='cargo clippy'
fi

# -----------------------------------------------------------------------------
# AWS
# -----------------------------------------------------------------------------
if has aws; then
  alias awsw='aws sts get-caller-identity'
  alias awsp='export AWS_PROFILE=$(aws configure list-profiles | fzf)'
fi

# -----------------------------------------------------------------------------
# Misc Tools
# -----------------------------------------------------------------------------
if has lazygit; then
  alias lg='lazygit'
fi

if has lazydocker; then
  alias lzd='lazydocker'
fi

if has k9s; then
  alias k9='k9s'
fi

# -----------------------------------------------------------------------------
# macOS Specific
# -----------------------------------------------------------------------------
if [[ "${JSH_OS}" == "macos" ]]; then
  alias o='open'
  alias oo='open .'
  alias finder='open -a Finder'
  alias flushdns='sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder'
  alias showfiles='defaults write com.apple.finder AppleShowAllFiles YES; killall Finder'
  alias hidefiles='defaults write com.apple.finder AppleShowAllFiles NO; killall Finder'
  alias cpwd='pwd | pbcopy'

  # Use GNU tools if available
  has gawk && alias awk='gawk'
  has gsed && alias sed='gsed'
  has gtar && alias tar='gtar'
  has ggrep && alias grep='ggrep --color=auto'
fi

# -----------------------------------------------------------------------------
# Linux Specific
# -----------------------------------------------------------------------------
if [[ "${JSH_OS}" == "linux" ]]; then
  alias pbcopy='xclip -selection clipboard 2>/dev/null || xsel --clipboard'
  alias pbpaste='xclip -selection clipboard -o 2>/dev/null || xsel --clipboard -o'
  alias open='xdg-open 2>/dev/null || sensible-browser'
  alias cpwd='pwd | xclip -selection clipboard'
fi
