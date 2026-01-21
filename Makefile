# =============================================================================
# Jsh - Shell Environment Build System
# =============================================================================
# This Makefile provides a unified interface for:
# - Project dependencies
# - Linting and formatting shell scripts
# - Running tests across different shells
# - CI/CD pipeline integration
#
# Usage: make [target]
# Run 'make help' for available targets
# =============================================================================

# Use bash from PATH (requires bash 4+ - install via brew on macOS)
SHELL := bash
.DEFAULT_GOAL := help

# =============================================================================
# Project Paths
# =============================================================================

JSH_DIR := $(CURDIR)
SRC_DIR := $(JSH_DIR)/src
LIB_DIR := $(JSH_DIR)/lib
TESTS_DIR := $(JSH_DIR)/tests
SCRIPTS_DIR := $(JSH_DIR)/scripts
PLUGINS_DIR := $(LIB_DIR)/zsh-plugins

# Version manifest for ZSH plugins
VERSIONS_FILE := $(LIB_DIR)/versions.json

# =============================================================================
# Platform Detection
# =============================================================================

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
    OS := darwin
else ifeq ($(UNAME_S),Linux)
    OS := linux
else
    OS := unknown
endif

ifeq ($(UNAME_M),x86_64)
    ARCH := amd64
else ifeq ($(UNAME_M),arm64)
    ARCH := arm64
else ifeq ($(UNAME_M),aarch64)
    ARCH := arm64
else
    ARCH := unknown
endif

PLATFORM := $(OS)-$(ARCH)

# =============================================================================
# Tool Versions
# =============================================================================

# ZSH plugin versions (from versions.json or defaults)
# Note: jq/fzf versions are managed in lib/versions.json (use 'jsh deps refresh')
JQ_CMD := $(shell command -v jq 2>/dev/null)
ifdef JQ_CMD
    ZSH_AUTOSUGGESTIONS_VERSION := $(shell $(JQ_CMD) -r '."zsh-autosuggestions" // "0.7.1"' $(VERSIONS_FILE) 2>/dev/null)
    ZSH_SYNTAX_HIGHLIGHTING_VERSION := $(shell $(JQ_CMD) -r '."zsh-syntax-highlighting" // "0.8.0"' $(VERSIONS_FILE) 2>/dev/null)
    ZSH_HISTORY_SUBSTRING_SEARCH_VERSION := $(shell $(JQ_CMD) -r '."zsh-history-substring-search" // "1.1.0"' $(VERSIONS_FILE) 2>/dev/null)
else
    ZSH_AUTOSUGGESTIONS_VERSION := 0.7.1
    ZSH_SYNTAX_HIGHLIGHTING_VERSION := 0.8.0
    ZSH_HISTORY_SUBSTRING_SEARCH_VERSION := 1.1.0
endif

# =============================================================================
# CI Detection & Colors
# =============================================================================

CI ?=
ifdef GITHUB_ACTIONS
    CI := true
endif
ifdef CI
    # Disable colors in CI for cleaner logs
    RED :=
    GREEN :=
    YELLOW :=
    BLUE :=
    CYAN :=
    RESET :=
