# tools.sh - Development tool discovery and management
# Provides: jsh tools list|check|install|recommend
# shellcheck disable=SC2034,SC2154

# Load guard
[[ -n "${_JSH_TOOLS_LOADED:-}" ]] && return 0
_JSH_TOOLS_LOADED=1

# =============================================================================
# Tool Definitions
# =============================================================================
# Format: TOOLS[name]="category|description|check_cmd|install_cmd"
# Categories: shell, editor, dev, k8s, git, container, cloud, network

declare -gA TOOLS

# Shell Tools
TOOLS[tmux]="shell|Terminal multiplexer|tmux -V|brew install tmux"
TOOLS[direnv]="shell|Directory-based env vars|direnv version|brew install direnv"

# Editor Tools
TOOLS[vim]="editor|Vi Improved|vim --version|brew install vim"
TOOLS[nvim]="editor|Neovim - hyperextensible|nvim --version|jsh:nvim"
TOOLS[code]="editor|Visual Studio Code|code --version|brew install --cask visual-studio-code"
TOOLS[helix]="editor|Modal editor in Rust|hx --version|brew install helix"

# Development Tools
TOOLS[git]="dev|Distributed version control|git --version|brew install git"
TOOLS[gh]="dev|GitHub CLI|gh --version|brew install gh"
TOOLS[make]="dev|Build automation|make --version|xcode-select --install"
TOOLS[cmake]="dev|Cross-platform build|cmake --version|brew install cmake"
TOOLS[jq]="dev|JSON processor|jq --version|brew install jq"
TOOLS[yq]="dev|YAML processor|yq --version|brew install yq"
TOOLS[curl]="dev|URL transfer tool|curl --version|brew install curl"
TOOLS[wget]="dev|Network downloader|wget --version|brew install wget"
TOOLS[httpie]="dev|Modern HTTP client|http --version|brew install httpie"

# Search & Navigation
TOOLS[fzf]="dev|Fuzzy finder|fzf --version|brew install fzf"
TOOLS[fd]="dev|Fast find alternative|fd --version|brew install fd"
TOOLS[rg]="dev|Fast grep (ripgrep)|rg --version|brew install ripgrep"
TOOLS[ag]="dev|The Silver Searcher|ag --version|brew install the_silver_searcher"
TOOLS[bat]="dev|Cat with syntax highlighting|bat --version|brew install bat"
TOOLS[eza]="dev|Modern ls replacement|eza --version|brew install eza"
TOOLS[tree]="dev|Directory tree viewer|tree --version|brew install tree"
TOOLS[zoxide]="dev|Smarter cd command|zoxide --version|brew install zoxide"

# Container Tools
TOOLS[docker]="container|Container runtime|docker --version|brew install --cask docker"
TOOLS[podman]="container|Daemonless containers|podman --version|brew install podman"
TOOLS[colima]="container|Container runtime (macOS)|colima version|brew install colima"
TOOLS[lazydocker]="container|Docker TUI|lazydocker --version|brew install lazydocker"

# Kubernetes Tools
TOOLS[kubectl]="k8s|Kubernetes CLI|kubectl version --client|brew install kubectl"
TOOLS[helm]="k8s|Kubernetes package manager|helm version|brew install helm"
TOOLS[k9s]="k8s|Kubernetes TUI|k9s version|brew install k9s"
TOOLS[kubectx]="k8s|Context/namespace switcher|kubectx --help|brew install kubectx"
TOOLS[stern]="k8s|Multi-pod log tailing|stern --version|brew install stern"
TOOLS[kustomize]="k8s|Kubernetes customization|kustomize version|brew install kustomize"

# Cloud Tools
TOOLS[aws]="cloud|AWS CLI|aws --version|brew install awscli"
TOOLS[gcloud]="cloud|Google Cloud CLI|gcloud --version|brew install --cask google-cloud-sdk"
TOOLS[az]="cloud|Azure CLI|az --version|brew install azure-cli"
TOOLS[terraform]="cloud|Infrastructure as Code|terraform --version|brew install terraform"

# Git Tools
TOOLS[git-lfs]="git|Git Large File Storage|git-lfs --version|brew install git-lfs"
TOOLS[delta]="git|Better git diff|delta --version|brew install git-delta"
TOOLS[lazygit]="git|Git TUI|lazygit --version|brew install lazygit"
TOOLS[tig]="git|Text-mode git interface|tig --version|brew install tig"

