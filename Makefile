# =============================================================================
# Jsh Makefile - Shell Environment Build System
# =============================================================================
# This Makefile provides a unified interface for:
# - Linting and formatting shell scripts
# - Running tests across different shells
# - Managing binary and plugin dependencies
# - Docker development environment
# - CI/CD pipeline integration
#
# Usage: make [target]
# Run 'make help' for available targets
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# =============================================================================
# Project Paths
# =============================================================================

JSH_DIR := $(CURDIR)
SRC_DIR := $(JSH_DIR)/src
LIB_DIR := $(JSH_DIR)/lib
BIN_DIR := $(LIB_DIR)/bin
TESTS_DIR := $(JSH_DIR)/tests
SCRIPTS_DIR := $(JSH_DIR)/scripts
PLUGINS_DIR := $(LIB_DIR)/zsh-plugins

# Version manifest
VERSIONS_FILE := $(BIN_DIR)/versions.json

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
PLATFORM_BIN_DIR := $(BIN_DIR)/$(PLATFORM)

# All supported platforms for bulk downloads
PLATFORMS := linux-amd64 linux-arm64 darwin-amd64 darwin-arm64

# =============================================================================
# Tool Versions (from versions.json)
# =============================================================================

# Use system jq if available, otherwise provide defaults
JQ_CMD := $(shell command -v jq 2>/dev/null)
ifdef JQ_CMD
    FZF_VERSION := $(shell $(JQ_CMD) -r '.fzf // "0.67.0"' $(VERSIONS_FILE) 2>/dev/null)
    JQ_VERSION := $(shell $(JQ_CMD) -r '.jq // "1.7.1"' $(VERSIONS_FILE) 2>/dev/null)
    ZSH_AUTOSUGGESTIONS_VERSION := $(shell $(JQ_CMD) -r '."zsh-autosuggestions" // "0.7.1"' $(VERSIONS_FILE) 2>/dev/null)
    ZSH_SYNTAX_HIGHLIGHTING_VERSION := $(shell $(JQ_CMD) -r '."zsh-syntax-highlighting" // "0.8.0"' $(VERSIONS_FILE) 2>/dev/null)
    ZSH_HISTORY_SUBSTRING_SEARCH_VERSION := $(shell $(JQ_CMD) -r '."zsh-history-substring-search" // "1.0.2"' $(VERSIONS_FILE) 2>/dev/null)
else
    FZF_VERSION := 0.67.0
    JQ_VERSION := 1.7.1
    ZSH_AUTOSUGGESTIONS_VERSION := 0.7.1
    ZSH_SYNTAX_HIGHLIGHTING_VERSION := 0.8.0
    ZSH_HISTORY_SUBSTRING_SEARCH_VERSION := 1.0.2
endif

# =============================================================================
# Docker Settings
# =============================================================================

DOCKER_IMAGE := jsh-dev
DOCKER_TAG := latest
DOCKER_PLATFORMS := linux/amd64,linux/arm64

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
.PHONY: lint lint-shell lint-syntax lint-yaml lint-format format
.PHONY: test test-verbose test-tap test-bash test-zsh
.PHONY: deps deps-check deps-download deps-download-all deps-verify deps-force
.PHONY: deps-plugins deps-plugins-force
.PHONY: docker docker-build docker-build-multi docker-dev docker-shell docker-test docker-clean
.PHONY: ci ci-lint ci-test ci-binaries
.PHONY: pre-push install-hooks

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
	@printf "$(YELLOW)Versions:$(RESET) fzf=$(FZF_VERSION) jq=$(JQ_VERSION)\n"
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
	@printf "$(GREEN)✔$(RESET) Clean complete\n"

clean-all: clean docker-clean ## Clean everything including Docker images
	@printf "$(BLUE)==>$(RESET) Removing downloaded binaries...\n"
	@rm -f $(BIN_DIR)/*/fzf $(BIN_DIR)/*/jq
	@printf "$(GREEN)✔$(RESET) Full cleanup complete\n"

# =============================================================================
# Linting
# =============================================================================

lint: lint-shell lint-yaml ## Run all linters

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
	@printf "$(GREEN)✔$(RESET) ShellCheck passed\n"

