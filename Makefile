.PHONY: help
.DEFAULT_GOAL := help
SHELL := /bin/bash

# Colors for output
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
GRAY := \033[0;90m
RESET := \033[0m

# Tool versions (can be overridden)
PYTHON := python3
SHFMT_VERSION := latest
YAMLLINT_CONFIG := .yamllint

# Format function: formats files and prints per-file output with timing
# Usage: $(call format_files,file_list,format_command,type_name)
# Example: $(call format_files,$(SHELL_FILES),shfmt -w -i 2 -ci -sr,Shell scripts)
define format_files
	errors=0; \
	for file in $(1); do \
		tmp=$$(mktemp); \
		cp "$${file}" "$$tmp"; \
		start=$$($(PYTHON) -c 'import time; print(int(time.time() * 1000))'); \
		if ! $(2) "$${file}"; then \
			errors=$$((errors + 1)); \
			rm -f "$$tmp"; \
			continue; \
		fi; \
		end=$$($(PYTHON) -c 'import time; print(int(time.time() * 1000))'); \
		duration=$$((end - start)); \
		if cmp -s "$${file}" "$$tmp"; then \
			status="(unchanged)"; \
		else \
			status="(formatted)"; \
		fi; \
		rm -f "$$tmp"; \
		echo -e "$(GRAY)$${file}$(RESET) $${duration}ms $$status"; \
		unset status; \
	done; \
	if [ $$errors -eq 0 ]; then \
		echo -e "$(GREEN)✓ $(3) formatted$(RESET)"; \
	else \
		echo -e "$(RED)✗ $(3) formatting failed$(RESET)"; \
		exit 1; \
	fi
endef

# Format function for find-based iteration (YAML, JSON, Markdown)
# Usage: $(call format_files_find,find_pattern,format_command,type_name)
define format_files_find
	$(1) -print0 | while IFS= read -r -d '' file; do \
		tmp=$$(mktemp); \
		cp "$${file}" "$$tmp"; \
		start=$$($(PYTHON) -c 'import time; print(int(time.time() * 1000))'); \
		if ! $(2) "$${file}" > /dev/null 2>&1; then \
			rm -f "$$tmp"; \
			continue; \
		fi; \
		end=$$($(PYTHON) -c 'import time; print(int(time.time() * 1000))'); \
		duration=$$((end - start)); \
		if cmp -s "$${file}" "$$tmp"; then \
			status="(unchanged)"; \
		else \
			status="(formatted)"; \
		fi; \
		rm -f "$$tmp"; \
		echo -e "$(GRAY)$${file}$(RESET) $${duration}ms $$status"; \
		unset status; \
	done && \
	echo -e "$(GREEN)✓ $(3) formatted$(RESET)"
endef

# Find files by type
# Shell files: Find by .sh extension OR by shebang in bin/ directory
SHELL_FILES := $(shell find . -type f -name "*.sh" ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/.fzf/*" ! -path "*/.vscode/*" ! -path "*/.config/nvim/*" ! -path "*/.config/*" ! -path "*/src/*"; \
	find dotfiles -type f \( -name ".bashrc" -o -name ".jshrc" \); \
	find bin -type f 2>/dev/null | while read -r f; do \
		shebang=$$(head -n1 "$$f" 2>/dev/null); \
		echo "$$shebang" | grep -qE '^\#!/.*zsh' && continue; \
		echo "$$shebang" | grep -qE '^\#!/.*(ba)?sh' && echo "$$f"; \
	done)
PYTHON_FILES := $(shell find . -type f -name "*.py" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/.venv/*")
YAML_FILES := $(shell find . -type f \( -name "*.yaml" -o -name "*.yml" \) ! -path "*/\.*" ! -path "*/node_modules/*")
JSON_FILES := $(shell find . -type f -name "*.json" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/package*.json")
MD_FILES := $(shell find . -type f -name "*.md" ! -path "*/\.*" ! -path "*/node_modules/*")

help: ## Show this help message
	@echo -e "$(CYAN)Available targets:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'

##@ Setup

install-tools: ## Install required development tools
	@echo -e "$(CYAN)Installing development tools...$(RESET)"
	@command -v brew >/dev/null 2>&1 || { echo -e "$(RED)Homebrew not found. Please install it first.$(RESET)"; exit 1; }
	@echo -e "$(CYAN)Installing Homebrew packages...$(RESET)"
	@brew list shfmt >/dev/null 2>&1 || brew install shfmt
	@brew list hadolint >/dev/null 2>&1 || brew install hadolint
	@brew list pre-commit >/dev/null 2>&1 || brew install pre-commit
	@brew list ruby >/dev/null 2>&1 || brew install ruby
	@echo -e "$(CYAN)Installing Ruby gems (using Homebrew Ruby)...$(RESET)"
	@BREW_RUBY="$$(brew --prefix ruby)/bin"; \
	BREW_GEM="$$BREW_RUBY/gem"; \
	RUBY_VERSION=$$("$$BREW_RUBY/ruby" -e 'puts RUBY_VERSION'); \
	export GEM_HOME="$$(brew --prefix)/lib/ruby/gems/$$RUBY_VERSION"; \
	export GEM_PATH="$$GEM_HOME"; \
	"$$BREW_GEM" list -i '^bashly$$' >/dev/null 2>&1 || "$$BREW_GEM" install bashly
	@echo -e "$(CYAN)Installing Node.js packages...$(RESET)"
	@if ! command -v bun >/dev/null 2>&1; then \
		echo -e "$(CYAN)Bun not found, installing...$(RESET)"; \
		if command -v brew >/dev/null 2>&1; then \
			brew install oven-sh/bun/bun && echo -e "$(GREEN)✓ bun installed via Homebrew$(RESET)"; \
		else \
			echo -e "$(YELLOW)⚠ Cannot install bun without Homebrew. Install manually from https://bun.sh$(RESET)"; \
			exit 1; \
		fi; \
	fi
	@command -v commitizen >/dev/null 2>&1 || bun install -g commitizen cz-conventional-changelog
	@command -v commitlint >/dev/null 2>&1 || bun install -g @commitlint/cli @commitlint/config-conventional
	@command -v eslint >/dev/null 2>&1 || bun install -g eslint eslint-config-google
	@echo -e "$(CYAN)Installing Python packages...$(RESET)"
	@pip3 install --upgrade black pylint autopep8 2>/dev/null || echo -e "$(YELLOW)Python tools skipped (pip3 not available)$(RESET)"
	@echo -e "$(CYAN)Setting up pre-commit hooks...$(RESET)"
	@pre-commit install --install-hooks 2>/dev/null || echo -e "$(YELLOW)Pre-commit hooks setup skipped$(RESET)"
	@echo -e "$(GREEN)✓ All tools installed$(RESET)"

check-tools: ## Check if required tools are installed
	@echo -e "$(CYAN)Checking for required tools...$(RESET)"
	@errors=0; \
	for tool in shfmt black pylint eslint pre-commit; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo -e "$(GREEN)✓$(RESET) $$tool"; \
		else \
			echo -e "$(RED)✗$(RESET) $$tool (missing)"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -gt 0 ]; then \
		echo -e "$(YELLOW)Run 'make install-tools' to install missing tools$(RESET)"; \
		exit 1; \
	fi

ensure-tools: ## Ensure all tools are installed
	@$(MAKE) check-tools >/dev/null 2>&1 || $(MAKE) install-tools

##@ Formatting

fmt: fmt-shell fmt-python fmt-yaml fmt-json fmt-markdown ## Format all files

fmt-shell: ## Format shell scripts
	@echo -e "$(CYAN)Formatting shell scripts...$(RESET)"
	@if [ -n "$(SHELL_FILES)" ]; then \
		$(call format_files,$(SHELL_FILES),shfmt -w -i 2 -ci -sr,Shell scripts); \
	else \
		echo -e "$(YELLOW)No shell files found$(RESET)"; \
	fi

fmt-python: ## Format Python files
	@echo -e "$(CYAN)Formatting Python files...$(RESET)"
	@if [ -n "$(PYTHON_FILES)" ]; then \
		$(call format_files,$(PYTHON_FILES),black --line-length 100 --quiet,Python files); \
	else \
		echo -e "$(YELLOW)No Python files found$(RESET)"; \
	fi

fmt-yaml: ## Format YAML files
	@echo -e "$(CYAN)Formatting YAML files...$(RESET)"
	@if [ -n "$(YAML_FILES)" ]; then \
		pre-commit run prettier --files $(YAML_FILES) || true; \
		echo -e "$(GREEN)✓ YAML files formatted$(RESET)"; \
	else \
		echo -e "$(YELLOW)No YAML files found$(RESET)"; \
	fi

fmt-json: ## Format JSON files
	@echo -e "$(CYAN)Formatting JSON files...$(RESET)"
	@if [ -n "$(JSON_FILES)" ]; then \
		pre-commit run prettier --files $(JSON_FILES) || true; \
		echo -e "$(GREEN)✓ JSON files formatted$(RESET)"; \
	else \
		echo -e "$(YELLOW)No JSON files found$(RESET)"; \
	fi

fmt-markdown: ## Format Markdown files
	@echo -e "$(CYAN)Formatting Markdown files...$(RESET)"
	@if [ -n "$(MD_FILES)" ]; then \
		pre-commit run prettier --files $(MD_FILES) || true; \
		echo -e "$(GREEN)✓ Markdown files formatted$(RESET)"; \
	else \
		echo -e "$(YELLOW)No Markdown files found$(RESET)"; \
	fi

##@ Syntax Checking

check-syntax: check-shell-syntax check-python-syntax check-yaml-syntax check-json-syntax ## Check syntax of all files

check-shell-syntax: ## Check shell script syntax
	@echo -e "$(CYAN)Checking shell script syntax...$(RESET)"
	@if [ -n "$(SHELL_FILES)" ]; then \
		errors=0; \
		for file in $(SHELL_FILES); do \
			bash -n "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo -e "$(GREEN)✓ All shell scripts have valid syntax$(RESET)"; \
		else \
			echo -e "$(RED)✗ Found $$errors shell script(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo -e "$(YELLOW)No shell files found$(RESET)"; \
	fi

check-python-syntax: ## Check Python syntax
	@echo -e "$(CYAN)Checking Python syntax...$(RESET)"
	@if [ -n "$(PYTHON_FILES)" ]; then \
		errors=0; \
		for file in $(PYTHON_FILES); do \
			$(PYTHON) -m py_compile "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo -e "$(GREEN)✓ All Python files have valid syntax$(RESET)"; \
		else \
			echo -e "$(RED)✗ Found $$errors Python file(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo -e "$(YELLOW)No Python files found$(RESET)"; \
	fi

check-yaml-syntax: ## Check YAML syntax
	@echo -e "$(CYAN)Checking YAML syntax...$(RESET)"
	@if [ -n "$(YAML_FILES)" ]; then \
		pre-commit run yamllint --files $(YAML_FILES) && \
		echo -e "$(GREEN)✓ All YAML files have valid syntax$(RESET)"; \
	else \
		echo -e "$(YELLOW)No YAML files found$(RESET)"; \
	fi

check-json-syntax: ## Check JSON syntax
	@echo -e "$(CYAN)Checking JSON syntax...$(RESET)"
	@if [ -n "$(JSON_FILES)" ]; then \
		errors=0; \
		for file in $(JSON_FILES); do \
			$(PYTHON) -m json.tool "$$file" > /dev/null 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo -e "$(GREEN)✓ All JSON files have valid syntax$(RESET)"; \
		else \
			echo -e "$(RED)✗ Found $$errors JSON file(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo -e "$(YELLOW)No JSON files found$(RESET)"; \
	fi

##@ Linting

check-lint-deps: ## Check if linting dependencies are installed
	@echo -e "$(CYAN)Checking linting dependencies...$(RESET)"
	@missing=0; \
	echo -e "$(BLUE)Required tools:$(RESET)"; \
	for tool in pre-commit shellcheck yamllint bun; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo -e "  ${GREEN}✓${RESET} $$tool"; \
		else \
			echo -e "  ${RED}✗${RESET} $$tool (missing)"; \
			missing=$$((missing + 1)); \
		fi; \
	done; \
	if [ $$missing -gt 0 ]; then \
		echo -e "\n$(YELLOW)Run 'make install-lint-deps' to install missing dependencies$(RESET)"; \
		exit 1; \
	else \
		echo -e "\n$(GREEN)✓ All linting dependencies are installed$(RESET)"; \
	fi

install-lint-deps: ## Install linting dependencies (pre-commit, shellcheck, yamllint, bun)
	@echo -e "$(CYAN)Installing linting dependencies...$(RESET)"
	@echo ""
	@echo -e "$(BLUE)Installing pre-commit...$(RESET)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		pip3 install --user pre-commit 2>/dev/null || pip install --user pre-commit || \
		{ echo -e "$(RED)Failed to install pre-commit. Please install Python and pip first.$(RESET)"; exit 1; }; \
		echo -e "$(GREEN)✓ pre-commit installed$(RESET)"; \
	else \
		echo -e "$(GREEN)✓ pre-commit already installed$(RESET)"; \
	fi
	@echo ""
	@echo -e "$(BLUE)Installing shellcheck...$(RESET)"
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		if command -v brew >/dev/null 2>&1; then \
			brew install shellcheck && echo -e "$(GREEN)✓ shellcheck installed via Homebrew$(RESET)"; \
		elif command -v apt-get >/dev/null 2>&1; then \
			echo -e "$(YELLOW)Installing shellcheck requires sudo...$(RESET)"; \
			sudo apt-get update && sudo apt-get install -y shellcheck && \
			echo -e "$(GREEN)✓ shellcheck installed via apt$(RESET)"; \
		else \
			echo -e "$(YELLOW)⚠ Cannot auto-install shellcheck. Please install manually:$(RESET)"; \
			echo -e "  macOS: brew install shellcheck"; \
			echo -e "  Linux: sudo apt-get install shellcheck"; \
		fi; \
	else \
		echo -e "$(GREEN)✓ shellcheck already installed$(RESET)"; \
	fi
	@echo ""
	@echo -e "$(BLUE)Installing yamllint...$(RESET)"
	@if ! command -v yamllint >/dev/null 2>&1; then \
		pip3 install --user yamllint 2>/dev/null || pip install --user yamllint || \
		echo -e "$(YELLOW)⚠ Failed to install yamllint via pip$(RESET)"; \
		if command -v yamllint >/dev/null 2>&1; then \
			echo -e "$(GREEN)✓ yamllint installed$(RESET)"; \
		fi; \
	else \
		echo -e "$(GREEN)✓ yamllint already installed$(RESET)"; \
	fi
	@echo ""
	@echo -e "$(BLUE)Checking bun...$(RESET)"
	@if ! command -v bun >/dev/null 2>&1; then \
		if command -v brew >/dev/null 2>&1; then \
			brew install oven-sh/bun/bun && echo -e "$(GREEN)✓ bun installed via Homebrew$(RESET)"; \
		else \
			echo -e "$(YELLOW)⚠ bun not found. markdownlint requires bun.$(RESET)"; \
			echo -e "  Install Bun from: https://bun.sh/"; \
			echo -e "  Or via curl: curl -fsSL https://bun.sh/install | bash"; \
			exit 1; \
		fi; \
	else \
		echo -e "$(GREEN)✓ bun already installed$(RESET)"; \
	fi
	@echo ""
	@echo -e "$(GREEN)✓ Dependency installation complete!$(RESET)"
	@echo -e "$(CYAN)Note: markdownlint-cli and prettier will be installed automatically via bunx$(RESET)"

ensure-lint-deps: ## Ensure linting dependencies are installed (auto-install if needed)
	@$(MAKE) check-lint-deps >/dev/null 2>&1 || $(MAKE) install-lint-deps

lint: ensure-lint-deps ## Lint all files using pre-commit
	@echo -e "$(CYAN)Running pre-commit on all files...$(RESET)"
	@pre-commit run --all-files && \
		echo -e "$(GREEN)✓ All linting checks passed$(RESET)" || \
		(echo -e "$(RED)✗ Some linting checks failed$(RESET)"; exit 1)

lint-shell: ## Lint shell scripts with shellcheck
	@echo -e "$(CYAN)Linting shell scripts...$(RESET)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo -e "$(YELLOW)Installing pre-commit via pip...$(RESET)"; \
		pip3 install --user pre-commit 2>/dev/null || pip install --user pre-commit; \
	fi
	@if [ -n "$(SHELL_FILES)" ]; then \
		pre-commit run shellcheck --files $(SHELL_FILES) && \
		echo -e "$(GREEN)✓ Shell scripts passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No shell files found$(RESET)"; \
	fi

lint-python: ## Lint Python files with pre-commit
	@echo -e "$(CYAN)Linting Python files...$(RESET)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo -e "$(YELLOW)Installing pre-commit via pip...$(RESET)"; \
		pip3 install --user pre-commit 2>/dev/null || pip install --user pre-commit; \
	fi
	@if [ -n "$(PYTHON_FILES)" ]; then \
		pre-commit run --files $(PYTHON_FILES) && \
		echo -e "$(GREEN)✓ Python files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No Python files found$(RESET)"; \
	fi

lint-yaml: ## Lint YAML files with yamllint
	@echo -e "$(CYAN)Linting YAML files...$(RESET)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo -e "$(YELLOW)Installing pre-commit via pip...$(RESET)"; \
		pip3 install --user pre-commit 2>/dev/null || pip install --user pre-commit; \
	fi
	@if [ -n "$(YAML_FILES)" ]; then \
		pre-commit run yamllint --files $(YAML_FILES) && \
		echo -e "$(GREEN)✓ YAML files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No YAML files found$(RESET)"; \
	fi

lint-markdown: ## Lint Markdown files with markdownlint
	@echo -e "$(CYAN)Linting Markdown files...$(RESET)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo -e "$(YELLOW)Installing pre-commit via pip...$(RESET)"; \
		pip3 install --user pre-commit 2>/dev/null || pip install --user pre-commit; \
	fi
	@if [ -n "$(MD_FILES)" ]; then \
		pre-commit run markdownlint --files $(MD_FILES) && \
		echo -e "$(GREEN)✓ Markdown files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No Markdown files found$(RESET)"; \
	fi

lint-js: ## Lint JavaScript files with prettier via pre-commit
	@echo -e "$(CYAN)Linting JavaScript files...$(RESET)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo -e "$(YELLOW)Installing pre-commit via pip...$(RESET)"; \
		pip3 install --user pre-commit 2>/dev/null || pip install --user pre-commit; \
	fi
	@JS_FILES=$$(find . -type f -name "*.js" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/.eslintrc.json"); \
	if [ -n "$$JS_FILES" ]; then \
		pre-commit run prettier --files $$JS_FILES --hook-stage manual && \
		echo -e "$(GREEN)✓ JavaScript files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No JavaScript files found$(RESET)"; \
	fi

##@ Git Commits

commit: ## Create a conventional commit with commitizen
	@echo -e "$(CYAN)Creating conventional commit...$(RESET)"
	@if command -v cz >/dev/null 2>&1; then \
		cz commit; \
	elif command -v git-cz >/dev/null 2>&1; then \
		git-cz; \
	else \
		echo -e "$(RED)Commitizen not installed. Run 'make install-tools' first.$(RESET)"; \
		exit 1; \
	fi

commit-msg-check: ## Check last commit message follows conventional commits
	@echo -e "$(CYAN)Checking commit message...$(RESET)"
	@if command -v commitlint >/dev/null 2>&1; then \
		git log -1 --pretty=format:"%s" | commitlint && \
		echo -e "$(GREEN)✓ Commit message is valid$(RESET)"; \
	else \
		echo -e "$(YELLOW)commitlint not installed. Skipping check.$(RESET)"; \
	fi

##@ Pre-commit Checks

pre-commit-run: ## Run pre-commit hooks on all files
	@echo -e "$(CYAN)Running pre-commit hooks...$(RESET)"
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo -e "$(RED)pre-commit not installed. Run 'make install-tools' first.$(RESET)"; \
		exit 1; \
	fi

pre-commit: check-syntax lint ## Run all pre-commit checks (syntax + lint)
	@echo -e "$(GREEN)✓ All pre-commit checks passed$(RESET)"

ci: check-syntax lint ## Run CI checks (syntax + lint)
	@echo -e "$(GREEN)✓ All CI checks passed$(RESET)"

##@ Build

build: ## Regenerate jsh CLI from bashly sources
	@echo -e "$(CYAN)Regenerating jsh CLI...$(RESET)"
	@if ! command -v bashly >/dev/null 2>&1; then \
		echo -e "$(RED)bashly not installed. Run 'make install-tools' first.$(RESET)"; \
		exit 1; \
	fi
	@bashly generate && \
		echo -e "$(GREEN)✓ jsh CLI regenerated successfully$(RESET)"

##@ Testing & Validation

test: pre-commit ## Run all tests and validation
	@echo -e "$(GREEN)✓ All tests passed$(RESET)"

validate: check-syntax ## Validate all file syntax
	@echo -e "$(GREEN)✓ All files validated$(RESET)"

##@ Cleanup

clean: ## Remove temporary files and caches
	@echo -e "$(CYAN)Cleaning up...$(RESET)"
	@find . -type f -name "*.pyc" -delete
	@find . -type d -name "__pycache__" -delete
	@find . -type d -name ".pytest_cache" -delete
	@find . -type d -name ".mypy_cache" -delete
	@SYNC_FILES=$$(find . -type f -name "*.sync-conflict-*" 2>/dev/null | wc -l | tr -d ' '); \
	if [ $$SYNC_FILES -gt 0 ]; then \
		echo -e "$(YELLOW)Found $$SYNC_FILES sync-conflict file(s)$(RESET)"; \
		find . -type f -name "*.sync-conflict-*" 2>/dev/null; \
		read -p "Delete sync-conflict files? [y/N] " -n 1 -r; \
		echo; \
		if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
			find . -type f -name "*.sync-conflict-*" -delete; \
			echo -e "$(GREEN)✓ Sync-conflict files deleted$(RESET)"; \
		else \
			echo -e "$(YELLOW)Sync-conflict files kept$(RESET)"; \
		fi; \
	fi
	@echo -e "$(GREEN)✓ Cleanup complete$(RESET)"

##@ Task Integration

task-%: ## Run any taskfile task (e.g., make task-setup)
	@task $(subst task-,,$@)

tasks: ## List all available tasks from taskfile
	@task --list
