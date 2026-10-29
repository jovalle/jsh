# Development checks. Machine setup runs through ./j.sh (jsh); see ./j.sh --help.
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
export PYTHONDONTWRITEBYTECODE := 1
# The first Python 3.9+, matching ./j.sh.
PYTHON := $(shell for p in python3 python3.14 python3.13 python3.12 python3.11; do \
  $$p -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null && { command -v $$p; break; }; done)

SHELL_FILES := bin/jsh bin/git j.sh lib/core.sh lib/output.sh \
  $(shell find modules -type f -name '*.sh' -not -path '*/home/*' -not -path 'modules/skills/*')
ZSH_FILES := modules/shell/home/.zshrc modules/shell/completions/_jsh lib/j.zsh lib/prompt.zsh \
  lib/startup.zsh
PYTHON_FILES := $(shell find lib modules tests -type f -name '*.py')

.PHONY: help check syntax headers readme modules lint test hooks

help:
	@printf '%s\n' \
	  'make check    Run syntax, headers, readme, modules, lint, and test' \
	  'make syntax   Parse every shell, zsh, Python, and JSON file' \
	  'make headers  Require the standard header on module scripts' \
	  'make readme   Require a README entry for every bin/ command' \
	  'make modules  Load every module.json and plan it for each platform' \
	  'make lint     Run shellcheck, pylint, yamllint, and markdownlint' \
	  'make test     Run the Python unittest suite' \
	  'make hooks    Run the pre-commit hooks on every file'

check: syntax headers readme modules lint test

syntax:
	@for file in $(SHELL_FILES); do bash -n "$$file"; done
	@for file in $(ZSH_FILES); do zsh -n "$$file"; done
	@$(PYTHON) -c 'import sys; [compile(open(p).read(), p, "exec") for p in sys.argv[1:]]' $(PYTHON_FILES)
	@$(PYTHON) -c 'import json, sys; [json.load(open(p)) for p in sys.argv[1:]]' \
	  $$(find modules -name '*.json' -not -path '*/home/*')

headers:
	@for file in modules/*/*.sh; do \
	  [[ $$(head -n 1 "$$file") == '#!/usr/bin/env bash' ]] && \
	    sed -n '2p' "$$file" | grep -Eq '^# [[:alnum:]]' && \
	    grep -Fq '. "$${JSH_ROOT}/lib/core.sh"' "$$file" || \
	    { echo "Missing script header: $$file" >&2; exit 1; }; \
	done

readme:
	@for file in bin/*; do \
	  [[ ! -f $$file ]] || grep -Fq "]($$file)" README.md || \
	    { echo "Undocumented command: $$file" >&2; exit 1; }; \
	done

modules:
	@PYTHONPATH=lib $(PYTHON) -c 'from jsh import modules, runner, system; \
	  found = modules.discover(); names = [m.name for m in found]; \
	  [runner.plan(found, (p,), system.Facts(platform=os, desktop=d, host="check"), names) \
	   for os, desks in (("darwin", ("darwin",)), ("debian", ("", "gnome", "xfce")), ("rhel", ("", "xfce"))) \
	   for d in desks for p in ("install", "link", "configure", "update")]; \
	  print(f"{len(found)} modules OK")'

lint:
	shellcheck --severity=warning $(SHELL_FILES)
	pylint --persistent=no $(PYTHON_FILES)
	yamllint -c .yamllint .pre-commit-config.yaml
	markdownlint README.md AGENTS.md

test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' < /dev/null

hooks:
	pre-commit run --all-files
