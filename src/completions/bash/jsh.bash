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

    # Complete options for main commands.
    if [[ "$cur" == -* ]]; then
        local options
        options=$("$jsh_completion" options "$cmd" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
        COMPREPLY=($(compgen -W "$options" -- "$cur"))
        [[ ${#COMPREPLY[@]} -gt 0 ]] && return
    fi

    # setup supports file-path arguments for --adopt / --decom.
    if [[ "$cmd" == "setup" ]]; then
        if [[ "$prev" == "--adopt" || "$prev" == "--decom" ]]; then
            COMPREPLY=($(compgen -f -- "$cur"))
            return
        fi
        if [[ "$cur" == --adopt=* ]]; then
            local prefix="${cur%%=*}="
            local value="${cur#*=}"
            local matches
            COMPREPLY=()
            while IFS= read -r match; do
                COMPREPLY+=("${prefix}${match}")
            done < <(compgen -f -- "$value")
            return
        fi
        if [[ "$cur" == --decom=* ]]; then
            local prefix="${cur%%=*}="
            local value="${cur#*=}"
            local matches
            COMPREPLY=()
            while IFS= read -r match; do
                COMPREPLY+=("${prefix}${match}")
            done < <(compgen -f -- "$value")
            return
        fi
    fi

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
}

# Register completion
complete -F _jsh_completion jsh
