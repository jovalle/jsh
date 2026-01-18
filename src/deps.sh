#!/usr/bin/env bash
# deps.sh - jsh dependency management
# Downloads binaries and plugins for all target platforms
# Can be executed standalone (bash) or sourced by jsh (bash/zsh)
# shellcheck disable=SC2034

# Only set strict mode when executed (not sourced)
# This check works in both bash and zsh
if [[ -n "${BASH_VERSION:-}" ]]; then
    # Bash: check if executed
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        set -euo pipefail
    fi
elif [[ -n "${ZSH_VERSION:-}" ]]; then
    # Zsh: being sourced (scripts executed in zsh have different $0)
    : # no strict mode when sourced
else
    # Unknown shell, assume executed
    set -euo pipefail
fi

# =============================================================================
# Constants
# =============================================================================

# Detect script directory (works in both bash and zsh, sourced or executed)
if [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2296,SC2298
    _DEPS_SCRIPT_DIR="${${(%):-%x}:A:h}"
elif [[ -n "${BASH_VERSION:-}" ]]; then
    _DEPS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    _DEPS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

JSH_DIR="${JSH_DIR:-${_DEPS_SCRIPT_DIR%/*}}"
LIB_DIR="${JSH_DIR}/lib"
BIN_DIR="${LIB_DIR}/bin"
VERSIONS_FILE="${BIN_DIR}/versions.json"

# Target platforms for binary downloads
TARGET_PLATFORMS=("darwin-arm64" "linux-amd64")

# =============================================================================
# Colors (auto-detect terminal support)
# =============================================================================

if [[ -t 1 ]]; then
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    BLUE=$'\e[34m'
    CYAN=$'\e[36m'
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    RST=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" RST=""
fi

# =============================================================================
# Output Helpers (consistent with jsh CLI)
# =============================================================================

info()    { echo "${BLUE}$*${RST}"; }
success() { echo "${GREEN}$*${RST}"; }
warn()    { echo "${YELLOW}$*${RST}" >&2; }
error()   { echo "${RED}$*${RST}" >&2; }

prefix_info()    { echo "  ${BLUE}◆${RST} $*"; }
prefix_success() { echo "  ${GREEN}✔${RST} $*"; }
prefix_warn()    { echo "  ${YELLOW}⚠${RST} $*" >&2; }
prefix_error()   { echo "  ${RED}✘${RST} $*" >&2; }

has() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
# Platform Detection
# =============================================================================

detect_platform() {
    local os arch
    os="$(uname -s)"; os="${os,,}"
    arch="$(uname -m)"

    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv*) arch="arm" ;;
    esac

    echo "${os}-${arch}"
}

get_version() {
    local tool="$1"
    if [[ -f "${VERSIONS_FILE}" ]] && has jq; then
        jq -r ".\"${tool}\" // empty" "${VERSIONS_FILE}"
    elif [[ -f "${VERSIONS_FILE}" ]]; then
        grep "\"${tool}\"" "${VERSIONS_FILE}" | sed 's/.*: *"\([^"]*\)".*/\1/'
    fi
}

# =============================================================================
# Binary Downloads
# =============================================================================

download_fzf() {
    local platform="$1"
    local version bin_path
    version=$(get_version "fzf")
    bin_path="${BIN_DIR}/${platform}/fzf"

    if [[ -x "${bin_path}" ]]; then
        prefix_success "fzf ${DIM}(${platform})${RST}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "fzf: no version in versions.json"
        return 1
    fi

    mkdir -p "${BIN_DIR}/${platform}"

    local url
    case "${platform}" in
        linux-amd64)  url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-linux_amd64.tar.gz" ;;
        linux-arm64)  url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-linux_arm64.tar.gz" ;;
        darwin-amd64) url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-darwin_amd64.tar.gz" ;;
        darwin-arm64) url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-darwin_arm64.tar.gz" ;;
        *) prefix_error "fzf: unsupported platform ${platform}"; return 1 ;;
    esac

    prefix_info "fzf v${version} ${DIM}(${platform})${RST} downloading..."
    if curl -sL "${url}" | tar xz -C "${BIN_DIR}/${platform}"; then
        chmod +x "${bin_path}"
        prefix_success "fzf v${version} ${DIM}(${platform})${RST}"
    else
        prefix_error "fzf: download failed"
        return 1
    fi
}

