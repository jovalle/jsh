#!/usr/bin/env bash

set -e

# Install brew if not present
if ! command -v brew &> /dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to PATH based on OS
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    # macOS - check both Apple Silicon and Intel paths
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f "/usr/local/bin/brew" ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  elif [[ "${OSTYPE}" == "linux"* ]]; then
    # Linux
    if [[ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
  fi
fi

REQUIRED_CMDS=(
  curl
  git
  jq
  make
  node
  pipx
  python
  stow
  task
  timeout
  vim
  zsh
)

# Mapping of command names to package names (when they differ)
declare -A PKG_MAP=(
  ["node"]="nodejs"      # Node.js runtime (Linux)
  ["task"]="go-task"     # Task runner
  ["timeout"]="coreutils" # GNU coreutils
)

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "Command '${cmd}' is missing. Installing..."

    # Use mapped package name if it exists, otherwise use command name
    pkg="${PKG_MAP[${cmd}]:-${cmd}}"

    brew install "${pkg}"
  else
    echo "Command '${cmd}' is already installed."
  fi
done

echo "Ready to run tasks!"
