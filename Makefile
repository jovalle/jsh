.PHONY: help
.DEFAULT_GOAL := help
SHELL := /bin/zsh

# Colors for output
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
RESET := \033[0m

# Tool versions (can be overridden)
PYTHON := python3
SHFMT_VERSION := latest
YAMLLINT_CONFIG := .yamllint

# Find files by type
# Shell files: Find by .sh extension OR by shebang in .bin/ directory
SHELL_FILES := $(shell find . -type f -name "*.sh" ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/.fzf/*" ! -path "*/.vscode/*" ! -path "*/.config/nvim/*" ! -path "*/.config/*"; \
	find .bin -type f 2>/dev/null | while read -r f; do head -n1 "$$f" 2>/dev/null | grep -qE '^\#!/bin/(ba)?sh' && echo "$$f"; done)
PYTHON_FILES := $(shell find . -type f -name "*.py" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/.venv/*")
YAML_FILES := $(shell find . -type f \( -name "*.yaml" -o -name "*.yml" \) ! -path "*/\.*" ! -path "*/node_modules/*")
JSON_FILES := $(shell find . -type f -name "*.json" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/package*.json")
MD_FILES := $(shell find . -type f -name "*.md" ! -path "*/\.*" ! -path "*/node_modules/*")

help: ## Show this help message
	@echo "$(CYAN)Available targets:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'

##@ Setup

install-tools: ## Install required development tools
	@echo "$(CYAN)Installing development tools...$(RESET)"
	@command -v brew >/dev/null 2>&1 || { echo "$(RED)Homebrew not found. Please install it first.$(RESET)"; exit 1; }
	@echo "$(CYAN)Installing Homebrew packages...$(RESET)"
	@brew list shfmt >/dev/null 2>&1 || brew install shfmt
	@brew list shellcheck >/dev/null 2>&1 || brew install shellcheck
	@brew list yamllint >/dev/null 2>&1 || brew install yamllint
	@brew list prettier >/dev/null 2>&1 || brew install prettier
	@brew list hadolint >/dev/null 2>&1 || brew install hadolint
	@brew list pre-commit >/dev/null 2>&1 || brew install pre-commit
	@echo "$(CYAN)Installing Node.js packages...$(RESET)"
	@command -v commitizen >/dev/null 2>&1 || npm install -g commitizen cz-conventional-changelog
	@command -v commitlint >/dev/null 2>&1 || npm install -g @commitlint/cli @commitlint/config-conventional
	@command -v eslint >/dev/null 2>&1 || npm install -g eslint eslint-config-google
	@command -v markdownlint >/dev/null 2>&1 || npm install -g markdownlint-cli
	@echo "$(CYAN)Installing Python packages...$(RESET)"
	@pip3 install --upgrade black pylint autopep8 2>/dev/null || echo "$(YELLOW)Python tools skipped (pip3 not available)$(RESET)"
	@echo "$(CYAN)Setting up pre-commit hooks...$(RESET)"
	@pre-commit install --install-hooks 2>/dev/null || echo "$(YELLOW)Pre-commit hooks setup skipped$(RESET)"
	@echo "$(GREEN)✓ All tools installed$(RESET)"

check-tools: ## Check if required tools are installed
	@echo "$(CYAN)Checking for required tools...$(RESET)"
	@errors=0; \
	for tool in shfmt shellcheck yamllint prettier black pylint eslint markdownlint pre-commit; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "$(GREEN)✓$(RESET) $$tool"; \
		else \
			echo "$(RED)✗$(RESET) $$tool (missing)"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -gt 0 ]; then \
		echo "$(YELLOW)Run 'make install-tools' to install missing tools$(RESET)"; \
		exit 1; \
	fi

##@ Formatting

format: format-shell format-python format-yaml format-json format-markdown ## Format all files

format-shell: ## Format shell scripts
	@echo "$(CYAN)Formatting shell scripts...$(RESET)"
	@if [ -n "$(SHELL_FILES)" ]; then \
		shfmt -w -i 2 -ci -sr $(SHELL_FILES) && \
		echo "$(GREEN)✓ Shell scripts formatted$(RESET)"; \
	else \
		echo "$(YELLOW)No shell files found$(RESET)"; \
	fi

format-python: ## Format Python files
	@echo "$(CYAN)Formatting Python files...$(RESET)"
	@if [ -n "$(PYTHON_FILES)" ]; then \
		black --line-length 100 $(PYTHON_FILES) && \
		echo "$(GREEN)✓ Python files formatted$(RESET)"; \
	else \
		echo "$(YELLOW)No Python files found$(RESET)"; \
	fi

format-yaml: ## Format YAML files
	@echo "$(CYAN)Formatting YAML files...$(RESET)"
	@if [ -n "$(YAML_FILES)" ]; then \
		prettier --write --print-width 100 $(YAML_FILES) && \
		echo "$(GREEN)✓ YAML files formatted$(RESET)"; \
	else \
		echo "$(YELLOW)No YAML files found$(RESET)"; \
	fi

format-json: ## Format JSON files
	@echo "$(CYAN)Formatting JSON files...$(RESET)"
	@if [ -n "$(JSON_FILES)" ]; then \
		prettier --write $(JSON_FILES) && \
		echo "$(GREEN)✓ JSON files formatted$(RESET)"; \
	else \
		echo "$(YELLOW)No JSON files found$(RESET)"; \
	fi

format-markdown: ## Format Markdown files
	@echo "$(CYAN)Formatting Markdown files...$(RESET)"
	@if [ -n "$(MD_FILES)" ]; then \
		prettier --write --prose-wrap always $(MD_FILES) && \
		echo "$(GREEN)✓ Markdown files formatted$(RESET)"; \
	else \
		echo "$(YELLOW)No Markdown files found$(RESET)"; \
	fi

##@ Syntax Checking

check-syntax: check-shell-syntax check-python-syntax check-yaml-syntax check-json-syntax ## Check syntax of all files

check-shell-syntax: ## Check shell script syntax
	@echo "$(CYAN)Checking shell script syntax...$(RESET)"
	@if [ -n "$(SHELL_FILES)" ]; then \
		errors=0; \
		for file in $(SHELL_FILES); do \
			bash -n "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo "$(GREEN)✓ All shell scripts have valid syntax$(RESET)"; \
		else \
			echo "$(RED)✗ Found $$errors shell script(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo "$(YELLOW)No shell files found$(RESET)"; \
	fi

check-python-syntax: ## Check Python syntax
	@echo "$(CYAN)Checking Python syntax...$(RESET)"
	@if [ -n "$(PYTHON_FILES)" ]; then \
		errors=0; \
		for file in $(PYTHON_FILES); do \
			$(PYTHON) -m py_compile "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo "$(GREEN)✓ All Python files have valid syntax$(RESET)"; \
		else \
			echo "$(RED)✗ Found $$errors Python file(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo "$(YELLOW)No Python files found$(RESET)"; \
	fi

check-yaml-syntax: ## Check YAML syntax
	@echo "$(CYAN)Checking YAML syntax...$(RESET)"
	@if [ -n "$(YAML_FILES)" ]; then \
		errors=0; \
		for file in $(YAML_FILES); do \
			$(PYTHON) -c "import yaml; yaml.safe_load(open('$$file'))" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo "$(GREEN)✓ All YAML files have valid syntax$(RESET)"; \
		else \
			echo "$(RED)✗ Found $$errors YAML file(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo "$(YELLOW)No YAML files found$(RESET)"; \
	fi

check-json-syntax: ## Check JSON syntax
	@echo "$(CYAN)Checking JSON syntax...$(RESET)"
	@if [ -n "$(JSON_FILES)" ]; then \
		errors=0; \
		for file in $(JSON_FILES); do \
			$(PYTHON) -m json.tool "$$file" > /dev/null 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			echo "$(GREEN)✓ All JSON files have valid syntax$(RESET)"; \
		else \
			echo "$(RED)✗ Found $$errors JSON file(s) with syntax errors$(RESET)"; \
			exit 1; \
		fi; \
	else \
		echo "$(YELLOW)No JSON files found$(RESET)"; \
	fi

##@ Linting

lint: lint-shell lint-python lint-yaml lint-markdown lint-js ## Lint all files

lint-shell: ## Lint shell scripts with shellcheck
	@echo "$(CYAN)Linting shell scripts...$(RESET)"
	@if [ -n "$(SHELL_FILES)" ]; then \
		shellcheck -x -S warning $(SHELL_FILES) && \
		echo "$(GREEN)✓ Shell scripts passed linting$(RESET)"; \
	else \
		echo "$(YELLOW)No shell files found$(RESET)"; \
	fi

lint-python: ## Lint Python files with pylint
	@echo "$(CYAN)Linting Python files...$(RESET)"
	@if [ -n "$(PYTHON_FILES)" ]; then \
		pylint --rcfile=.pylintrc $(PYTHON_FILES) 2>/dev/null || \
		pylint $(PYTHON_FILES) && \
		echo "$(GREEN)✓ Python files passed linting$(RESET)"; \
	else \
		echo "$(YELLOW)No Python files found$(RESET)"; \
	fi

lint-yaml: ## Lint YAML files with yamllint
	@echo "$(CYAN)Linting YAML files...$(RESET)"
	@if [ -n "$(YAML_FILES)" ]; then \
		if [ -f "$(YAMLLINT_CONFIG)" ]; then \
			yamllint -c $(YAMLLINT_CONFIG) $(YAML_FILES); \
		else \
			yamllint $(YAML_FILES); \
		fi && \
		echo "$(GREEN)✓ YAML files passed linting$(RESET)"; \
	else \
		echo "$(YELLOW)No YAML files found$(RESET)"; \
	fi

lint-markdown: ## Lint Markdown files with markdownlint
	@echo "$(CYAN)Linting Markdown files...$(RESET)"
	@if [ -n "$(MD_FILES)" ]; then \
		if [ -f ".markdownlint.json" ]; then \
			markdownlint --config .markdownlint.json $(MD_FILES); \
		else \
			markdownlint $(MD_FILES); \
		fi && \
		echo "$(GREEN)✓ Markdown files passed linting$(RESET)"; \
	else \
		echo "$(YELLOW)No Markdown files found$(RESET)"; \
	fi

lint-js: ## Lint JavaScript files with ESLint
	@echo "$(CYAN)Linting JavaScript files...$(RESET)"
	@JS_FILES=$$(find . -type f -name "*.js" ! -path "*/\.*" ! -path "*/node_modules/*"); \
	if [ -n "$$JS_FILES" ]; then \
		if [ -f ".eslintrc.json" ]; then \
			eslint $$JS_FILES; \
		else \
			eslint --config .eslintrc.json $$JS_FILES; \
		fi && \
		echo "$(GREEN)✓ JavaScript files passed linting$(RESET)"; \
	else \
		echo "$(YELLOW)No JavaScript files found$(RESET)"; \
	fi

##@ Git Commits

commit: ## Create a conventional commit with commitizen
	@echo "$(CYAN)Creating conventional commit...$(RESET)"
	@if command -v cz >/dev/null 2>&1; then \
		cz commit; \
	elif command -v git-cz >/dev/null 2>&1; then \
		git-cz; \
	else \
		echo "$(RED)Commitizen not installed. Run 'make install-tools' first.$(RESET)"; \
		exit 1; \
	fi

commit-msg-check: ## Check last commit message follows conventional commits
	@echo "$(CYAN)Checking commit message...$(RESET)"
	@if command -v commitlint >/dev/null 2>&1; then \
		git log -1 --pretty=format:"%s" | commitlint && \
		echo "$(GREEN)✓ Commit message is valid$(RESET)"; \
	else \
		echo "$(YELLOW)commitlint not installed. Skipping check.$(RESET)"; \
	fi

##@ Pre-commit Checks

pre-commit-run: ## Run pre-commit hooks on all files
	@echo "$(CYAN)Running pre-commit hooks...$(RESET)"
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo "$(RED)pre-commit not installed. Run 'make install-tools' first.$(RESET)"; \
		exit 1; \
	fi

pre-commit: check-syntax lint ## Run all pre-commit checks (syntax + lint)
	@echo "$(GREEN)✓ All pre-commit checks passed$(RESET)"

ci: check-syntax lint ## Run CI checks (syntax + lint)
	@echo "$(GREEN)✓ All CI checks passed$(RESET)"

##@ Testing & Validation

test: pre-commit ## Run all tests and validation
	@echo "$(GREEN)✓ All tests passed$(RESET)"

validate: check-syntax ## Validate all file syntax
	@echo "$(GREEN)✓ All files validated$(RESET)"

##@ Cleanup

clean: ## Remove temporary files and caches
	@echo "$(CYAN)Cleaning up...$(RESET)"
	@find . -type f -name "*.pyc" -delete
	@find . -type d -name "__pycache__" -delete
	@find . -type d -name ".pytest_cache" -delete
	@find . -type d -name ".mypy_cache" -delete
	@SYNC_FILES=$$(find . -type f -name "*.sync-conflict-*" 2>/dev/null | wc -l | tr -d ' '); \
	if [ $$SYNC_FILES -gt 0 ]; then \
		echo "$(YELLOW)Found $$SYNC_FILES sync-conflict file(s)$(RESET)"; \
		find . -type f -name "*.sync-conflict-*" 2>/dev/null; \
		read -p "Delete sync-conflict files? [y/N] " -n 1 -r; \
		echo; \
		if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
			find . -type f -name "*.sync-conflict-*" -delete; \
			echo "$(GREEN)✓ Sync-conflict files deleted$(RESET)"; \
		else \
			echo "$(YELLOW)Sync-conflict files kept$(RESET)"; \
		fi; \
	fi
	@echo "$(GREEN)✓ Cleanup complete$(RESET)"

##@ Task Integration

task-%: ## Run any taskfile task (e.g., make task-setup)
	@task $(subst task-,,$@)

tasks: ## List all available tasks from taskfile
	@task --list
