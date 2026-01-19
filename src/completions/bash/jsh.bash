#!/usr/bin/env bash
# jsh.bash - Bash completion for jsh CLI
# Dynamic extraction of commands and options from @jsh-* metadata
# shellcheck disable=SC2207

_jsh_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    local jsh_completion="${JSH_DIR:-${HOME}/.jsh}/bin/jsh-completion"

    # Check if helper exists
    if [[ ! -x "$jsh_completion" ]]; then
        return
    fi

    # First argument - complete commands (options available via --help)
    if [[ $cword -eq 1 ]]; then
        local commands
        commands=$("$jsh_completion" commands 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    # Get the main command
    local cmd="${words[1]}"

    # Get subcommands for this command (options available via --help)
    local subcommands
    subcommands=$("$jsh_completion" subcommands "$cmd" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')

    # Second argument - complete subcommands only
    if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        return
    fi

    # No further completions
    COMPREPLY=()

    # Handle special dynamic completions (positional arguments only)
    case "$cmd" in
        host)
            if [[ "${words[2]}" =~ ^(status|refresh|reset)$ ]] && [[ $cword -eq 3 ]]; then
                _jsh_host_names
            fi
            ;;
    esac
}

# Dynamic completion: remote host names
_jsh_host_names() {
    local hosts_dir="${JSH_DIR:-${HOME}/.jsh}/local/hosts"
    local hosts=""

    if [[ -d "$hosts_dir" ]]; then
        hosts=$(find "$hosts_dir" -maxdepth 1 -name '*.json' -exec basename {} .json \; 2>/dev/null | tr '\n' ' ')
    fi

    COMPREPLY=($(compgen -W "$hosts" -- "${COMP_WORDS[COMP_CWORD]}"))
}

# Register completion
complete -F _jsh_completion jsh