download_jq() {
    local platform="$1"
    local version bin_path
    version=$(get_version "jq")
    bin_path="${BIN_DIR}/${platform}/jq"

    if [[ -x "${bin_path}" ]]; then
        prefix_success "jq ${DIM}(${platform})${RST}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "jq: no version in versions.json"
        return 1
    fi

    mkdir -p "${BIN_DIR}/${platform}"

    local url
    case "${platform}" in
        darwin-arm64) url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-macos-arm64" ;;
        darwin-amd64) url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-macos-amd64" ;;
        linux-amd64)  url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-linux-amd64" ;;
        linux-arm64)  url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-linux-arm64" ;;
        *) prefix_error "jq: unsupported platform ${platform}"; return 1 ;;
    esac

    prefix_info "jq v${version} ${DIM}(${platform})${RST} downloading..."
    if curl -sL "${url}" -o "${bin_path}"; then
        chmod +x "${bin_path}"
        prefix_success "jq v${version} ${DIM}(${platform})${RST}"
    else
        prefix_error "jq: download failed"
        return 1
    fi
}

# =============================================================================
# ZSH Plugin Downloads
# =============================================================================

download_zsh_autosuggestions() {
    local version target
    version=$(get_version "zsh-autosuggestions")
    target="${LIB_DIR}/zsh-plugins/zsh-autosuggestions.zsh"

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        prefix_success "zsh-autosuggestions"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "zsh-autosuggestions: no version in versions.json"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins"

    prefix_info "zsh-autosuggestions v${version} downloading..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sL "https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v${version}.tar.gz" | tar xz -C "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-autosuggestions-${version}/zsh-autosuggestions.zsh" "${target}"
        rm -rf "${tmp_dir}"
        prefix_success "zsh-autosuggestions v${version}"
    else
        rm -rf "${tmp_dir}"
        prefix_error "zsh-autosuggestions: download failed"
        return 1
    fi
}

download_zsh_syntax_highlighting() {
    local version target
    version=$(get_version "zsh-syntax-highlighting")
    target="${LIB_DIR}/zsh-plugins/zsh-syntax-highlighting.zsh"

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        prefix_success "zsh-syntax-highlighting"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "zsh-syntax-highlighting: no version in versions.json"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins/highlighters"

    prefix_info "zsh-syntax-highlighting v${version} downloading..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sL "https://github.com/zsh-users/zsh-syntax-highlighting/archive/refs/tags/${version}.tar.gz" | tar xz -C "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-syntax-highlighting-${version}/zsh-syntax-highlighting.zsh" "${target}"
        rm -rf "${LIB_DIR}/zsh-plugins/highlighters"
        cp -r "${tmp_dir}/zsh-syntax-highlighting-${version}/highlighters" "${LIB_DIR}/zsh-plugins/"
        echo "${version}" > "${LIB_DIR}/zsh-plugins/.version"
        rm -rf "${tmp_dir}"
        prefix_success "zsh-syntax-highlighting v${version}"
    else
        rm -rf "${tmp_dir}"
        prefix_error "zsh-syntax-highlighting: download failed"
        return 1
    fi
}

download_zsh_history_substring_search() {
    local version target
    version=$(get_version "zsh-history-substring-search")
    target="${LIB_DIR}/zsh-plugins/zsh-history-substring-search.zsh"

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        prefix_success "zsh-history-substring-search"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "zsh-history-substring-search: no version in versions.json"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins"

    prefix_info "zsh-history-substring-search v${version} downloading..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sL "https://github.com/zsh-users/zsh-history-substring-search/archive/refs/tags/v${version}.tar.gz" | tar xz -C "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-history-substring-search-${version}/zsh-history-substring-search.zsh" "${target}"
        rm -rf "${tmp_dir}"
        prefix_success "zsh-history-substring-search v${version}"
    else
        rm -rf "${tmp_dir}"
        prefix_error "zsh-history-substring-search: download failed"
        return 1
    fi
}

