# Local checks only: nothing here installs software or changes application settings.
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

SHELL_FILES := install.sh $(shell find scripts lib -type f -name '*.sh') \
  $(shell for file in bin/*; do [ -f "$$file" ] || continue; if head -n 1 "$$file" | grep -Eq 'sh$$'; then printf '%s ' "$$file"; fi; done)
BASH_RC := dotfiles/.bashrc dotfiles/.bash_profile
ZSH_FILES := dotfiles/.zshrc

.PHONY: help check syntax lint test-shell fmt hooks
help:
	@printf '%s\n' 'make check   Syntax, ShellCheck, and isolated shell smoke checks' \
	  'make syntax  Parse shell files and Python bin commands' \
	  'make lint    ShellCheck Bash/POSIX shell files' \
	  'make test-shell  Interactive Bash and Zsh smoke checks in temporary homes' \
	  'make fmt     Format Bash/POSIX shell files with shfmt' \
	  'make hooks   Run pre-commit hooks'

check: syntax lint test-shell
syntax:
	@for file in $(SHELL_FILES) $(BASH_RC); do bash -n "$$file"; done
	@for file in $(ZSH_FILES); do zsh -n "$$file"; done
	@for file in lib/shell/commands.sh lib/shell/navigation.sh; do zsh -n "$$file"; done
	@cache=$$(mktemp -d); trap 'rm -rf -- "$$cache"' EXIT; \
	  PYTHONPYCACHEPREFIX="$$cache" python3 -m py_compile lib/git/*.py bin/cafe bin/microphone scripts/check.py
lint:
	shellcheck -x --severity=warning $(SHELL_FILES) $(BASH_RC)
test-shell:
	python3 scripts/check.py
fmt:
	shfmt --write $(SHELL_FILES) $(BASH_RC)
hooks:
	pre-commit run --all-files
