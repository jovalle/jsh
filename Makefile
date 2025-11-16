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
# Shell files: Find by .sh extension OR by shebang in .bin/ directory
SHELL_FILES := $(shell find . -type f -name "*.sh" ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/.fzf/*" ! -path "*/.vscode/*" ! -path "*/.config/nvim/*" ! -path "*/.config/*"; \
	find .bin -type f 2>/dev/null | while read -r f; do \
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
	@brew list shellcheck >/dev/null 2>&1 || brew install shellcheck
	@brew list yamllint >/dev/null 2>&1 || brew install yamllint
	@brew list prettier >/dev/null 2>&1 || brew install prettier
	@brew list hadolint >/dev/null 2>&1 || brew install hadolint
	@brew list pre-commit >/dev/null 2>&1 || brew install pre-commit
	@echo -e "$(CYAN)Installing Node.js packages...$(RESET)"
	@command -v commitizen >/dev/null 2>&1 || npm install -g commitizen cz-conventional-changelog
	@command -v commitlint >/dev/null 2>&1 || npm install -g @commitlint/cli @commitlint/config-conventional
	@command -v eslint >/dev/null 2>&1 || npm install -g eslint eslint-config-google
	@command -v markdownlint >/dev/null 2>&1 || npm install -g markdownlint-cli
	@echo -e "$(CYAN)Installing Python packages...$(RESET)"
	@pip3 install --upgrade black pylint autopep8 2>/dev/null || echo -e "$(YELLOW)Python tools skipped (pip3 not available)$(RESET)"
	@echo -e "$(CYAN)Setting up pre-commit hooks...$(RESET)"
	@pre-commit install --install-hooks 2>/dev/null || echo -e "$(YELLOW)Pre-commit hooks setup skipped$(RESET)"
	@echo -e "$(GREEN)✓ All tools installed$(RESET)"

check-tools: ## Check if required tools are installed
	@echo -e "$(CYAN)Checking for required tools...$(RESET)"
	@errors=0; \
	for tool in shfmt shellcheck yamllint prettier black pylint eslint markdownlint pre-commit; do \
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
		$(call format_files_find,find . -type f \( -name "*.yaml" -o -name "*.yml" \) ! -path "*/\\.*" ! -path "*/node_modules/*",prettier --write --print-width 100,YAML files); \
	else \
		echo -e "$(YELLOW)No YAML files found$(RESET)"; \
	fi

fmt-json: ## Format JSON files
	@echo -e "$(CYAN)Formatting JSON files...$(RESET)"
	@if [ -n "$(JSON_FILES)" ]; then \
		$(call format_files_find,find . -type f -name "*.json" ! -path "*/\\.*" ! -path "*/node_modules/*" ! -path "*/package*.json",prettier --write,JSON files); \
	else \
		echo -e "$(YELLOW)No JSON files found$(RESET)"; \
	fi

fmt-markdown: ## Format Markdown files
	@echo -e "$(CYAN)Formatting Markdown files...$(RESET)"
	@if [ -n "$(MD_FILES)" ]; then \
		$(call format_files_find,find . -type f -name "*.md" ! -path "*/\\.*" ! -path "*/node_modules/*",prettier --write --prose-wrap always,Markdown files); \
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
		errors=0; \
		for file in $(YAML_FILES); do \
			yamllint -d relaxed "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo -e "$(GREEN)✓ All YAML files have valid syntax$(RESET)"; \
		else \
			echo -e "$(RED)✗ Found $$errors YAML file(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
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

lint: lint-shell lint-python lint-yaml lint-markdown lint-js ## Lint all files

lint-shell: ## Lint shell scripts with shellcheck
	@echo -e "$(CYAN)Linting shell scripts...$(RESET)"
	@if [ -n "$(SHELL_FILES)" ]; then \
		shellcheck -x -S warning $(SHELL_FILES) && \
		echo -e "$(GREEN)✓ Shell scripts passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No shell files found$(RESET)"; \
	fi

lint-python: ## Lint Python files with pylint
	@echo -e "$(CYAN)Linting Python files...$(RESET)"
	@if [ -n "$(PYTHON_FILES)" ]; then \
		pylint --rcfile=.pylintrc $(PYTHON_FILES) 2>/dev/null || \
		pylint $(PYTHON_FILES) && \
		echo -e "$(GREEN)✓ Python files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No Python files found$(RESET)"; \
	fi

lint-yaml: ## Lint YAML files with yamllint
	@echo -e "$(CYAN)Linting YAML files...$(RESET)"
	@if [ -n "$(YAML_FILES)" ]; then \
		if [ -f "$(YAMLLINT_CONFIG)" ]; then \
			yamllint -c $(YAMLLINT_CONFIG) $(YAML_FILES); \
		else \
			yamllint $(YAML_FILES); \
		fi && \
		echo -e "$(GREEN)✓ YAML files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No YAML files found$(RESET)"; \
	fi

lint-markdown: ## Lint Markdown files with markdownlint
	@echo -e "$(CYAN)Linting Markdown files...$(RESET)"
	@if [ -n "$(MD_FILES)" ]; then \
		if [ -f ".markdownlint.json" ]; then \
			markdownlint --config .markdownlint.json $(MD_FILES); \
		else \
			markdownlint $(MD_FILES); \
		fi && \
		echo -e "$(GREEN)✓ Markdown files passed linting$(RESET)"; \
	else \
		echo -e "$(YELLOW)No Markdown files found$(RESET)"; \
	fi

lint-js: ## Lint JavaScript files with ESLint
	@echo -e "$(CYAN)Linting JavaScript files...$(RESET)"
	@JS_FILES=$$(find . -type f -name "*.js" ! -path "*/\.*" ! -path "*/node_modules/*"); \
	if [ -n "$$JS_FILES" ]; then \
		if [ -f ".eslintrc.json" ]; then \
			echo "$$JS_FILES" | xargs eslint; \
		else \
			echo "$$JS_FILES" | xargs eslint --config .eslintrc.json; \
		fi && \
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
