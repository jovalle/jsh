# Jsh - Task Runner
# Usage: just <recipe>

set shell := ["bash", "-euo", "pipefail", "-c"]

jsh_dir := justfile_directory()
src_dir := jsh_dir / "src"
tests_dir := jsh_dir / "tests"
scripts_dir := jsh_dir / "scripts"

# List available recipes
default:
    @just --list

# Install contributor dependencies
deps:
    #!/usr/bin/env bash
    set -euo pipefail
    JSH_DIR="{{ jsh_dir }}"
    if [[ -n "${CI:-}" ]]; then
        RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; RESET='\033[0m'
    fi

    uname_s="$(uname -s)"
    case "$uname_s" in
        Darwin) os="darwin" ;;
        Linux) os="linux" ;;
        *) os="unknown" ;;
    esac

    printf "${BLUE}==>${RESET} Installing contributor dependencies...\n"
    if [[ "$os" == "darwin" ]]; then
        command -v brew >/dev/null 2>&1 || { printf "${RED}✘${RESET} Missing required tool: brew\n"; exit 1; }
        brew_cmd=(brew)
        if [[ "$(id -u)" == "0" ]]; then
            delegate_user="${JSH_BREW_DELEGATE_USER:-$(id -nu 1000 2>/dev/null || getent passwd 1000 2>/dev/null | cut -d: -f1 || true)}"
            if [[ -n "$delegate_user" ]]; then
                if command -v runuser >/dev/null 2>&1; then
                    brew_cmd=(runuser -u "$delegate_user" -- brew)
                elif command -v sudo >/dev/null 2>&1; then
                    brew_cmd=(sudo -H -u "$delegate_user" brew)
                fi
            else
                printf "${YELLOW}⚠${RESET} Running as root without a brew delegate user; brew commands may fail\n"
            fi
        fi
        for tool in shellcheck bats-core pre-commit jq yamllint bash; do
            if "${brew_cmd[@]}" list "$tool" >/dev/null 2>&1; then
                printf "${GREEN}✓${RESET} %s (already installed)\n" "$tool"
            else
                printf "${BLUE}↓${RESET} Installing %s...\n" "$tool"
                if "${brew_cmd[@]}" install "$tool" >/dev/null 2>&1; then
                    printf "${GREEN}✓${RESET} %s installed\n" "$tool"
                else
                    printf "${RED}✘${RESET} Failed to install %s\n" "$tool"
                fi
            fi
        done
    elif [[ "$os" == "linux" ]]; then
        if command -v brew >/dev/null 2>&1; then
            printf "${CYAN}Detected:${RESET} brew\n"
            run_brew() {
                if [[ "$(id -u)" == "0" ]]; then
                    local delegate_user delegate_home
                    delegate_user="${JSH_BREW_DELEGATE_USER:-$(id -nu 1000 2>/dev/null || getent passwd 1000 2>/dev/null | cut -d: -f1 || true)}"
                    if [[ -z "$delegate_user" ]]; then
                        printf "${YELLOW}⚠${RESET} Running as root without a brew delegate user; brew commands may fail\n"
                        return 1
                    fi
                    delegate_home="$(getent passwd "$delegate_user" 2>/dev/null | cut -d: -f6)"
                    [[ -n "$delegate_home" ]] || delegate_home="/home/$delegate_user"
                    if command -v runuser >/dev/null 2>&1; then
                        runuser -u "$delegate_user" -- env HOME="$delegate_home" XDG_CACHE_HOME="$delegate_home/.cache" bash -lc "cd '$delegate_home' && /home/linuxbrew/.linuxbrew/bin/brew $*"
                    elif command -v sudo >/dev/null 2>&1; then
                        sudo -H -u "$delegate_user" /home/linuxbrew/.linuxbrew/bin/brew "$@"
                    else
                        printf "${RED}✘${RESET} Need runuser or sudo to run brew as non-root\n"
                        return 1
                    fi
                else
                    brew "$@"
                fi
            }
            for tool in shellcheck bats-core pre-commit jq yamllint bash; do
                if run_brew list "$tool" >/dev/null 2>&1; then
                    printf "${GREEN}✓${RESET} %s (already installed)\n" "$tool"
                else
                    printf "${BLUE}↓${RESET} Installing %s...\n" "$tool"
                    if run_brew install "$tool" >/dev/null 2>&1; then
                        printf "${GREEN}✓${RESET} %s installed\n" "$tool"
                    else
                        printf "${RED}✘${RESET} Failed to install %s\n" "$tool"
                    fi
                fi
            done
        elif command -v apt-get >/dev/null 2>&1; then
            printf "${CYAN}Detected:${RESET} apt\n"
            sudo apt-get update -qq
            sudo apt-get install -y -qq shellcheck bats jq python3-pip >/dev/null 2>&1
            pip3 install --user pre-commit yamllint >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            printf "${CYAN}Detected:${RESET} dnf\n"
            sudo dnf install -y -q ShellCheck bats jq python3-pip >/dev/null 2>&1
            pip3 install --user pre-commit yamllint >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            printf "${CYAN}Detected:${RESET} pacman\n"
            sudo pacman -S --noconfirm --quiet shellcheck bats jq python-pre-commit yamllint >/dev/null 2>&1
        else
            printf "${RED}✘${RESET} Unsupported Linux package manager. Install manually: shellcheck bats pre-commit jq yamllint\n"
            exit 1
        fi
    else
        printf "${RED}✘${RESET} Unsupported OS: %s\n" "$os"
        exit 1
    fi

    if command -v pre-commit >/dev/null 2>&1; then
        pre-commit install --hook-type pre-commit --hook-type commit-msg >/dev/null 2>&1 || true
        printf "${GREEN}✓${RESET} pre-commit hooks installed\n"
    else
        printf "${YELLOW}⚠${RESET} pre-commit not installed; skipping hook installation\n"
    fi

