if [[ "${args[--install]}" ]]; then
  # Install completions
  completion_file="$HOME/.jsh-completion.zsh"
  "$0" completions > "$completion_file"

  # Add to .zshrc if not already there
  if ! grep -q "source.*jsh-completion" "$HOME/.zshrc" 2>/dev/null; then
    echo "" >> "$HOME/.zshrc"
    echo "# jsh completions" >> "$HOME/.zshrc"
    echo "source $completion_file" >> "$HOME/.zshrc"
    success "Completions installed to $completion_file and added to .zshrc"
  else
    success "Completions updated at $completion_file"
  fi
  exit 0
fi

# Generate completions
cat << 'EOF'
#compdef jsh

_jsh() {
  local -a commands
  commands=(
    'init:Set up shell environment'
    'install:Install packages'
    'uninstall:Uninstall a package and remove from config'
    'upgrade:Upgrade all packages'
    'configure:Apply dotfiles, OS settings, and app configs'
    'dotfiles:Manage dotfile symlinks'
    'clean:Remove caches, temp files, old Homebrew versions'
    'status:Show brew packages, services, symlinks, git status'
    'doctor:Check for missing tools, broken symlinks, repo issues'
    'deinit:Remove jsh symlinks and restore backups'
    'brew:Homebrew wrapper'
    'completions:Generate shell completion script'
  )

  _arguments -C \
    '1: :->command' \
    '*:: :->args'

  case $state in
    command)
      _describe -t commands 'jsh command' commands
      ;;
    args)
      case $line[1] in
        init)
          _arguments \
            '(-y --non-interactive)'{-y,--non-interactive}'[Use defaults]' \
            '--shell[Pre-select shell]:shell:(zsh bash skip)' \
            '--minimal[Lightweight setup]' \
            '--full[Full setup with plugins]' \
            '--setup[Also run install + configure]' \
            '--no-install[Skip package installation]' \
            '--skip-brew[Skip Homebrew]' \
            '--dry-run[Preview changes]'
          ;;
        dotfiles)
          _arguments \
            '(-s --status)'{-s,--status}'[Show symlink status]' \
            '(-d --remove)'{-d,--remove}'[Remove symlinks]'
          ;;
        install)
          # Could add package completion here
          ;;
        uninstall)
          # Could add installed package completion here
          ;;
        completions)
          _arguments \
            '(-i --install)'{-i,--install}'[Install to shell config]'
          ;;
      esac
      ;;
  esac
}

_jsh
EOF
