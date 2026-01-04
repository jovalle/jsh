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
        commands=$("$jsh_path" help 2>/dev/null | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            awk '
                /^(SETUP|PACKAGE|INFO) COMMANDS:/ || /^SSH:/ { in_section=1; next }
                /^[A-Z]/ { in_section=0 }
                in_section && /^    [a-z]/ { print $1 }
            ' | sort -u | tr '\n' ' ')
    fi

    # First argument - complete commands
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands -h --help -v --version -r --reload" -- "$cur"))
        return
    fi

    # Subcommand completion
    local cmd="${words[1]}"
    case "$cmd" in
        install)
            _jsh_install_completion
            ;;
        uninstall)
            _jsh_uninstall_completion
            ;;
        dotfiles|dots)
            _jsh_dotfiles_completion
            ;;
        edit)
            _jsh_edit_completion
            ;;
        doctor|check)
            COMPREPLY=($(compgen -W "-f --fix" -- "$cur"))
            ;;
        teardown|deinit)
            COMPREPLY=($(compgen -W "--full -r --restore -y --yes" -- "$cur"))
            ;;
        ssh)
            _jsh_ssh_completion
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

_jsh_install_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local jsh_path="${JSH_DIR:-${HOME}/.jsh}/jsh"
    local pm_flags="-a --all -s --save"

    # Extract package manager flags dynamically
    if [[ -f "$jsh_path" ]]; then
        local dynamic_flags
        dynamic_flags=$(awk '
            /^cmd_install\(\)/ { in_func=1 }
            in_func && /^}$/ { in_func=0 }
            in_func && /--[a-z]+\)/ {
                match($0, /--[a-z]+/)
                flag = substr($0, RSTART, RLENGTH)
                if (flag && flag != "--save" && flag != "--all") print flag
            }
        ' "$jsh_path" | sort -u | tr '\n' ' ')
        pm_flags="$pm_flags $dynamic_flags"
    fi

    COMPREPLY=($(compgen -W "$pm_flags" -- "$cur"))
}

_jsh_uninstall_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local jsh_path="${JSH_DIR:-${HOME}/.jsh}/jsh"
    local pm_flags="-r --remove"

    # Extract package manager flags dynamically
    if [[ -f "$jsh_path" ]]; then
        local dynamic_flags
        dynamic_flags=$(awk '
            /^cmd_uninstall\(\)/ { in_func=1 }
            in_func && /^}$/ { in_func=0 }
            in_func && /--[a-z]+\)/ {
                match($0, /--[a-z]+/)
                flag = substr($0, RSTART, RLENGTH)
                if (flag && flag != "--remove") print flag
            }
        ' "$jsh_path" | sort -u | tr '\n' ' ')
        pm_flags="$pm_flags $dynamic_flags"
    fi

    # Get installed packages for completion
    local packages=""
    if command -v brew &>/dev/null; then
        packages=$(brew list --formula 2>/dev/null | tr '\n' ' ')
        packages="$packages $(brew list --cask 2>/dev/null | tr '\n' ' ')"
    fi

    COMPREPLY=($(compgen -W "$pm_flags $packages" -- "$cur"))
}

_jsh_dotfiles_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cword="${COMP_CWORD}"

    # Determine if we're completing subcommand or its arguments
    # dots/dotfiles is word 1, subcommand would be word 2
    if [[ $cword -eq 2 ]]; then
        # Complete subcommands
        local subcommands="link unlink restore status"
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    elif [[ "${COMP_WORDS[2]}" == "restore" ]]; then
        # Complete backup timestamps for restore
        local backup_dir="${HOME}/.jsh_backup"
        local backups="latest"
        if [[ -d "$backup_dir" ]]; then
            local dir_backups
            dir_backups=$(find "$backup_dir" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | xargs -I {} basename {} | tr '\n' ' ')
            backups="$backups $dir_backups"
        fi
        COMPREPLY=($(compgen -W "$backups" -- "$cur"))
    fi
}

_jsh_edit_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local jsh_path="${JSH_DIR:-${HOME}/.jsh}/jsh"
    local configs=""

    # Extract edit targets dynamically
    if [[ -f "$jsh_path" ]]; then
        configs=$(awk '
            /^cmd_edit\(\)/ { in_func=1 }
            in_func && /^}$/ { exit }
            in_func && /case.*file/ { in_case=1 }
            in_case && /esac/ { in_case=0 }
            in_case && /^[[:space:]]+[a-z0-9|]+\)/ {
                line = $0
                gsub(/^[[:space:]]+/, "", line)
                gsub(/\).*/, "", line)
                # Handle alternatives like "zsh|zshrc" - print each
                n = split(line, parts, "|")
                for (i = 1; i <= n; i++) {
                    cmd = parts[i]
                    # Skip empty, wildcards, and quoted strings
                    if (cmd && cmd !~ /^["*]/ && cmd !~ /^\*?$/) {
                        print cmd
                    }
                }
            }
        ' "$jsh_path" | sort -u | tr '\n' ' ')
    fi

    # Fallback
    if [[ -z "$configs" ]]; then
        configs="zsh bash aliases functions prompt tmux git vim vscode local"
    fi

    COMPREPLY=($(compgen -W "$configs" -- "$cur"))
}

_jsh_ssh_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local hosts=""

    # Extract hosts from SSH config and known_hosts
    if [[ -f ~/.ssh/config ]]; then
        hosts=$(grep -i "^Host " ~/.ssh/config 2>/dev/null | awk '{print $2}' | grep -v '\*' | tr '\n' ' ')
    fi

    if [[ -f ~/.ssh/known_hosts ]]; then
        local known
        known=$(cut -f1 -d' ' ~/.ssh/known_hosts 2>/dev/null | tr ',' '\n' | grep -v '^\[' | grep -v '^#' | sort -u | tr '\n' ' ')
        hosts="$hosts $known"
    fi

    COMPREPLY=($(compgen -W "$hosts" -- "$cur"))
}

# Register completion
complete -F _jsh_completion jsh