# Network Tools
TOOLS[nmap]="network|Network scanner|nmap --version|brew install nmap"
TOOLS[mtr]="network|Network diagnostic|mtr --version|brew install mtr"
TOOLS[ssh-copy-id]="network|SSH key installer|command -v ssh-copy-id|brew install ssh-copy-id"

# =============================================================================
# Tool Categories
# =============================================================================

declare -gA TOOL_CATEGORIES
TOOL_CATEGORIES[shell]="Shell & Terminal"
TOOL_CATEGORIES[editor]="Editors & IDEs"
TOOL_CATEGORIES[dev]="Development Tools"
TOOL_CATEGORIES[container]="Container Tools"
TOOL_CATEGORIES[k8s]="Kubernetes Tools"
TOOL_CATEGORIES[cloud]="Cloud & Infrastructure"
TOOL_CATEGORIES[git]="Git Tools"
TOOL_CATEGORIES[network]="Network Tools"

# =============================================================================
# Platform-Specific Package Mappings
# =============================================================================

# Map brew package names to dnf package names (only where they differ)
declare -gA TOOL_PKG_MAP_DNF
TOOL_PKG_MAP_DNF[neovim]="neovim"
TOOL_PKG_MAP_DNF[fd]="fd-find"
TOOL_PKG_MAP_DNF[ripgrep]="ripgrep"
TOOL_PKG_MAP_DNF[kubectl]="kubectl"
TOOL_PKG_MAP_DNF[git-delta]="git-delta"
TOOL_PKG_MAP_DNF[the_silver_searcher]="the_silver_searcher"
TOOL_PKG_MAP_DNF[vim]="vim-enhanced"

# Get platform-appropriate install command for a package
# Args: $1 = brew package name or special jsh: command (from install_cmd)
# Returns: platform-specific install command
_tools_get_install_cmd() {
    local brew_pkg="$1"
    local os_type
    os_type=$(uname -s)

    # Handle jsh: prefixed commands (custom install via jsh deps)
    if [[ "${brew_pkg}" == jsh:* ]]; then
        local tool_name="${brew_pkg#jsh:}"
        echo "source '${JSH_DIR}/src/deps.sh' && download_binary '${tool_name}'"
        return
    fi

    if [[ "${os_type}" == "Darwin" ]]; then
        # macOS: use brew as-is
        if [[ "${brew_pkg}" == *"--cask"* ]]; then
            echo "brew install ${brew_pkg}"
        else
            echo "brew install ${brew_pkg}"
        fi
    elif [[ "${os_type}" == "Linux" ]]; then
        # Linux: translate to dnf
        local pkg_name="${brew_pkg}"

        # Handle brew install --cask (not applicable on Linux)
        if [[ "${pkg_name}" == *"--cask"* ]]; then
            echo "echo 'Cask not available on Linux: ${pkg_name}'"
            return
        fi

        # Check if we have a mapping for this package
        if [[ -n "${TOOL_PKG_MAP_DNF[${pkg_name}]:-}" ]]; then
            pkg_name="${TOOL_PKG_MAP_DNF[${pkg_name}]}"
        fi

        # Handle special cases
        case "${pkg_name}" in
            xcode-select)
                echo "echo 'xcode-select not applicable on Linux'"
                ;;
            docker)
                echo "sudo dnf install -y podman podman-docker"
                ;;
            colima)
                echo "echo 'colima not applicable on Linux (use podman)'"
                ;;
            awscli)
                echo "sudo dnf install -y awscli2"
                ;;
            *)
                echo "sudo dnf install -y ${pkg_name}"
                ;;
        esac
    else
        echo "echo 'Unsupported platform: ${os_type}'"
    fi
}

# =============================================================================
# Helper Functions
# =============================================================================

# Parse tool definition
# Args: $1 = tool name
# Sets: _TOOL_CATEGORY, _TOOL_DESC, _TOOL_CHECK, _TOOL_INSTALL
_tools_parse() {
    local name="$1"
    local def="${TOOLS[$name]:-}"

    if [[ -z "${def}" ]]; then
        return 1
    fi

    IFS='|' read -r _TOOL_CATEGORY _TOOL_DESC _TOOL_CHECK _TOOL_INSTALL <<< "${def}"
}

