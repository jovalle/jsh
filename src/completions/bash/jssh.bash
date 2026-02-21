#!/usr/bin/env bash
# jssh.bash - Bash completion for jssh (SSH with portable Jsh environment)
# Completes hosts only - use --help for options
# shellcheck disable=SC2207

_jssh_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    # Complete hosts only - options available via --help
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

# Register completion
complete -F _jssh_completion jssh
