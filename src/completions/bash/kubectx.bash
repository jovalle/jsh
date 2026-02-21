#!/usr/bin/env bash
# kubectx.bash - Bash completion for kubectx
# shellcheck disable=SC2207

_kubectx_completion() {
    local cur prev
    _get_comp_words_by_ref -n : cur prev 2>/dev/null || cur="${COMP_WORDS[COMP_CWORD]}"

    case "$prev" in
        -a|--add) COMPREPLY=($(compgen -f -- "$cur")); return ;;
        -d|--delete|-e|--external) _kubectx_complete_contexts; return ;;
    esac

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "-a --add -c --current -d --delete -e --external -u --unset -h --help" -- "$cur"))
        else
            _kubectx_complete_contexts
        fi
    fi
}

_kubectx_complete_contexts() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    command -v kubectl &>/dev/null || return
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ')
    COMPREPLY=($(compgen -W "- $contexts" -- "$cur"))
    # Suppress trailing space if completing "-"
    [[ ${#COMPREPLY[@]} -eq 1 && "${COMPREPLY[0]}" == "-" ]] && compopt -o nospace
}

complete -F _kubectx_completion kubectx
