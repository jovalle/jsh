CHECK_TARGETS := check-script-headers check-readme check-shell-syntax check-zsh-syntax check-python-syntax \
	check-yaml-syntax check-json-syntax lint-shell lint-python \
	lint-yaml lint-markdown lint-js test-reconciliation
FORMAT_TARGETS := format-shell format-python format-yaml format-json format-markdown

.PHONY: help install essentials update setup deploy configure patch hooks uninstall preview check \
	format clean \
	check-tools check-syntax lint ci validate pre-commit pre-commit-run commit \
	commit-msg-check $(CHECK_TARGETS) $(FORMAT_TARGETS)
.DEFAULT_GOAL := help

SHELL := /bin/bash

JSH_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
HASH := \#
UI_LIB := $(JSH_ROOT)/lib/ui.sh
OUTPUT := . "$(UI_LIB)";
PLATFORM ?= $(shell os=$$(uname -s); \
	if [ "$$os" = Darwin ]; then printf darwin; \
	elif [ "$$os" = Linux ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then printf wsl; \
	elif [ "$$os" = Linux ]; then printf linux; \
	else printf unsupported; fi)

PLATFORM_DIRS_darwin := unix darwin
PLATFORM_DIRS_linux := unix linux
PLATFORM_DIRS_wsl := unix linux windows
PLATFORM_DIRS := $(PLATFORM_DIRS_$(PLATFORM))
SCRIPT_BASENAME ?=

define run_scripts
	@$(OUTPUT) if [ -z "$(PLATFORM_DIRS)" ]; then \
		jsh::log_error "Unsupported platform: $(PLATFORM)"; \
		exit 1; \
	fi
	@$(OUTPUT) LC_ALL=C; export LC_ALL; failed_scripts=0; script_status=0; \
	setup_interrupt_report=$${JSH_INTERRUPT_REPORT:-1}; \
	trap 'trap - HUP INT TERM; exit 129' HUP; \
	trap 'trap - HUP INT TERM; [ "$$setup_interrupt_report" -ne 1 ] || printf "\nInterrupted.\n" >&2; exit 130' INT; \
	trap 'trap - HUP INT TERM; exit 143' TERM; \
	JSH_INTERRUPT_REPORT=0; export JSH_INTERRUPT_REPORT; \
	first_script=1; \
	for action in $(1); do \
		action_platforms="$(PLATFORM_DIRS)"; \
		if [ "$$action" = install ]; then \
			action_platforms="$(filter-out unix,$(PLATFORM_DIRS)) unix"; \
		fi; \
		for platform in $$action_platforms; do \
			dir="$(JSH_ROOT)/scripts/$$platform/$$action"; \
			[ -d "$$dir" ] || continue; \
			for script in "$$dir"/*; do \
				[ -f "$$script" ] && [ -x "$$script" ] || continue; \
				[ -z "$(SCRIPT_BASENAME)" ] || [ "$${script##*/}" = "$(SCRIPT_BASENAME)" ] || continue; \
				case "$$script" in \
					*sync-conflict*) continue ;; \
					*.sh|*.zsh) ;; \
					*) continue ;; \
				esac; \
				[ "$$first_script" -eq 1 ] || jsh_blank; \
				first_script=0; \
				jsh::status info "Running $$script"; \
				if "$$script"; then \
					:; \
				else \
					script_status=$$?; \
					if [ "$$script_status" -eq 129 ] || [ "$$script_status" -eq 130 ] || [ "$$script_status" -eq 143 ]; then \
						[ "$$script_status" -ne 130 ] || [ "$$setup_interrupt_report" -ne 1 ] || printf '\nInterrupted.\n' >&2; \
						exit "$$script_status"; \
					fi; \
					if [ "$${JSH_CONTINUE_ON_ERROR:-0}" = 1 ]; then \
						jsh::status error "Failed: $$script"; \
						failed_scripts=$$((failed_scripts + 1)); \
					else \
						exit "$$script_status"; \
					fi; \
				fi; \
			done; \
		done; \
	done; \
	[ "$$failed_scripts" -eq 0 ]
endef

# Tool versions (can be overridden)
PYTHON := python3
BATS ?= bats
YAMLLINT_CONFIG := dotfiles/.yamllint