# Check if a tool is installed
# Args: $1 = tool name
# Returns: 0 if installed, 1 if not
_tools_is_installed() {
    local name="$1"
    _tools_parse "${name}" || return 1

    # Extract command name from check command
    local cmd="${_TOOL_CHECK%% *}"

    # Check if command exists
    command -v "${cmd}" >/dev/null 2>&1
}

# Get tool version
# Args: $1 = tool name
# Output: version string or empty
_tools_get_version() {
    local name="$1"
    _tools_parse "${name}" || return 1

    local output
    output=$(eval "${_TOOL_CHECK}" 2>/dev/null | head -1) || return 1

    # Extract version number (common patterns)
    echo "${output}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# =============================================================================
# Commands
# =============================================================================

# List all tools with install status
# Usage: cmd_tools_list [options]
# Options for 'jsh tools list' are defined with the main cmd_tools metadata
cmd_tools_list() {
    local filter_category=""
    local filter_missing=false
    local filter_installed=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--category)
                filter_category="$2"
                shift 2
                ;;
            --missing)
                filter_missing=true
                shift
                ;;
            --installed)
                filter_installed=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local current_category=""
    local name installed version

    # Sort tools by category, then name
    local sorted_tools
    sorted_tools=$(for name in "${!TOOLS[@]}"; do
        _tools_parse "${name}"
        echo "${_TOOL_CATEGORY}:${name}"
    done | sort)

    echo ""

    while IFS=: read -r cat name; do
        [[ -z "${name}" ]] && continue

        # Filter by category
        if [[ -n "${filter_category}" ]] && [[ "${cat}" != "${filter_category}" ]]; then
            continue
        fi

        _tools_parse "${name}"

        # Check install status
        if _tools_is_installed "${name}"; then
            installed=true
            version=$(_tools_get_version "${name}" || true)
        else
            installed=false
            version=""
        fi

        # Apply filters
        if [[ "${filter_missing}" == true ]] && [[ "${installed}" == true ]]; then
            continue
        fi
        if [[ "${filter_installed}" == true ]] && [[ "${installed}" == false ]]; then
            continue
        fi

        # Print category header
        if [[ "${cat}" != "${current_category}" ]]; then
            [[ -n "${current_category}" ]] && echo ""
            current_category="${cat}"
            local cat_name="${TOOL_CATEGORIES[${cat}]:-${cat}}"
            echo "${BOLD}${cat_name}${RST}"
        fi

        # Print tool
        if [[ "${installed}" == true ]]; then
            printf "  ${GRN}✓${RST} %-14s ${DIM}%-30s${RST} %s\n" "${name}" "${_TOOL_DESC}" "${version}"
        else
            printf "  ${DIM}-${RST} %-14s ${DIM}%-30s${RST}\n" "${name}" "${_TOOL_DESC}"
        fi
    done <<< "${sorted_tools}"

    echo ""
}

# Check installed tools for issues
cmd_tools_check() {
    local errors=0
    local name
    local -a results=()

    echo ""
    echo "${BOLD}Checking installed tools...${RST}"
    echo ""

    for name in "${!TOOLS[@]}"; do
        if _tools_is_installed "${name}"; then
            _tools_parse "${name}"

            # Try to run the check command
            if eval "${_TOOL_CHECK}" >/dev/null 2>&1; then
                local version
                version=$(_tools_get_version "${name}" || true)
                results+=("${GRN}✓${RST} ${name} ${DIM}(${version})${RST}")
            else
                results+=("${RED}✘${RST} ${name}: check command failed")
                ((errors++)) || true  # Avoid exit when errors=0 with set -e
            fi
        fi
    done

    # Sort and print results
    printf '%s\n' "${results[@]}" | sort

    echo ""
    if [[ ${errors} -eq 0 ]]; then
        success "All tools working correctly"
    else
        warn "${errors} tool(s) have issues"
    fi
}

