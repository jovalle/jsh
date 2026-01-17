#!/usr/bin/env bash
# jssh.bash - Bash completion for jssh (SSH with portable Jsh environment)
# Extends ssh completion with jssh-specific options
# shellcheck disable=SC2207

_jssh_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    # jssh-specific options
    local jssh_opts="--help -h --check --status --rebuild"

    # Check if we already have a jssh-specific terminal option
    local has_terminal_opt=0
    for word in "${words[@]}"; do
        case "$word" in
            --check|--status|--rebuild|--help|-h)
                has_terminal_opt=1
                break
                ;;
        esac
    done

    # If terminal option given, no more completions
    if [[ $has_terminal_opt -eq 1 ]] && [[ $cword -gt 1 ]]; then
        COMPREPLY=()
        return
    fi

    # First argument - offer jssh options and hosts
    if [[ $cword -eq 1 ]]; then
        # If starting with -, complete jssh options
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "$jssh_opts" -- "$cur"))
            return
        fi

        # Otherwise, complete hosts
        _jssh_complete_hosts
        return
    fi

    # SSH option handling
    case "$prev" in
        -p)
            # Port number - no completion
            COMPREPLY=()
            return
            ;;
        -i|-F)
            # Identity file or config file
            _filedir
            return
            ;;
        -l)
            # Login name
            _jssh_complete_users
            return
            ;;
        -o)
            # SSH options
            _jssh_complete_ssh_options
            return
            ;;
        -J)
            # Jump host
            _jssh_complete_hosts
            return
            ;;
    esac

    # If current word starts with -, complete SSH options
    if [[ "$cur" == -* ]]; then
        local ssh_opts="-p -i -l -o -F -J -4 -6 -A -C -q -v -X -Y -N -T -t"
        COMPREPLY=($(compgen -W "$jssh_opts $ssh_opts" -- "$cur"))
        return
    fi

    # Default: complete hosts
    _jssh_complete_hosts
}

# Complete SSH hosts from known_hosts and ssh_config
_jssh_complete_hosts() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local hosts=""

    # From ssh_config
    if [[ -f ~/.ssh/config ]]; then
        hosts+=$(awk '/^Host / && !/\*/ {print $2}' ~/.ssh/config 2>/dev/null | tr '\n' ' ')
    fi

    # From known_hosts (skip hashed entries)
    if [[ -f ~/.ssh/known_hosts ]]; then
        hosts+=$(/usr/bin/cut -f1 -d' ' ~/.ssh/known_hosts 2>/dev/null | \
            /usr/bin/tr ',' '\n' | \
            /usr/bin/grep -v '^#' | \
            /usr/bin/grep -v '^\[' | \
            /usr/bin/grep -v '^|' | \
            sort -u | tr '\n' ' ')
    fi

    # Generate unique completions
    local unique_hosts
    unique_hosts=$(echo "$hosts" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    COMPREPLY=($(compgen -W "$unique_hosts" -- "$cur"))
}

# Complete SSH users
_jssh_complete_users() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local users="root admin ubuntu ec2-user centos debian $USER"
    COMPREPLY=($(compgen -W "$users" -- "$cur"))
}

# Complete SSH -o options
_jssh_complete_ssh_options() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local options="
        AddKeysToAgent
        BatchMode
        BindAddress
        CanonicalizeHostname
        Compression
        ConnectionAttempts
        ConnectTimeout
        ControlMaster
        ControlPath
        ControlPersist
        ForwardAgent
        ForwardX11
        HostKeyAlgorithms
        IdentityFile
        LocalForward
        LogLevel
        Port
        PreferredAuthentications
        ProxyCommand
        ProxyJump
        PubkeyAuthentication
        RemoteForward
        RequestTTY
        ServerAliveCountMax
        ServerAliveInterval
        StrictHostKeyChecking
        TCPKeepAlive
        User
        UserKnownHostsFile
    "
    COMPREPLY=($(compgen -W "$options" -- "$cur"))
}

# Register completion
complete -F _jssh_completion jssh