# Find files by type
# Shell files: Find by .sh extension OR by shebang in bin/ directory
SHELL_FILES := $(shell find . -type f -name "*.sh" ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "./local/vendor/*" ! -path "./tmp/*" ! -path "*/.config/*" ! -name "*sync-conflict*"; \
	find bin -type f 2>/dev/null | while read -r f; do head -n1 "$$f" 2>/dev/null | grep -qE '^$(HASH)!/usr/bin/env bash|^$(HASH)!/bin/(ba)?sh' && echo "$$f"; done)
ZSH_FILES := $(shell find . -type f \( -name "*.zsh" -o -name ".zshrc" \) ! -path "*/.git/*" ! -path "./local/vendor/*" ! -path "./tmp/*" ! -name "*sync-conflict*")
SCRIPT_FILES := $(shell find scripts -type f \( -name "*.sh" -o -name "*.zsh" \) ! -name "*sync-conflict*" | sort)
PYTHON_FILES := $(shell find . -type f -name "*.py" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/.venv/*" ! -path "./local/*" ! -path "./tmp/*" ! -name "*sync-conflict*"; \
	find bin -type f 2>/dev/null | while read -r f; do head -n1 "$$f" 2>/dev/null | grep -qE '^$(HASH)!/usr/bin/env python3?' && echo "$$f"; done)
YAML_FILES := $(shell find . -type f \( -name "*.yaml" -o -name "*.yml" \) ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "./local/vendor/*" ! -path "./tmp/*" ! -name "*sync-conflict*")
JSON_FIND := find . -type f -name "*.json" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "*/package*.json" ! -path "./local/*" ! -path "./tmp/*" ! -name "*sync-conflict*"
JSON_FILES := $(shell $(JSON_FIND))
MD_FILES := $(shell find . -type f -name "*.md" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "./graphify-out/*" ! -path "./local/vendor/*" ! -path "./tmp/*" ! -name "*sync-conflict*")

##@ General

help: ## Show this help message
	@$(OUTPUT) jsh::log_info "Available targets:"
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { section = substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*## / { \
			if (section != shown) { printf "\n%s\n", section; shown = section } \
			printf "  %-20s %s\n", $$1, $$2 \
		}' $(MAKEFILE_LIST)

##@ Setup

install: ## Install packages and platform applications
	$(call run_scripts,install)

essentials: export JSH_PACKAGE_LAYERS = core
essentials: SCRIPT_BASENAME = packages.sh
essentials: ## Install only the core shell package layer
	$(call run_scripts,install)

update: ## Update packages, dependencies, and managed configuration
	@"$(JSH_ROOT)/bin/jsh" update

deploy: ## Deploy dotfiles and command links
	$(call run_scripts,deploy)

configure: ## Configure the current platform
	$(call run_scripts,configure)

patch: ## Apply patches for the current platform
	$(call run_scripts,patch)

setup: ## Discover and run the current platform setup
	$(call run_scripts,install deploy configure)

hooks: ## Install repository hooks
	@"$(JSH_ROOT)/scripts/development/hooks.sh"

uninstall: ## Remove dotfile links managed by jstow
	@$(OUTPUT) if ! jsh::confirm "Remove managed dotfile links from $(HOME)?" --default no; then \
		jsh::log_warn "Skipping uninstall."; exit 0; \
	fi; \
	bash "$(JSH_ROOT)/bin/jstow" --delete --dir "$(JSH_ROOT)" --target "$(HOME)" dotfiles

##@ Documentation

preview: ## Open generated architecture diagrams
	@$(OUTPUT) diagram_dir="$(JSH_ROOT)/docs/architecture"; \
	set -- "$$diagram_dir"/*.html; \
	if [ ! -e "$$1" ]; then \
		jsh::log_error "No generated architecture diagrams found in $$diagram_dir."; \
		exit 1; \
	fi; \
	case "$(PLATFORM)" in \
		darwin) opener=open ;; \
		linux) opener=xdg-open ;; \
		*) jsh::log_error "Opening diagrams is unsupported on $(PLATFORM)."; exit 1 ;; \
	esac; \
	command -v "$$opener" >/dev/null 2>&1 || { jsh::log_error "$$opener is unavailable."; exit 1; }; \
	for diagram in "$$@"; do "$$opener" "$$diagram"; done

##@ Formatting

format: $(FORMAT_TARGETS) ## Format all files

format-shell: # Format shell scripts
	@$(OUTPUT) jsh::log_info "Formatting shell scripts..."
	@$(OUTPUT) if [ -n "$(SHELL_FILES)" ]; then \
		shfmt -w -i 2 -ci -sr $(SHELL_FILES) && \
		jsh::log_success "Shell scripts formatted"; \
	else \
		jsh::log_warn "No shell files found"; \
	fi

format-python: # Format Python files
	@$(OUTPUT) jsh::log_info "Formatting Python files..."
	@$(OUTPUT) if [ -n "$(PYTHON_FILES)" ]; then \
		black --line-length 100 $(PYTHON_FILES) && \
		jsh::log_success "Python files formatted"; \
	else \
		jsh::log_warn "No Python files found"; \
	fi

format-yaml: # Format YAML files
	@$(OUTPUT) jsh::log_info "Formatting YAML files..."
	@$(OUTPUT) if [ -n "$(YAML_FILES)" ]; then \
		prettier --write --print-width 100 $(YAML_FILES) && \
		jsh::log_success "YAML files formatted"; \
	else \
		jsh::log_warn "No YAML files found"; \
	fi

format-json: # Format JSON files
	@$(OUTPUT) jsh::log_info "Formatting JSON files..."
	@$(OUTPUT) if [ -n "$(JSON_FILES)" ]; then \
		prettier --write $(JSON_FILES) && \
		jsh::log_success "JSON files formatted"; \
	else \
		jsh::log_warn "No JSON files found"; \
	fi

format-markdown: # Format Markdown files
	@$(OUTPUT) jsh::log_info "Formatting Markdown files..."
	@$(OUTPUT) if [ -n "$(MD_FILES)" ]; then \
		prettier --write --prose-wrap always $(MD_FILES) && \
		jsh::log_success "Markdown files formatted"; \
	else \
		jsh::log_warn "No Markdown files found"; \
	fi

##@ Checking

check: $(CHECK_TARGETS) ## Run all checks

check-tools: ## Check required developer tools
	@$(OUTPUT) jsh::log_info "Checking for required tools..."
	@$(OUTPUT) errors=0; \
	for tool in actionlint autopep8 bats black check-added-large-files commitlint cz eslint gitleaks hadolint jq \
		markdownlint pre-commit prettier pylint shellcheck shfmt stow yamllint yq; do \
		if command -v $$tool >/dev/null 2>&1; then \
			jsh::log_success "$$tool"; \
		else \
			jsh::log_error "$$tool (missing)"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -gt 0 ]; then \
		jsh::log_warn "Run 'make install' to install missing tools"; \
		exit 1; \
	fi

check-script-headers: # Check setup script headers
	@$(OUTPUT) jsh::log_info "Checking setup script headers..."
	@$(OUTPUT) errors=0; \
	for script in $(SCRIPT_FILES); do \
		case "$$script" in \
			*.sh) expected='#!/usr/bin/env bash' ;; \
			*.zsh) expected='#!/usr/bin/env zsh' ;; \
		esac; \
		if [ "$$(sed -n '1p' "$$script")" != "$$expected" ]; then \
			jsh::log_error "Invalid shebang: $$script"; \
			errors=$$((errors + 1)); \
		fi; \
		if ! sed -n '2p' "$$script" | grep -Eq '^# [[:alnum:]]'; then \
			jsh::log_error "Missing description: $$script"; \
			errors=$$((errors + 1)); \
		fi; \
		if ! sed -n '1,20p' "$$script" | grep -Fq '/lib/*; do' || \
			! sed -n '1,20p' "$$script" | grep -Fq '[[ -f $${library_file} && -x $${library_file} ]] || continue' || \
			! sed -n '1,20p' "$$script" | grep -Fq '. "$${library_file}"'; then \
			jsh::log_error "Missing dynamic library import: $$script"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -eq 0 ]; then \
		jsh::log_success "Setup script headers are standardized"; \
	else \
		jsh::log_error "Found $$errors setup script header error(s)"; \
		exit 1; \
	fi

check-readme: # Check that every included command is documented
	@$(OUTPUT) jsh::log_info "Checking README bin coverage..."
	@$(OUTPUT) errors=0; \
	for file in $$(git ls-files 'bin/*'); do \
		if ! grep -Fq "](bin/$${file#bin/})" README.md; then \
			jsh::log_error "Missing README entry: $$file"; \
			errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -eq 0 ]; then \
		jsh::log_success "All included commands are documented"; \
	else \
		jsh::log_error "Found $$errors undocumented command(s)"; \
		exit 1; \
	fi

check-syntax: check-shell-syntax check-zsh-syntax check-python-syntax check-yaml-syntax check-json-syntax ## Check all supported file syntax

check-shell-syntax: # Check Bash syntax
	@$(OUTPUT) jsh::log_info "Checking shell script syntax..."
	@$(OUTPUT) if [ -n "$(SHELL_FILES)" ]; then \
		errors=0; \
		for file in $(SHELL_FILES); do \
			bash -n "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh::log_success "All shell scripts have valid syntax"; \
		else \
			jsh::log_error "Found $$errors shell script(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh::log_warn "No shell files found"; \
	fi

check-zsh-syntax: # Check Zsh syntax
	@$(OUTPUT) jsh::log_info "Checking Zsh syntax..."
	@$(OUTPUT) if [ -n "$(ZSH_FILES)" ]; then \
		errors=0; \
		for file in $(ZSH_FILES); do \
			zsh -n "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh::log_success "All Zsh files have valid syntax"; \
		else \
			jsh::log_error "Found $$errors Zsh file(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh::log_warn "No Zsh files found"; \
	fi

check-python-syntax: # Check Python syntax
	@$(OUTPUT) jsh::log_info "Checking Python syntax..."
	@$(OUTPUT) if [ -n "$(PYTHON_FILES)" ]; then \
		errors=0; \
		for file in $(PYTHON_FILES); do \
			$(PYTHON) -c 'import ast, sys, tokenize; path = sys.argv[1]; source = tokenize.open(path).read(); ast.parse(source, filename=path)' "$$file" 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh::log_success "All Python files have valid syntax"; \
		else \
			jsh::log_error "Found $$errors Python file(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh::log_warn "No Python files found"; \
	fi

check-yaml-syntax: # Check YAML syntax
	@$(OUTPUT) jsh::log_info "Checking YAML syntax..."
	@$(OUTPUT) if [ -n "$(YAML_FILES)" ]; then \
		errors=0; \
		for file in $(YAML_FILES); do \
			yq '.' "$$file" > /dev/null 2>&1 || errors=$$((errors + 1)); \
		done; \
		if [ $$errors -eq 0 ]; then \
			jsh::log_success "All YAML files have valid syntax"; \
		else \
			jsh::log_error "Found $$errors YAML file(s) with syntax errors"; \
			exit 1; \
		fi; \
	else \
		jsh::log_warn "No YAML files found"; \
	fi

check-json-syntax: # Check JSON syntax
	@$(OUTPUT) jsh::log_info "Checking JSON syntax..."
	@$(OUTPUT) if [ -n "$(JSON_FILES)" ]; then \
		if $(JSON_FIND) -print0 | xargs -0 bash -c '\
			. "$$1"; shift; \
			errors=0; \
			for file do \
				if ! output="$$($(PYTHON) -m json.tool "$$file" 2>&1 > /dev/null)"; then \
					jsh::log_error "$$file"; \
					jsh::log_detail "  $$output"; \
					errors=$$((errors + 1)); \
				fi; \
			done; \
			[ $$errors -eq 0 ]' bash "$(UI_LIB)"; then \
			jsh::log_success "All JSON files have valid syntax"; \
		else \
			jsh::log_error "JSON syntax check failed"; \
			exit 1; \
		fi; \
	else \
		jsh::log_warn "No JSON files found"; \
	fi

##@ Linting

lint: lint-shell lint-python lint-yaml lint-markdown lint-js ## Run all linters

lint-shell: # Lint shell scripts with shellcheck
	@$(OUTPUT) jsh::log_info "Linting shell scripts..."
	@$(OUTPUT) if [ -n "$(SHELL_FILES)" ]; then \
		shellcheck -x -S warning $(SHELL_FILES) && \
		jsh::log_success "Shell scripts passed linting"; \
	else \
		jsh::log_warn "No shell files found"; \
	fi

lint-python: # Lint Python files with pylint
	@$(OUTPUT) jsh::log_info "Linting Python files..."
	@$(OUTPUT) if [ -n "$(PYTHON_FILES)" ]; then \
		pylint --rcfile=.pylintrc $(PYTHON_FILES) 2>/dev/null || \
		pylint $(PYTHON_FILES) && \
		jsh::log_success "Python files passed linting"; \
	else \
		jsh::log_warn "No Python files found"; \
	fi

lint-yaml: # Lint YAML files with yamllint
	@$(OUTPUT) jsh::log_info "Linting YAML files..."
	@$(OUTPUT) if [ -n "$(YAML_FILES)" ]; then \
		if [ -f "$(YAMLLINT_CONFIG)" ]; then \
			yamllint -c $(YAMLLINT_CONFIG) $(YAML_FILES); \
		else \
			yamllint $(YAML_FILES); \
		fi && \
		jsh::log_success "YAML files passed linting"; \
	else \
		jsh::log_warn "No YAML files found"; \
	fi

lint-markdown: # Lint Markdown files with markdownlint
	@$(OUTPUT) jsh::log_info "Linting Markdown files..."
	@$(OUTPUT) if [ -n "$(MD_FILES)" ]; then \
		if [ -f ".markdownlint.json" ]; then \
			markdownlint --config .markdownlint.json $(MD_FILES); \
		else \
			markdownlint $(MD_FILES); \
		fi && \
		jsh::log_success "Markdown files passed linting"; \
	else \
		jsh::log_warn "No Markdown files found"; \
	fi

lint-js: # Lint JavaScript files with ESLint
	@$(OUTPUT) jsh::log_info "Linting JavaScript files..."
	@$(OUTPUT) JS_FILES=$$(find . -type f -name "*.js" ! -path "*/\.*" ! -path "*/node_modules/*" ! -path "./local/vendor/*" ! -path "./tmp/*"); \
	if [ -n "$$JS_FILES" ]; then \
		eslint $$JS_FILES && \
		jsh::log_success "JavaScript files passed linting"; \
	else \
		jsh::log_warn "No JavaScript files found"; \
	fi

##@ Git Commits

commit: ## Create a conventional commit with commitizen
	@$(OUTPUT) jsh::log_info "Creating conventional commit..."
	@$(OUTPUT) if command -v cz >/dev/null 2>&1; then \
		cz commit; \
	elif command -v git-cz >/dev/null 2>&1; then \
		git-cz; \
	else \
		jsh::log_error "Commitizen not installed. Run 'make install' first."; \
		exit 1; \
	fi

commit-msg-check: ## Check the latest commit message
	@$(OUTPUT) jsh::log_info "Checking commit message..."
	@$(OUTPUT) if command -v commitlint >/dev/null 2>&1; then \
		git log -1 --pretty=format:"%s" | commitlint && \
		jsh::log_success "Commit message is valid"; \
	else \
		jsh::log_warn "commitlint not installed. Skipping check."; \
	fi

##@ Pre-commit Checks

pre-commit-run: ## Run pre-commit hooks on all files
	@$(OUTPUT) jsh::log_info "Running pre-commit hooks..."
	@$(OUTPUT) if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		jsh::log_error "pre-commit not installed. Run 'make install' first."; \
		exit 1; \
	fi

pre-commit: check ## Run checks used by pre-commit

##@ Validation

ci: check ## Run CI checks

validate: check ## Run all checks

##@ Cleanup

clean: ## Remove temporary files and caches
	@$(OUTPUT) jsh::log_info "Cleaning up..."
	@find . -type f -name "*.pyc" ! -path "./local/vendor/*" -delete
	@find . -type d -name "__pycache__" ! -path "./local/vendor/*" -delete
	@find . -type d -name ".mypy_cache" ! -path "./local/vendor/*" -delete
	@find . -name "*sync-conflict-*" -delete
	@$(OUTPUT) jsh::log_success "Cleanup complete"

.PHONY: test-reconciliation
test-reconciliation: ## Test planning, completions, idempotency and platform adapters
	@$(BATS) tests/cafe.bats
	@$(BATS) tests/completions.bats
	@$(BATS) tests/env.bats
	@$(BATS) tests/helium.bats
	@$(BATS) tests/install.bats
	@$(BATS) tests/jgit.bats
	@$(BATS) tests/jgraphify.bats
	@$(BATS) tests/jmount.bats
	@$(BATS) tests/kubectx.bats
	@$(BATS) tests/linux.bats
	@$(BATS) tests/spotify.bats
	@$(BATS) tests/syncthing.bats
	@$(BATS) tests/ui.bats
	@$(BATS) tests/waterfox.bats
	@node --test tests/spotifix.test.js
	@PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py'
