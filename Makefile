# Setup shortcuts and local checks. Targets stay short and call
# scripts/configure.sh or one tool; setup logic lives in Ansible roles.
# Works with the GNU Make 3.81 that ships with macOS. Words after a command are its
# arguments: make configure helium waterfox, make check lint.

SHELL := /bin/bash
COMMANDS := help configure list check format

ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(COMMANDS)),)
ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
ifneq ($(ARGS),)
.PHONY: $(ARGS)
$(ARGS):
	@:
endif
endif

shell_files := $(shell { printf '%s\n' install.sh; find scripts lib ansible/helpers ansible/roles -type f -name '*.sh'; for file in bin/*; do [ -f "$$file" ] && head -n 1 "$$file" | grep -Eq 'sh$$' && printf '%s\n' "$$file" || true; done; } | tr '\n' ' ')
bash_rc := dotfiles/.bashrc dotfiles/.bash_profile
zsh_files := dotfiles/.zshrc lib/shell/commands.sh lib/shell/navigation.sh
checks := syntax lint shell ansible

.DEFAULT_GOAL := help
.PHONY: $(COMMANDS) _syntax _lint _shell _ansible _hooks

help:
	@printf '%s\n' 'Usage: make COMMAND [ARGS ...]' '' \
	  '  configure [GROUP...] Configure apps, agents, and system settings' \
	  '  list groups          List setup groups' \
	  '  check [WHAT]         Run syntax, lint, shell, and ansible checks, one of them, or hooks' \
	  '  format               Format shell files with shfmt'

configure:
	scripts/configure.sh $(ARGS)

list:
	@case "$(or $(ARGS),groups)" in groups) scripts/configure.sh --list ;; *) echo 'make list: only groups' >&2; exit 2 ;; esac

check:
	@what="$(or $(ARGS),all)"; case "$$what" in \
	  all) targets="$(addprefix _,$(checks))" ;; \
	  syntax | lint | shell | ansible | hooks) targets="_$$what" ;; \
	  *) echo 'make check: syntax, lint, shell, ansible, or hooks' >&2; exit 2 ;; \
	esac; $(MAKE) --no-print-directory $$targets

format:
	shfmt --write $(shell_files) $(bash_rc)

_syntax:
	set -e; for file in $(shell_files) $(bash_rc); do bash -n "$$file"; done
	set -e; for file in $(zsh_files); do zsh -n "$$file"; done
	cache=$$(mktemp -d); trap 'rm -rf -- "$$cache"' EXIT; PYTHONPYCACHEPREFIX="$$cache" python3 -m py_compile lib/output.py lib/git/*.py ansible/plugins/*/*.py bin/cafe bin/microphone scripts/check.py

_lint:
	shellcheck -x --severity=warning $(shell_files) $(bash_rc)

_shell:
	python3 scripts/check.py

_ansible:
	./scripts/ansible.sh
	cd ansible && ANSIBLE_CONFIG=ansible.cfg ../local/ansible/venv/bin/ansible-playbook --syntax-check site.yml
	cd ansible && ANSIBLE_CONFIG=ansible.cfg PATH="$$PWD/../local/ansible/venv/bin:$$PATH" ansible-lint

_hooks:
	pre-commit run --all-files
