CHECK_TARGETS := check-script-headers check-shell-syntax check-zsh-syntax check-python-syntax \
	check-yaml-syntax check-json-syntax lint-shell lint-python \
	lint-yaml lint-markdown lint-js
FORMAT_TARGETS := format-shell format-python format-yaml format-json format-markdown

.PHONY: help install setup deploy configure patch uninstall check test test-fast \
	test-integration format clean \
	check-tools check-syntax lint ci validate pre-commit pre-commit-run commit \
	commit-msg-check $(CHECK_TARGETS) $(FORMAT_TARGETS)
.DEFAULT_GOAL := help

JSH_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OUTPUT := for library_file in "$(JSH_ROOT)"/lib/*; do \
	[ -f "$$library_file" ] && [ -x "$$library_file" ] || continue; \
	. "$$library_file"; \
done; unset library_file;
PLATFORM ?= $(shell os=$$(uname -s); \
	if [ "$$os" = Darwin ]; then printf darwin; \
	elif [ "$$os" = Linux ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then printf wsl; \
	elif [ "$$os" = Linux ]; then printf linux; \
	else printf unsupported; fi)

PLATFORM_DIRS_darwin := unix darwin
PLATFORM_DIRS_linux := unix linux
PLATFORM_DIRS_wsl := unix linux windows
PLATFORM_DIRS := $(PLATFORM_DIRS_$(PLATFORM))

define run_scripts
	@$(OUTPUT) if [ -z "$(PLATFORM_DIRS)" ]; then \
		jsh_error "Unsupported platform: $(PLATFORM)"; \
		exit 1; \
	fi
	@$(OUTPUT) set -e; \
	first_script=1; \
	for action in $(1); do \
		for platform in $(PLATFORM_DIRS); do \
			dir="$(JSH_ROOT)/scripts/$$platform/$$action"; \
			[ -d "$$dir" ] || continue; \
			for script in "$$dir"/*; do \
				[ -f "$$script" ] && [ -x "$$script" ] || continue; \
				[ "$$first_script" -eq 1 ] || jsh_blank; \
				first_script=0; \
				jsh_info "Running $$script"; \
				"$$script"; \
			done; \
		done; \
	done
endef

# Tool versions (can be overridden)
PYTHON := python3
YAMLLINT_CONFIG := dotfiles/.yamllint

# Find files by type
# Shell files: Find by .sh extension OR by shebang in bin/ directory
SHELL_FILES := $(shell find . -type f -name "*.sh" ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "./local/vendor/*" ! -path "./tmp/*" ! -path "*/.config/*"; \
	find bin -type f 2>/dev/null | while read -r f; do head -n1 "$$f" 2>/dev/null | grep -qE '^\#!/usr/bin/env bash|^\#!/bin/(ba)?sh' && echo "$$f"; done)
ZSH_FILES := $(shell find . -type f \( -name "*.zsh" -o -name ".zshrc" \) ! -path "*/.git/*" ! -path "./local/vendor/*" ! -path "./tmp/*")
SCRIPT_FILES := $(shell find scripts -type f \( -name "*.sh" -o -name "*.zsh" \) | sort)
BATS_TEST_FILES := $(shell find tests -type f \( -name "*.bats" -o -name "*.bash" \) 2>/dev/null)
FAST_TEST_FILES := tests/commands.bats tests/completions.bats tests/jstow.bats \
	tests/platform-safety.bats
INTEGRATION_TEST_FILES := tests/jsh-runtime.bats tests/jssh.bats
PYTHON_FILES := $(shell find . -type f -name "*.py" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/.venv/*" ! -path "./local/vendor/*" ! -path "./tmp/*"; \
	find bin -type f 2>/dev/null | while read -r f; do head -n1 "$$f" 2>/dev/null | grep -qE '^\#!/usr/bin/env python3?' && echo "$$f"; done)
YAML_FILES := $(shell find . -type f \( -name "*.yaml" -o -name "*.yml" \) ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "./local/vendor/*" ! -path "./tmp/*")
JSON_FIND := find . -type f -name "*.json" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/package*.json" ! -path "./local/*" ! -path "./tmp/*"
JSON_FILES := $(shell $(JSON_FIND))
MD_FILES := $(shell find . -type f -name "*.md" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "./local/vendor/*" ! -path "./tmp/*")

##@ General

help: ## Show this help message
	@$(OUTPUT) jsh_info "Available targets:"
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { section = substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*## / { \
			if (section != shown) { printf "\n%s\n", section; shown = section } \
			printf "  %-20s %s\n", $$1, $$2 \
		}' $(MAKEFILE_LIST)

##@ Setup

install: ## Install packages and repository hooks
	$(call run_scripts,install)

deploy: ## Deploy dotfiles and command links
	$(call run_scripts,deploy)

configure: ## Configure the current platform
	$(call run_scripts,configure)

patch: ## Apply patches for the current platform
	$(call run_scripts,patch)

setup: ## Run full platform setup
	$(call run_scripts,deploy install configure patch)

uninstall: ## Remove dotfile links managed by jstow
	@$(OUTPUT) jsh_prompt "Remove managed dotfile links from $(HOME)? [y/N]: "; \
	read -r confirm || confirm=; \
	case $$confirm in \
		[Yy]) ;; \
		*) jsh_warn "Skipping uninstall."; exit 0 ;; \
	esac; \
	bash "$(JSH_ROOT)/bin/jstow" --delete --dir "$(JSH_ROOT)" --target "$(HOME)" dotfiles

##@ Testing

test: test-fast test-integration ## Run all behavior tests

test-fast: ## Run fast command and filesystem contracts
	@bats $(FAST_TEST_FILES)

test-integration: ## Run shell runtime and remote integration contracts
	@bats $(INTEGRATION_TEST_FILES)

##@ Formatting

format: $(FORMAT_TARGETS) ## Format all files

format-shell: # Format shell scripts
	@$(OUTPUT) jsh_info "Formatting shell scripts..."
	@$(OUTPUT) if [ -n "$(SHELL_FILES)" ]; then \
		shfmt -w -i 2 -ci -sr $(SHELL_FILES) && \
		jsh_success "Shell scripts formatted"; \
	else \
		jsh_warn "No shell files found"; \
	fi

format-python: # Format Python files
	@$(OUTPUT) jsh_info "Formatting Python files..."
	@$(OUTPUT) if [ -n "$(PYTHON_FILES)" ]; then \
		black --line-length 100 $(PYTHON_FILES) && \
		jsh_success "Python files formatted"; \
	else \
		jsh_warn "No Python files found"; \
	fi

format-yaml: # Format YAML files
	@$(OUTPUT) jsh_info "Formatting YAML files..."
	@$(OUTPUT) if [ -n "$(YAML_FILES)" ]; then \
		prettier --write --print-width 100 $(YAML_FILES) && \
		jsh_success "YAML files formatted"; \
	else \
		jsh_warn "No YAML files found"; \
	fi

format-json: # Format JSON files
	@$(OUTPUT) jsh_info "Formatting JSON files..."
	@$(OUTPUT) if [ -n "$(JSON_FILES)" ]; then \
		prettier --write $(JSON_FILES) && \
		jsh_success "JSON files formatted"; \
	else \
		jsh_warn "No JSON files found"; \
	fi

format-markdown: # Format Markdown files
	@$(OUTPUT) jsh_info "Formatting Markdown files..."
	@$(OUTPUT) if [ -n "$(MD_FILES)" ]; then \
		prettier --write --prose-wrap always $(MD_FILES) && \
		jsh_success "Markdown files formatted"; \
	else \
		jsh_warn "No Markdown files found"; \
	fi

##@ Checking

check: $(CHECK_TARGETS) ## Run all checks

check-tools: ## Check required developer tools
	@$(OUTPUT) jsh_info "Checking for required tools..."
	@$(OUTPUT) errors=0; \
	for tool in actionlint autopep8 bats black commitlint cz eslint gitleaks hadolint jq \
		markdownlint pre-commit prettier pylint shellcheck shfmt stow yamllint yq; do \
		if command -v $$tool >/dev/null 2>&1; then \
			jsh_success "$$tool"; \
		else \
			jsh_error "$$tool (missing)"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -gt 0 ]; then \
		jsh_warn "Run 'make install' to install missing tools"; \
		exit 1; \
	fi

check-script-headers: # Check setup script headers
	@$(OUTPUT) jsh_info "Checking setup script headers..."
	@$(OUTPUT) errors=0; \
	for script in $(SCRIPT_FILES); do \
		case "$$script" in \
			*.sh) expected='#!/usr/bin/env bash' ;; \
			*.zsh) expected='#!/usr/bin/env zsh' ;; \
		esac; \
		if [ "$$(sed -n '1p' "$$script")" != "$$expected" ]; then \
			jsh_error "Invalid shebang: $$script"; \
			errors=$$((errors + 1)); \
		fi; \
		if ! sed -n '2p' "$$script" | grep -Eq '^# [[:alnum:]]'; then \
			jsh_error "Missing description: $$script"; \
			errors=$$((errors + 1)); \
		fi; \
		if ! sed -n '1,20p' "$$script" | grep -Fq '/lib/*; do' || \
			! sed -n '1,20p' "$$script" | grep -Fq '[[ -f $${library_file} && -x $${library_file} ]] || continue' || \
			! sed -n '1,20p' "$$script" | grep -Fq '. "$${library_file}"'; then \
			jsh_error "Missing dynamic library import: $$script"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -eq 0 ]; then \
		jsh_success "Setup script headers are standardized"; \
	else \
		jsh_error "Found $$errors setup script header error(s)"; \
		exit 1; \
	fi

check-syntax: check-shell-syntax check-zsh-syntax check-python-syntax check-yaml-syntax check-json-syntax ## Check all supported file syntax

check-shell-syntax: # Check Bash syntax
	@$(OUTPUT) jsh_info "Checking shell script syntax..."
	@$(OUTPUT) if [ -n "$(SHELL_FILES)" ]; then \
		errors=0; \
		for file in $(SHELL_FILES); do \
			bash -n "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh_success "All shell scripts have valid syntax"; \
		else \
			jsh_error "Found $$errors shell script(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh_warn "No shell files found"; \
	fi

check-zsh-syntax: # Check Zsh syntax
	@$(OUTPUT) jsh_info "Checking Zsh syntax..."
	@$(OUTPUT) if [ -n "$(ZSH_FILES)" ]; then \
		errors=0; \
		for file in $(ZSH_FILES); do \
			zsh -n "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh_success "All Zsh files have valid syntax"; \
		else \
			jsh_error "Found $$errors Zsh file(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh_warn "No Zsh files found"; \
	fi

check-python-syntax: # Check Python syntax
	@$(OUTPUT) jsh_info "Checking Python syntax..."
	@$(OUTPUT) if [ -n "$(PYTHON_FILES)" ]; then \
		errors=0; \
		for file in $(PYTHON_FILES); do \
			$(PYTHON) -c 'import ast, sys, tokenize; path = sys.argv[1]; source = tokenize.open(path).read(); ast.parse(source, filename=path)' "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh_success "All Python files have valid syntax"; \
		else \
			jsh_error "Found $$errors Python file(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh_warn "No Python files found"; \
	fi

check-yaml-syntax: # Check YAML syntax
	@$(OUTPUT) jsh_info "Checking YAML syntax..."
	@$(OUTPUT) if [ -n "$(YAML_FILES)" ]; then \
		errors=0; \
		for file in $(YAML_FILES); do \
			$(PYTHON) -c "import yaml; yaml.safe_load(open('$$file'))" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh_success "All YAML files have valid syntax"; \
		else \
			jsh_error "Found $$errors YAML file(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh_warn "No YAML files found"; \
	fi

check-json-syntax: # Check JSON syntax
	@$(OUTPUT) jsh_info "Checking JSON syntax..."
	@$(OUTPUT) if [ -n "$(JSON_FILES)" ]; then \
		if $(JSON_FIND) -print0 | xargs -0 sh -c '\
			. "$$1"; shift; \
			errors=0; \
			for file do \
				if ! output="$$($(PYTHON) -m json.tool "$$file" 2>&1 > /dev/null)"; then \
					jsh_error "$$file"; \
					jsh_detail "  $$output"; \
					errors=$$((errors + 1)); \
				fi; \
			done; \
			[ $$errors -eq 0 ]' sh "$(OUTPUT_LIB)"; then \
			jsh_success "All JSON files have valid syntax"; \
		else \
			jsh_error "JSON syntax check failed"; \
			exit 1; \
		fi; \
	else \
		jsh_warn "No JSON files found"; \
	fi

##@ Linting

lint: lint-shell lint-python lint-yaml lint-markdown lint-js ## Run all linters

lint-shell: # Lint shell scripts with shellcheck
	@$(OUTPUT) jsh_info "Linting shell scripts..."
	@$(OUTPUT) if [ -n "$(SHELL_FILES) $(BATS_TEST_FILES)" ]; then \
		shellcheck -x -S warning $(SHELL_FILES) $(BATS_TEST_FILES) && \
		jsh_success "Shell scripts passed linting"; \
	else \
		jsh_warn "No shell files found"; \
	fi

lint-python: # Lint Python files with pylint
	@$(OUTPUT) jsh_info "Linting Python files..."
	@$(OUTPUT) if [ -n "$(PYTHON_FILES)" ]; then \
		pylint --rcfile=.pylintrc $(PYTHON_FILES) 2>/dev/null || \
		pylint $(PYTHON_FILES) && \
		jsh_success "Python files passed linting"; \
	else \
		jsh_warn "No Python files found"; \
	fi

lint-yaml: # Lint YAML files with yamllint
	@$(OUTPUT) jsh_info "Linting YAML files..."
	@$(OUTPUT) if [ -n "$(YAML_FILES)" ]; then \
		if [ -f "$(YAMLLINT_CONFIG)" ]; then \
			yamllint -c $(YAMLLINT_CONFIG) $(YAML_FILES); \
		else \
			yamllint $(YAML_FILES); \
		fi && \
		jsh_success "YAML files passed linting"; \
	else \
		jsh_warn "No YAML files found"; \
	fi

lint-markdown: # Lint Markdown files with markdownlint
	@$(OUTPUT) jsh_info "Linting Markdown files..."
	@$(OUTPUT) if [ -n "$(MD_FILES)" ]; then \
		if [ -f ".markdownlint.json" ]; then \
			markdownlint --config .markdownlint.json $(MD_FILES); \
		else \
			markdownlint $(MD_FILES); \
		fi && \
		jsh_success "Markdown files passed linting"; \
	else \
		jsh_warn "No Markdown files found"; \
	fi

lint-js: # Lint JavaScript files with ESLint
	@$(OUTPUT) jsh_info "Linting JavaScript files..."
	@$(OUTPUT) JS_FILES=$$(find . -type f -name "*.js" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "./local/vendor/*"); \
	if [ -n "$$JS_FILES" ]; then \
		eslint $$JS_FILES && \
		jsh_success "JavaScript files passed linting"; \
	else \
		jsh_warn "No JavaScript files found"; \
	fi

##@ Git Commits

commit: ## Create a conventional commit with commitizen
	@$(OUTPUT) jsh_info "Creating conventional commit..."
	@$(OUTPUT) if command -v cz >/dev/null 2>&1; then \
		cz commit; \
	elif command -v git-cz >/dev/null 2>&1; then \
		git-cz; \
	else \
		jsh_error "Commitizen not installed. Run 'make install' first."; \
		exit 1; \
	fi

commit-msg-check: ## Check the latest commit message
	@$(OUTPUT) jsh_info "Checking commit message..."
	@$(OUTPUT) if command -v commitlint >/dev/null 2>&1; then \
		git log -1 --pretty=format:"%s" | commitlint && \
		jsh_success "Commit message is valid"; \
	else \
		jsh_warn "commitlint not installed. Skipping check."; \
	fi

##@ Pre-commit Checks

pre-commit-run: ## Run pre-commit hooks on all files
	@$(OUTPUT) jsh_info "Running pre-commit hooks..."
	@$(OUTPUT) if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		jsh_error "pre-commit not installed. Run 'make install' first."; \
		exit 1; \
	fi

pre-commit: check ## Run checks used by pre-commit

##@ Validation

ci: check test ## Run CI checks and tests

validate: check test ## Run all checks and tests

##@ Cleanup

clean: ## Remove temporary files and caches
	@$(OUTPUT) jsh_info "Cleaning up..."
	@find . -type f -name "*.pyc" ! -path "./local/vendor/*" -delete
	@find . -type d -name "__pycache__" ! -path "./local/vendor/*" -delete
	@find . -type d -name ".pytest_cache" ! -path "./local/vendor/*" -delete
	@find . -type d -name ".mypy_cache" ! -path "./local/vendor/*" -delete
	@$(OUTPUT) jsh_success "Cleanup complete"
