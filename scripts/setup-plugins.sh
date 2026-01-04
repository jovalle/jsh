#!/usr/bin/env bash
# setup-plugins.sh - Setup jsh plugins and binaries
# Downloads binaries if not present, verifies embedded plugins
# shellcheck disable=SC2034

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSH_DIR="${SCRIPT_DIR%/*}"
LIB_DIR="${JSH_DIR}/lib"
BIN_DIR="${LIB_DIR}/bin"
VERSIONS_FILE="${BIN_DIR}/versions.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${CYAN}==>${NC} $*"
}

has() {
    command -v "$1" &>/dev/null
}

detect_platform() {
    local os arch
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
# Binary Downloads
# =============================================================================

download_fzf() {
    local version platform bin_path
    version=$(get_version "fzf")
    platform=$(detect_platform)
    bin_path="${BIN_DIR}/${platform}/fzf"

    log_step "Checking fzf..."

    if [[ -x "${bin_path}" ]]; then
        log_success "fzf already installed for ${platform}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        log_warn "No fzf version found in ${VERSIONS_FILE}"
        return 1
    fi

    mkdir -p "${BIN_DIR}/${platform}"

    local url
    case "${platform}" in
        linux-amd64) url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-linux_amd64.tar.gz" ;;
        linux-arm64) url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-linux_arm64.tar.gz" ;;
        darwin-amd64) url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-darwin_amd64.tar.gz" ;;
        darwin-arm64) url="https://github.com/junegunn/fzf/releases/download/v${version}/fzf-${version}-darwin_arm64.tar.gz" ;;
        *) log_error "Unsupported platform: ${platform}"; return 1 ;;
    esac

    log_info "Downloading fzf v${version} for ${platform}..."
    if curl -sL "${url}" | tar xz -C "${BIN_DIR}/${platform}"; then
        chmod +x "${bin_path}"
        log_success "fzf v${version} installed"
    else
        log_error "Failed to download fzf"
        return 1
    fi
}

download_jq() {
    local version platform bin_path
    version=$(get_version "jq")
    platform=$(detect_platform)
    bin_path="${BIN_DIR}/${platform}/jq"

    log_step "Checking jq..."

    if [[ -x "${bin_path}" ]]; then
        log_success "jq already installed for ${platform}"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        log_warn "No jq version found in ${VERSIONS_FILE}"
        return 1
    fi

    mkdir -p "${BIN_DIR}/${platform}"

    local url
    case "${platform}" in
        darwin-arm64) url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-macos-arm64" ;;
        darwin-amd64) url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-macos-amd64" ;;
        linux-amd64)  url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-linux-amd64" ;;
        linux-arm64)  url="https://github.com/jqlang/jq/releases/download/jq-${version}/jq-linux-arm64" ;;
        *) log_error "Unsupported platform: ${platform}"; return 1 ;;
    esac

    log_info "Downloading jq v${version} for ${platform}..."
    if curl -sL "${url}" -o "${bin_path}"; then
        chmod +x "${bin_path}"
        log_success "jq v${version} installed"
    else
        log_error "Failed to download jq from ${url}"
        return 1
    fi
}

# =============================================================================
# ZSH Plugin Downloads
# =============================================================================

download_zsh_autosuggestions() {
    local version
    version=$(get_version "zsh-autosuggestions")
    local target="${LIB_DIR}/zsh-plugins/zsh-autosuggestions.zsh"

    log_step "Checking zsh-autosuggestions..."

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        log_success "zsh-autosuggestions already installed"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        log_warn "No zsh-autosuggestions version found in ${VERSIONS_FILE}"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins"

    log_info "Downloading zsh-autosuggestions v${version}..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sL "https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v${version}.tar.gz" | tar xz -C "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-autosuggestions-${version}/zsh-autosuggestions.zsh" "${target}"
        rm -rf "${tmp_dir}"
        log_success "zsh-autosuggestions v${version} installed"
    else
        rm -rf "${tmp_dir}"
        log_error "Failed to download zsh-autosuggestions"
        return 1
    fi
}

