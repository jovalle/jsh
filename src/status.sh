#!/usr/bin/env bash
# status.sh - Installation status and diagnostics
# Provides cmd_status and related helper functions
#
# Dependencies: core.sh (colors, helpers), symlinks.sh (_process_symlink_rules)
# shellcheck disable=SC2034

# Load guard
[[ -n "${_JSH_STATUS_LOADED:-}" ]] && return 0
_JSH_STATUS_LOADED=1

# =============================================================================
# Helper Functions
# =============================================================================

# Find broken symlinks in a directory
# Args: $1 = directory, $2 = depth (default: 1)
_find_broken_symlinks() {
    local search_dir="$1"
    local depth="${2:-1}"

    [[ -d "${search_dir}" ]] || return

    find "${search_dir}" -maxdepth "${depth}" -type l 2>/dev/null | while read -r link; do
        if [[ ! -e "${link}" ]]; then
            echo "${link}"
        fi
    done
}

# Check a bundled binary's health
# Args: $1 = binary name, $2 = bin directory
# Returns: 0=healthy, 1=not bundled, 2=not in PATH, 3=wrong version in PATH, 4=runtime error
# Output: status message suitable for display
_check_bundled_binary() {
    local name="$1"
    local bin_dir="$2"
    local bundled="${bin_dir}/${name}"
    local resolved version_output exit_code

    # Check if bundled binary exists
    if [[ ! -x "${bundled}" ]]; then
        echo "not_bundled"
        return 1
    fi

    # Check what's being resolved via PATH
    resolved=$(command -v "${name}" 2>/dev/null)
    if [[ -z "${resolved}" ]]; then
        echo "not_in_path"
        return 2
    fi

    # Check if resolved binary is our bundled version
    if [[ "${resolved}" != "${bundled}" ]]; then
        echo "wrong_path:${resolved}"
        return 3
    fi

    # Run version check to verify runtime health
    # Capture both stdout and stderr, and the exit code
    case "${name}" in
        fzf)
            version_output=$("${bundled}" --version 2>&1)
            exit_code=$?
            if [[ ${exit_code} -eq 0 ]]; then
                echo "healthy:${version_output}"
                return 0
            fi
            ;;
        jq)
            version_output=$("${bundled}" --version 2>&1)
            exit_code=$?
            if [[ ${exit_code} -eq 0 ]]; then
                # jq --version outputs "jq-X.Y.Z", strip the "jq-" prefix
                echo "healthy:${version_output#jq-}"
                return 0
            fi
            ;;
        *)
            # Generic check for other binaries
            version_output=$("${bundled}" --version 2>&1 || "${bundled}" -v 2>&1 || true)
            exit_code=$?
            if [[ ${exit_code} -eq 0 ]]; then
                local ver_line
                ver_line=$(echo "${version_output}" | head -1)
                echo "healthy:${ver_line}"
                return 0
            fi
            ;;
    esac

    # Runtime error - try to identify the cause
    if [[ "${version_output}" == *"GLIBC"* ]]; then
        echo "runtime_error:glibc version mismatch"
    elif [[ "${version_output}" == *"cannot open shared object"* ]]; then
        local missing_lib
        missing_lib=$(echo "${version_output}" | grep -o 'lib[^:]*\.so[^ ]*' | head -1)
        echo "runtime_error:missing ${missing_lib:-shared library}"
    elif [[ "${version_output}" == *"Illegal instruction"* ]]; then
        echo "runtime_error:CPU instruction incompatibility"
    else
        echo "runtime_error:${version_output%%$'\n'*}"
    fi
    return 4
}

# =============================================================================
# Status Command
# =============================================================================

