root_dir="$(get_root_dir)"
package="${args[package]}"

header "Uninstalling package: $package"

found=false

if is_macos; then
  if ! check_brew; then
    error "Homebrew is required on macOS"
  fi

  # Check if it's a cask
  casks_file="$root_dir/configs/macos/casks.json"
  if [[ -f "$casks_file" ]] && jq -e --arg pkg "$package" 'index($pkg) != null' "$casks_file" > /dev/null 2>&1; then
    log "Uninstalling cask: $package"
    brew_cmd uninstall --cask "$package" 2>/dev/null || warn "Failed to uninstall cask"
    remove_package_from_json "$casks_file" "$package"
    found=true
  fi

  # Check if it's a formula
  formulae_file="$root_dir/configs/macos/formulae.json"
  if [[ -f "$formulae_file" ]] && jq -e --arg pkg "$package" 'index($pkg) != null' "$formulae_file" > /dev/null 2>&1; then
    log "Uninstalling formula: $package"
    brew_cmd uninstall "$package" 2>/dev/null || warn "Failed to uninstall formula"
    remove_package_from_json "$formulae_file" "$package"
    found=true
  fi

  # If not found in config, try to uninstall anyway
  if [[ "$found" == "false" ]]; then
    log "Package not in config files, attempting uninstall..."
    if brew_cmd uninstall --cask "$package" 2>/dev/null; then
      success "Uninstalled cask: $package"
    elif brew_cmd uninstall "$package" 2>/dev/null; then
      success "Uninstalled formula: $package"
    else
      error "Package '$package' not found or failed to uninstall"
    fi
  fi

elif is_linux; then
  # Check brew formulae first
  formulae_file="$root_dir/configs/linux/formulae.json"
  if [[ -f "$formulae_file" ]] && jq -e --arg pkg "$package" 'index($pkg) != null' "$formulae_file" > /dev/null 2>&1; then
    log "Uninstalling brew formula: $package"
    brew_cmd uninstall "$package" 2>/dev/null || warn "Failed to uninstall via brew"
    remove_package_from_json "$formulae_file" "$package"
    found=true
  fi

  # Check system package manager configs
  config_files=(
    "apt:$root_dir/configs/linux/apt.json"
    "dnf:$root_dir/configs/linux/dnf.json"
    "pacman:$root_dir/configs/linux/pacman.json"
  )

  for entry in "${config_files[@]}"; do
    pm="${entry%%:*}"
    config_file="${entry#*:}"

    if [[ -f "$config_file" ]] && jq -e --arg pkg "$package" 'index($pkg) != null' "$config_file" > /dev/null 2>&1; then
      log "Found in $pm config, uninstalling..."
      case "$pm" in
        apt) sudo apt-get remove -y "$package" 2>/dev/null || warn "apt remove failed" ;;
        dnf) sudo dnf remove -y "$package" 2>/dev/null || warn "dnf remove failed" ;;
        pacman) sudo pacman -Rs --noconfirm "$package" 2>/dev/null || warn "pacman remove failed" ;;
      esac
      remove_package_from_json "$config_file" "$package"
      found=true
    fi
  done

  # If not found in config, try to uninstall anyway
  if [[ "$found" == "false" ]]; then
    log "Package not in config files, attempting uninstall..."
    if command -v brew &> /dev/null && brew_cmd uninstall "$package" 2>/dev/null; then
      success "Uninstalled via brew: $package"
    elif command -v apt-get &> /dev/null && sudo apt-get remove -y "$package" 2>/dev/null; then
      success "Uninstalled via apt: $package"
    elif command -v dnf &> /dev/null && sudo dnf remove -y "$package" 2>/dev/null; then
      success "Uninstalled via dnf: $package"
    elif command -v pacman &> /dev/null && sudo pacman -Rs --noconfirm "$package" 2>/dev/null; then
      success "Uninstalled via pacman: $package"
    else
      error "Package '$package' not found or failed to uninstall"
    fi
  fi
else
  error "Unsupported operating system"
fi

if [[ "$found" == "true" ]]; then
  success "Uninstalled: $package"
fi