# Run shell lint checks (shellcheck + yamllint)
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    JSH_DIR="{{ jsh_dir }}"
    SRC_DIR="{{ src_dir }}"
    SCRIPTS_DIR="{{ scripts_dir }}"
    if [[ -n "${CI:-}" ]]; then
        RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
    fi

    command -v shellcheck >/dev/null 2>&1 || { printf "${RED}✘${RESET} Missing required tool: shellcheck\n"; exit 1; }
    printf "${BLUE}==>${RESET} Running ShellCheck...\n"
    find "$SRC_DIR" -type f -name '*.sh' ! -name 'zsh.sh' ! -name '*.sync-conflict-*.sh' -exec shellcheck {} +
    shellcheck "$JSH_DIR/jsh"
    for f in "$JSH_DIR"/bin/*; do
        if head -1 "$f" 2>/dev/null | grep -q '^#!.*sh'; then
            shellcheck "$f"
        fi
    done
    if [[ -d "$SCRIPTS_DIR" ]]; then
        find "$SCRIPTS_DIR" -type f -name '*.sh' -exec shellcheck {} +
    fi

    printf "${BLUE}==>${RESET} Running bash syntax checks...\n"
    while IFS= read -r f; do
        case "$f" in
            */zsh.sh|*/j.sh) continue ;;
        esac
        bash -n "$f"
    done < <(find "$SRC_DIR" -type f -name '*.sh' ! -name '*.sync-conflict-*.sh')

    if command -v zsh >/dev/null 2>&1; then
        zsh -n "$SRC_DIR/zsh.sh"
    fi
    bash -n "$JSH_DIR/jsh"

    if command -v yamllint >/dev/null 2>&1; then
        printf "${BLUE}==>${RESET} Running yamllint...\n"
        workflow_yamls="$(find "$JSH_DIR/.github/workflows" -type f -name '*.yml' 2>/dev/null || true)"
        if [[ -n "$workflow_yamls" ]]; then
            yamllint -c "$JSH_DIR/.yamllint" $workflow_yamls
        else
            printf "${YELLOW}⚠${RESET} No workflow YAML files found; skipping yamllint workflow check\n"
        fi
    fi
    printf "${GREEN}✓${RESET} Lint passed\n"

# Run BATS test suite
test:
    #!/usr/bin/env bash
    set -euo pipefail
    TESTS_DIR="{{ tests_dir }}"
    if [[ -n "${CI:-}" ]]; then
        RED=""; GREEN=""; BLUE=""; RESET=""
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; RESET='\033[0m'
    fi

    command -v bats >/dev/null 2>&1 || { printf "${RED}✘${RESET} Missing required tool: bats\n"; exit 1; }
    printf "${BLUE}==>${RESET} Running BATS tests...\n"
    bats --version
    tmp_git_cfg="$(mktemp)"
    trap 'rm -f "$tmp_git_cfg"' EXIT
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" GIT_CONFIG_GLOBAL="$tmp_git_cfg" GIT_CONFIG_NOSYSTEM=1 bats "$TESTS_DIR"/*.bats
    printf "${GREEN}✓${RESET} Tests passed\n"

# Run lint then tests
check: lint test
