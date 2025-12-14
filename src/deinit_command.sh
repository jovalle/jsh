root_dir="$(get_root_dir)"
dotfiles_dir="$root_dir/dotfiles"

header "Deinitializing jsh"

warn "This will remove all jsh-managed symlinks and restore original files."
if ! confirm "Continue with uninstall?"; then
  info "Uninstall cancelled"
  exit 0
fi

removed_count=0
restored_count=0

log "Removing jsh-managed symlinks from home directory..."

# Process home directory symlinks
for item in "$dotfiles_dir"/.* "$dotfiles_dir"/*; do
  [[ "$(basename "$item")" == "." || "$(basename "$item")" == ".." ]] && continue
  [[ ! -e "$item" ]] && continue

  basename_item=$(basename "$item")
  target="$HOME/$basename_item"

  [[ "$basename_item" == ".config" ]] && continue

  if [[ -L "$target" ]]; then
    link_target=$(readlink "$target" 2> /dev/null || echo "")

    if [[ "$link_target" == "$item" ]]; then
      echo "🗑️  Removing symlink: $target"
      rm "$target"
      ((removed_count++))

      backup_path="${target}-backup"
      if [[ -e "$backup_path" || -L "$backup_path" ]]; then
        echo "♻️  Restoring backup: $backup_path -> $target"
        mv "$backup_path" "$target"
        ((restored_count++))
      fi
    fi
  fi
done

log "Removing jsh-managed symlinks from .config directory..."

if [[ -d "$dotfiles_dir/.config" ]]; then
  for config_item in "$dotfiles_dir/.config"/*; do
    [[ ! -e "$config_item" ]] && continue

    config_basename=$(basename "$config_item")
    config_target="$HOME/.config/$config_basename"

    if [[ -L "$config_target" ]]; then
      link_target=$(readlink "$config_target" 2> /dev/null || echo "")

      if [[ "$link_target" == "$config_item" ]]; then
        echo "🗑️  Removing symlink: $config_target"
        rm "$config_target"
        ((removed_count++))

        backup_path="${config_target}-backup"
        if [[ -e "$backup_path" || -L "$backup_path" ]]; then
          echo "♻️  Restoring backup: $backup_path -> $config_target"
          mv "$backup_path" "$config_target"
          ((restored_count++))
        fi
      fi
    fi
  done
fi

info "Note: You may want to remove '$root_dir/bin' from your PATH"

echo ""
success "Uninstall complete!"
info "  Removed symlinks: $removed_count"
info "  Restored backups: $restored_count"

if [[ $restored_count -gt 0 ]]; then
  info ""
  info "Your original files have been restored."
fi

info ""
info "To completely remove jsh, run: rm -rf $root_dir"
