#!/usr/bin/env bash
# jsh.bash - Bash completion for jsh CLI
# Dynamic extraction of commands and options from jsh script
# shellcheck disable=SC2207

_jsh_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword="${COMP_CWORD}"
    }

    local jsh_path="${JSH_DIR:-${HOME}/.jsh}/jsh"

    # Main commands - extract dynamically or use fallback
    local commands
    if [[ -x "$jsh_path" ]]; then
        # Strip ANSI codes and extract commands from help output
        # Pattern matches any "WORD COMMANDS:" section header dynamically
        # Uses BSD awk compatible syntax (index() instead of !~)
        commands=$("$jsh_path" help 2>/dev/null | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            awk '
                /^[A-Z]+ COMMANDS:/ { in_section=1; next }
                /^[A-Z]/ { if (index($0, "COMMANDS:") == 0) in_section=0 }
                in_section && /^    [a-z]/ { print $1 }
            ' | sort -u | tr '\n' ' ')
    fi

    # First argument - complete commands only (no flags)
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    # Subcommand completion
    local cmd="${words[1]}"
    case "$cmd" in
        setup|init)
            COMPREPLY=($(compgen -W "-i --interactive" -- "$cur"))
            ;;
        teardown|deinit)
            COMPREPLY=($(compgen -W "--full -r --restore -y --yes" -- "$cur"))
            ;;
        status)
            COMPREPLY=($(compgen -W "-f --fix -v --verbose" -- "$cur"))
            ;;
        doctor|check)
            COMPREPLY=($(compgen -W "-f --fix" -- "$cur"))
            ;;
        unlink)
            _jsh_unlink_completion
            ;;
        upgrade|update)
            COMPREPLY=($(compgen -W "-c --check --no-brew --no-submodules" -- "$cur"))
            ;;
        project|proj|p)
            _jsh_project_completion
            ;;
        profile)
            _jsh_profile_completion
            ;;
        deps|dependencies)
            _jsh_deps_completion
            ;;
        host|hosts)
            _jsh_host_completion
            ;;
        # New commands
        tools)
            _jsh_tools_completion
            ;;
        clean)
            _jsh_clean_completion
            ;;
        install)
            _jsh_install_completion
            ;;
        sync)
            _jsh_sync_completion
            ;;
        configure|config)
            _jsh_configure_completion
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

_jsh_unlink_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    # If completing after --restore=, offer backups
    if [[ "$prev" == "--restore" ]] || [[ "$cur" == "--restore="* ]]; then
        local backup_dir="${HOME}/.jsh_backup"
        local backups="latest"
        if [[ -d "$backup_dir" ]]; then
            local dir_backups
            dir_backups=$(find "$backup_dir" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | xargs -I {} basename {} | tr '\n' ' ')
            backups="$backups $dir_backups"
        fi
        COMPREPLY=($(compgen -W "$backups" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "--restore" -- "$cur"))
    fi
}

_jsh_project_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    # Determine if we're completing subcommand or flags
    if [[ $cword -eq 2 ]]; then
        local subcommands="sync status list profile cd"
        local flags="-l --list -v --verbose"
        COMPREPLY=($(compgen -W "$subcommands $flags" -- "$cur"))
    elif [[ "${COMP_WORDS[2]}" == "profile" ]]; then
        _jsh_profile_completion
    fi
}

_jsh_profile_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local subcommands="list add remove show apply"
    COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
}

_jsh_deps_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    if [[ $cword -eq 2 ]]; then
        local subcommands="status check refresh doctor capabilities fix-bash"
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    fi
}

_jsh_host_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    if [[ $cword -eq 2 ]]; then
        local subcommands="list status refresh reset"
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    elif [[ $cword -eq 3 ]]; then
        # For status, refresh, reset - complete host names
        local subcmd="${COMP_WORDS[2]}"
        case "$subcmd" in
            status|refresh|reset)
                local hosts_dir="${JSH_DIR:-${HOME}/.jsh}/local/hosts"
                local hosts=""
                if [[ -d "$hosts_dir" ]]; then
                    hosts=$(find "$hosts_dir" -maxdepth 1 -name '*.json' 2>/dev/null | xargs -I {} basename {} .json | tr '\n' ' ')
                fi
                COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
                ;;
        esac
    fi
}

# Tools command completion
_jsh_tools_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    if [[ $cword -eq 2 ]]; then
        local subcommands="list check install recommend"
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    elif [[ $cword -ge 3 ]] && [[ "${COMP_WORDS[2]}" == "list" ]]; then
        local flags="-c --category --missing --installed"
        local categories="shell editor dev container k8s cloud git network"
        if [[ "${COMP_WORDS[$((cword-1))]}" == "-c" ]] || [[ "${COMP_WORDS[$((cword-1))]}" == "--category" ]]; then
            COMPREPLY=($(compgen -W "$categories" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$flags" -- "$cur"))
        fi
    fi
}

# Clean command completion
_jsh_clean_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local flags="-n --dry-run -y --yes"
    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
}

# Install command completion
_jsh_install_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local flags="--brew --npm --pip --cargo"
    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
}

# Sync command completion
_jsh_sync_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local flags="--pull --push -c --check -f --force --no-stash"
    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
}

# Configure command completion
_jsh_configure_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cword="${COMP_CWORD}"

    if [[ $cword -eq 2 ]]; then
        local subcommands="all macos dock apps linux list"
        local flags="-n --check --dry-run -y --yes"
        COMPREPLY=($(compgen -W "$subcommands $flags" -- "$cur"))
    else
        local flags="-n --check --dry-run -y --yes"
        COMPREPLY=($(compgen -W "$flags" -- "$cur"))
    fi
}

# Register completion
complete -F _jsh_completion jsh