download_zsh_syntax_highlighting() {
    local version
    version=$(get_version "zsh-syntax-highlighting")
    local target="${LIB_DIR}/zsh-plugins/zsh-syntax-highlighting.zsh"

    log_step "Checking zsh-syntax-highlighting..."

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        log_success "zsh-syntax-highlighting already installed"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        log_warn "No zsh-syntax-highlighting version found in ${VERSIONS_FILE}"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins/highlighters"

    log_info "Downloading zsh-syntax-highlighting v${version}..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sL "https://github.com/zsh-users/zsh-syntax-highlighting/archive/refs/tags/${version}.tar.gz" | tar xz -C "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-syntax-highlighting-${version}/zsh-syntax-highlighting.zsh" "${target}"
        rm -rf "${LIB_DIR}/zsh-plugins/highlighters"
        cp -r "${tmp_dir}/zsh-syntax-highlighting-${version}/highlighters" "${LIB_DIR}/zsh-plugins/"
        echo "${version}" > "${LIB_DIR}/zsh-plugins/.version"
        rm -rf "${tmp_dir}"
        log_success "zsh-syntax-highlighting v${version} installed"
    else
        rm -rf "${tmp_dir}"
        log_error "Failed to download zsh-syntax-highlighting"
        return 1
    fi
}

download_zsh_history_substring_search() {
    local version
    version=$(get_version "zsh-history-substring-search")
    local target="${LIB_DIR}/zsh-plugins/zsh-history-substring-search.zsh"

    log_step "Checking zsh-history-substring-search..."

    if [[ -f "${target}" ]] && [[ -z "${FORCE_DOWNLOAD:-}" ]]; then
        log_success "zsh-history-substring-search already installed"
        return 0
    fi

    if [[ -z "${version}" ]]; then
        log_warn "No zsh-history-substring-search version found in ${VERSIONS_FILE}"
        return 1
    fi

    mkdir -p "${LIB_DIR}/zsh-plugins"

    log_info "Downloading zsh-history-substring-search v${version}..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -sL "https://github.com/zsh-users/zsh-history-substring-search/archive/refs/tags/v${version}.tar.gz" | tar xz -C "${tmp_dir}"; then
        cp "${tmp_dir}/zsh-history-substring-search-${version}/zsh-history-substring-search.zsh" "${target}"
        rm -rf "${tmp_dir}"
        log_success "zsh-history-substring-search v${version} installed"
    else
        rm -rf "${tmp_dir}"
        log_error "Failed to download zsh-history-substring-search"
        return 1
    fi
}

# =============================================================================
# Plugin Verification
# =============================================================================

verify_plugins() {
    log_step "Verifying embedded plugins..."

    local errors=0

    # Check zsh plugins
    local plugins=(
        "zsh-plugins/zsh-autosuggestions.zsh"
        "zsh-plugins/zsh-syntax-highlighting.zsh"
        "zsh-plugins/zsh-history-substring-search.zsh"
        "zsh-plugins/highlighters/main/main-highlighter.zsh"
    )

    for plugin in "${plugins[@]}"; do
        if [[ -f "${LIB_DIR}/${plugin}" ]]; then
            log_success "${plugin}"
        else
            log_error "Missing: ${plugin}"
            ((errors++))
        fi
    done

    # Check completions (submodule or bundled fallback)
    if [[ -d "${LIB_DIR}/zsh-completions/src" ]]; then
        log_success "zsh-completions/ submodule ($(ls "${LIB_DIR}/zsh-completions/src" | wc -l | tr -d ' ') files)"
    elif [[ -d "${LIB_DIR}/zsh-plugins/completions-core" ]]; then
        log_success "zsh-plugins/completions-core/ ($(ls "${LIB_DIR}/zsh-plugins/completions-core" | wc -l | tr -d ' ') files)"
    else
        log_warn "zsh-completions submodule not initialized (run: git submodule update --init)"
    fi

    return ${errors}
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║              Jsh Plugin & Binary Setup                         ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    local platform
    platform=$(detect_platform)
    log_info "Detected platform: ${platform}"
    echo ""

    local errors=0

    # Download binaries
    log_info "=== Binaries ==="
    echo ""
    download_fzf || ((errors++))
    echo ""

    download_jq || ((errors++))
    echo ""

    # Download ZSH plugins
    log_info "=== ZSH Plugins ==="
    echo ""
    download_zsh_autosuggestions || ((errors++))
    echo ""

    download_zsh_syntax_highlighting || ((errors++))
    echo ""

    download_zsh_history_substring_search || ((errors++))
    echo ""

    # Verify plugins
    log_info "=== Verification ==="
    echo ""
    verify_plugins || ((errors++))

    echo ""
    echo "════════════════════════════════════════════════════════════════"

    if [[ ${errors} -eq 0 ]]; then
        log_success "All plugins and binaries configured successfully!"
    else
        log_warn "Setup completed with ${errors} warning(s)"
    fi

    echo ""
    log_info "Restart your shell or run: source ~/.zshrc"
    echo ""
}

# Run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