lint-syntax: ## Quick syntax check (bash -n) for all scripts
	@printf "$(BLUE)==>$(RESET) Checking shell syntax...\n"
	@# Skip zsh.sh as it contains zsh-specific syntax (glob qualifiers)
	@for f in $(SRC_DIR)/*.sh; do \
		case "$$f" in */zsh.sh) continue ;; esac; \
		bash -n "$$f" || exit 1; \
	done
	@bash -n $(JSH_DIR)/jsh
	@printf "$(GREEN)✔$(RESET) Syntax check passed\n"

lint-yaml: ## Run yamllint on YAML files
	@printf "$(BLUE)==>$(RESET) Running yamllint...\n"
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -c $(JSH_DIR)/.yamllint $(JSH_DIR)/.github/workflows/*.yml && \
		printf "$(GREEN)✔$(RESET) YAML lint passed\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) yamllint not installed, skipping\n"; \
	fi

lint-format: ## Check formatting with prettier
	@printf "$(BLUE)==>$(RESET) Checking format with prettier...\n"
	@if command -v npx >/dev/null 2>&1; then \
		npx prettier --check "**/*.{json,yaml,yml,md}" --ignore-path .gitignore 2>/dev/null && \
		printf "$(GREEN)✔$(RESET) Format check passed\n" || \
		printf "$(YELLOW)⚠$(RESET) Format issues found (run 'make format' to fix)\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) npx not available, skipping format check\n"; \
	fi

format: ## Fix formatting with prettier
	@printf "$(BLUE)==>$(RESET) Formatting files...\n"
	@if command -v npx >/dev/null 2>&1; then \
		npx prettier --write "**/*.{json,yaml,yml,md}" --ignore-path .gitignore; \
		printf "$(GREEN)✔$(RESET) Formatting complete\n"; \
	else \
		printf "$(RED)✘$(RESET) npx not available\n"; \
		exit 1; \
	fi

# =============================================================================
# Testing
# =============================================================================

