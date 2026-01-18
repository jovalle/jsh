# lib/cli.sh - Self-documenting CLI framework
# Source this in scripts to get auto-generated help and completions
#
# Usage:
#   #!/usr/bin/env bash
#   # @name mycli
#   # @version 1.0.0
#   # @desc Short description
#   # @usage mycli [options] [args...]
#   # @option -h,--help  Show this help
#   source "${0%/*}/../lib/cli.sh"
#   main() { ... }
#   cli_main main "$@"
#
# shellcheck shell=bash

# =============================================================================
# Dependencies
# =============================================================================

# Source common helpers if not already loaded
if [[ -z "${C_RESET:-}" ]]; then
    # shellcheck disable=SC1091
    source "${BASH_SOURCE[0]%/*}/common.sh" 2>/dev/null || {
        # Minimal fallback colors
        if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
            C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
            C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
            C_BLUE=$'\033[34m' C_CYAN=$'\033[36m'
        else
            C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN=''
            C_YELLOW='' C_BLUE='' C_CYAN=''
        fi
    }
fi

# =============================================================================
# Global State (set by cli_parse)
# =============================================================================

declare -A _CLI_META=()        # name, version, desc, usage
declare -a _CLI_OPTIONS=()     # "-h,--help|Show help"
declare -a _CLI_COMMANDS=()    # "setup|Setup jsh"
declare -a _CLI_SUBCOMMANDS=() # "tools:list|List all tools"
declare -a _CLI_ARGS=()        # "enum shell,editor,dev"
declare -a _CLI_EXAMPLES=()    # "mycli -t 2h"
_CLI_PARSED=false
_CLI_SCRIPT=""

# =============================================================================
# Metadata Parser
# =============================================================================

# Parse @tag metadata from a script file
# Args: $1 = script path (defaults to $0)
cli_parse() {
    local script="${1:-${_CLI_SCRIPT:-$0}}"
    _CLI_SCRIPT="${script}"

    # Reset state - must unset and re-declare to properly clear associative array
    unset _CLI_META
    declare -gA _CLI_META=()
    _CLI_OPTIONS=()
    _CLI_COMMANDS=()
    _CLI_SUBCOMMANDS=()
    _CLI_ARGS=()
    _CLI_EXAMPLES=()

    # Read metadata from script header (stop at first non-comment, non-blank line)
    local in_header=true
    local line

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip shebang
        [[ "${line}" == "#!"* ]] && continue

        # Stop at first non-comment, non-blank line
        if [[ "${in_header}" == true ]]; then
            if [[ "${line}" =~ ^[[:space:]]*$ ]]; then
                continue
            elif [[ "${line}" != "#"* ]]; then
                break
            fi
        fi

        # Strip leading # and whitespace
        line="${line#\#}"
        line="${line#"${line%%[![:space:]]*}"}"

        # Parse @tag directives
        case "${line}" in
            @name\ *)
                _CLI_META[name]="${line#@name }"
                ;;
            @version\ *)
                _CLI_META[version]="${line#@version }"
                ;;
            @desc\ *)
                _CLI_META[desc]="${line#@desc }"
                ;;
            @usage\ *)
                _CLI_META[usage]="${line#@usage }"
                ;;
            @option\ *)
                _CLI_OPTIONS+=("${line#@option }")
                ;;
            @cmd\ *)
                _CLI_COMMANDS+=("${line#@cmd }")
                ;;
            @sub\ *)
                _CLI_SUBCOMMANDS+=("${line#@sub }")
                ;;
            @arg\ *)
                _CLI_ARGS+=("${line#@arg }")
                ;;
            @example\ *)
                _CLI_EXAMPLES+=("${line#@example }")
                ;;
        esac
    done < "${script}"

    _CLI_PARSED=true
}

# Ensure metadata is parsed
_cli_ensure_parsed() {
    if [[ "${_CLI_PARSED}" != true ]]; then
        cli_parse
    fi
}

