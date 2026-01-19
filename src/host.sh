#!/usr/bin/env bash
# host.sh - Remote host management for jssh
# Provides cmd_host and related subcommands
#
# Dependencies: core.sh (colors, helpers)
# shellcheck disable=SC2034

# Load guard
[[ -n "${_JSH_HOST_LOADED:-}" ]] && return 0
_JSH_HOST_LOADED=1

# =============================================================================
# Host Commands
# =============================================================================

# @jsh-cmd host Manage remote host configurations for jssh
# @jsh-sub list List known remote hosts
# @jsh-sub status Show host capabilities and decisions
# @jsh-sub refresh Re-run remote preflight for a host
# @jsh-sub reset Clear cached decisions for a host
cmd_host() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "${subcmd}" in
        list|ls|l)
            cmd_host_list "$@"
            ;;
        status|s)
            cmd_host_status "$@"
            ;;
        refresh|r)
            cmd_host_refresh "$@"
            ;;
        reset)
            cmd_host_reset "$@"
            ;;
        *)
            echo "${BOLD}jsh host${RST} - Remote host management"
            echo ""
            echo "${BOLD}USAGE:${RST}"
            echo "    jsh host <command> [hostname]"
            echo ""
            echo "${BOLD}COMMANDS:${RST}"
            echo "    ${CYN}list${RST}          List known remote hosts"
            echo "    ${CYN}status${RST}        Show host capabilities and decisions"
            echo "    ${CYN}refresh${RST}       Re-run remote preflight for a host"
            echo "    ${CYN}reset${RST}         Clear cached decisions for a host"
            ;;
    esac
}

cmd_host_list() {
    local hosts_dir="${JSH_DIR}/local/hosts"

    echo ""
    echo "${BOLD}Known Remote Hosts${RST}"
    echo ""

    if [[ ! -d "${hosts_dir}" ]] || [[ -z "$(ls -A "${hosts_dir}" 2>/dev/null)" ]]; then
        prefix_info "No remote hosts configured yet"
        echo ""
        echo "Remote hosts are tracked when you use ${CYN}jssh${RST} to connect."
        return 0
    fi

    for host_file in "${hosts_dir}"/*.json; do
        [[ -f "${host_file}" ]] || continue

        local hostname platform last_check
        if has jq; then
            hostname=$(jq -r '.hostname // "unknown"' "${host_file}")
            platform=$(jq -r '.platform // "unknown"' "${host_file}")
            last_check=$(jq -r '.last_check // "never"' "${host_file}")
        else
            hostname=$(basename "${host_file}" .json)
            platform="unknown"
            last_check="unknown"
        fi

        printf "  ${CYN}%-30s${RST}  ${DIM}%s${RST}  %s\n" \
            "${hostname}" "${platform}" "${last_check}"
    done

    echo ""
}

cmd_host_status() {
    local hostname="${1:-}"

    if [[ -z "${hostname}" ]]; then
        error "Usage: jsh host status <hostname>"
        return 1
    fi

    local hosts_dir="${JSH_DIR}/local/hosts"
    local host_file

    # Try exact match first, then glob
    if [[ -f "${hosts_dir}/${hostname}.json" ]]; then
        host_file="${hosts_dir}/${hostname}.json"
    else
        # Try to find a match
        local matches=("${hosts_dir}"/*"${hostname}"*.json)
        if [[ ${#matches[@]} -eq 1 ]] && [[ -f "${matches[0]}" ]]; then
            host_file="${matches[0]}"
        elif [[ ${#matches[@]} -gt 1 ]]; then
            error "Multiple matches found. Be more specific:"
            for m in "${matches[@]}"; do
                echo "  $(basename "${m}" .json)"
            done
            return 1
        else
            error "Host not found: ${hostname}"
            prefix_info "Available hosts: jsh host list"
            return 1
        fi
    fi

    if ! has jq; then
        cat "${host_file}"
        return 0
    fi

    echo ""
    echo "${BOLD}Host: $(jq -r '.hostname' "${host_file}")${RST}"
    echo ""

    echo "${CYN}System:${RST}"
    echo "  Platform:    $(jq -r '.platform // "unknown"' "${host_file}")"
    echo "  glibc:       $(jq -r '.glibc // "N/A"' "${host_file}")"
    echo "  Last check:  $(jq -r '.last_check // "never"' "${host_file}")"
    echo ""

    echo "${CYN}Capabilities:${RST}"
    jq -r '.capabilities // {} | to_entries[] | "  \(if .value then "✔" else "✘" end) \(.key)"' "${host_file}"
    echo ""

    echo "${CYN}Dependency Decisions:${RST}"
    jq -r '.decisions // {} | to_entries[] | "  \(.key): \(.value.strategy) (\(.value.reason // ""))"' "${host_file}"
    echo ""
}

cmd_host_refresh() {
    local hostname="${1:-}"

    if [[ -z "${hostname}" ]]; then
        error "Usage: jsh host refresh <hostname>"
        return 1
    fi

    info "Refreshing host: ${hostname}"
    warn "Remote host refresh requires jssh connection"
    prefix_info "Connect with: jssh ${hostname}"
    prefix_info "The preflight will run automatically on connection"
}

cmd_host_reset() {
    local hostname="${1:-}"

    if [[ -z "${hostname}" ]]; then
        error "Usage: jsh host reset <hostname>"
        return 1
    fi

    local hosts_dir="${JSH_DIR}/local/hosts"
    local host_file="${hosts_dir}/${hostname}.json"

    if [[ ! -f "${host_file}" ]]; then
        # Try glob match
        local matches=("${hosts_dir}"/*"${hostname}"*.json)
        if [[ ${#matches[@]} -eq 1 ]] && [[ -f "${matches[0]}" ]]; then
            host_file="${matches[0]}"
        else
            error "Host not found: ${hostname}"
            return 1
        fi
    fi

    local actual_hostname
    actual_hostname=$(basename "${host_file}" .json)

    read -r -p "Reset all decisions for ${actual_hostname}? [y/N] " confirm
    if [[ "${confirm}" =~ ^[Yy] ]]; then
        rm -f "${host_file}"
        success "Reset ${actual_hostname} - will re-prompt on next jssh connection"
    else
        info "Cancelled"
    fi
}
