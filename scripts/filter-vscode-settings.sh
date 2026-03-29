#!/usr/bin/env bash
set -euo pipefail

for dependency in jq prettier; do
  if ! command -v "${dependency}" >/dev/null 2>&1; then
    printf 'filter-vscode-settings: %s is required\n' "${dependency}" >&2
    exit 1
  fi
done

jq 'del(.["chat.tools.urls.autoApprove"])' | prettier --parser json
