#!/usr/bin/env bash
# j.bash - Bash completion for j command (smart directory jumping)
# Provides directory suggestions from the frecency database and projects
# shellcheck disable=SC2207

_j_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    # Complete directories only - use --help for options
    _j_complete_directories
}

_j_complete_directories() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local j_data="${J_DATA:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/j.db}"
    local dirs=""

    # Load from j database
    if [[ -f "$j_data" ]]; then
        local line path score time
        while IFS='|' read -r path score time; do
            [[ -z "$path" ]] && continue
            [[ ! -d "$path" ]] && continue
            # Add the path (convert to display format if it starts with HOME)
            if [[ "$path" == "${HOME}"* ]]; then
                dirs+="~${path#"$HOME"} "
            else
                dirs+="$path "
            fi
        done < "$j_data"
    fi

    # Add projects from JSH_PROJECTS paths (fast - no git status)
    local projects_paths="${JSH_PROJECTS:-${HOME}/.jsh,${HOME}/projects/*}"
    local oldIFS="$IFS"
    IFS=','
    for entry in ${projects_paths}; do
        entry="${entry/#\~/${HOME}}"
        entry="${entry#"${entry%%[![:space:]]*}"}"  # trim leading whitespace
        entry="${entry%"${entry##*[![:space:]]}"}"  # trim trailing whitespace

        if [[ "$entry" == *"*"* ]]; then
            # Expand glob pattern
            shopt -s nullglob
            for dir in ${entry}; do
                [[ ! -d "$dir" ]] && continue
                if [[ "$dir" == "${HOME}"* ]]; then
                    dirs+="~${dir#"$HOME"} "
                else
                    dirs+="$dir "
                fi
            done
            shopt -u nullglob
        elif [[ -d "$entry" ]]; then
            if [[ "$entry" == "${HOME}"* ]]; then
                dirs+="~${entry#"$HOME"} "
            else
                dirs+="$entry "
            fi
        fi
    done
    IFS="$oldIFS"

    # Generate completions - unique entries only
    local unique_dirs
    unique_dirs=$(echo "$dirs" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    COMPREPLY=($(compgen -W "$unique_dirs" -- "$cur"))
}

# Register completion
complete -F _j_completion j
