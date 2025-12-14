root_dir="$(get_root_dir)"

# Parse flags
install_packages=true
skip_brew=false
dry_run=false
interactive=true
target_shell=""
setup_type=""
run_setup=false

[[ "${args[--non-interactive]}" ]] && interactive=false
[[ "${args[--shell]}" ]] && target_shell="${args[--shell]}"
[[ "${args[--minimal]}" ]] && setup_type="minimal"
[[ "${args[--full]}" ]] && setup_type="full"
[[ "${args[--setup]}" ]] && run_setup=true
[[ "${args[--no-install]}" ]] && install_packages=false
[[ "${args[--skip-brew]}" ]] && skip_brew=true
[[ "${args[--dry-run]}" ]] && dry_run=true

header "Initializing jsh environment"

# Interactive prompts
if [[ "$interactive" == "true" ]]; then
  echo ""
  info "Welcome to jsh! Let's configure your shell environment."
  echo ""

  # Shell selection
  if [[ -z "$target_shell" ]]; then
    echo -e "${BOLD}Shell Selection:${RESET}"
    echo "  1) zsh   (recommended)"
    echo "  2) bash  (traditional)"
    echo "  3) skip  (keep current: $(basename "$SHELL"))"
    echo ""
    read -n 1 -r -p "Choose your shell (1-3): " shell_choice
    echo ""
    echo ""

    case "$shell_choice" in
      1) target_shell="zsh" ;;
      2) target_shell="bash" ;;
      3) target_shell="skip" ;;
      *) target_shell="zsh" ;;
    esac
  fi

  # Setup type selection
  if [[ -z "$setup_type" ]]; then
    echo -e "${BOLD}Setup Type:${RESET}"
    echo "  1) Minimal  - Core tools only"
    echo "  2) Full     - Themes, plugins, completions"
    echo ""
    read -n 1 -r -p "Choose setup type (1-2): " setup_choice
    echo ""
    echo ""

    case "$setup_choice" in
      1) setup_type="minimal" ;;
      2) setup_type="full" ;;
      *) setup_type="full" ;;
    esac
  fi

  # Package installation confirmation
  if [[ "$install_packages" == "true" ]]; then
    echo -e "${BOLD}Package Installation:${RESET}"
    info "This will install Homebrew and essential tools."
    echo ""

    if ! confirm "Proceed with package installation?"; then
      install_packages=false
      skip_brew=true
    fi
  fi
else
  # Non-interactive defaults
  [[ -z "$target_shell" ]] && target_shell="zsh"
  [[ -z "$setup_type" ]] && setup_type="full"
fi

if [[ "$setup_type" == "minimal" ]]; then
  export ZSH_MINIMAL=1
  info "Minimal setup selected"
  echo ""
fi

header "Starting initialization"

# 1. Git Submodules
if [[ -f "$root_dir/.gitmodules" ]]; then
  log "Initializing git submodules..."
  if [[ "$dry_run" == "false" ]]; then
    git -C "$root_dir" submodule update --init --recursive
  fi
fi

# 2. Install fzf
if [[ -f "$root_dir/.fzf/install" && ! -f "$root_dir/.fzf/bin/fzf" ]]; then
  log "Installing fzf..."
  if [[ "$dry_run" == "false" ]]; then
    "$root_dir/.fzf/install" --bin
    export PATH="$root_dir/.fzf/bin:$PATH"
  fi
fi

# 3. Homebrew
if [[ "$install_packages" == "true" && "$skip_brew" == "false" ]]; then
  if [[ "$dry_run" == "false" ]]; then
    non_interactive_flag="false"
    [[ "$interactive" == "false" ]] && non_interactive_flag="true"
    if ! ensure_brew "$non_interactive_flag"; then
      warn "Continuing without Homebrew..."
    fi
  fi
fi

# 4. Basic Tools
if [[ "$install_packages" == "true" ]]; then
  log "Installing basic tools..."
  basic_tools=(curl jq make python timeout vim)
  if command -v brew &> /dev/null; then
    for tool in "${basic_tools[@]}"; do
      if ! command -v "$tool" &> /dev/null; then
        log "Installing $tool..."
        pkg="$tool"
        [[ "$tool" == "timeout" ]] && pkg="coreutils"
        if [[ "$dry_run" == "false" ]]; then
          brew install "$pkg" 2>/dev/null || true
        fi
      fi
    done
  fi
fi

# 5. Shell Setup
if [[ "$install_packages" == "true" && "$target_shell" != "skip" ]]; then
  log "Configuring shell: $target_shell"

  if ! command -v "$target_shell" &> /dev/null; then
    log "$target_shell not found, installing..."
    if [[ "$dry_run" == "false" ]]; then
      install_package "$target_shell" || true
    fi
  fi

  if command -v "$target_shell" &> /dev/null; then
    current_shell=$(get_user_shell)

    if [[ "$current_shell" != *"$target_shell"* ]]; then
      shell_path=$(command -v "$target_shell")

      if ! grep -q "^$shell_path$" /etc/shells 2> /dev/null; then
        log "Adding $shell_path to /etc/shells..."
        if [[ "$dry_run" == "false" ]]; then
          echo "$shell_path" | sudo tee -a /etc/shells > /dev/null
        fi
      fi

      log "Changing default shell to $target_shell..."
      if [[ "$dry_run" == "false" ]]; then
        chsh -s "$shell_path" || warn "Failed to change shell"
      fi
    else
      info "Shell is already $target_shell"
    fi
  fi
fi

# 6. Link dotfiles
if [[ "$dry_run" == "false" ]]; then
  "$0" dotfiles
fi

# 7. Zinit installation
if [[ "$install_packages" == "true" && "$dry_run" == "false" && "$target_shell" == "zsh" ]]; then
  zinit_home="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

  if [[ "$setup_type" == "full" && ! -d "${zinit_home}" ]]; then
    if [[ "$interactive" == "true" ]]; then
      echo ""
      info "Zinit enables themes, syntax highlighting, and auto-suggestions."
      echo ""

      if confirm "Install zinit and plugins?"; then
        log "Installing zinit..."
        mkdir -p "${zinit_home%/*}"
        git clone https://github.com/zdharma-continuum/zinit.git "${zinit_home}" || warn "Failed to install zinit"
      fi
    else
      log "Installing zinit..."
      mkdir -p "${zinit_home%/*}"
      git clone https://github.com/zdharma-continuum/zinit.git "${zinit_home}" 2>/dev/null || true
    fi
  fi
fi

# 8. Run setup if requested
if [[ "$run_setup" == "true" && "$dry_run" == "false" ]]; then
  header "Running full setup"
  "$0" install
  "$0" configure
fi

success "Initialization complete!"

echo ""
info "Summary:"
info "  Shell:      $target_shell"
info "  Setup type: $setup_type"
info "  Packages:   $(if [[ "$install_packages" == "true" ]]; then echo "installed"; else echo "skipped"; fi)"
info "  Full setup: $(if [[ "$run_setup" == "true" ]]; then echo "yes"; else echo "no"; fi)"
echo ""

if [[ "$dry_run" == "false" && "$target_shell" != "skip" ]]; then
  if [[ "$interactive" == "false" ]]; then
    log "Starting $target_shell session..."
    exec "$target_shell"
  else
    info "To activate your new shell, run: exec $target_shell"
    echo ""
    if confirm "Start new $target_shell session now?"; then
      exec "$target_shell"
    fi
  fi
fi
