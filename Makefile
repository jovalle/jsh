# =============================================================================
# Jsh - Minimal Contributor Makefile
# =============================================================================
# Public targets:
# - deps: install contributor dependencies
# - lint: run shell/script lint checks
# - test: run BATS test suite

SHELL := bash
.DEFAULT_GOAL := deps

JSH_DIR := $(CURDIR)
SRC_DIR := $(JSH_DIR)/src
TESTS_DIR := $(JSH_DIR)/tests
SCRIPTS_DIR := $(JSH_DIR)/scripts

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
OS := darwin
else ifeq ($(UNAME_S),Linux)
OS := linux
else
OS := unknown
endif

ifdef CI
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

.PHONY: deps lint test

define require_cmd
	@command -v $(1) >/dev/null 2>&1 || { \
		printf "$(RED)✘$(RESET) Missing required tool: $(1)\\n"; \
		exit 1; \
	}
endef

deps: ## Install contributor dependencies
	@printf "$(BLUE)==>$(RESET) Installing contributor dependencies...\\n"
ifeq ($(OS),darwin)
	@$(call require_cmd,brew)
	@brew_cmd="brew"; \
	if [ "$$(id -u)" = "0" ]; then \
		delegate_user="$${JSH_BREW_DELEGATE_USER:-$$(id -nu 1000 2>/dev/null || getent passwd 1000 2>/dev/null | cut -d: -f1)}"; \
		if [ -n "$$delegate_user" ]; then \
			if command -v runuser >/dev/null 2>&1; then \
				brew_cmd="runuser -u $$delegate_user -- brew"; \
			elif command -v sudo >/dev/null 2>&1; then \
				brew_cmd="sudo -H -u $$delegate_user brew"; \
			fi; \
		else \
			printf "$(YELLOW)⚠$(RESET) Running as root without a brew delegate user; brew commands may fail\\n"; \
		fi; \
	fi; \
	for tool in shellcheck bats-core pre-commit jq yamllint bash; do \
		if $$brew_cmd list "$$tool" >/dev/null 2>&1; then \
			printf "$(GREEN)✓$(RESET) $$tool (already installed)\\n"; \
		else \
			printf "$(BLUE)↓$(RESET) Installing $$tool...\\n"; \
			$$brew_cmd install "$$tool" >/dev/null 2>&1 && \
				printf "$(GREEN)✓$(RESET) $$tool installed\\n" || \
				printf "$(RED)✘$(RESET) Failed to install $$tool\\n"; \
		fi; \
	done