# =============================================================================
# Plugin Verification
# =============================================================================

verify_plugins() {
    local errors=0

    local plugins=(
        "zsh-plugins/zsh-autosuggestions.zsh"
        "zsh-plugins/zsh-syntax-highlighting.zsh"
        "zsh-plugins/zsh-history-substring-search.zsh"
        "zsh-plugins/highlighters/main/main-highlighter.zsh"
    )

    for plugin in "${plugins[@]}"; do
        if [[ -f "${LIB_DIR}/${plugin}" ]]; then
            prefix_success "${plugin}"
        else
            prefix_error "${plugin}"
            ((errors++))
        fi
    done

    # Check completions (submodule or bundled fallback)
    if [[ -d "${LIB_DIR}/zsh-completions/src" ]]; then
        local count
        count=$(find "${LIB_DIR}/zsh-completions/src" -type f | wc -l | tr -d ' ')
        prefix_success "zsh-completions ${DIM}(${count} files)${RST}"
    elif [[ -d "${LIB_DIR}/zsh-plugins/completions-core" ]]; then
        local count
        count=$(find "${LIB_DIR}/zsh-plugins/completions-core" -type f | wc -l | tr -d ' ')
        prefix_success "zsh-plugins/completions-core ${DIM}(${count} files)${RST}"
    else
        prefix_warn "zsh-completions submodule not initialized"
        echo "         ${DIM}run: git submodule update --init${RST}"
    fi

    return ${errors}
}

# =============================================================================
# Banner
# =============================================================================

_deps_banner() {
    echo ""
    echo "${BOLD}${CYAN}"
    echo "     ██╗███████╗██╗  ██╗"
    echo "     ██║██╔════╝██║  ██║"
    echo "     ██║███████╗███████║"
    echo "██   ██║╚════██║██╔══██║"
    echo "╚█████╔╝███████║██║  ██║"
    echo " ╚════╝ ╚══════╝╚═╝  ╚═╝"
    echo "${RST}"
    echo "${DIM}  Dependency Management${RST}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    local force_download=false
    local current_only=false
    local subcmd=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) force_download=true; FORCE_DOWNLOAD=1; shift ;;
            --current)  current_only=true; shift ;;
            -h|--help)
                echo "Usage: deps.sh [COMMAND] [OPTIONS]"
                echo ""
                echo "Commands:"
                echo "  install         Download all dependencies (default)"
                echo "  status          Show dependency status"
                echo "  submodules      List submodules status"
                echo "  submodules update  Update all submodules"
                echo ""
                echo "Options:"
                echo "  -f, --force     Force re-download of all dependencies"
                echo "  --current       Only download for current platform"
                echo "  -h, --help      Show this help"
                exit 0
                ;;
            install|status|submodules)
                subcmd="$1"; shift ;;
            update)
                # Handle 'submodules update'
                if [[ "${subcmd}" == "submodules" ]]; then
                    update_submodules
                    return $?
                fi
                shift ;;
            *) shift ;;
        esac
    done

    # Handle subcommands
    case "${subcmd}" in
        status)
            _jsh_deps_status
            return 0
            ;;
        submodules)
            list_submodules
            return 0
            ;;
    esac

    _deps_banner

    local current_platform
    current_platform=$(detect_platform)
    info "Current platform: ${current_platform}"
    echo ""

    local errors=0
    local platforms_to_install=()

    if [[ "${current_only}" == true ]]; then
        platforms_to_install=("${current_platform}")
    else
        platforms_to_install=("${TARGET_PLATFORMS[@]}")
    fi

    # Download binaries for all target platforms
    echo "${CYAN}Binaries:${RST}"
    for platform in "${platforms_to_install[@]}"; do
        download_fzf "${platform}" || ((errors++))
        download_jq "${platform}" || ((errors++))
    done
    echo ""

    # Download ZSH plugins (platform-independent)
    echo "${CYAN}ZSH Plugins:${RST}"
    download_zsh_autosuggestions || ((errors++))
    download_zsh_syntax_highlighting || ((errors++))
    download_zsh_history_substring_search || ((errors++))
    echo ""

    # Verify plugins
    echo "${CYAN}Verification:${RST}"
    verify_plugins || ((errors++))
    echo ""

    # Summary
    if [[ ${errors} -eq 0 ]]; then
        echo "${GREEN}✔${RST} All dependencies configured"
    else
        echo "${YELLOW}⚠${RST} Completed with ${errors} warning(s)"
    fi
    echo ""
}

