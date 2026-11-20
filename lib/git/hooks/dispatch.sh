#!/bin/sh
# Global Git hook: reject AI attribution, then run the repository's own hooks of the same name.

hook=${0##*/}
if [ "${hook}" = commit-msg ] && grep -iqE '^[[:space:]]*co-authored-by[[:space:]]*:' "$1"; then
  printf '%s\n' 'Commit rejected: remove the Co-authored-by trailer.' >&2
  exit 1
fi
# Tracked .githooks are code from the clone, so they run only after `git config jsh.hooks true`.
# core.hooksPath replaces .git/hooks, so also hand off to what pre-commit or git-lfs installed there.
tracked=''
installed=''
if top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -x "${top}/.githooks/${hook}" ] &&
  [ "$(git config --bool jsh.hooks)" = true ]; then
  tracked=${top}/.githooks/${hook}
fi
if common=$(git rev-parse --git-common-dir 2>/dev/null) && [ -x "${common}/hooks/${hook}" ]; then
  installed=${common}/hooks/${hook}
fi
if [ -n "${tracked}" ] && [ -n "${installed}" ]; then
  # Both hooks need the same input: pre-push and post-rewrite read refs from stdin.
  input=$(mktemp) || exit
  cat >"${input}"
  "${tracked}" "$@" <"${input}" && "${installed}" "$@" <"${input}"
  status=$?
  rm -f -- "${input}"
  exit "${status}"
fi
[ -z "${tracked}" ] || exec "${tracked}" "$@"
[ -z "${installed}" ] || exec "${installed}" "$@"