test: ## Run BATS unit tests
	@printf "$(BLUE)==>$(RESET) Running BATS tests...\n"
	@bats --version
	@bats $(TESTS_DIR)/*.bats
	@printf "$(GREEN)✔$(RESET) Tests passed\n"

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
# Dependency Management
# =============================================================================

deps: deps-check deps-download deps-plugins deps-verify ## Full dependency setup for current platform

deps-check: ## Check if required tools are available
	@printf "$(BLUE)==>$(RESET) Checking required tools...\n"
	@command -v curl >/dev/null 2>&1 || { printf "$(RED)✘$(RESET) curl not found\n"; exit 1; }
	@command -v tar >/dev/null 2>&1 || { printf "$(RED)✘$(RESET) tar not found\n"; exit 1; }
	@printf "$(GREEN)✔$(RESET) Required tools available\n"

deps-download: ## Download binaries for current platform
	@printf "$(BLUE)==>$(RESET) Downloading binaries for $(PLATFORM)...\n"
	@mkdir -p $(PLATFORM_BIN_DIR)
	@$(MAKE) --no-print-directory _download-fzf-$(PLATFORM)
	@$(MAKE) --no-print-directory _download-jq-$(PLATFORM)
	@printf "$(GREEN)✔$(RESET) Binaries downloaded for $(PLATFORM)\n"

deps-download-all: ## Download binaries for all platforms (CI)
	@printf "$(BLUE)==>$(RESET) Downloading binaries for all platforms...\n"
	@for platform in $(PLATFORMS); do \
		printf "$(CYAN)  ➜$(RESET) $$platform\n"; \
		mkdir -p $(BIN_DIR)/$$platform; \
		$(MAKE) --no-print-directory _download-fzf-$$platform || exit 1; \
		$(MAKE) --no-print-directory _download-jq-$$platform || exit 1; \
	done
	@printf "$(GREEN)✔$(RESET) All platform binaries downloaded\n"

deps-verify: ## Verify downloaded binaries work
	@printf "$(BLUE)==>$(RESET) Verifying binaries for $(PLATFORM)...\n"
	@if [ -x "$(PLATFORM_BIN_DIR)/fzf" ]; then \
		$(PLATFORM_BIN_DIR)/fzf --version >/dev/null 2>&1 && \
		printf "$(GREEN)✔$(RESET) fzf $(FZF_VERSION)\n" || \
		printf "$(RED)✘$(RESET) fzf binary error\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) fzf not found\n"; \
	fi
	@if [ -x "$(PLATFORM_BIN_DIR)/jq" ]; then \
		$(PLATFORM_BIN_DIR)/jq --version >/dev/null 2>&1 && \
		printf "$(GREEN)✔$(RESET) jq $(JQ_VERSION)\n" || \
		printf "$(RED)✘$(RESET) jq binary error\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) jq not found\n"; \
	fi

deps-force: clean-all deps-download-all deps-plugins-force ## Force re-download everything

# -----------------------------------------------------------------------------
# FZF Downloads
# -----------------------------------------------------------------------------

_download-fzf-linux-amd64:
	@if [ ! -x "$(BIN_DIR)/linux-amd64/fzf" ]; then \
		curl -sL "https://github.com/junegunn/fzf/releases/download/v$(FZF_VERSION)/fzf-$(FZF_VERSION)-linux_amd64.tar.gz" | tar xz -C $(BIN_DIR)/linux-amd64; \
		chmod +x $(BIN_DIR)/linux-amd64/fzf; \
	fi

_download-fzf-linux-arm64:
	@if [ ! -x "$(BIN_DIR)/linux-arm64/fzf" ]; then \
		curl -sL "https://github.com/junegunn/fzf/releases/download/v$(FZF_VERSION)/fzf-$(FZF_VERSION)-linux_arm64.tar.gz" | tar xz -C $(BIN_DIR)/linux-arm64; \
		chmod +x $(BIN_DIR)/linux-arm64/fzf; \
	fi

_download-fzf-darwin-amd64:
	@if [ ! -x "$(BIN_DIR)/darwin-amd64/fzf" ]; then \
		curl -sL "https://github.com/junegunn/fzf/releases/download/v$(FZF_VERSION)/fzf-$(FZF_VERSION)-darwin_amd64.tar.gz" | tar xz -C $(BIN_DIR)/darwin-amd64; \
		chmod +x $(BIN_DIR)/darwin-amd64/fzf; \
	fi

_download-fzf-darwin-arm64:
	@if [ ! -x "$(BIN_DIR)/darwin-arm64/fzf" ]; then \
		curl -sL "https://github.com/junegunn/fzf/releases/download/v$(FZF_VERSION)/fzf-$(FZF_VERSION)-darwin_arm64.tar.gz" | tar xz -C $(BIN_DIR)/darwin-arm64; \
		chmod +x $(BIN_DIR)/darwin-arm64/fzf; \
	fi

# -----------------------------------------------------------------------------
# jq Downloads
# -----------------------------------------------------------------------------

_download-jq-linux-amd64:
	@if [ ! -x "$(BIN_DIR)/linux-amd64/jq" ]; then \
		curl -sL "https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-amd64" -o $(BIN_DIR)/linux-amd64/jq; \
		chmod +x $(BIN_DIR)/linux-amd64/jq; \
	fi

_download-jq-linux-arm64:
	@if [ ! -x "$(BIN_DIR)/linux-arm64/jq" ]; then \
		curl -sL "https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-arm64" -o $(BIN_DIR)/linux-arm64/jq; \
		chmod +x $(BIN_DIR)/linux-arm64/jq; \
	fi

_download-jq-darwin-amd64:
	@if [ ! -x "$(BIN_DIR)/darwin-amd64/jq" ]; then \
		curl -sL "https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-macos-amd64" -o $(BIN_DIR)/darwin-amd64/jq; \
		chmod +x $(BIN_DIR)/darwin-amd64/jq; \
	fi

_download-jq-darwin-arm64:
	@if [ ! -x "$(BIN_DIR)/darwin-arm64/jq" ]; then \
		curl -sL "https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-macos-arm64" -o $(BIN_DIR)/darwin-arm64/jq; \
		chmod +x $(BIN_DIR)/darwin-arm64/jq; \
	fi

# -----------------------------------------------------------------------------
# ZSH Plugin Downloads
# -----------------------------------------------------------------------------

deps-plugins: ## Download ZSH plugins
	@printf "$(BLUE)==>$(RESET) Downloading ZSH plugins...\n"
	@mkdir -p $(PLUGINS_DIR)/highlighters
	@$(MAKE) --no-print-directory _download-zsh-autosuggestions
	@$(MAKE) --no-print-directory _download-zsh-syntax-highlighting
	@$(MAKE) --no-print-directory _download-zsh-history-substring-search
	@printf "$(GREEN)✔$(RESET) ZSH plugins downloaded\n"

deps-plugins-force: ## Force re-download ZSH plugins
	@rm -f $(PLUGINS_DIR)/zsh-autosuggestions.zsh
	@rm -f $(PLUGINS_DIR)/zsh-syntax-highlighting.zsh
	@rm -f $(PLUGINS_DIR)/zsh-history-substring-search.zsh
	@rm -rf $(PLUGINS_DIR)/highlighters
	@$(MAKE) --no-print-directory deps-plugins

_download-zsh-autosuggestions:
	@if [ ! -f "$(PLUGINS_DIR)/zsh-autosuggestions.zsh" ]; then \
		tmp=$$(mktemp -d); \
		curl -sL "https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v$(ZSH_AUTOSUGGESTIONS_VERSION).tar.gz" | tar xz -C "$$tmp"; \
		cp "$$tmp/zsh-autosuggestions-$(ZSH_AUTOSUGGESTIONS_VERSION)/zsh-autosuggestions.zsh" $(PLUGINS_DIR)/; \
		rm -rf "$$tmp"; \
		printf "  $(GREEN)✔$(RESET) zsh-autosuggestions v$(ZSH_AUTOSUGGESTIONS_VERSION)\n"; \
	fi

_download-zsh-syntax-highlighting:
	@if [ ! -f "$(PLUGINS_DIR)/zsh-syntax-highlighting.zsh" ]; then \
		tmp=$$(mktemp -d); \
		curl -sL "https://github.com/zsh-users/zsh-syntax-highlighting/archive/refs/tags/$(ZSH_SYNTAX_HIGHLIGHTING_VERSION).tar.gz" | tar xz -C "$$tmp"; \
		cp "$$tmp/zsh-syntax-highlighting-$(ZSH_SYNTAX_HIGHLIGHTING_VERSION)/zsh-syntax-highlighting.zsh" $(PLUGINS_DIR)/; \
		rm -rf $(PLUGINS_DIR)/highlighters; \
		cp -r "$$tmp/zsh-syntax-highlighting-$(ZSH_SYNTAX_HIGHLIGHTING_VERSION)/highlighters" $(PLUGINS_DIR)/; \
		rm -rf "$$tmp"; \
		printf "  $(GREEN)✔$(RESET) zsh-syntax-highlighting v$(ZSH_SYNTAX_HIGHLIGHTING_VERSION)\n"; \
	fi

_download-zsh-history-substring-search:
	@if [ ! -f "$(PLUGINS_DIR)/zsh-history-substring-search.zsh" ]; then \
		tmp=$$(mktemp -d); \
		curl -sL "https://github.com/zsh-users/zsh-history-substring-search/archive/refs/tags/v$(ZSH_HISTORY_SUBSTRING_SEARCH_VERSION).tar.gz" | tar xz -C "$$tmp"; \
		cp "$$tmp/zsh-history-substring-search-$(ZSH_HISTORY_SUBSTRING_SEARCH_VERSION)/zsh-history-substring-search.zsh" $(PLUGINS_DIR)/; \
		rm -rf "$$tmp"; \
		printf "  $(GREEN)✔$(RESET) zsh-history-substring-search v$(ZSH_HISTORY_SUBSTRING_SEARCH_VERSION)\n"; \
	fi

# -----------------------------------------------------------------------------
# Vim Plugin Setup (portable vim-plug configuration)
# -----------------------------------------------------------------------------

VIM_CONFIG_DIR := $(LIB_DIR)/vim-config
VIM_PLUGGED_DIR := $(VIM_CONFIG_DIR)/plugged
VIM_PLUG_URL := https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

vim-setup: ## Download vim-plug and clone vim plugins
	@printf "$(BLUE)==>$(RESET) Setting up portable vim configuration...\n"
	@mkdir -p $(VIM_CONFIG_DIR)/autoload $(VIM_PLUGGED_DIR)
	@if [ ! -f "$(VIM_CONFIG_DIR)/autoload/plug.vim" ]; then \
		printf "  Downloading vim-plug...\n"; \
		curl -fsSL $(VIM_PLUG_URL) -o $(VIM_CONFIG_DIR)/autoload/plug.vim; \
		printf "  $(GREEN)✔$(RESET) vim-plug installed\n"; \
	fi
	@$(MAKE) --no-print-directory _clone-vim-plugins
	@printf "$(GREEN)✔$(RESET) Vim setup complete\n"

vim-update: ## Update vim plugins to latest
	@printf "$(BLUE)==>$(RESET) Updating vim plugins...\n"
	@for dir in $(VIM_PLUGGED_DIR)/*/; do \
		if [ -d "$$dir/.git" ]; then \
			name=$$(basename "$$dir"); \
			printf "  Updating $$name...\n"; \
			git -C "$$dir" pull --quiet 2>/dev/null || true; \
		fi; \
	done
	@printf "$(GREEN)✔$(RESET) Vim plugins updated\n"

