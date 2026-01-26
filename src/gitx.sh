# gitx.sh - Shell wrapper for gitx commands that need parent shell integration
# shellcheck disable=SC2119,SC2120,SC2207,SC2296
#
# This file should be sourced, not executed, so that `gitx` shell function
# can change the current directory of the calling shell after clone/create.
#
# Commands handled by this wrapper:
#   gitx clone <url> [name]   Clone repository and cd into it
#   gitx create <name>        Create project directory and cd into it
#   gitx remote <name>        Open remote project in VS Code
#
# All other commands pass through to bin/gitx.

[[ -n "${_JSH_GITX_LOADED:-}" ]] && return 0
_JSH_GITX_LOADED=1

# =============================================================================
# Configuration
# =============================================================================

# Remote projects config file
_GITX_REMOTE_CONFIG="${JSH_DIR:-${HOME}/.jsh}/local/projects.json"

# =============================================================================
# Remote Project Functions
# =============================================================================

# Get remote project info from config
# Arguments:
#   $1 - Project name
# Output: JSON object with host, path, user, etc. or empty if not found
_gitx_get_remote() {
    local name="$1"

    if [[ ! -f "${_GITX_REMOTE_CONFIG}" ]]; then
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        printf 'jq is required for remote projects\n' >&2
        return 1
    fi

    jq -r --arg name "${name}" '.remotes[$name] // empty' "${_GITX_REMOTE_CONFIG}" 2>/dev/null || true
}

# List all remote project names
# Output: Project names, one per line
_gitx_list_remotes() {
    if [[ ! -f "${_GITX_REMOTE_CONFIG}" ]]; then
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        return 0
    fi

    jq -r '.remotes | keys[]' "${_GITX_REMOTE_CONFIG}" 2>/dev/null || true
}

# Open a remote project in VS Code Remote SSH
# Arguments:
#   $1 - Project name
# Returns: 0 on success, 1 on failure
_gitx_open_remote() {
    local name="$1"
    local remote_info host remote_path user ssh_key

    remote_info="$(_gitx_get_remote "${name}")"

    if [[ -z "${remote_info}" ]]; then
        printf '%s✗%s No remote project found: %s%s%s\n' "${C_ERR:-}" "${RST:-}" "${C_GIT:-}" "${name}" "${RST:-}" >&2
        printf '\n%sAvailable remote projects:%s\n' "${DIM:-}" "${RST:-}" >&2
        _gitx_list_remotes | while read -r proj; do
            printf '  %s%s%s\n' "${CYN:-}" "${proj}" "${RST:-}" >&2
        done
        return 1
    fi

    host=$(printf '%s' "${remote_info}" | jq -r '.host')
    remote_path=$(printf '%s' "${remote_info}" | jq -r '.path')
    user=$(printf '%s' "${remote_info}" | jq -r '.user // empty')
    ssh_key=$(printf '%s' "${remote_info}" | jq -r '.ssh_key // empty')

    if [[ -z "${host}" ]] || [[ -z "${remote_path}" ]]; then
        printf '%s✗%s Invalid remote project config for: %s%s%s\n' "${C_ERR:-}" "${RST:-}" "${C_GIT:-}" "${name}" "${RST:-}" >&2
        return 1
    fi

    # Build SSH target (user@host or just host)
    local ssh_target="${host}"
    [[ -n "${user}" ]] && ssh_target="${user}@${host}"

    # Open in VS Code Remote SSH
    printf '%sOpening remote:%s %s%s%s (%s%s%s:%s%s%s)\n' \
        "${C_INFO:-}" "${RST:-}" \
        "${C_GIT:-}" "${name}" "${RST:-}" \
        "${C_MUTED:-}" "${ssh_target}" "${RST:-}" \
        "${CYN:-}" "${remote_path}" "${RST:-}"
    [[ -n "${ssh_key}" ]] && printf '  %sKey:%s %s\n' "${DIM:-}" "${RST:-}" "${ssh_key}"

    code --remote "ssh-remote+${ssh_target}" "${remote_path}"
}

# =============================================================================
# Main gitx Function
# =============================================================================

gitx() {
    local open_code=false

    # Parse global flags first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--code)
                open_code=true
                shift
                ;;
            -h|--help)
                # Pass through to binary for help
                command gitx --help
                return $?
                ;;
            -*)
                # Unknown flag - let the binary handle it
                break
                ;;
            *)
                break
                ;;
        esac
    done

    # Handle commands that need shell integration
    case "${1:-}" in
        clone|create)
            # Clone/create project then cd into it via temp file
            local cd_file
            cd_file=$(mktemp "${TMPDIR:-/tmp}/gitx-cd.XXXXXX")

            JSH_WRAPPER=1 JSH_CD_FILE="${cd_file}" command gitx "$@"
            local ret=$?

            if [[ $ret -eq 0 && -f "${cd_file}" ]]; then
                local target_dir
                target_dir=$(cat "${cd_file}")
                if [[ -n "${target_dir}" && -d "${target_dir}" ]]; then
                    cd "${target_dir}" || ret=1
                    [[ "${open_code}" == true ]] && code .
                fi
            fi

            rm -f "${cd_file}"
            return $ret
            ;;

        remote)
            # Open remote project in VS Code (no cd - it's on a different machine)
            shift
            if [[ $# -eq 0 ]]; then
                printf '%sUsage:%s gitx remote <project-name>\n' "${DIM:-}" "${RST:-}" >&2
                printf '\n%sAvailable remote projects:%s\n' "${DIM:-}" "${RST:-}" >&2
                _gitx_list_remotes | while read -r proj; do
                    printf '  %s%s%s\n' "${CYN:-}" "${proj}" "${RST:-}" >&2
                done
                return 1
            fi
            _gitx_open_remote "$1"
            return $?
            ;;

        *)
            # Pass through to binary for all other commands
            command gitx "$@"
            return $?
            ;;
    esac
}
