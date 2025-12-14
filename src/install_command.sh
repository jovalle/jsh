# jsh install - Package installation command
#
# Usage:
#   jsh install                  - Install all packages from config files
#   jsh install <package>        - Install a single package (auto-detect package manager)
#   jsh install <package> --brew - Install via specific package manager
#
# Behavior:
#   - Single package: Uses Homebrew/Linuxbrew by default, or specified package manager
#   - Bulk install: Uses config JSONs (system package managers + brew formulae)
#   - Root delegation: When running as root, delegates brew commands to BREW_USER
#
# Environment Variables:
#   - BREW_USER: User to run Homebrew as when executing as root (loaded from .env)

root_dir="$(get_root_dir)"
package="${args[package]:-}"

# Determine which package manager to use based on flags
detect_package_manager() {
  [[ "${args[--brew]}" ]] && echo "brew" && return
  [[ "${args[--gem]}" ]] && echo "gem" && return
  [[ "${args[--bun]}" ]] && echo "bun" && return
  [[ "${args[--npm]}" ]] && echo "npm" && return
  [[ "${args[--pip]}" ]] && echo "pip" && return
  [[ "${args[--cargo]}" ]] && echo "cargo" && return
  [[ "${args[--apt]}" ]] && echo "apt" && return
  [[ "${args[--dnf]}" ]] && echo "dnf" && return
  [[ "${args[--pacman]}" ]] && echo "pacman" && return
  [[ "${args[--yum]}" ]] && echo "yum" && return
  [[ "${args[--zypper]}" ]] && echo "zypper" && return
  echo "auto"
}

# Install a package via specified package manager
install_via_package_manager() {
  local pkg="$1"
  local pm="$2"

  case "$pm" in
    brew)
      if is_macos; then
        # Try cask first, then formula
        if brew_cmd install --cask "$pkg" 2>/dev/null; then
          success "Installed cask: $pkg"
          add_package_to_json "$root_dir/configs/macos/casks.json" "$pkg"
          return 0
        elif brew_cmd install "$pkg" 2>/dev/null; then
          success "Installed formula: $pkg"
          add_package_to_json "$root_dir/configs/macos/formulae.json" "$pkg"
          return 0
        fi
      else
        if brew_cmd install "$pkg" 2>/dev/null; then
          success "Installed via brew: $pkg"
          add_package_to_json "$root_dir/configs/linux/formulae.json" "$pkg"
          return 0
        fi
      fi
      return 1
      ;;
    gem)
      if command -v gem &>/dev/null; then
        gem install "$pkg" && success "Installed gem: $pkg" && return 0
      else
        error "gem not found. Install Ruby first."
      fi
      return 1
      ;;
    bun)
      if command -v bun &>/dev/null; then
        bun install -g "$pkg" && success "Installed bun package: $pkg" && return 0
      else
        error "bun not found. Install from https://bun.sh"
      fi
      return 1
      ;;
    npm)
      if command -v npm &>/dev/null; then
        npm install -g "$pkg" && success "Installed npm package: $pkg" && return 0
      else
        error "npm not found. Install Node.js first."
      fi
      return 1
      ;;
    pip)
      if command -v pip3 &>/dev/null; then
        pip3 install --user "$pkg" && success "Installed pip package: $pkg" && return 0
      elif command -v pip &>/dev/null; then
        pip install --user "$pkg" && success "Installed pip package: $pkg" && return 0
      else
        error "pip not found. Install Python first."
      fi
      return 1
      ;;
    cargo)
      if command -v cargo &>/dev/null; then
        cargo install "$pkg" && success "Installed cargo package: $pkg" && return 0
      else
        error "cargo not found. Install Rust first."
      fi
      return 1
      ;;
    apt)
      if command -v apt-get &>/dev/null; then
        sudo apt-get install -y "$pkg" && success "Installed apt package: $pkg" && return 0
      else
        error "apt-get not found."
      fi
      return 1
      ;;
    dnf)
      if command -v dnf &>/dev/null; then
        sudo dnf install -y "$pkg" && success "Installed dnf package: $pkg" && return 0
      else
        error "dnf not found."
      fi
      return 1
      ;;
    pacman)
      if command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm "$pkg" && success "Installed pacman package: $pkg" && return 0
      else
        error "pacman not found."
      fi
      return 1
      ;;
    yum)
      if command -v yum &>/dev/null; then
        sudo yum install -y "$pkg" && success "Installed yum package: $pkg" && return 0
      else
        error "yum not found."
      fi
      return 1
      ;;
    zypper)
      if command -v zypper &>/dev/null; then
        sudo zypper install -y "$pkg" && success "Installed zypper package: $pkg" && return 0
      else
        error "zypper not found."
      fi
      return 1
      ;;
    *)
      error "Unknown package manager: $pm"
      return 1
      ;;
  esac
}

