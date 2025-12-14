root_dir="$(get_root_dir)"
dotfiles_dir="$root_dir/dotfiles"

# Handle flags
if [[ "${args[--status]}" ]]; then
  # Show status
  header "Dotfile Symlink Status"

  for item in "$dotfiles_dir"/.* "$dotfiles_dir"/*; do
    [[ "$(basename "$item")" == "." || "$(basename "$item")" == ".." ]] && continue
    [[ ! -e "$item" ]] && continue

    basename_item=$(basename "$item")

    if [[ "$basename_item" == ".config" ]]; then
      for config_item in "$item"/*; do
        [[ ! -e "$config_item" ]] && continue
        config_basename=$(basename "$config_item")
        config_target="$HOME/.config/$config_basename"

        if [[ -L "$config_target" ]]; then
          link_target=$(readlink "$config_target" 2>/dev/null || true)
          if [[ "$link_target" == "$config_item" ]]; then
            echo -e "  ${GREEN}✓${RESET} .config/$config_basename"
          else
            echo -e "  ${YELLOW}⚠${RESET} .config/$config_basename (wrong target)"
          fi
        elif [[ -e "$config_target" ]]; then
          echo -e "  ${YELLOW}⚠${RESET} .config/$config_basename (file exists)"
        else
          echo -e "  ${RED}✗${RESET} .config/$config_basename (not linked)"
        fi
      done
    else
      target="$HOME/$basename_item"
      if [[ -L "$target" ]]; then
        link_target=$(readlink "$target" 2>/dev/null || true)
        if [[ "$link_target" == "$item" ]]; then
          echo -e "  ${GREEN}✓${RESET} $basename_item"
        else
          echo -e "  ${YELLOW}⚠${RESET} $basename_item (wrong target)"
        fi
      elif [[ -e "$target" ]]; then
        echo -e "  ${YELLOW}⚠${RESET} $basename_item (file exists)"
      else
        echo -e "  ${RED}✗${RESET} $basename_item (not linked)"
      fi
    fi
  done
  exit 0
fi

if [[ "${args[--remove]}" ]]; then
  # Remove symlinks
  log "Removing jsh-managed symlinks..."

  find ~ -maxdepth 1 -type l -print 2>/dev/null | while read -r link; do
    target=$(readlink "$link" 2> /dev/null || echo "")
    if [[ "$target" == *"$root_dir/dotfiles"* ]]; then
      echo "🗑️  Removing symlink: $link"
      rm "$link"
    fi
  done

  if [[ -d "$HOME/.config" ]]; then
    find "$HOME/.config" -maxdepth 1 -type l -print 2>/dev/null | while read -r link; do
      target=$(readlink "$link" 2> /dev/null || echo "")
      if [[ "$target" == *"$root_dir/dotfiles/.config"* ]]; then
        echo "🗑️  Removing symlink: $link"
        rm "$link"
      fi
    done
  fi

  success "Dotfiles symlinks removed"
  exit 0
fi

# Default: deploy dotfiles
log "Deploying dotfiles..."
mkdir -p "$HOME/.config"

for item in "$dotfiles_dir"/.* "$dotfiles_dir"/*; do
  [[ "$(basename "$item")" == "." || "$(basename "$item")" == ".." ]] && continue
  [[ ! -e "$item" ]] && continue

  basename_item=$(basename "$item")
  target="$HOME/$basename_item"

  if [[ "$basename_item" == ".config" ]]; then
    log "Processing .config directory..."
    for config_item in "$item"/*; do
      [[ ! -e "$config_item" ]] && continue
      config_basename=$(basename "$config_item")
      config_target="$HOME/.config/$config_basename"

      if [[ -e "$config_target" || -L "$config_target" ]]; then
        link_target=$(readlink "$config_target" 2> /dev/null || echo "")
        if [[ "$link_target" != "$config_item" ]]; then
          # Prompt user for existing file
          echo ""
          warn "Conflict: $config_target already exists"
          if [[ -L "$config_target" ]]; then
            info "  Current symlink points to: $link_target"
          fi
          echo "  [s]kip  [b]ackup and replace  [o]verwrite"
          read -n 1 -r -p "  Choice: " choice
          echo ""
          case "$choice" in
            b|B)
              mv "$config_target" "${config_target}-backup"
              ln -sf "$config_item" "$config_target"
              echo "  ✓ Backed up and linked $config_basename"
              ;;
            o|O)
              rm -rf "$config_target"
              ln -sf "$config_item" "$config_target"
              echo "  ✓ Overwritten $config_basename"
              ;;
            *)
              echo "  ⏭ Skipped $config_basename"
              ;;
          esac
        else
          rm "$config_target"
          ln -sf "$config_item" "$config_target"
        fi
      else
        ln -sf "$config_item" "$config_target"
        echo "  ✓ Linked $config_basename"
      fi
    done
  else
    if [[ -e "$target" || -L "$target" ]]; then
      link_target=$(readlink "$target" 2> /dev/null || echo "")
      if [[ "$link_target" != "$item" ]]; then
        echo ""
        warn "Conflict: $target already exists"
        if [[ -L "$target" ]]; then
          info "  Current symlink points to: $link_target"
        fi
        echo "  [s]kip  [b]ackup and replace  [o]verwrite"
        read -n 1 -r -p "  Choice: " choice
        echo ""
        case "$choice" in
          b|B)
            mv "$target" "${target}-backup"
            ln -sf "$item" "$target"
            echo "  ✓ Backed up and linked $basename_item"
            ;;
          o|O)
            rm -rf "$target"
            ln -sf "$item" "$target"
            echo "  ✓ Overwritten $basename_item"
            ;;
          *)
            echo "  ⏭ Skipped $basename_item"
            ;;
        esac
      else
        rm "$target"
        ln -sf "$item" "$target"
      fi
    else
      ln -sf "$item" "$target"
      echo "  ✓ Linked $basename_item"
    fi
  fi
done

success "Dotfiles deployed successfully"
