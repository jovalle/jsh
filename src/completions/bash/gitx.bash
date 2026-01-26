#!/usr/bin/env bash
# gitx.bash - Bash completion for gitx CLI
# Fully dynamic extraction from gitx help output
# shellcheck disable=SC2207

# Cache for help output
_GITX_HELP_CACHE=""

# Get gitx help output (cached)
_gitx_get_help() {
    local gitx_path="${JSH_DIR:-${HOME}/.jsh}/bin/gitx"

    if [[ -z "$_GITX_HELP_CACHE" ]]; then
        if [[ -x "$gitx_path" ]]; then
            _GITX_HELP_CACHE=$("$gitx_path" --help 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
        fi
    fi
    printf '%s' "$_GITX_HELP_CACHE"
}

# Extract main commands dynamically
_gitx_get_commands() {
    local help_output
    help_output=$(_gitx_get_help)

    if [[ -n "$help_output" ]]; then
        printf '%s' "$help_output" | awk '
            /^COMMANDS/ { in_section=1; next }
            /^[A-Z]/ { in_section=0 }
            in_section && /^[ \t]+[a-z]/ {
                cmd = $1
                if (cmd !~ /^\(/) print cmd
            }
        ' | sort -u | tr '\n' ' '
    fi
}

# Extract subcommands for a given command
_gitx_get_subcommands() {
    local cmd="$1"
    local help_output
    help_output=$(_gitx_get_help)

    if [[ -n "$help_output" ]]; then
        printf '%s' "$help_output" | awk -v cmd="$cmd" '
            /^SUBCOMMANDS/ { in_section=1; next }
            /^[A-Z]/ && !/^SUBCOMMANDS/ { in_section=0 }
            in_section && $0 ~ "^[ \t]+"cmd":" {
                line = $0
                gsub(/^[ \t]+/, "", line)
                sub(/^[^:]+:/, "", line)  # Remove "command:"
                subcmd = line
                sub(/[ \t].*/, "", subcmd)
                print subcmd
            }
        ' | tr '\n' ' '
    fi
}

_gitx_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    # First argument - complete commands
    if [[ $cword -eq 1 ]]; then
        local commands
        commands=$(_gitx_get_commands)

        # Fallback if dynamic extraction fails
        if [[ -z "$commands" ]]; then
            commands="update profile clone create list path commit amend push backup remote"
        fi

        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    # Subcommand completion
    local cmd="${words[1]}"

    # First try dynamic subcommands from help
    local subcommands
    subcommands=$(_gitx_get_subcommands "$cmd")

    if [[ -n "$subcommands" ]] && [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        return
    fi

    # Special handling for commands needing dynamic data
    case "$cmd" in
        profile)
            if [[ $cword -eq 2 ]]; then
                local profiles="$subcommands"
                # Add profile names from config
                local jsh_profiles="${JSH_PROFILES:-${HOME}/.jsh/local/profiles.json}"
                if [[ -f "$jsh_profiles" ]] && command -v jq &>/dev/null; then
                    profiles="$profiles $(jq -r '.profiles | keys | .[]' "$jsh_profiles" 2>/dev/null | tr '\n' ' ')"
                fi
                COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
            fi
            ;;
        remote)
            if [[ $cword -eq 2 ]]; then
                local remotes=""
                local remote_config="${JSH_DIR:-${HOME}/.jsh}/local/projects.json"
                if [[ -f "$remote_config" ]] && command -v jq &>/dev/null; then
                    remotes=$(jq -r '.remotes | keys | .[]' "$remote_config" 2>/dev/null | tr '\n' ' ')
                fi
                COMPREPLY=($(compgen -W "$remotes" -- "$cur"))
            fi
            ;;
        path)
            if [[ $cword -eq 2 ]]; then
                _gitx_path_completion
            fi
            ;;
        clone|add)
            # No completion for URLs
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

# Path command completion - complete project names
_gitx_path_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local projects=""
    local projects_paths="${JSH_PROJECTS:-${HOME}/.jsh,${HOME}/projects/*}"
    local IFS=','

    for entry in ${projects_paths}; do
        entry="${entry/#\~/${HOME}}"
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"

        if [[ "$entry" == *"*"* ]]; then
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
}

# Register completion
complete -F _gitx_completion gitx