else
    RED := \033[0;31m
    GREEN := \033[0;32m
    YELLOW := \033[1;33m
    BLUE := \033[0;34m
    CYAN := \033[0;36m
    RESET := \033[0m
endif

# =============================================================================
# Phony Targets
# =============================================================================

.PHONY: help all clean clean-all
.PHONY: lint lint-shell lint-syntax lint-compat lint-yaml lint-format lint-secrets format
.PHONY: test test-verbose test-tap test-bash test-zsh
.PHONY: deps deps-check deps-install
.PHONY: ci ci-lint ci-test
.PHONY: docker docker-bash docker-zsh

# =============================================================================
# Help
# =============================================================================

help: ## Show this help message
	@echo ""
	@printf "$(CYAN)Jsh Build System$(RESET)\n"
	@echo ""
	@printf "$(YELLOW)Usage:$(RESET) make [target]\n"
	@echo ""
	@printf "$(YELLOW)Platform:$(RESET) $(PLATFORM)\n"
	@echo ""
	@printf "$(YELLOW)Targets:$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# =============================================================================
# Core Targets
# =============================================================================

all: lint test ## Run full development workflow (lint + test)

clean: ## Clean generated files and caches
	@printf "$(BLUE)==>$(RESET) Cleaning...\n"
	@rm -rf $(JSH_DIR)/.cache
	@rm -rf $(TESTS_DIR)/.bats-*
	@rm -rf /tmp/jsh-*
	@printf "$(GREEN)✓$(RESET) Clean complete\n"
	@# Check for platform binaries and prompt for removal
	@bin_dirs=$$(find $(JSH_DIR)/bin -maxdepth 1 -type d -name '*-*' 2>/dev/null | head -5); \
	if [ -n "$$bin_dirs" ]; then \
		printf "\n$(YELLOW)Platform binaries found:$(RESET)\n"; \
		for d in $$bin_dirs; do \
			count=$$(find "$$d" -type f 2>/dev/null | wc -l | tr -d ' '); \
			printf "  %s (%s files)\n" "$$(basename $$d)" "$$count"; \
		done; \
		printf "\n"; \
		printf "Remove platform binaries? [y/N] "; \
		read -r ans; \
		if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
			rm -rf $(JSH_DIR)/bin/*-*/; \
			printf "$(GREEN)✓$(RESET) Platform binaries removed\n"; \
		else \
			printf "$(CYAN)◆$(RESET) Binaries kept\n"; \
		fi; \
	fi

clean-all: ## Clean everything including platform binaries (no prompt)
	@printf "$(BLUE)==>$(RESET) Cleaning all...\n"
	@rm -rf $(JSH_DIR)/.cache
	@rm -rf $(TESTS_DIR)/.bats-*
	@rm -rf /tmp/jsh-*
	@rm -rf $(JSH_DIR)/bin/*-*/
	@printf "$(GREEN)✓$(RESET) Full clean complete\n"

# =============================================================================
# Linting
# =============================================================================

lint: lint-shell lint-compat lint-yaml lint-secrets ## Run all linters

lint-shell: ## Run ShellCheck on all shell scripts
	@printf "$(BLUE)==>$(RESET) Running ShellCheck...\n"
	@shellcheck --version | head -1
	@shellcheck $(SRC_DIR)/*.sh
	@shellcheck $(JSH_DIR)/jsh
	@for f in $(JSH_DIR)/bin/*; do \
		if head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh'; then \
			shellcheck "$$f" || exit 1; \
		fi; \
	done
	@if [ -d "$(SCRIPTS_DIR)" ]; then \
		find $(SCRIPTS_DIR) -name '*.sh' -exec shellcheck {} +; \
	fi
	@printf "$(GREEN)✓$(RESET) ShellCheck passed\n"

lint-syntax: ## Quick syntax check (bash -n) for all scripts
	@printf "$(BLUE)==>$(RESET) Checking shell syntax...\n"
	@# Skip zsh.sh as it contains zsh-specific syntax (glob qualifiers)
	@for f in $(SRC_DIR)/*.sh; do \
		case "$$f" in */zsh.sh) continue ;; esac; \
		bash -n "$$f" || exit 1; \
	done
	@bash -n $(JSH_DIR)/jsh
	@printf "$(GREEN)✓$(RESET) Syntax check passed\n"

lint-compat: ## Verify bash 4+ is available (required for jsh)
	@printf "$(BLUE)==>$(RESET) Checking bash version requirement...\n"
	@# jsh requires bash 4+ for modern features (associative arrays, etc.)
	@# Check common locations for modern bash
	@found_bash=""; \
	for bash_path in /opt/homebrew/bin/bash /usr/local/bin/bash $$(which bash 2>/dev/null); do \
		if [ -x "$$bash_path" ]; then \
			ver=$$($$bash_path --version 2>/dev/null | head -1 | sed 's/.*version \([0-9]*\).*/\1/'); \
			if [ "$$ver" -ge 4 ] 2>/dev/null; then \
				found_bash="$$bash_path (v$$ver)"; \
				break; \
			fi; \
		fi; \
	done; \
	if [ -z "$$found_bash" ]; then \
		printf "$(RED)✘$(RESET) No bash 4+ found\n"; \
		printf "  On macOS: brew install bash\n"; \
		printf "  Then ensure Homebrew is in PATH, or run: jsh deps fix-bash\n"; \
		exit 1; \
	fi; \
	printf "$(GREEN)✓$(RESET) Bash 4+ available: $$found_bash\n"

lint-yaml: ## Run yamllint on YAML files
	@printf "$(BLUE)==>$(RESET) Running yamllint...\n"
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -c $(JSH_DIR)/.yamllint $(JSH_DIR)/.github/workflows/*.yml && \
		printf "$(GREEN)✓$(RESET) YAML lint passed\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) yamllint not installed, skipping\n"; \
	fi

lint-format: ## Check formatting with prettier
	@printf "$(BLUE)==>$(RESET) Checking format with prettier...\n"
	@if command -v npx >/dev/null 2>&1; then \
		npx prettier --check "**/*.{json,yaml,yml,md}" --ignore-path .gitignore 2>/dev/null && \
		printf "$(GREEN)✓$(RESET) Format check passed\n" || \
		printf "$(YELLOW)⚠$(RESET) Format issues found (run 'make format' to fix)\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) npx not available, skipping format check\n"; \
	fi

format: ## Fix formatting with prettier
	@printf "$(BLUE)==>$(RESET) Formatting files...\n"
	@if command -v npx >/dev/null 2>&1; then \
		npx prettier --write "**/*.{json,yaml,yml,md}" --ignore-path .gitignore; \
		printf "$(GREEN)✓$(RESET) Formatting complete\n"; \
	else \
		printf "$(RED)✘$(RESET) npx not available\n"; \
		exit 1; \
	fi

lint-secrets: ## Scan for secrets with gitleaks (via pre-commit)
	@printf "$(BLUE)==>$(RESET) Scanning for secrets...\n"
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run gitleaks --all-files && \
		printf "$(GREEN)✓$(RESET) No secrets detected\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) pre-commit not installed, skipping secret scan\n"; \
		printf "  Install: pip install pre-commit\n"; \
	fi

# =============================================================================
# Testing
# =============================================================================

test: ## Run BATS unit tests
	@printf "$(BLUE)==>$(RESET) Running BATS tests...\n"
	@bats --version
	@bats $(TESTS_DIR)/*.bats
	@printf "$(GREEN)✓$(RESET) Tests passed\n"

test-verbose: ## Run tests with verbose output
	@printf "$(BLUE)==>$(RESET) Running BATS tests (verbose)...\n"
	@bats --verbose-run $(TESTS_DIR)/*.bats

test-tap: ## Run tests with TAP output (for CI)
	@bats --tap $(TESTS_DIR)/*.bats

test-bash: ## Run tests explicitly in bash
	@printf "$(BLUE)==>$(RESET) Running tests in bash...\n"
	@bash -c 'bats $(TESTS_DIR)/*.bats'

test-zsh: ## Run tests explicitly in zsh
	@printf "$(BLUE)==>$(RESET) Running tests in zsh...\n"
	@zsh -c 'bats $(TESTS_DIR)/*.bats'

# =============================================================================
# Dependencies
# =============================================================================
# Required tools for development:
#   - bash 4+      : Modern bash features (associative arrays, etc.)
#   - shellcheck   : Shell script linting
#   - bats         : Bash testing framework
#   - pre-commit   : Git hook management
#   - jq           : JSON processing (for dependency management)
# Optional tools:
#   - yamllint     : YAML linting
#   - prettier     : Formatting (via npx)
# =============================================================================

# Tool requirements
REQUIRED_TOOLS := shellcheck bats pre-commit jq
OPTIONAL_TOOLS := yamllint

deps: deps-install ## Bootstrap dev environment (install tools + configure hooks)
	@printf "\n$(BLUE)==>$(RESET) Configuring git hooks...\n"
	@pre-commit install --hook-type pre-commit --hook-type commit-msg >/dev/null 2>&1 && \
		printf "$(GREEN)✓$(RESET) Pre-commit hooks installed\n" || \
		printf "$(RED)✘$(RESET) Failed to install pre-commit hooks\n"
	@printf "\n$(BLUE)==>$(RESET) Running verification...\n"
	@$(MAKE) --no-print-directory deps-check
	@printf "\n$(GREEN)✓$(RESET) Dev environment ready! Run 'make all' to verify.\n"

deps-check: ## Verify all dependencies are installed
	@printf "$(BLUE)==>$(RESET) Checking dependencies...\n"
	@missing=0; \
	for tool in $(REQUIRED_TOOLS); do \
		if command -v "$$tool" >/dev/null 2>&1; then \
			ver=$$($$tool --version 2>/dev/null | head -1 | sed 's/.*version //;s/[^0-9.].*//'); \
			printf "  $(GREEN)✓$(RESET) $$tool $(CYAN)$$ver$(RESET)\n"; \
		else \
			printf "  $(RED)✘$(RESET) $$tool $(RED)(missing)$(RESET)\n"; \
			missing=1; \
		fi; \
	done; \
	for tool in $(OPTIONAL_TOOLS); do \
		if command -v "$$tool" >/dev/null 2>&1; then \
			ver=$$($$tool --version 2>/dev/null | head -1 | sed 's/.*version //;s/[^0-9.].*//'); \
			printf "  $(GREEN)✓$(RESET) $$tool $(CYAN)$$ver$(RESET)\n"; \
		else \
			printf "  $(YELLOW)○$(RESET) $$tool $(YELLOW)(optional)$(RESET)\n"; \
		fi; \
	done; \
	printf "\n"; \
	bash_ver=$$(bash --version | head -1 | sed 's/.*version \([0-9]*\).*/\1/'); \
	if [ "$$bash_ver" -ge 4 ] 2>/dev/null; then \
		printf "  $(GREEN)✓$(RESET) bash 4+ $(CYAN)(v$$bash_ver)$(RESET)\n"; \
	else \
		printf "  $(RED)✘$(RESET) bash 4+ $(RED)(found v$$bash_ver)$(RESET)\n"; \
		missing=1; \
	fi; \
	if [ -f .git/hooks/pre-commit ] && grep -q pre-commit .git/hooks/pre-commit 2>/dev/null; then \
		printf "  $(GREEN)✓$(RESET) pre-commit hooks configured\n"; \
	else \
		printf "  $(YELLOW)○$(RESET) pre-commit hooks $(YELLOW)(not installed)$(RESET)\n"; \
	fi; \
	if [ "$$missing" -eq 1 ]; then \
		printf "\n$(RED)✘$(RESET) Missing required dependencies. Run: make deps-install\n"; \
		exit 1; \
	fi

deps-install: ## Install required development tools
	@printf "$(BLUE)==>$(RESET) Installing development dependencies...\n"
	@printf "$(CYAN)    Platform:$(RESET) $(PLATFORM)\n\n"
ifeq ($(OS),darwin)
	@# macOS: Use Homebrew
	@if ! command -v brew >/dev/null 2>&1; then \
		printf "$(RED)✘$(RESET) Homebrew not found. Install from https://brew.sh\n"; \
		exit 1; \
	fi
	@printf "$(BLUE)==>$(RESET) Installing via Homebrew...\n"
	@for tool in shellcheck bats-core pre-commit jq yamllint; do \
		if brew list "$$tool" >/dev/null 2>&1; then \
			printf "  $(GREEN)✓$(RESET) $$tool (already installed)\n"; \
		else \
			printf "  $(BLUE)↓$(RESET) Installing $$tool...\n"; \
			brew install "$$tool" >/dev/null 2>&1 && \
				printf "  $(GREEN)✓$(RESET) $$tool installed\n" || \
				printf "  $(RED)✘$(RESET) Failed to install $$tool\n"; \
		fi; \
	done
	@# Ensure bash 4+ is available
	@bash_ver=$$(bash --version | head -1 | sed 's/.*version \([0-9]*\).*/\1/'); \
	if [ "$$bash_ver" -lt 4 ] 2>/dev/null; then \
		printf "\n$(BLUE)==>$(RESET) Installing modern bash...\n"; \
		brew install bash >/dev/null 2>&1 && \
			printf "  $(GREEN)✓$(RESET) bash 4+ installed\n" || \
			printf "  $(RED)✘$(RESET) Failed to install bash\n"; \
	fi
else ifeq ($(OS),linux)
	@# Linux: Detect package manager and install
	@printf "$(BLUE)==>$(RESET) Installing via package manager...\n"
	@if command -v apt-get >/dev/null 2>&1; then \
		printf "  $(CYAN)Detected:$(RESET) apt (Debian/Ubuntu)\n"; \
		sudo apt-get update -qq; \
		sudo apt-get install -y -qq shellcheck bats jq python3-pip >/dev/null 2>&1; \
		pip3 install --user pre-commit yamllint >/dev/null 2>&1; \
	elif command -v dnf >/dev/null 2>&1; then \
		printf "  $(CYAN)Detected:$(RESET) dnf (Fedora/RHEL)\n"; \
		sudo dnf install -y -q ShellCheck bats jq python3-pip >/dev/null 2>&1; \
		pip3 install --user pre-commit yamllint >/dev/null 2>&1; \
	elif command -v pacman >/dev/null 2>&1; then \
		printf "  $(CYAN)Detected:$(RESET) pacman (Arch)\n"; \
		sudo pacman -S --noconfirm --quiet shellcheck bash-bats jq python-pre-commit yamllint >/dev/null 2>&1; \
	else \
		printf "$(YELLOW)⚠$(RESET) Unknown package manager. Install manually:\n"; \
		printf "    shellcheck bats pre-commit jq yamllint\n"; \
	fi
else
	@printf "$(YELLOW)⚠$(RESET) Unsupported platform: $(PLATFORM)\n"
	@printf "    Install manually: shellcheck bats pre-commit jq\n"
endif
	@printf "\n$(GREEN)✓$(RESET) Tool installation complete\n"

# =============================================================================
# CI Targets (used by GitHub Actions and locally)
# =============================================================================

ci: ci-lint ci-test ## Full CI pipeline (mirrors GitHub Actions)
	@printf "$(GREEN)✓$(RESET) CI pipeline complete\n"

ci-lint: ## CI lint stage
	@printf "$(BLUE)==>$(RESET) CI: Linting...\n"
	@$(MAKE) --no-print-directory lint-shell
	@$(MAKE) --no-print-directory lint-syntax
	@$(MAKE) --no-print-directory lint-compat
	@$(MAKE) --no-print-directory lint-yaml

ci-test: ## CI test stage
	@printf "$(BLUE)==>$(RESET) CI: Testing...\n"
	@$(MAKE) --no-print-directory test

# =============================================================================
# Docker Development
# =============================================================================

DOCKER_IMAGE ?= debian:bookworm
DOCKER_SHELL ?= bash
DOCKER_NAME := jsh-test-$(shell date +%s)

docker: ## Run ephemeral Docker container for testing (DOCKER_SHELL=bash|zsh)
	@printf "$(BLUE)==>$(RESET) Starting ephemeral container ($(DOCKER_SHELL))...\n"
	@printf "$(CYAN)    Tip:$(RESET) Run './jsh setup' then 'source ~/.$(DOCKER_SHELL)rc' to test jsh\n"
	@docker run -it --rm \
		--name "$(DOCKER_NAME)" \
		-v "$(JSH_DIR):/root/.jsh" \
		-w /root/.jsh \
		-e TERM=xterm-256color \
		$(DOCKER_IMAGE) \
		$(DOCKER_SHELL)

docker-bash: ## Run ephemeral Docker container with bash
	@$(MAKE) --no-print-directory docker DOCKER_SHELL=bash

docker-zsh: ## Run ephemeral Docker container with zsh (installs zsh first)
	@printf "$(BLUE)==>$(RESET) Starting ephemeral container (zsh)...\n"
	@printf "$(CYAN)    Tip:$(RESET) Run './jsh setup' then 'source ~/.zshrc' to test jsh\n"
	@docker run -it --rm \
		--name "$(DOCKER_NAME)" \
		-v "$(JSH_DIR):/root/.jsh" \
		-w /root/.jsh \
		-e TERM=xterm-256color \
		$(DOCKER_IMAGE) \
		sh -c 'apt-get update -qq && apt-get install -y -qq zsh >/dev/null 2>&1 && exec zsh'
