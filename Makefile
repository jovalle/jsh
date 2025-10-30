# Makefile proxy to Taskfile
# Forwards all make commands to task commands

.DEFAULT_GOAL := help

# Catch-all target: route all unknown targets to task
%:
	@task $@

# Special target to handle make without arguments
.PHONY: help
help:
	@task --list

# Allow passing arguments to tasks
# Usage: make target ARGS="arg1 arg2"
ARGS :=
ifneq ($(ARGS),)
%:
	@task $@ -- $(ARGS)
endif