# @jsh-cmd status Show installation status, symlinks, and check for issues
# @jsh-opt -f,--fix Fix issues (remove broken symlinks)
# @jsh-opt -v,--verbose Show verbose output
cmd_status() {
    local fix_issues=false
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix|-f)
                fix_issues=true
                shift
                ;;
            --verbose|-v)
                verbose=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    show_banner

    # Installation info
    echo "${CYN}Installation:${RST}"
    echo "  Directory: ${JSH_DIR}"
    echo "  Version:   ${VERSION}"

    if [[ -d "${JSH_DIR}/.git" ]]; then
        local branch commit remote_status
        branch=$(git -C "${JSH_DIR}" branch --show-current 2>/dev/null || echo "unknown")
        commit=$(git -C "${JSH_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "  Branch:    ${branch}"
        echo "  Commit:    ${commit}"

        # Check if ahead/behind remote
        local ahead behind
        ahead=$(git -C "${JSH_DIR}" rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
        behind=$(git -C "${JSH_DIR}" rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
        if [[ "${ahead}" -gt 0 ]] || [[ "${behind}" -gt 0 ]]; then
            remote_status=""
            [[ "${ahead}" -gt 0 ]] && remote_status+="${GRN}↑${ahead}${RST}"
            [[ "${behind}" -gt 0 ]] && remote_status+="${RED}↓${behind}${RST}"
            echo "  Remote:    ${remote_status}"
        fi
    fi

    # Platform info
    echo ""
    echo "${CYN}Platform:${RST}"
    local platform="${JSH_PLATFORM:-unknown}"
    echo "  OS:        ${JSH_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
    echo "  Arch:      ${JSH_ARCH:-$(uname -m)}"
    echo "  Platform:  ${platform}"
    echo "  Shell:     ${SHELL##*/} (${JSH_SHELL:-unknown})"
    echo "  EDITOR:    ${EDITOR:-not set}"

    # Detailed symlink status
    echo ""
    echo "${CYN}Symlinks:${RST}"
    _process_symlink_rules "" "status"

    # Tool checks - Requirements
    echo ""
    echo "${CYN}Requirements:${RST}"
    local issues=0

    # Required tools with versions
    echo "  ${DIM}Required:${RST}"
    local required=("git" "curl")
    for tool in "${required[@]}"; do
        if has "${tool}"; then
            local ver=""
            case "${tool}" in
                git)  ver=$(git --version 2>/dev/null | cut -d' ' -f3) ;;
                curl) ver=$(curl --version 2>/dev/null | head -1 | cut -d' ' -f2) ;;
            esac
            echo "    ${GRN}✔${RST} ${tool} ${DIM}${ver}${RST}"
        else
            echo "    ${RED}✘${RST} ${tool} ${DIM}(required)${RST}"
            ((issues++))
        fi
    done

    # Check bash version (require 4.0+ for modern features)
    local bash_ver bash_major
    bash_ver="${BASH_VERSION:-$(bash --version 2>/dev/null | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')}"
    bash_major="${bash_ver%%.*}"
    if [[ "${bash_major}" -ge 4 ]]; then
        echo "    ${GRN}✔${RST} bash ${DIM}${bash_ver}${RST}"
    else
        echo "    ${RED}✘${RST} bash ${DIM}${bash_ver} (need 4.0+, run: jsh deps fix-bash)${RST}"
        ((issues++))
    fi

    if has zsh; then
        local zsh_ver
        zsh_ver=$(zsh --version 2>/dev/null | cut -d' ' -f2)
        echo "    ${GRN}✔${RST} zsh ${DIM}${zsh_ver}${RST}"
    else
        echo "    ${YLW}⚠${RST} zsh ${DIM}(recommended)${RST}"
    fi

    # Optional tools
    echo "  ${DIM}Optional:${RST}"
    local recommended=("fzf" "fd" "rg" "bat" "eza" "tmux" "jq")
    for tool in "${recommended[@]}"; do
        if has "${tool}"; then
            local ver=""
            case "${tool}" in
                fzf)  ver=$("${tool}" --version 2>/dev/null | head -1) ;;
                fd)   ver=$("${tool}" --version 2>/dev/null | cut -d' ' -f2) ;;
                rg)   ver=$("${tool}" --version 2>/dev/null | head -1 | cut -d' ' -f2) ;;
                bat)  ver=$("${tool}" --version 2>/dev/null | cut -d' ' -f2) ;;
                eza)  ver=$("${tool}" --version 2>/dev/null | sed -n '2s/^v\([^ ]*\).*/\1/p') ;;
                tmux) ver=$("${tool}" -V 2>/dev/null | cut -d' ' -f2) ;;
                jq)   ver=$("${tool}" --version 2>/dev/null) ;;
            esac
            echo "    ${GRN}✔${RST} ${tool} ${DIM}${ver}${RST}"
        else
            echo "    ${DIM}-${RST} ${tool}"
        fi
    done

    # Bundled binaries (downloaded via `make download-tools`)
    echo ""
    echo "${CYN}Bundled Binaries:${RST}"
    local bin_dir="${JSH_DIR}/bin/${platform}"

    if [[ "${platform}" == "unknown" ]]; then
        echo "  ${YLW}⚠${RST} Unknown platform, cannot check bundled binaries"
    elif [[ ! -d "${bin_dir}" ]]; then
        echo "  ${DIM}-${RST} No bundled binaries (optional)"
        echo "  ${DIM}  Download: make download-tools${RST}"
        echo "  ${DIM}  Or install: brew install jq fzf${RST}"
    else
        local key_deps=("fzf" "jq")
        for dep in "${key_deps[@]}"; do
            local result status_type status_detail
            result=$(_check_bundled_binary "${dep}" "${bin_dir}")
            status_type="${result%%:*}"
            status_detail="${result#*:}"

            case "${status_type}" in
                healthy)
                    echo "  ${GRN}✔${RST} ${dep}: ${status_detail}"
                    ;;
                not_bundled)
                    echo "  ${DIM}-${RST} ${dep} (not bundled for ${platform})"
                    ;;
                not_in_path)
                    echo "  ${RED}✘${RST} ${dep}: bundled but not in PATH"
                    echo "      ${DIM}Expected: ${bin_dir}/${dep}${RST}"
                    ((issues++))
                    ;;
                wrong_path)
                    echo "  ${YLW}⚠${RST} ${dep}: using system version"
                    echo "      ${DIM}Active:   ${status_detail}${RST}"
                    echo "      ${DIM}Bundled:  ${bin_dir}/${dep}${RST}"
                    ;;
                runtime_error)
                    echo "  ${RED}✘${RST} ${dep}: ${status_detail}"
                    echo "      ${DIM}Binary: ${bin_dir}/${dep}${RST}"
                    ((issues++))
                    ;;
            esac
        done
    fi

    # ZSH Plugins
    echo ""
    echo "${CYN}ZSH Plugins:${RST}"
    local plugins_dir="${JSH_DIR}/lib/zsh-plugins"
    local plugins=("zsh-autosuggestions" "zsh-syntax-highlighting" "zsh-history-substring-search")
    for plugin in "${plugins[@]}"; do
        local plugin_file="${plugins_dir}/${plugin}.zsh"
        if [[ -f "${plugin_file}" ]]; then
            echo "  ${GRN}✔${RST} ${plugin}"
        else
            echo "  ${YLW}⚠${RST} ${plugin} ${DIM}(not installed)${RST}"
        fi
    done

    # Check highlighters directory for syntax highlighting
    if [[ -d "${plugins_dir}/highlighters" ]]; then
        local highlighter_count
        highlighter_count=$(find "${plugins_dir}/highlighters" -name "*.zsh" 2>/dev/null | wc -l | tr -d ' ')
        echo "  ${GRN}✔${RST} highlighters ${DIM}(${highlighter_count} files)${RST}"
    fi

    # Submodules
    echo ""
    echo "${CYN}Submodules:${RST}"
    local gitmodules="${JSH_DIR}/.gitmodules"
    if [[ -f "${gitmodules}" ]]; then
        while IFS= read -r line; do
            if [[ "${line}" =~ path\ =\ (.+) ]]; then
                local submod_path="${BASH_REMATCH[1]}"
                local full_path="${JSH_DIR}/${submod_path}"

                if [[ ! -d "${full_path}" ]]; then
                    echo "  ${RED}✘${RST} ${submod_path} ${DIM}(not cloned)${RST}"
                    ((issues++))
                elif [[ -z "$(ls -A "${full_path}" 2>/dev/null)" ]]; then
                    echo "  ${YLW}○${RST} ${submod_path} ${DIM}(not initialized)${RST}"
                else
                    local sub_commit
                    sub_commit=$(git -C "${full_path}" rev-parse --short HEAD 2>/dev/null || echo "?")
                    echo "  ${GRN}✔${RST} ${submod_path} ${DIM}(${sub_commit})${RST}"
                fi
            fi
        done < "${gitmodules}"
    else
        echo "  ${DIM}No submodules configured${RST}"
    fi

    # Dependency versions (from versions.json)
    local versions_file="${JSH_DIR}/lib/versions.json"
    if [[ -f "${versions_file}" ]]; then
        echo ""
        echo "${CYN}Configured Versions:${RST}"
        if has jq; then
            jq -r 'to_entries[] | "  \(.key): v\(.value)"' "${versions_file}" 2>/dev/null
        else
            # Fallback without jq
            while IFS= read -r line; do
                if [[ "${line}" =~ \"([^\"]+)\":\ *\"([^\"]+)\" ]]; then
                    echo "  ${BASH_REMATCH[1]}: v${BASH_REMATCH[2]}"
                fi
            done < "${versions_file}"
        fi
    fi

    # Broken symlinks check
    echo ""
    echo "${CYN}Broken symlinks:${RST}"
    local xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"
    local broken_links=()

    while IFS= read -r link; do
        [[ -n "${link}" ]] && broken_links+=("${link}")
    done < <(_find_broken_symlinks "${JSH_DIR}" 3)

    while IFS= read -r link; do
        [[ -n "${link}" ]] && broken_links+=("${link}")
    done < <(_find_broken_symlinks "${HOME}" 1)

    while IFS= read -r link; do
        [[ -n "${link}" ]] && broken_links+=("${link}")
    done < <(_find_broken_symlinks "${xdg_config}" 2)

    if [[ ${#broken_links[@]} -eq 0 ]]; then
        echo "  ${GRN}✔${RST} None found"
    else
        for link in "${broken_links[@]}"; do
            local target
            target=$(readlink "${link}" 2>/dev/null || echo "unknown")
            if [[ "${fix_issues}" == true ]]; then
                rm -f "${link}"
                echo "  ${GRN}✔${RST} Fixed: ${link}"
            else
                echo "  ${RED}✘${RST} ${link} -> ${target}"
                ((issues++))
            fi
        done

        if [[ "${fix_issues}" != true ]] && [[ ${#broken_links[@]} -gt 0 ]]; then
            echo ""
            info "Run ${CYN}jsh status --fix${RST} to remove broken symlinks"
        fi
    fi

    # Summary
    echo ""
    if [[ "${issues}" -eq 0 ]]; then
        prefix_success "No issues found"
    else
        prefix_warn "${issues} issue(s) found"
    fi
}