# =============================================================================
# Submodule Management
# =============================================================================

# List all submodules with their status
list_submodules() {
    local git_dir="${JSH_DIR}/.git"

    if [[ ! -d "${git_dir}" ]]; then
        prefix_warn "Not a git repository"
        return 1
    fi

    echo "${CYAN}Submodules:${RST}"

    # Parse .gitmodules if it exists
    local gitmodules="${JSH_DIR}/.gitmodules"
    if [[ ! -f "${gitmodules}" ]]; then
        prefix_info "No submodules configured"
        return 0
    fi

    # Extract submodule paths using git config
    local submodule_count=0
    local paths
    paths=$(git config --file "${gitmodules}" --get-regexp 'submodule\..*\.path' 2>/dev/null | cut -d' ' -f2)

    if [[ -z "${paths}" ]]; then
        prefix_info "No submodules configured"
        return 0
    fi

    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue

        local status_icon status_text
        local full_path="${JSH_DIR}/${path}"

        if [[ ! -d "${full_path}" ]]; then
            status_icon="${RED}✘${RST}"
            status_text="not cloned"
        elif [[ -z "$(ls -A "${full_path}" 2>/dev/null)" ]]; then
            status_icon="${YELLOW}○${RST}"
            status_text="empty (not initialized)"
        else
            # Check if submodule is up to date
            local head_commit
            if head_commit=$(git -C "${full_path}" rev-parse --short HEAD 2>/dev/null); then
                status_icon="${GREEN}✔${RST}"
                status_text="${DIM}${head_commit}${RST}"
            else
                status_icon="${YELLOW}?${RST}"
                status_text="unknown state"
            fi
        fi

        echo "  ${status_icon} ${path} ${status_text}"
        ((submodule_count++))
    done <<< "${paths}"

    if [[ ${submodule_count} -eq 0 ]]; then
        prefix_info "No submodules configured"
    fi
}

# Update submodules (init and update)
update_submodules() {
    local git_dir="${JSH_DIR}/.git"

    if [[ ! -d "${git_dir}" ]]; then
        prefix_warn "Not a git repository"
        return 1
    fi

    echo "${CYAN}Updating submodules:${RST}"

    # Initialize any uninitialized submodules
    prefix_info "Initializing submodules..."
    if git -C "${JSH_DIR}" submodule update --init --depth 1 2>/dev/null; then
        prefix_success "Submodules initialized"
    else
        prefix_warn "Some submodules may have failed to initialize"
    fi

    # Update to latest
    prefix_info "Updating submodules to latest..."
    if git -C "${JSH_DIR}" submodule update --remote --depth 1 2>/dev/null; then
        prefix_success "Submodules updated"
    else
        prefix_warn "Some submodules may have failed to update"
    fi

    echo ""
    list_submodules
}

# =============================================================================
# Functions for jsh CLI integration
# =============================================================================

