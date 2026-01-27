#!/usr/bin/env bash
# deps.sh - jsh dependency management
# Downloads ZSH plugins and manages submodules
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
VERSIONS_FILE="${LIB_DIR}/versions.json"

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
# Timing Utilities (uv-style summaries)
# =============================================================================

# Get current time in milliseconds (pattern from profiler.sh)
_deps_now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        awk "BEGIN {printf \"%.0f\", ${EPOCHREALTIME} * 1000}"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000' 2>/dev/null || echo "$(($(date +%s) * 1000))"
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# Format milliseconds as human-readable duration
_deps_format_duration() {
    local ms="$1"
    if [[ ${ms} -ge 1000 ]]; then
        awk "BEGIN {printf \"%.1fs\", ${ms} / 1000}"
    else
        echo "${ms}ms"
    fi
}

# Print uv-style summary line
_deps_summary() {
    local count="$1" start_ms="$2" label="${3:-Installed}"
    local end_ms duration item_word
    end_ms=$(_deps_now_ms)
    duration=$(_deps_format_duration $((end_ms - start_ms)))
    item_word="packages"
    [[ ${count} -eq 1 ]] && item_word="package"
    [[ ${count} -gt 0 ]] && echo "${label} ${count} ${item_word} in ${duration}"
}

# =============================================================================
# Output Helpers (consistent with jsh CLI)
# =============================================================================

info()    { echo "${BLUE}$*${RST}"; }
success() { echo "${GREEN}$*${RST}"; }
warn()    { echo "${YELLOW}$*${RST}" >&2; }
error()   { echo "${RED}$*${RST}" >&2; }

prefix_info()    { echo "  ${BLUE}◆${RST} $*"; }
prefix_success() { echo "  ${GREEN}✓${RST} $*"; }
prefix_warn()    { echo "  ${YELLOW}⚠${RST} $*" >&2; }
prefix_error()   { echo "  ${RED}✘${RST} $*" >&2; }

# uv-style prefixes for add/remove actions
prefix_add()    { echo " ${GREEN}+${RST} $*"; }
prefix_remove() { echo " ${RED}-${RST} $*"; }

has() { command -v "$1" >/dev/null 2>&1; }

# Download a file using curl or wget (whichever is available)
# Usage: download_file <url> <output_path>
# Returns: 0 on success, 1 on failure
download_file() {
    local url="$1" output="$2"

    if has curl; then
        curl -fsSL "${url}" -o "${output}" 2>/dev/null
    elif has wget; then
        wget -q -O "${output}" "${url}" 2>/dev/null
    else
        return 1
    fi
}

# Download and extract a tarball using curl or wget
# Usage: download_tarball <url> <extract_dir>
# Returns: 0 on success, 1 on failure
download_tarball() {
    local url="$1" extract_dir="$2"

    if has curl; then
        curl -fsSL "${url}" | tar xz -C "${extract_dir}" 2>/dev/null
    elif has wget; then
        wget -q -O- "${url}" | tar xz -C "${extract_dir}" 2>/dev/null
    else
        return 1
    fi
}

# Check if we have a download tool available
has_download_tool() {
    has curl || has wget
}

# =============================================================================
# Platform Detection
# =============================================================================

detect_platform() {
    local os arch
    # Use tr for lowercase - works in both bash and zsh
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
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
# Binary Tool Downloads (jq, fzf)
# =============================================================================
# Downloads essential tools to bin/<platform>/ directory
# These are git-ignored - users can also install via package manager
# Versions are defined in lib/versions.json (single source of truth)

# Get download URL for a binary tool
# Usage: get_binary_url <tool> <platform> <version>
get_binary_url() {
    local tool="$1" platform="$2" version="$3"
    local os arch jq_os nvim_os nvim_arch

    os="${platform%-*}"    # darwin or linux
    arch="${platform#*-}"  # amd64 or arm64

    case "${tool}" in
        jq)
            # jq releases use 'macos' instead of 'darwin' for macOS builds
            jq_os="${os}"
            [[ "${os}" == "darwin" ]] && jq_os="macos"
            # jq releases use format: jq-<os>-<arch>
            echo "https://github.com/jqlang/jq/releases/download/jq-${version}/jq-${jq_os}-${arch}"
            ;;
        fzf)
            # fzf releases use format: fzf-<version>-<os>_<arch>.tar.gz (note: underscore)
            echo "https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-${os}_${arch}.tar.gz"
            ;;
        nvim)
            # nvim releases use format: nvim-<os>-<arch>.tar.gz
            # macOS uses 'macos', linux uses 'linux'
            # arch: x86_64 or arm64
            nvim_os="${os}"
            [[ "${os}" == "darwin" ]] && nvim_os="macos"
            nvim_arch="${arch}"
            [[ "${arch}" == "amd64" ]] && nvim_arch="x86_64"
            echo "https://github.com/neovim/neovim/releases/download/v${version}/nvim-${nvim_os}-${nvim_arch}.tar.gz"
            ;;
        *)
            return 1
            ;;
    esac
}