# Install recommended tools
cmd_tools_install() {
    local tools_to_install=()
    local name

    # Check for missing essential tools
    local essential=("git" "curl" "jq" "fzf" "fd" "rg" "bat")

    for name in "${essential[@]}"; do
        if ! _tools_is_installed "${name}"; then
            tools_to_install+=("${name}")
        fi
    done

    if [[ ${#tools_to_install[@]} -eq 0 ]]; then
        success "All essential tools are installed"
        return 0
    fi

    echo ""
    echo "${BOLD}Missing essential tools:${RST}"
    for name in "${tools_to_install[@]}"; do
        _tools_parse "${name}"
        echo "  - ${name}: ${_TOOL_DESC}"
    done
    echo ""

    read -r -p "Install missing tools? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy] ]]; then
        info "Installation cancelled"
        return 0
    fi

    echo ""
    for name in "${tools_to_install[@]}"; do
        _tools_parse "${name}"

        # Get platform-appropriate install command
        local brew_pkg="${_TOOL_INSTALL#brew install }"
        brew_pkg="${brew_pkg#brew install --cask }"
        local install_cmd
        install_cmd=$(_tools_get_install_cmd "${brew_pkg}")

        info "Installing ${name}..."
        if eval "${install_cmd}"; then
            prefix_success "${name} installed"
        else
            prefix_error "${name} installation failed"
        fi
    done
}

# Show personalized recommendations
cmd_tools_recommend() {
    echo ""
    echo "${BOLD}Recommended Tools${RST}"
    echo ""

    # Check what's missing from recommended sets
    local categories=("shell" "dev" "git")
    local recommendations=()

    for cat in "${categories[@]}"; do
        local cat_tools=()
        local cat_missing=()

        for name in "${!TOOLS[@]}"; do
            _tools_parse "${name}"
            if [[ "${_TOOL_CATEGORY}" == "${cat}" ]]; then
                cat_tools+=("${name}")
                if ! _tools_is_installed "${name}"; then
                    cat_missing+=("${name}")
                fi
            fi
        done

        if [[ ${#cat_missing[@]} -gt 0 ]]; then
            local cat_name="${TOOL_CATEGORIES[${cat}]:-${cat}}"
            echo "${CYAN}${cat_name}:${RST}"
            for name in "${cat_missing[@]}"; do
                _tools_parse "${name}"
                printf "  ${DIM}•${RST} %-14s ${DIM}%s${RST}\n" "${name}" "${_TOOL_DESC}"
            done
            echo ""
        fi
    done
}

# =============================================================================
# Main Command Handler
# =============================================================================

# @jsh-cmd tools Discover and manage development tools
# @jsh-sub list List all tools with install status
# @jsh-sub check Verify installed tools work correctly
# @jsh-sub install Install recommended tools
# @jsh-sub recommend Show personalized recommendations
# Options for 'jsh tools list':
# @jsh-opt -c,--category Filter by category
# @jsh-opt --missing Show only missing tools
# @jsh-opt --installed Show only installed tools
# @jsh-arg enum shell,editor,dev,container,k8s,cloud,git,network
cmd_tools() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "${subcmd}" in
        list|ls|l)
            cmd_tools_list "$@"
            ;;
        check|c)
            cmd_tools_check "$@"
            ;;
        install|i)
            cmd_tools_install "$@"
            ;;
        recommend|rec|r)
            cmd_tools_recommend "$@"
            ;;
        -h|--help|help)
            echo "${BOLD}jsh tools${RST} - Development tool discovery"
            echo ""
            echo "${BOLD}USAGE:${RST}"
            echo "    jsh tools [command] [options]"
            echo ""
            echo "${BOLD}COMMANDS:${RST}"
            echo "    ${CYAN}list${RST}              List all tools with install status (default)"
            echo "    ${CYAN}check${RST}             Verify installed tools work correctly"
            echo "    ${CYAN}install${RST}           Install recommended tools"
            echo "    ${CYAN}recommend${RST}         Show personalized recommendations"
            echo ""
            echo "${BOLD}LIST OPTIONS:${RST}"
            echo "    -c, --category <cat>  Filter by category"
            echo "    --missing             Show only missing tools"
            echo "    --installed           Show only installed tools"
            echo ""
            echo "${BOLD}CATEGORIES:${RST}"
            for cat in "${!TOOL_CATEGORIES[@]}"; do
                printf "    %-12s %s\n" "${cat}" "${TOOL_CATEGORIES[${cat}]}"
            done | sort
            echo ""
            echo "${BOLD}EXAMPLES:${RST}"
            echo "    jsh tools list                  # List all tools"
            echo "    jsh tools list -c k8s           # List Kubernetes tools only"
            echo "    jsh tools list --missing        # List tools not installed"
            echo "    jsh tools check                 # Verify installed tools"
            ;;
        *)
            error "Unknown command: ${subcmd}"
            echo ""
            cmd_tools --help
            return 1
            ;;
    esac
}
