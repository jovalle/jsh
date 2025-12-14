root_dir="$(get_root_dir)"

header "Upgrading packages"

# Update zinit if present
if command -v zsh &> /dev/null; then
  log "Cleaning zinit..."
  zsh -ic 'zinit delete --clean' 2> /dev/null || true
  log "Updating zinit..."
  zsh -ic 'zinit self-update' 2> /dev/null || true
  zsh -ic 'zinit update --all' 2> /dev/null || true
fi

if is_macos; then
  if command -v brew &> /dev/null; then
    log "Upgrading Homebrew packages..."
    brew update && brew upgrade
  fi
  if command -v mas &> /dev/null; then
    log "Upgrading Mac App Store apps..."
    mas upgrade
  fi
elif is_linux; then
  log "Upgrading packages..."
  upgrade_packages
  if command -v brew &> /dev/null; then
    log "Upgrading Homebrew packages..."
    brew update && brew upgrade
  fi
fi

success "Upgrade complete"
