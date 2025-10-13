# Aliases

# Conditional aliases (order-specific)
command -v vim >/dev/null 2>&1 && alias vi='vim'
command -v eza >/dev/null 2>&1 && alias ls='eza --git --color=always --icons=always'
command -v nvim >/dev/null 2>&1 && alias vim='nvim'
command -v hx >/dev/null 2>&1 && alias vim='hx'

# General aliases
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
alias git+="git push --set-upstream origin \$(git rev-parse --abbrev-ref HEAD)" # Push current branch to origin
alias git-='git reset HEAD~1' # Undo last commit
alias gl="git log --graph --oneline" # Easy commit history
alias glances='glances -1 -t 0.5' # Faster output from glances
alias grep='grep --color=auto -i' # Preferred 'grep' implementation
alias gvimdiff='git difftool --tool=vimdiff --no-prompt' # Open all git changes in vimdiff
alias h='history'
alias k='kubectl' # Abbreviate kube control
alias kav='kubectl api-versions' # List all APIs
alias kci='kubectl cluster-info' # Show kube-api info
alias kctx='kubectx' # Change kube context
alias kdf='kubectl delete -f' # Inverse of `kaf`
alias kenc="sops --age \$(cat \${SOPS_AGE_KEY_FILE} | grep -oP \"public key: \K(.*)\") --encrypt --encrypted-regex '^(data|stringData)$' --in-place"
alias kexec='kubectl exec -it' # Open terminal into pod
alias kns='kubens' # Change kube namespace
alias l='ls -la' # Long, show hidden files
alias ls='ls --color' # Show colors
alias less='less -FSRXc' # Preferred 'less' implementation
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
alias proxy+="export {{http,https}_proxy,{HTTP,HTTPS}_PROXY}=${PROXY_ENDPOINT}; export {NO_PROXY,no_proxy}=${PROXY_ENDPOINT:-go,localhost}" # proxy+: set as per env and on command
alias proxy-="unset {http,https}_proxy {HTTP,HTTPS}_PROXY {NO_PROXY,no_proxy}" # proxy-: unset proxy env vars
alias rm='rm -i' # Always prompt before deleting
alias show_options='shopt' # Show_options: display bash options settings
alias sshx='eval $(ssh-agent) && ssh-add 2>/dev/null' # sshx: Import SSH keys
alias stowrm='find $HOME -maxdepth 1 -type l | xargs -I {} unlink {}' # stowrm: Remove all symlinks (`stow -D` only removes existing matches)
alias sudo='sudo ' # Enable aliases to be sudo’ed
alias t="touch" # Create file
alias tf='terraform' # Abbreviation
alias timestamp='date "+%Y%m%dT%H%M%S"' # Filename ready complete time format
alias tmux="tmux -2" # Force 256 color support
alias ts='date +%F-%H%M' # Timestamp (2025-09-20-1022)
alias vscode='open -a "Visual Studio Code"' # VSCode shortcut
alias vz='vim ~/.zshrc' # Open zshrc
alias w='watch -n1 -d -t ' # Faster watch, highlight changes and no title
alias wget='wget -c' # Preferred 'wget' implementation (resume download)
alias whatis='declare -f' # Print function definition
alias which='type -a' # Preferred 'which' implementation
alias work='cd ${WORK_DIR:-${HOME}}' # Shortcut to project dir

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
