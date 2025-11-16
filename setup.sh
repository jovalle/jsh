#!/usr/bin/env zsh

set -e

# Initialize git submodules (e.g., fzf)
if [[ -f .gitmodules ]]; then
  echo "Initializing git submodules..."
  git submodule update --init --recursive
fi

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
  make
  python
  stow
  task
  timeout
  vim
  zsh
)

# Mapping of command names to package names (when they differ)
declare -A PKG_MAP=(
  ["task"]="go-task"      # Task runner
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

echo ""
echo "📦 Deploying dotfiles with stow..."
stow -v . --adopt || {
  echo "⚠️  Warning: stow encountered issues. Some dotfiles may need manual review."
}

echo ""
echo "✅ Setup complete!"
echo ""
echo "📋 Next steps:"
echo "  1. Reload your shell to load the new configuration:"
echo "       exec zsh"
echo "  2. The 'jsh' command will now be available globally. Run:"
echo "       jsh init"
echo ""
echo "💡 Note: 'jsh' works from any directory after the shell is reloaded."
echo ""