# Get version for a binary tool (from versions.json with fallback)
get_binary_version() {
    local tool="$1"
    local version
    version=$(get_version "$tool")
    if [[ -n "$version" ]]; then
        echo "$version"
    else
        # Fallback defaults if versions.json is missing or tool not found
        case "$tool" in
            jq)   echo "1.7.1" ;;
            fzf)  echo "0.60.3" ;;
            nvim) echo "0.11.5" ;;
            *)    return 1 ;;
        esac
    fi
}

# Download a binary tool to bin/<platform>/
# Usage: download_binary <tool>
# Returns: 0 on success, 1 on failure
download_binary() {
    local tool="$1"
    local platform version url bin_dir target

    # Check for download tool availability first
    if ! has_download_tool; then
        prefix_error "${tool}: no download tool available (need curl or wget)"
        prefix_info "Install with: apt-get install curl (Linux) or brew install curl (macOS)"
        return 1
    fi

    platform=$(detect_platform)
    version=$(get_binary_version "${tool}") || {
        prefix_error "${tool}: unknown tool"
        return 1
    }
    url=$(get_binary_url "${tool}" "${platform}" "${version}") || {
        prefix_error "${tool}: failed to get download URL"
        return 1
    }

    bin_dir="${JSH_DIR}/bin/${platform}"
    target="${bin_dir}/${tool}"

    # Check if already exists
    if [[ -x "${target}" ]]; then
        prefix_success "${tool}==${version} ${DIM}(cached)${RST}"
        return 0
    fi

    # Create directory
    mkdir -p "${bin_dir}"

    case "${tool}" in
        jq)
            # jq is a single binary - direct download
            if download_file "${url}" "${target}"; then
                chmod +x "${target}"
                prefix_add "${tool}==${version}"
                return 0
            else
                prefix_error "${tool}: download failed"
                prefix_info "Install manually: brew install jq (macOS) or apt install jq (Linux)"
                return 1
            fi
            ;;
        fzf)
            # fzf is a tarball - extract to temp then move
            local tmp_dir
            tmp_dir=$(mktemp -d)
            if download_tarball "${url}" "${tmp_dir}"; then
                mv "${tmp_dir}/fzf" "${target}"
                chmod +x "${target}"
                rm -rf "${tmp_dir}"
                prefix_add "${tool}==${version}"
                return 0
            else
                rm -rf "${tmp_dir}"
                prefix_error "${tool}: download failed"
                prefix_info "Install manually: brew install fzf (macOS) or apt install fzf (Linux)"
                return 1
            fi
            ;;
        nvim)
            # nvim is a tarball with directory structure - extract entire package
            local tmp_dir nvim_dir nvim_install_dir
            tmp_dir=$(mktemp -d)
            nvim_install_dir="${JSH_DIR}/lib/nvim/${platform}"
            if download_tarball "${url}" "${tmp_dir}"; then
                # Find the extracted directory (nvim-linux-x86_64 or nvim-macos-arm64 etc.)
                nvim_dir=$(find "${tmp_dir}" -maxdepth 1 -type d -name 'nvim-*' | head -1)
                if [[ -z "${nvim_dir}" ]]; then
                    rm -rf "${tmp_dir}"
                    prefix_error "${tool}: unexpected archive structure"
                    return 1
                fi
                # Install to lib/nvim/<platform>/
                mkdir -p "${nvim_install_dir}"
                rm -rf "${nvim_install_dir:?}"/*
                mv "${nvim_dir}"/* "${nvim_install_dir}/"
                rm -rf "${tmp_dir}"
                # Create symlink in bin/<platform>/
                ln -sf "${nvim_install_dir}/bin/nvim" "${target}"
                prefix_add "${tool}==${version}"
                return 0
            else
                rm -rf "${tmp_dir}"
                prefix_error "${tool}: download failed"
                prefix_info "Install manually: brew install neovim (macOS) or dnf install neovim (Linux)"
                return 1
            fi
            ;;
        *)
            prefix_error "${tool}: no download handler"
            return 1
            ;;
    esac
}

# Download all binary tools (with user confirmation)
# Usage: download_all_binaries [--force]
download_all_binaries() {
    local force=false
    [[ "${1:-}" == "--force" ]] && force=true

    local platform bin_dir
    platform=$(detect_platform)
    bin_dir="${JSH_DIR}/bin/${platform}"

    echo ""
    echo "${CYAN}Shell Tools:${RST}"
    echo "  ${DIM}Target: ${bin_dir}/${RST}"
    echo ""

    local errors=0
    local tools=("jq" "fzf")

    for tool in "${tools[@]}"; do
        # Skip if exists and not forcing
        if [[ -x "${bin_dir}/${tool}" ]] && [[ "${force}" == false ]]; then
            prefix_success "${tool} (already installed)"
            continue
        fi

        download_binary "${tool}" || ((errors++))
    done

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        warn "Some tools failed to download. You can:"
        echo "  ${DIM}1. Retry: jsh deps refresh${RST}"
        echo "  ${DIM}2. Install via package manager: brew install jq fzf${RST}"
        return 1
    fi

    return 0
}

# Download a tool for a specific platform
# Usage: download_binary_for_platform <tool> <platform>
download_binary_for_platform() {
    local tool="$1" platform="$2"
    local version url bin_dir target

    version=$(get_binary_version "${tool}") || {
        prefix_error "${tool}: unknown tool"
        return 1
    }
    url=$(get_binary_url "${tool}" "${platform}" "${version}") || {
        prefix_error "${tool}: failed to get download URL for ${platform}"
        return 1
    }

    bin_dir="${JSH_DIR}/bin/${platform}"
    target="${bin_dir}/${tool}"

    # Check if already exists
    if [[ -x "${target}" ]]; then
        prefix_success "${tool} ${platform} (cached)"
        return 0
    fi

    mkdir -p "${bin_dir}"
    prefix_info "${tool} ${platform} v${version} downloading..."

    case "${tool}" in
        jq)
            if download_file "${url}" "${target}"; then
                chmod +x "${target}"
                prefix_success "${tool} ${platform} v${version}"
                return 0
            fi
            ;;
        fzf)
            local tmp_dir
            tmp_dir=$(mktemp -d)
            if download_tarball "${url}" "${tmp_dir}"; then
                mv "${tmp_dir}/fzf" "${target}"
                chmod +x "${target}"
                rm -rf "${tmp_dir}"
                prefix_success "${tool} ${platform} v${version}"
                return 0
            fi
            rm -rf "${tmp_dir}"
            ;;
        nvim)
            local tmp_dir nvim_dir nvim_install_dir
            tmp_dir=$(mktemp -d)
            nvim_install_dir="${JSH_DIR}/lib/nvim/${platform}"
            if download_tarball "${url}" "${tmp_dir}"; then
                nvim_dir=$(find "${tmp_dir}" -maxdepth 1 -type d -name 'nvim-*' | head -1)
                if [[ -n "${nvim_dir}" ]]; then
                    mkdir -p "${nvim_install_dir}"
                    rm -rf "${nvim_install_dir:?}"/*
                    mv "${nvim_dir}"/* "${nvim_install_dir}/"
                    rm -rf "${tmp_dir}"
                    ln -sf "${nvim_install_dir}/bin/nvim" "${target}"
                    prefix_success "${tool} ${platform} v${version}"
                    return 0
                fi
            fi
            rm -rf "${tmp_dir}"
            ;;
    esac

    prefix_error "${tool} ${platform}: download failed"
    return 1
}

# Download binaries for all supported platforms
# Usage: download_all_platforms [--force]
download_all_platforms() {
    local force=false
    [[ "${1:-}" == "--force" ]] && force=true

    if ! has_download_tool; then
        error "No download tool available (need curl or wget)"
        return 1
    fi

    local platforms=("darwin-arm64" "darwin-amd64" "linux-arm64" "linux-amd64")
    local tools=("fzf" "jq")
    local errors=0

    echo ""
    echo "${CYAN}Downloading binaries for all platforms...${RST}"
    echo ""

    for platform in "${platforms[@]}"; do
        echo "${BOLD}${platform}:${RST}"
        for tool in "${tools[@]}"; do
            local target="${JSH_DIR}/bin/${platform}/${tool}"
            if [[ -x "${target}" ]] && [[ "${force}" == false ]]; then
                prefix_success "${tool} (cached)"
            else
                download_binary_for_platform "${tool}" "${platform}" || ((errors++))
            fi
        done
        echo ""
    done

    if [[ ${errors} -gt 0 ]]; then
        warn "${errors} download(s) failed"
        return 1
    fi

    success "All platform binaries downloaded"
    return 0
}

# Check if bundled binaries are available and add to PATH
# Call this during shell initialization
setup_binary_path() {
    local platform bin_dir
    platform=$(detect_platform)
    bin_dir="${JSH_DIR}/bin/${platform}"

    # Only add to PATH if directory exists and has executables
    if [[ -d "${bin_dir}" ]] && [[ -n "$(ls -A "${bin_dir}" 2>/dev/null)" ]]; then
        # Prepend to PATH so bundled versions take priority
        export PATH="${bin_dir}:${PATH}"
        return 0
    fi

    return 1
}

# =============================================================================
# ZSH Plugin Downloads
# =============================================================================

download_zsh_autosuggestions() {
    local version target
    version=$(get_version "zsh-autosuggestions")
    target="${LIB_DIR}/zsh-plugins/zsh-autosuggestions.zsh"

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        prefix_success "zsh-autosuggestions==${version} ${DIM}(cached)${RST}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "zsh-autosuggestions: no version in versions.json"
        return 1
    fi

    if ! has_download_tool; then
        prefix_error "zsh-autosuggestions: no download tool available (need curl or wget)"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins"

    local tmp_dir url
    tmp_dir=$(mktemp -d)
    url="https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v${version}.tar.gz"
    if download_tarball "${url}" "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-autosuggestions-${version}/zsh-autosuggestions.zsh" "${target}"
        rm -rf "${tmp_dir}"
        prefix_add "zsh-autosuggestions==${version}"
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
        prefix_success "zsh-syntax-highlighting==${version} ${DIM}(cached)${RST}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "zsh-syntax-highlighting: no version in versions.json"
        return 1
    fi

    if ! has_download_tool; then
        prefix_error "zsh-syntax-highlighting: no download tool available (need curl or wget)"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins/highlighters"

    local tmp_dir url
    tmp_dir=$(mktemp -d)
    url="https://github.com/zsh-users/zsh-syntax-highlighting/archive/refs/tags/${version}.tar.gz"
    if download_tarball "${url}" "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-syntax-highlighting-${version}/zsh-syntax-highlighting.zsh" "${target}"
        rm -rf "${LIB_DIR}/zsh-plugins/highlighters"
        cp -r "${tmp_dir}/zsh-syntax-highlighting-${version}/highlighters" "${LIB_DIR}/zsh-plugins/"
        echo "${version}" > "${LIB_DIR}/zsh-plugins/.version"
        rm -rf "${tmp_dir}"
        prefix_add "zsh-syntax-highlighting==${version}"
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
        prefix_success "zsh-history-substring-search==${version} ${DIM}(cached)${RST}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        prefix_warn "zsh-history-substring-search: no version in versions.json"
        return 1
    fi

    if ! has_download_tool; then
        prefix_error "zsh-history-substring-search: no download tool available (need curl or wget)"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins"

    local tmp_dir url
    tmp_dir=$(mktemp -d)
    url="https://github.com/zsh-users/zsh-history-substring-search/archive/refs/tags/v${version}.tar.gz"
    if download_tarball "${url}" "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-history-substring-search-${version}/zsh-history-substring-search.zsh" "${target}"
        rm -rf "${tmp_dir}"
        prefix_add "zsh-history-substring-search==${version}"
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
    local subcmd=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) force_download=true; FORCE_DOWNLOAD=1; shift ;;
            -h|--help)
                echo "Usage: deps.sh [COMMAND] [OPTIONS]"
                echo ""
                echo "Commands:"
                echo "  install         Download all ZSH plugins (default)"
                echo "  status          Show dependency status"
                echo "  submodules      List submodules status"
                echo "  submodules update  Update all submodules"
                echo ""
                echo "Options:"
                echo "  -f, --force     Force re-download of all dependencies"
                echo "  -h, --help      Show this help"
                echo ""
                echo "Note: fzf, jq, and other tools should be installed via your"
                echo "package manager (brew install fzf jq)"
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

    local errors=0 installed=0
    local start_ms
    start_ms=$(_deps_now_ms)

    # Download ZSH plugins (platform-independent)
    # Track installs by checking return and whether file existed before
    echo "${CYAN}ZSH Plugins:${RST}"

    local plugin_existed
    plugin_existed=$([[ -f "${LIB_DIR}/zsh-plugins/zsh-autosuggestions.zsh" ]] && echo 1 || echo 0)
    if download_zsh_autosuggestions; then
        [[ "${plugin_existed}" == "0" || -n "${FORCE_DOWNLOAD:-}" ]] && ((installed++)) || true
    else
        ((errors++))
    fi

    plugin_existed=$([[ -f "${LIB_DIR}/zsh-plugins/zsh-syntax-highlighting.zsh" ]] && echo 1 || echo 0)
    if download_zsh_syntax_highlighting; then
        [[ "${plugin_existed}" == "0" || -n "${FORCE_DOWNLOAD:-}" ]] && ((installed++)) || true
    else
        ((errors++))
    fi

    plugin_existed=$([[ -f "${LIB_DIR}/zsh-plugins/zsh-history-substring-search.zsh" ]] && echo 1 || echo 0)
    if download_zsh_history_substring_search; then
        [[ "${plugin_existed}" == "0" || -n "${FORCE_DOWNLOAD:-}" ]] && ((installed++)) || true
    else
        ((errors++))
    fi
    echo ""

    # Verify plugins
    echo "${CYAN}Verification:${RST}"
    verify_plugins || ((errors++))
    echo ""

    # uv-style summary
    _deps_summary "${installed}" "${start_ms}"

    # Summary
    if [[ ${errors} -eq 0 ]]; then
        echo "${GREEN}✓${RST} All dependencies configured"
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
                status_icon="${GREEN}✓${RST}"
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

    # System tools status
    echo "${CYAN}System Tools (install via package manager):${RST}"
    local tools=("jq" "fzf" "fd" "rg" "bat" "eza")
    for tool in "${tools[@]}"; do
        if has "${tool}"; then
            local version=""
            case "${tool}" in
                jq)  version=$("${tool}" --version 2>/dev/null) ;;
                fzf) version=$("${tool}" --version 2>/dev/null | head -1) ;;
                fd)  version=$("${tool}" --version 2>/dev/null | cut -d' ' -f2) ;;
                rg)  version=$("${tool}" --version 2>/dev/null | head -1 | cut -d' ' -f2) ;;
                bat) version=$("${tool}" --version 2>/dev/null | cut -d' ' -f2) ;;
                eza) version=$("${tool}" --version 2>/dev/null | sed -n '2s/^v\([^ ]*\).*/\1/p') ;;
            esac
            prefix_success "${tool} ${DIM}(${version})${RST}"
        else
            if [[ "${tool}" == "jq" ]]; then
                prefix_error "${tool} (required - install with: brew install jq)"
            else
                prefix_info "${tool} ${DIM}(optional)${RST}"
            fi
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
        echo "${CYAN}Configured Plugin Versions:${RST}"
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
    local has_git=false has_curl=false has_make=false has_gcc=false has_jq=false has_fzf=false
    has git && has_git=true
    has curl && has_curl=true
    has make && has_make=true
    has gcc && has_gcc=true
    has jq && has_jq=true
    has fzf && has_fzf=true

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
  "system_tools": {
    "jq": ${has_jq},
    "fzf": ${has_fzf}
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
            echo "  ${GREEN}✓${RST} ${tool} ${DIM}(${version})${RST}"
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