else ifeq ($(OS),linux)
	@if command -v brew >/dev/null 2>&1; then \
		printf "$(CYAN)Detected:$(RESET) brew\n"; \
		run_brew() { \
			if [ "$$(id -u)" = "0" ]; then \
				local delegate_user delegate_home; \
				delegate_user="$${JSH_BREW_DELEGATE_USER:-$$(id -nu 1000 2>/dev/null || getent passwd 1000 2>/dev/null | cut -d: -f1)}"; \
				if [ -z "$$delegate_user" ]; then \
					printf "$(YELLOW)⚠$(RESET) Running as root without a brew delegate user; brew commands may fail\n"; \
					return 1; \
				fi; \
				delegate_home="$$(getent passwd "$$delegate_user" 2>/dev/null | cut -d: -f6)"; \
				[ -n "$$delegate_home" ] || delegate_home="/home/$$delegate_user"; \
				if command -v runuser >/dev/null 2>&1; then \
					runuser -u "$$delegate_user" -- env HOME="$$delegate_home" XDG_CACHE_HOME="$$delegate_home/.cache" bash -lc "cd '$$delegate_home' && /home/linuxbrew/.linuxbrew/bin/brew $$*"; \
				elif command -v sudo >/dev/null 2>&1; then \
					sudo -H -u "$$delegate_user" /home/linuxbrew/.linuxbrew/bin/brew "$$@"; \
				else \
					printf "$(RED)✘$(RESET) Need runuser or sudo to run brew as non-root\n"; \
					return 1; \
				fi; \
			else \
				brew "$$@"; \
			fi; \
		}; \
		for tool in shellcheck bats-core pre-commit jq yamllint bash; do \
			if run_brew list "$$tool" >/dev/null 2>&1; then \
				printf "$(GREEN)✓$(RESET) $$tool (already installed)\n"; \
			else \
				printf "$(BLUE)↓$(RESET) Installing $$tool...\n"; \
				run_brew install "$$tool" >/dev/null 2>&1 && \
					printf "$(GREEN)✓$(RESET) $$tool installed\n" || \
					printf "$(RED)✘$(RESET) Failed to install $$tool\n"; \
			fi; \
		done; \
	elif command -v apt-get >/dev/null 2>&1; then \
		printf "$(CYAN)Detected:$(RESET) apt\\n"; \
		sudo apt-get update -qq; \
		sudo apt-get install -y -qq shellcheck bats jq python3-pip >/dev/null 2>&1; \
		pip3 install --user pre-commit yamllint >/dev/null 2>&1; \
	elif command -v dnf >/dev/null 2>&1; then \
		printf "$(CYAN)Detected:$(RESET) dnf\\n"; \
		sudo dnf install -y -q ShellCheck bats jq python3-pip >/dev/null 2>&1; \
		pip3 install --user pre-commit yamllint >/dev/null 2>&1; \
	elif command -v pacman >/dev/null 2>&1; then \
		printf "$(CYAN)Detected:$(RESET) pacman\\n"; \
		sudo pacman -S --noconfirm --quiet shellcheck bats jq python-pre-commit yamllint >/dev/null 2>&1; \
	else \
		printf "$(RED)✘$(RESET) Unsupported Linux package manager. Install manually: shellcheck bats pre-commit jq yamllint\\n"; \
		exit 1; \
	fi
else
	@printf "$(RED)✘$(RESET) Unsupported OS: $(OS)\\n"
	@exit 1
endif
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit install --hook-type pre-commit --hook-type commit-msg >/dev/null 2>&1 || true; \
		printf "$(GREEN)✓$(RESET) pre-commit hooks installed\\n"; \
	else \
		printf "$(YELLOW)⚠$(RESET) pre-commit not installed; skipping hook installation\\n"; \
	fi

lint: ## Run shell lint checks
	@$(call require_cmd,shellcheck)
	@printf "$(BLUE)==>$(RESET) Running ShellCheck...\\n"
	@find $(SRC_DIR) -type f -name '*.sh' -exec shellcheck {} +
	@shellcheck $(JSH_DIR)/jsh
	@for f in $(JSH_DIR)/bin/*; do \
		if head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh'; then \
			shellcheck "$$f" || exit 1; \
		fi; \
	done
	@if [ -d "$(SCRIPTS_DIR)" ]; then \
		find $(SCRIPTS_DIR) -type f -name '*.sh' -exec shellcheck {} +; \
	fi
	@printf "$(BLUE)==>$(RESET) Running bash syntax checks...\\n"
	@for f in $$(find $(SRC_DIR) -type f -name '*.sh'); do \
		case "$$f" in */zsh.sh|*/j.sh) continue ;; esac; \
		bash -n "$$f" || exit 1; \
	done
	@bash -n $(JSH_DIR)/jsh
	@if command -v yamllint >/dev/null 2>&1; then \
		printf "$(BLUE)==>$(RESET) Running yamllint...\\n"; \
		yamllint -c $(JSH_DIR)/.yamllint $(JSH_DIR)/.github/workflows/*.yml; \
	fi
	@printf "$(GREEN)✓$(RESET) Lint passed\\n"

test: ## Run BATS tests
	@$(call require_cmd,bats)
	@printf "$(BLUE)==>$(RESET) Running BATS tests...\\n"
	@bats --version
	@tmp_git_cfg=$$(mktemp); \
	PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" GIT_CONFIG_GLOBAL="$$tmp_git_cfg" GIT_CONFIG_NOSYSTEM=1 bats $(TESTS_DIR)/*.bats; \
	rc=$$?; rm -f "$$tmp_git_cfg"; exit $$rc
	@printf "$(GREEN)✓$(RESET) Tests passed\\n"
