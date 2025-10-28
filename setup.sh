#!/bin/bash

set -e

REQUIRED_CMDS=(
  curl
  stow
  vim
  wget
  zsh
)

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Command '$cmd' is missing. Installing..."
    if command -v apt-get &> /dev/null; then
      sudo apt-get update && sudo apt-get install -y "$cmd"
    elif command -v yum &> /dev/null; then
      sudo yum install -y "$cmd"
    elif command -v dnf &> /dev/null; then
      sudo dnf install -y "$cmd"
    elif command -v brew &> /dev/null; then
      brew install "$cmd"
    else
      echo "Error: No supported package manager found to install '$cmd'."
      exit 1
    fi
  else
    echo "Command '$cmd' is already installed."
  fi
done

if [ ! -x /usr/local/bin/task ]; then
  sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b .
  sudo install -o root -g root -m 0755 task /usr/local/bin/task
fi

[ -f ./task ] && rm -f ./task

echo "Ready to run tasks!"