vim-clean: ## Remove vim plugins (keeps vimrc)
	@printf "$(BLUE)==>$(RESET) Cleaning vim plugins...\n"
	@rm -rf $(VIM_PLUGGED_DIR)
	@printf "$(GREEN)✔$(RESET) Vim plugins removed\n"

vim-verify: ## Verify vim setup is complete
	@printf "$(BLUE)==>$(RESET) Verifying vim setup...\n"
	@if [ -f "$(VIM_CONFIG_DIR)/autoload/plug.vim" ]; then \
		printf "  $(GREEN)✔$(RESET) vim-plug installed\n"; \
	else \
		printf "  $(RED)✘$(RESET) vim-plug missing\n"; \
	fi
	@if [ -f "$(VIM_CONFIG_DIR)/vimrc" ]; then \
		printf "  $(GREEN)✔$(RESET) vimrc present\n"; \
	else \
		printf "  $(RED)✘$(RESET) vimrc missing\n"; \
	fi
	@plugins_count=$$(ls -d $(VIM_PLUGGED_DIR)/*/ 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$plugins_count" -ge 5 ]; then \
		printf "  $(GREEN)✔$(RESET) $$plugins_count vim plugins installed\n"; \
	else \
		printf "  $(YELLOW)⚠$(RESET) Only $$plugins_count plugins (expected 8)\n"; \
	fi

_clone-vim-plugins:
	@printf "  Cloning vim plugins...\n"
	@if [ ! -d "$(VIM_PLUGGED_DIR)/fzf" ]; then \
		git clone --depth 1 https://github.com/junegunn/fzf.git $(VIM_PLUGGED_DIR)/fzf 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) fzf\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/fzf.vim" ]; then \
		git clone --depth 1 https://github.com/junegunn/fzf.vim.git $(VIM_PLUGGED_DIR)/fzf.vim 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) fzf.vim\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/vim-fugitive" ]; then \
		git clone --depth 1 https://github.com/tpope/vim-fugitive.git $(VIM_PLUGGED_DIR)/vim-fugitive 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) vim-fugitive\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/vim-gitgutter" ]; then \
		git clone --depth 1 https://github.com/airblade/vim-gitgutter.git $(VIM_PLUGGED_DIR)/vim-gitgutter 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) vim-gitgutter\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/lightline.vim" ]; then \
		git clone --depth 1 https://github.com/itchyny/lightline.vim.git $(VIM_PLUGGED_DIR)/lightline.vim 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) lightline.vim\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/nerdtree" ]; then \
		git clone --depth 1 https://github.com/preservim/nerdtree.git $(VIM_PLUGGED_DIR)/nerdtree 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) nerdtree\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/vim-surround" ]; then \
		git clone --depth 1 https://github.com/tpope/vim-surround.git $(VIM_PLUGGED_DIR)/vim-surround 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) vim-surround\n"; \
	fi
	@if [ ! -d "$(VIM_PLUGGED_DIR)/vim-commentary" ]; then \
		git clone --depth 1 https://github.com/tpope/vim-commentary.git $(VIM_PLUGGED_DIR)/vim-commentary 2>/dev/null; \
		printf "    $(GREEN)✔$(RESET) vim-commentary\n"; \
	fi

# =============================================================================
# Docker
# =============================================================================

DOCKER_BUILD_ARGS := --build-arg FZF_VERSION=$(FZF_VERSION) \
                     --build-arg JQ_VERSION=$(JQ_VERSION)

docker: docker-build ## Build Docker development image

docker-build: ## Build the Docker image
	@printf "$(BLUE)==>$(RESET) Building Docker image...\n"
	@docker build $(DOCKER_BUILD_ARGS) -t $(DOCKER_IMAGE):$(DOCKER_TAG) .
	@printf "$(GREEN)✔$(RESET) Docker image built: $(DOCKER_IMAGE):$(DOCKER_TAG)\n"

docker-build-multi: ## Build for multiple platforms (requires buildx)
	@printf "$(BLUE)==>$(RESET) Building multi-platform Docker image...\n"
	@docker buildx build $(DOCKER_BUILD_ARGS) \
		--platform $(DOCKER_PLATFORMS) \
		-t $(DOCKER_IMAGE):$(DOCKER_TAG) .

docker-dev: docker-build ## Start interactive development container
	@printf "$(BLUE)==>$(RESET) Starting dev container...\n"
	@docker compose up -d dev
	@docker compose exec dev /bin/zsh

docker-shell: ## Quick shell in a fresh container
	@docker compose run --rm dev /bin/zsh

docker-test: docker-build ## Run tests inside container
	@printf "$(BLUE)==>$(RESET) Running tests in container...\n"
	@docker compose run --rm ci

docker-clean: ## Remove Docker images and containers
	@printf "$(BLUE)==>$(RESET) Cleaning Docker resources...\n"
	@docker compose down -v --rmi local 2>/dev/null || true
	@docker rmi $(DOCKER_IMAGE):$(DOCKER_TAG) 2>/dev/null || true
	@printf "$(GREEN)✔$(RESET) Docker cleanup complete\n"

# =============================================================================
# CI Targets (used by GitHub Actions and locally)
# =============================================================================

ci: ci-lint ci-test ## Full CI pipeline (mirrors GitHub Actions)
	@printf "$(GREEN)✔$(RESET) CI pipeline complete\n"

ci-lint: ## CI lint stage
	@printf "$(BLUE)==>$(RESET) CI: Linting...\n"
	@$(MAKE) --no-print-directory lint-shell
	@$(MAKE) --no-print-directory lint-syntax
	@$(MAKE) --no-print-directory lint-yaml

ci-test: ## CI test stage
	@printf "$(BLUE)==>$(RESET) CI: Testing...\n"
	@$(MAKE) --no-print-directory test

ci-binaries: ## CI binary update stage
	@printf "$(BLUE)==>$(RESET) CI: Updating binaries...\n"
	@$(MAKE) --no-print-directory deps-download-all
	@$(MAKE) --no-print-directory deps-plugins

# =============================================================================
# Git Hooks
# =============================================================================

pre-push: lint test ## Run before pushing (install with: make install-hooks)
	@printf "$(GREEN)✔$(RESET) Pre-push checks passed\n"

install-hooks: ## Install git pre-push hook
	@printf "$(BLUE)==>$(RESET) Installing git hooks...\n"
	@echo '#!/bin/sh' > $(JSH_DIR)/.git/hooks/pre-push
	@echo 'make pre-push' >> $(JSH_DIR)/.git/hooks/pre-push
	@chmod +x $(JSH_DIR)/.git/hooks/pre-push
	@printf "$(GREEN)✔$(RESET) Pre-push hook installed\n"
