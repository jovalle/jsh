#!/usr/bin/env bash

set -e

apply_brew_shellenv() {
  local brew_bin="$1"
  [[ -n "$brew_bin" && -x "$brew_bin" ]] || return 1

  local brew_env
  if brew_env="$("$brew_bin" shellenv)"; then
    eval "$brew_env"
    return 0
  fi

  return 1
}

# Initialize git submodules (e.g., fzf)
if [[ -f .gitmodules ]]; then
  echo "Initializing git submodules..."
  git submodule update --init --recursive
fi

# Install brew if not present
if ! command -v brew &> /dev/null; then
  # Try common brew locations before attempting online install.
  if [[ -z "${BREW_CHECKED-}" ]]; then
    brew_candidates=(
      "/opt/homebrew/bin/brew"
      "/usr/local/bin/brew"
      "/home/linuxbrew/.linuxbrew/bin/brew"
      "${HOME}/.linuxbrew/bin/brew"
      "${HOME}/linuxbrew/.linuxbrew/bin/brew"
    )
    for brew_bin in "${brew_candidates[@]}"; do
      if [[ -x "${brew_bin}" ]]; then
        echo "Found Homebrew binary at ${brew_bin}; attempting to load environment..."
        if apply_brew_shellenv "${brew_bin}"; then
          echo "Homebrew environment loaded from ${brew_bin}."
          export BREW_CHECKED=1
          # Re-exec the script so the top-level 'brew' check will now detect it in PATH
          exec env BREW_CHECKED=1 "$0" "$@"
        else
          echo "Failed to load Homebrew environment from ${brew_bin}."
        fi
      fi
    done
  fi

  echo "Installing Homebrew/Linuxbrew..."
  install_script="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "${install_script}"
  /bin/bash "${install_script}"
  rm -f "${install_script}"

  # Add brew to PATH based on OS
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    # macOS - check both Apple Silicon and Intel paths
    apply_brew_shellenv "/opt/homebrew/bin/brew" || apply_brew_shellenv "/usr/local/bin/brew" || true
  elif [[ "${OSTYPE}" == "linux"* ]]; then
    # Linux (native or WSL)
    brew_candidates=(
      "/home/linuxbrew/.linuxbrew/bin/brew"
      "${HOME}/.linuxbrew/bin/brew"
      "${HOME}/linuxbrew/.linuxbrew/bin/brew"
    )
    for brew_path in "${brew_candidates[@]}"; do
      if apply_brew_shellenv "${brew_path}"; then
        break
      fi
    done
    unset brew_candidates
  fi
else
  echo "Homebrew is already installed."
fi

REQUIRED_CMDS=(
  curl
  jq
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
echo "🐚 Configuring Homebrew zsh as default shell..."

# Get current user's login shell from /etc/passwd
current_shell=$(getent passwd "$(whoami)" | cut -d: -f7)

# Find the Homebrew-installed zsh
zsh_paths=(
  "$(brew --prefix)/bin/zsh"
  "${HOME}/.linuxbrew/bin/zsh"
  "/home/linuxbrew/.linuxbrew/bin/zsh"
  "/opt/homebrew/bin/zsh"
  "/usr/local/bin/zsh"
)

brew_zsh=""
for zsh_path in "${zsh_paths[@]}"; do
  if [[ -x "$zsh_path" ]]; then
    brew_zsh="$zsh_path"
    break
  fi
done

if [[ -z "$brew_zsh" ]]; then
  echo "⚠️  Homebrew zsh not found. Skipping shell configuration."
else
  echo "✓ Found Homebrew zsh at $brew_zsh"

  # Add brew bin directory to PATH if not already present
  brew_bin="$(dirname "$brew_zsh")"
  if [[ ":$PATH:" != *":$brew_bin:"* ]]; then
    export PATH="$brew_bin:$PATH"
  fi

  # Ensure zsh is in /etc/shells for chsh
  if ! grep -q "^$brew_zsh$" /etc/shells 2>/dev/null; then
    echo "Adding $brew_zsh to /etc/shells..."
    echo "$brew_zsh" | sudo tee -a /etc/shells > /dev/null
  fi

  # Check if zsh is already the default shell
  if [[ "$current_shell" == "$brew_zsh" ]]; then
    echo "✓ Zsh is already the default shell"
  elif [[ "$current_shell" == *"/bash" ]]; then
    echo "Current shell is bash. Changing to zsh..."
    if chsh -s "$brew_zsh"; then
      echo "✓ Default shell changed to zsh"
      echo ""
      echo "⚠️  Please restart your shell to load zsh configuration:"
      echo "   exec zsh"
    else
      echo "⚠️  Failed to set default shell. Please run manually:"
      echo "   chsh -s $brew_zsh"
      echo "   Then restart your shell: exec zsh"
    fi
  else
    echo "Current shell: $current_shell"
    echo "Setting $brew_zsh as default shell..."
    if chsh -s "$brew_zsh"; then
      echo "✓ Default shell changed to zsh"
      echo ""
      echo "⚠️  Please restart your shell to load zsh configuration:"
      echo "   exec zsh"
    else
      echo "⚠️  Failed to set default shell. Please run manually:"
      echo "   chsh -s $brew_zsh"
      echo "   Then restart your shell: exec zsh"
    fi
  fi
fi

echo ""
echo "📦 Deploying dotfiles with stow..."
stow -v --no-folding dotfiles --adopt || {
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