# Status display for 'jsh deps status'
_jsh_deps_status() {
    local current_platform
    current_platform=$(detect_platform)
    info "Platform: ${current_platform}"
    echo ""

    # Binary status
    echo "${CYAN}Bundled Binaries:${RST}"
    local binaries=("fzf" "jq")
    for bin in "${binaries[@]}"; do
        local bin_path="${BIN_DIR}/${current_platform}/${bin}"
        if [[ -x "${bin_path}" ]]; then
            local version_info=""
            case "${bin}" in
                fzf) version_info=$("${bin_path}" --version 2>/dev/null | head -1) ;;
                jq)  version_info=$("${bin_path}" --version 2>/dev/null) ;;
            esac
            prefix_success "${bin} ${DIM}(${version_info})${RST}"
        else
            prefix_warn "${bin} not installed for ${current_platform}"
        fi
    done
    echo ""

    # Plugin status
    echo "${CYAN}ZSH Plugins:${RST}"
    local plugins=(
        "zsh-autosuggestions.zsh"
        "zsh-syntax-highlighting.zsh"
        "zsh-history-substring-search.zsh"
    )
    for plugin in "${plugins[@]}"; do
        local plugin_path="${LIB_DIR}/zsh-plugins/${plugin}"
        if [[ -f "${plugin_path}" ]]; then
            prefix_success "${plugin%.zsh}"
        else
            prefix_warn "${plugin%.zsh} not installed"
        fi
    done
    echo ""

    # Submodule status
    list_submodules
    echo ""

    # Version info
    if [[ -f "${VERSIONS_FILE}" ]]; then
        echo "${CYAN}Configured Versions:${RST}"
        if has jq; then
            jq -r 'to_entries[] | "  \(.key): v\(.value)"' "${VERSIONS_FILE}"
        else
            cat "${VERSIONS_FILE}"
        fi
    fi
}

# Preflight check for dependency resolution
_jsh_preflight_full() {
    local platform capabilities
    platform=$(detect_platform)

    # Check system capabilities
    local has_git=false has_curl=false has_make=false has_gcc=false
    has git && has_git=true
    has curl && has_curl=true
    has make && has_make=true
    has gcc && has_gcc=true

    # Check for glibc version (Linux only)
    local glibc_version="N/A"
    if [[ "$(uname -s)" == "Linux" ]]; then
        glibc_version=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "unknown")
    fi

    # Output JSON state
    cat << EOF
{
  "platform": "${platform}",
  "glibc": "${glibc_version}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "capabilities": {
    "git": ${has_git},
    "curl": ${has_curl},
    "make": ${has_make},
    "gcc": ${has_gcc}
  },
  "binaries": {
    "fzf": $([ -x "${BIN_DIR}/${platform}/fzf" ] && echo true || echo false),
    "jq": $([ -x "${BIN_DIR}/${platform}/jq" ] && echo true || echo false)
  }
}
EOF
}

# Capability status display
_jsh_capability_status() {
    echo ""
    echo "${BOLD}Build Capabilities${RST}"
    echo ""

    echo "${CYAN}Tools:${RST}"
    local tools=("git" "curl" "make" "gcc" "cargo" "go")
    for tool in "${tools[@]}"; do
        if has "${tool}"; then
            local version=""
            case "${tool}" in
                git)   version=$(git --version 2>/dev/null | cut -d' ' -f3) ;;
                curl)  version=$(curl --version 2>/dev/null | head -1 | cut -d' ' -f2) ;;
                make)  version=$(make --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1) ;;
                gcc)   version=$(gcc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' | head -1) ;;
                cargo) version=$(cargo --version 2>/dev/null | cut -d' ' -f2) ;;
                go)    version=$(go version 2>/dev/null | cut -d' ' -f3 | sed 's/go//') ;;
            esac
            echo "  ${GREEN}✔${RST} ${tool} ${DIM}(${version})${RST}"
        else
            echo "  ${DIM}-${RST} ${tool}"
        fi
    done
    echo ""

    echo "${CYAN}Platform Info:${RST}"
    echo "  OS:       $(uname -s)"
    echo "  Arch:     $(uname -m)"
    echo "  Platform: $(detect_platform)"

    if [[ "$(uname -s)" == "Linux" ]]; then
        local glibc
        glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "unknown")
        echo "  glibc:    ${glibc}"
    fi
    echo ""
}

# =============================================================================
# Main Entry Point
# =============================================================================

# Run main if script is executed (not sourced)
# In zsh, if we reach here we're being sourced (shebang is bash)
# In bash, compare BASH_SOURCE to $0
if [[ -n "${BASH_VERSION:-}" ]] && [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
