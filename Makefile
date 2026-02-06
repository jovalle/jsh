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
	@for tool in shellcheck bats-core pre-commit jq yamllint bash; do \
		if brew list "$$tool" >/dev/null 2>&1; then \
			printf "$(GREEN)✓$(RESET) $$tool (already installed)\\n"; \
		else \
			printf "$(BLUE)↓$(RESET) Installing $$tool...\\n"; \
			brew install "$$tool" >/dev/null 2>&1 && \
				printf "$(GREEN)✓$(RESET) $$tool installed\\n" || \
				printf "$(RED)✘$(RESET) Failed to install $$tool\\n"; \
		fi; \
	done
else ifeq ($(OS),linux)
	@if command -v apt-get >/dev/null 2>&1; then \
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
	@printf "$(GREEN)✓$(RESET) Dependency setup complete\\n"

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