# =============================================================================
# Help Generation
# =============================================================================

# Generate formatted help output
cli_help() {
    _cli_ensure_parsed

    local name="${_CLI_META[name]:-${0##*/}}"
    local version="${_CLI_META[version]:-}"
    local desc="${_CLI_META[desc]:-}"
    local usage="${_CLI_META[usage]:-${name} [options]}"

    # Header
    printf "%s%s%s" "${C_BOLD}" "${name}" "${C_RESET}"
    [[ -n "${version}" ]] && printf " %sv%s%s" "${C_DIM}" "${version}" "${C_RESET}"
    [[ -n "${desc}" ]] && printf " - %s" "${desc}"
    printf "\n\n"

    # Usage
    printf "%sUSAGE%s\n" "${C_BOLD}" "${C_RESET}"
    printf "    %s\n\n" "${usage}"

    # Commands (if any)
    if [[ ${#_CLI_COMMANDS[@]} -gt 0 ]]; then
        printf "%sCOMMANDS%s\n" "${C_BOLD}" "${C_RESET}"
        _cli_print_aligned _CLI_COMMANDS
        printf "\n"
    fi

    # Subcommands (if any)
    if [[ ${#_CLI_SUBCOMMANDS[@]} -gt 0 ]]; then
        printf "%sSUBCOMMANDS%s\n" "${C_BOLD}" "${C_RESET}"
        _cli_print_subcommands
        printf "\n"
    fi

    # Options
    if [[ ${#_CLI_OPTIONS[@]} -gt 0 ]]; then
        printf "%sOPTIONS%s\n" "${C_BOLD}" "${C_RESET}"
        _cli_print_options
        printf "\n"
    fi

    # Examples (if any)
    if [[ ${#_CLI_EXAMPLES[@]} -gt 0 ]]; then
        printf "%sEXAMPLES%s\n" "${C_BOLD}" "${C_RESET}"
        for example in "${_CLI_EXAMPLES[@]}"; do
            printf "    %s%s%s\n" "${C_CYAN}" "${example}" "${C_RESET}"
        done
        printf "\n"
    fi
}

# Print options with aligned descriptions
_cli_print_options() {
    local max_width=0
    local -a flags=()
    local -a descs=()

    # Regex patterns (stored in variables to avoid parsing issues with special chars)
    local re_opt_with_arg='^([^[:space:]]+)[[:space:]]+<([^>]+)>[[:space:]]+(.+)$'
    local re_opt_simple='^([^[:space:]]+)[[:space:]]+(.+)$'

    for opt in "${_CLI_OPTIONS[@]}"; do
        local flag desc arg=""

        # Parse: -s,--long <ARG>  Description
        # or:    -s,--long        Description
        if [[ "${opt}" =~ ${re_opt_with_arg} ]]; then
            flag="${BASH_REMATCH[1]}"
            arg=" <${BASH_REMATCH[2]}>"
            desc="${BASH_REMATCH[3]}"
        elif [[ "${opt}" =~ ${re_opt_simple} ]]; then
            flag="${BASH_REMATCH[1]}"
            desc="${BASH_REMATCH[2]}"
        else
            flag="${opt}"
            desc=""
        fi

        # Expand -s,--long to "-s, --long"
        flag="${flag//,/, }"
        flag="${flag}${arg}"

        flags+=("${flag}")
        descs+=("${desc}")

        local len=${#flag}
        [[ ${len} -gt ${max_width} ]] && max_width=${len}
    done

    # Add padding
    ((max_width += 4))
    [[ ${max_width} -lt 24 ]] && max_width=24

    for i in "${!flags[@]}"; do
        printf "    %-${max_width}s%s\n" "${flags[${i}]}" "${descs[${i}]}"
    done
}

# Print commands/subcommands with aligned descriptions
_cli_print_aligned() {
    local -n arr=$1
    local max_width=0
    local -a names=()
    local -a descs=()

    for item in "${arr[@]}"; do
        local name desc

        # Parse: "name  description" or "name description"
        if [[ "${item}" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
            name="${BASH_REMATCH[1]}"
            desc="${BASH_REMATCH[2]}"
        else
            name="${item}"
            desc=""
        fi

        names+=("${name}")
        descs+=("${desc}")

        local len=${#name}
        [[ ${len} -gt ${max_width} ]] && max_width=${len}
    done

    # Add padding
    ((max_width += 4))
    [[ ${max_width} -lt 16 ]] && max_width=16

    for i in "${!names[@]}"; do
        printf "    %s%-${max_width}s%s%s\n" "${C_CYAN}" "${names[${i}]}" "${C_RESET}" "${descs[${i}]}"
    done
}

# Print subcommands grouped by parent command
_cli_print_subcommands() {
    local current_parent=""
    local max_width=0

    # First pass: find max width
    for sub in "${_CLI_SUBCOMMANDS[@]}"; do
        local full_name
        if [[ "${sub}" =~ ^([^[:space:]]+) ]]; then
            full_name="${BASH_REMATCH[1]}"
            local len=${#full_name}
            [[ ${len} -gt ${max_width} ]] && max_width=${len}
        fi
    done

    ((max_width += 4))
    [[ ${max_width} -lt 20 ]] && max_width=20

    # Second pass: print grouped
    for sub in "${_CLI_SUBCOMMANDS[@]}"; do
        local full_name desc parent child

        if [[ "${sub}" =~ ^([^:]+):([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
            parent="${BASH_REMATCH[1]}"
            child="${BASH_REMATCH[2]}"
            full_name="${parent}:${child}"
            desc="${BASH_REMATCH[3]}"

            # Print parent header if changed
            if [[ "${parent}" != "${current_parent}" ]]; then
                [[ -n "${current_parent}" ]] && printf "\n"
                current_parent="${parent}"
            fi

            printf "    %s%-${max_width}s%s%s\n" "${C_CYAN}" "${full_name}" "${C_RESET}" "${desc}"
        fi
    done
}

# =============================================================================
# Usage and Version
# =============================================================================

# Print short usage line (for error messages)
cli_usage() {
    _cli_ensure_parsed
    local name="${_CLI_META[name]:-${0##*/}}"
    local usage="${_CLI_META[usage]:-${name} [options]}"
    printf "Usage: %s\n" "${usage}"
    printf "Try '%s --help' for more information.\n" "${name}"
}

# Print version string
cli_version() {
    _cli_ensure_parsed
    local name="${_CLI_META[name]:-${0##*/}}"
    local version="${_CLI_META[version]:-unknown}"
    printf "%s %s\n" "${name}" "${version}"
}

# =============================================================================
# Main Entry Point
# =============================================================================

# Handle --help/--version/--completions, then call user function
# Args: $1 = user's main function name, $@ = script arguments
cli_main() {
    local main_func="$1"
    shift

    # Parse metadata from calling script
    cli_parse "${_CLI_SCRIPT:-${BASH_SOURCE[1]:-$0}}"

    # Handle special flags before user gets control
    case "${1:-}" in
        -h|--help)
            cli_help
            exit 0
            ;;
        --version)
            cli_version
            exit 0
            ;;
        --completions)
            local shell_type="${2:-zsh}"
            cli_completions "${shell_type}"
            exit 0
            ;;
    esac

    # Call user's main function
    "${main_func}" "$@"
}

# =============================================================================
# Command Dispatch
# =============================================================================

# Dispatch to cmd_* functions based on first argument
# Args: $1 = default command (or empty), $@ = script arguments
cli_dispatch() {
    local default_cmd="${1:-help}"
    shift

    local cmd="${1:-${default_cmd}}"
    shift 2>/dev/null || true

    # Parse metadata
    cli_parse "${_CLI_SCRIPT:-${BASH_SOURCE[1]:-$0}}"

    # Handle special flags
    case "${cmd}" in
        -h|--help|help)
            cli_help
            return 0
            ;;
        -v|--version|version)
            cli_version
            return 0
            ;;
        --completions)
            local shell_type="${1:-zsh}"
            cli_completions "${shell_type}"
            return 0
            ;;
    esac

    # Look for cmd_* function
    local func="cmd_${cmd}"
    func="${func//-/_}"  # Replace hyphens with underscores

    if declare -f "${func}" >/dev/null 2>&1; then
        "${func}" "$@"
    else
        printf "%sError:%s Unknown command: %s\n" "${C_RED}" "${C_RESET}" "${cmd}" >&2
        cli_usage >&2
        return 1
    fi
}

# =============================================================================
# Completion Generation
# =============================================================================

# Generate shell completions
# Args: $1 = shell type (zsh|bash)
cli_completions() {
    local shell_type="${1:-zsh}"
    _cli_ensure_parsed

    case "${shell_type}" in
        zsh)
            _cli_gen_zsh_completions
            ;;
        bash)
            _cli_gen_bash_completions
            ;;
        *)
            printf "Unknown shell type: %s (use zsh or bash)\n" "${shell_type}" >&2
            return 1
            ;;
    esac
}

# Generate zsh completion script
_cli_gen_zsh_completions() {
    local name="${_CLI_META[name]:-${0##*/}}"
    local desc="${_CLI_META[desc]:-}"

    cat << 'HEADER'
#compdef _CMDNAME_ CMDNAME
# Auto-generated by lib/cli.sh

HEADER

    # Replace CMDNAME placeholder
    sed -i '' "s/_CMDNAME_/_${name}/g; s/CMDNAME/${name}/g" 2>/dev/null || true

    printf "_${name}() {\n"
    printf "    local -a commands options\n\n"

    # Commands
    if [[ ${#_CLI_COMMANDS[@]} -gt 0 ]]; then
        printf "    commands=(\n"
        for cmd in "${_CLI_COMMANDS[@]}"; do
            local cmd_name cmd_desc
            if [[ "${cmd}" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
                cmd_name="${BASH_REMATCH[1]}"
                cmd_desc="${BASH_REMATCH[2]}"
            else
                cmd_name="${cmd}"
                cmd_desc=""
            fi
            # Escape special characters in description
            cmd_desc="${cmd_desc//\"/\\\"}"
            cmd_desc="${cmd_desc//\'/\\\'}"
            printf "        '%s:%s'\n" "${cmd_name}" "${cmd_desc}"
        done
        printf "    )\n\n"
    fi

    # Options
    if [[ ${#_CLI_OPTIONS[@]} -gt 0 ]]; then
        printf "    options=(\n"
        # Regex patterns in variables for portable parsing
        local re_opt_with_arg='^([^[:space:]]+)[[:space:]]+<([^>]+)>[[:space:]]+(.+)$'
        local re_opt_simple='^([^[:space:]]+)[[:space:]]+(.+)$'

        for opt in "${_CLI_OPTIONS[@]}"; do
            local flags desc arg=""

            if [[ "${opt}" =~ ${re_opt_with_arg} ]]; then
                flags="${BASH_REMATCH[1]}"
                arg=":${BASH_REMATCH[2]}"
                desc="${BASH_REMATCH[3]}"
            elif [[ "${opt}" =~ ${re_opt_simple} ]]; then
                flags="${BASH_REMATCH[1]}"
                desc="${BASH_REMATCH[2]}"
            else
                flags="${opt}"
                desc=""
            fi

            # Escape special characters
            desc="${desc//\"/\\\"}"
            desc="${desc//\[/\\[}"
            desc="${desc//\]/\\]}"

            # Split flags and generate zsh format
            local IFS=','
            read -ra flag_arr <<< "${flags}"
            for flag in "${flag_arr[@]}"; do
                flag="${flag# }"  # Trim leading space
                printf "        '%s[%s]%s'\n" "${flag}" "${desc}" "${arg}"
            done
        done
        printf "    )\n\n"
    fi

    # Completion logic
    if [[ ${#_CLI_COMMANDS[@]} -gt 0 ]]; then
        cat << 'EOF'
    _arguments -C \
        $options \
        "1: :{_describe 'command' commands}" \
        "*::arg:->args"
EOF
    else
        cat << 'EOF'
    _arguments -C \
        $options \
        "*:file:_files"
EOF
    fi

    printf "}\n"
}

# Generate bash completion script
_cli_gen_bash_completions() {
    local name="${_CLI_META[name]:-${0##*/}}"

    printf "# Auto-generated by lib/cli.sh\n\n"
    printf "_%s() {\n" "${name}"
    printf "    local cur prev words cword\n"
    printf "    _init_completion || return\n\n"

    # Commands
    if [[ ${#_CLI_COMMANDS[@]} -gt 0 ]]; then
        printf "    local commands=\""
        for cmd in "${_CLI_COMMANDS[@]}"; do
            local cmd_name
            if [[ "${cmd}" =~ ^([^[:space:]]+) ]]; then
                cmd_name="${BASH_REMATCH[1]}"
                printf "%s " "${cmd_name}"
            fi
        done
        printf "\"\n\n"
    fi

    # Options
    if [[ ${#_CLI_OPTIONS[@]} -gt 0 ]]; then
        printf "    local options=\""
        for opt in "${_CLI_OPTIONS[@]}"; do
            local flags
            if [[ "${opt}" =~ ^([^[:space:]]+) ]]; then
                flags="${BASH_REMATCH[1]}"
                # Split on comma
                local IFS=','
                read -ra flag_arr <<< "${flags}"
                for flag in "${flag_arr[@]}"; do
                    flag="${flag# }"
                    printf "%s " "${flag}"
                done
            fi
        done
        printf "\"\n\n"
    fi

    # Completion logic
    cat << 'EOF'
    case "${prev}" in
        *)
            if [[ "${cur}" == -* ]]; then
                COMPREPLY=($(compgen -W "${options}" -- "${cur}"))
            else
EOF

    if [[ ${#_CLI_COMMANDS[@]} -gt 0 ]]; then
        printf "                COMPREPLY=(\$(compgen -W \"\${commands}\" -- \"\${cur}\"))\n"
    else
        printf "                COMPREPLY=()\n"
    fi

    cat << 'EOF'
            fi
            ;;
    esac
}
EOF

    printf "\ncomplete -F _%s %s\n" "${name}" "${name}"
}

# =============================================================================
# Discovery Helper (for bin/cli)
# =============================================================================

# Find all scripts with @name metadata in a directory
# Args: $1 = directory to search
cli_discover() {
    local search_dir="${1:-.}"

    # Use portable find (macOS doesn't support -executable)
    # Note: The `|| true` ensures this doesn't fail with pipefail in strict mode
    find "${search_dir}" -type f -perm +111 2>/dev/null | {
        while read -r script; do
            # Skip binary files by checking for shebang
            local first_line
            first_line=$(head -1 "${script}" 2>/dev/null) || continue
            [[ "${first_line}" == "#!"* ]] || continue

            # Look for @name tag in first 50 lines
            local name
            name=$(head -50 "${script}" 2>/dev/null | grep -m1 "^# @name " | sed 's/^# @name //' || true)

            if [[ -n "${name}" ]]; then
                printf "%s\t%s\n" "${name}" "${script}"
            fi
        done
        true  # Ensure pipeline succeeds
    }
}

# =============================================================================
# Initialization
# =============================================================================

# Set script path for later parsing
_CLI_SCRIPT="${BASH_SOURCE[1]:-$0}"
