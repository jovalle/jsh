#!/usr/bin/env bash
# jgit.bash - Bash completion for jgit CLI
# Dynamic extraction of commands from jgit help output
# shellcheck disable=SC2207

_jgit_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    local jgit_path="${JSH_DIR:-${HOME}/.jsh}/bin/jgit"

    # Extract main commands dynamically from help output
    local commands
    if [[ -x "$jgit_path" ]]; then
        # Strip ANSI codes and extract commands from COMMANDS section
        commands=$("$jgit_path" --help 2>/dev/null | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            awk '
                /^COMMANDS:/ { in_section=1; next }
                /^[A-Z]/ { in_section=0 }
                in_section && /^  [a-z]/ {
                    cmd = $1
                    if (cmd !~ /^\(/) print cmd
                }
            ' | sort -u | tr '\n' ' ')
    fi

    # Fallback commands if dynamic extraction fails
    if [[ -z "$commands" ]]; then
        commands="update profile add create list path"
    fi

    # First argument - complete commands
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    # Subcommand completion
    local cmd="${words[1]}"
    case "$cmd" in
        profile)
            _jgit_profile_completion
            ;;
        list|-l)
            # Options available via: jgit list --help
            COMPREPLY=()
            ;;
        add)
            # After URL, complete local name (no completion)
            COMPREPLY=()
            ;;
        create)
            # Complete nothing for project name
            COMPREPLY=()
            ;;
        path)
            _jgit_path_completion
            ;;
        update)
            # No additional arguments
            COMPREPLY=()
            ;;
        *)
            # Git passthrough - use git completion if available
            if declare -F _git &>/dev/null; then
                _git
            else
                COMPREPLY=()
            fi
            ;;
    esac
}

# Profile subcommand completion
_jgit_profile_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    if [[ $cword -eq 2 ]]; then
        local subcommands="list status"

        # Add dynamic profile names if config exists
        local jsh_profiles="${JSH_PROFILES:-${HOME}/.jsh/local/profiles.json}"
        if [[ -f "$jsh_profiles" ]] && command -v jq &>/dev/null; then
            local profiles
            profiles=$(jq -r '.profiles | keys | .[]' "$jsh_profiles" 2>/dev/null | tr '\n' ' ')
            subcommands="$subcommands $profiles"
        fi

        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    fi
}

# Path command completion - complete project names
_jgit_path_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    if [[ $cword -eq 2 ]]; then
        local projects=""
        local projects_paths="${JSH_PROJECTS:-${HOME}/.jsh,${HOME}/projects/*}"
        local IFS=','

        for entry in ${projects_paths}; do
            entry="${entry/#\~/${HOME}}"
            entry="${entry#"${entry%%[![:space:]]*}"}"
            entry="${entry%"${entry##*[![:space:]]}"}"

            if [[ "$entry" == *"*"* ]]; then
                # Expand glob pattern
                shopt -s nullglob
                for dir in ${entry}; do
                    [[ -d "$dir" ]] && projects="$projects ${dir##*/}"
                done
                shopt -u nullglob
            elif [[ -d "$entry" ]]; then
                projects="$projects ${entry##*/}"
            fi
        done

        COMPREPLY=($(compgen -W "$projects" -- "$cur"))
    fi
}

# Register completion
complete -F _jgit_completion jgit
