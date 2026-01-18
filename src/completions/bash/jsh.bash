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

    local jsh_complete="${JSH_DIR:-${HOME}/.jsh}/bin/jsh-complete"

    # Check if helper exists
    if [[ ! -x "$jsh_complete" ]]; then
        return
    fi

    # First argument - complete commands
    if [[ $cword -eq 1 ]]; then
        local commands
        commands=$("$jsh_complete" commands 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
        COMPREPLY=($(compgen -W "$commands -h --help -v --version" -- "$cur"))
        return
    fi

    # Get the main command
    local cmd="${words[1]}"

    # Get subcommands and options for this command
    local subcommands options
    subcommands=$("$jsh_complete" subcommands "$cmd" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
    options=$("$jsh_complete" options "$cmd" 2>/dev/null | cut -d: -f1 | tr ',' ' ' | tr '\n' ' ')

    # Second argument - complete subcommands or options
    if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$subcommands $options -h --help" -- "$cur"))
        return
    fi

    # Third+ argument - complete options
    COMPREPLY=($(compgen -W "$options -h --help" -- "$cur"))

    # Handle special dynamic completions
    case "$cmd" in
        host)
            if [[ "${words[2]}" =~ ^(status|refresh|reset)$ ]] && [[ $cword -eq 3 ]]; then
                _jsh_host_names
            fi
            ;;
        unlink)
            if [[ "$prev" == "--restore" ]] || [[ "$cur" == "--restore="* ]]; then
                _jsh_backup_names
            fi
            ;;
    esac
}

# Dynamic completion: remote host names
_jsh_host_names() {
    local hosts_dir="${JSH_DIR:-${HOME}/.jsh}/local/hosts"
    local hosts=""

    if [[ -d "$hosts_dir" ]]; then
        hosts=$(find "$hosts_dir" -maxdepth 1 -name '*.json' 2>/dev/null | \
            xargs -I {} basename {} .json | tr '\n' ' ')
    fi

    COMPREPLY=($(compgen -W "$hosts" -- "${COMP_WORDS[COMP_CWORD]}"))
}

# Dynamic completion: backup names
_jsh_backup_names() {
    local backup_dir="${HOME}/.jsh_backup"
    local backups="latest"

    if [[ -d "$backup_dir" ]]; then
        local dir_backups
        dir_backups=$(find "$backup_dir" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | \
            xargs -I {} basename {} | tr '\n' ' ')
        backups="$backups $dir_backups"
    fi

    COMPREPLY=($(compgen -W "$backups" -- "${COMP_WORDS[COMP_CWORD]}"))
}

# Register completion
complete -F _jsh_completion jsh