if [[ -z "$package" ]]; then
  # Install all packages from config (brew + system packages)
  header "Installing packages"

  if is_linux; then
    # Install Linux system packages from config
    # Note: These are managed via system package managers (apt, dnf, pacman)
    log "Updating package cache..."
    update_package_cache

    # Determine package manager
    packages=()
    if command -v apt-get &> /dev/null; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && packages+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/linux/apt.json")
    elif command -v dnf &> /dev/null; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && packages+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/linux/dnf.json")
    elif command -v pacman &> /dev/null; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && packages+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/linux/pacman.json")
    fi

    for pkg in "${packages[@]}"; do
      install_package "$pkg" || warn "Failed to install $pkg"
    done
  fi

  if is_macos && check_brew; then
    # Install casks
    log "Installing Casks..."
    casks=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && casks+=("$line")
    done < <(load_packages_from_json "$root_dir/configs/macos/casks.json")

    if [[ ${#casks[@]} -gt 0 ]]; then
      brew install --force --cask "${casks[@]}" 2>/dev/null || true
    fi
  fi

  if check_brew; then
    # Install formulae
    log "Installing Formulae..."
    formulae=()
    if is_macos; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && formulae+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/macos/formulae.json")
    else
      while IFS= read -r line; do
        [[ -n "$line" ]] && formulae+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/linux/formulae.json")
    fi

    if [[ ${#formulae[@]} -gt 0 ]]; then
      brew install --force "${formulae[@]}" 2>/dev/null || true
    fi

    # Start services
    log "Starting Services..."
    services=()
    if is_macos; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && services+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/macos/services.json")
    else
      while IFS= read -r line; do
        [[ -n "$line" ]] && services+=("$line")
      done < <(load_packages_from_json "$root_dir/configs/linux/services.json")
    fi

    for svc in "${services[@]}"; do
      brew services start "$svc" 2>/dev/null || true
    done
  fi

  success "Package installation complete"
else
  # Install single package
  header "Installing package: $package"

  # Detect package manager
  pm=$(detect_package_manager)

  if [[ "$pm" == "auto" ]]; then
    # Auto-detect: prefer brew on both platforms
    if is_macos; then
      if ! check_brew; then
        error "Homebrew is required on macOS for auto-install"
        exit 1
      fi
      pm="brew"
    elif is_linux; then
      if ! check_brew; then
        error "Homebrew/Linuxbrew is required for auto-install. Run 'jsh init' to install it."
        exit 1
      fi
      pm="brew"
    else
      error "Unsupported operating system"
      exit 1
    fi
  fi

  # Install via specified package manager
  if install_via_package_manager "$package" "$pm"; then
    # Package installed successfully - don't search for cross-platform equivalents
    success "Installation complete"
  else
    error "Failed to install '$package' via $pm"
    # Only search for alternatives if installation failed
    search_cross_platform_packages "$package"
    exit 1
  fi
fi
