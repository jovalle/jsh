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
nukem() {
  if [ -z "$1" ]; then
    echo "Usage: $0 <namespace>"
    return 1
  fi

  kubectl get namespace "${1}" -o json | tr -d "\n" | sed "s/\"finalizers\": \[[^]]\+\]/\"finalizers\": []/" | kubectl replace --raw /api/v1/namespaces/"${1}"/finalize -f -
}
quiet() { [[ $# == 0 ]] && &> /dev/null || "$*" &> /dev/null ; } # quiet: Mute output of a command or redirection
rcode() { code --remote ssh-remote+${1:-${DEFAULT_REMOTE_HOST}} ${2:-/etc/${1:-${DEFAULT_REMOTE_HOST}}} } # rcode: Open remote dir in vscode
