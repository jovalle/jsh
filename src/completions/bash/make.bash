#!/usr/bin/env bash
# make.bash - Bash completion for make with dynamic target extraction
# Parses Makefile for targets and their descriptions (from ## comments)
# shellcheck disable=SC2207

_make_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    }

    # Handle -f and -C options to find the right Makefile
    local makefile=""
    local makedir="."
    local i
    for ((i=1; i < ${#COMP_WORDS[@]}; i++)); do
        case "${COMP_WORDS[i]}" in
            -f|--file|--makefile)
                if [[ $((i+1)) -lt ${#COMP_WORDS[@]} ]]; then
                    makefile="${COMP_WORDS[i+1]}"
                fi
                ;;
            -C|--directory)
                if [[ $((i+1)) -lt ${#COMP_WORDS[@]} ]]; then
                    makedir="${COMP_WORDS[i+1]}"
                fi
                ;;
        esac
    done

    # Find the Makefile
    if [[ -z "$makefile" ]]; then
        for f in GNUmakefile makefile Makefile; do
            if [[ -f "${makedir}/${f}" ]]; then
                makefile="${makedir}/${f}"
                break
            fi
        done
    fi

    # If completing options
    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-B -C -d -e -f -i -I -j -k -l -n -o -p -q -r -R -s -S -t -v -w -W --always-make --directory --debug --environment-overrides --file --ignore-errors --include-dir --jobs --keep-going --load-average --just-print --old-file --print-data-base --question --no-builtin-rules --no-builtin-variables --silent --no-keep-going --touch --version --print-directory --no-print-directory --what-if --help" -- "$cur"))
        return
    fi

    # If we found a Makefile, extract targets dynamically
    if [[ -f "$makefile" ]]; then
        local targets
        # Extract targets: lines matching "target:" that aren't variables or patterns
        # Include both documented (##) and undocumented targets, excluding internal ones (_*)
        # Uses BSD awk compatible syntax
        targets=$(awk '
            # Skip lines starting with tab (recipes)
            /^\t/ { next }
            # Skip variable assignments
            /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:?+]?=/ { next }
            # Skip .PHONY and other special targets
            /^\./ { next }
            # Skip internal targets (starting with _)
            /^_/ { next }
            # Match target definitions
            /^[a-zA-Z][a-zA-Z0-9_-]*:/ {
                # Extract target name (handle multiple targets on one line)
                split($0, parts, ":")
                n = split(parts[1], targets, /[[:space:]]+/)
                for (i = 1; i <= n; i++) {
                    t = targets[i]
                    # BSD awk compatible: use positive matches instead of !~
                    if (t && t ~ /^[a-zA-Z]/) {
                        print t
                    }
                }
            }
        ' "$makefile" | sort -u | tr '\n' ' ')

        COMPREPLY=($(compgen -W "$targets" -- "$cur"))
    fi
}

# Register completion for make and gmake
complete -F _make_completion make
complete -F _make_completion gmake
