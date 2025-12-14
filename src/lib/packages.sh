# Package management functions for jsh

# Load packages from JSON file into stdout (one per line)
load_packages_from_json() {
  local json_file="$1"
  if [[ ! -f "$json_file" ]]; then
    return 1
  fi

  if command -v jq &> /dev/null; then
    jq -r '.[]' "$json_file" 2> /dev/null
  else
    grep -o '"[^"]*"' "$json_file" | tr -d '"'
  fi
}

# Add a package to a JSON array file (sorted, no duplicates)
add_package_to_json() {
  local json_file="$1"
  local package="$2"

  if [[ -z "$json_file" || -z "$package" ]]; then
    error "Usage: add_package_to_json <json_file> <package>"
  fi

  if ! command -v jq &> /dev/null; then
    error "jq is required for JSON manipulation"
  fi

  if [[ ! -f "$json_file" ]]; then
    echo "[]" > "$json_file"
  fi

  if jq -e --arg pkg "$package" 'index($pkg) != null' "$json_file" > /dev/null 2>&1; then
    info "Package '$package' already in $(basename "$json_file")"
    return 0
  fi

  local temp_file
  temp_file=$(mktemp)
  if jq --arg pkg "$package" '. + [$pkg] | sort' "$json_file" > "$temp_file"; then
    mv "$temp_file" "$json_file"
    success "Added '$package' to $(basename "$json_file")"
    return 0
  else
    rm -f "$temp_file"
    error "Failed to add package to $json_file"
  fi
}

# Remove a package from a JSON array file
remove_package_from_json() {
  local json_file="$1"
  local package="$2"

  if [[ -z "$json_file" || -z "$package" ]]; then
    error "Usage: remove_package_from_json <json_file> <package>"
  fi

  if ! command -v jq &> /dev/null; then
    error "jq is required for JSON manipulation"
  fi

  if [[ ! -f "$json_file" ]]; then
    warn "Config file does not exist: $json_file"
    return 1
  fi

  if ! jq -e --arg pkg "$package" 'index($pkg) != null' "$json_file" > /dev/null 2>&1; then
    info "Package '$package' not found in $(basename "$json_file")"
    return 1
  fi

  local temp_file
  temp_file=$(mktemp)
  if jq --arg pkg "$package" 'map(select(. != $pkg))' "$json_file" > "$temp_file"; then
    mv "$temp_file" "$json_file"
    success "Removed '$package' from $(basename "$json_file")"
    return 0
  else
    rm -f "$temp_file"
    error "Failed to remove package from $json_file"
  fi
}

# Search for linuxbrew equivalent
search_linuxbrew_package() {
  local package="$1"
  local root_dir
  root_dir="$(get_root_dir)"
  local linux_formulae_file="$root_dir/configs/linux/formulae.json"

  local search_results
  search_results=$(brew search "$package" 2>/dev/null | grep -v "^==" | grep -v "^$" || true)

  if [[ -z "$search_results" ]]; then
    log "No linuxbrew equivalent found for '$package'"
    return 0
  fi

  local matches=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && matches+=("$line")
  done <<< "$search_results"

  local match_count=${#matches[@]}

  if [[ $match_count -eq 0 ]]; then
    log "No linuxbrew equivalent found for '$package'"
    return 0
  elif [[ $match_count -eq 1 ]]; then
    local linux_package="${matches[0]}"
    info "Found linuxbrew equivalent: $linux_package"
    add_package_to_json "$linux_formulae_file" "$linux_package"
  else
    echo ""
    info "Multiple linuxbrew matches found for '$package':"
    local i=1
    for match in "${matches[@]}"; do
      echo "  $i) $match"
      ((i++))
    done
    echo "  0) Skip"
    echo ""

    local selection
    read -r -p "Select package number [0-$match_count]: " selection

    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$match_count" ]]; then
      local selected_package="${matches[$((selection-1))]}"
      info "Adding linuxbrew package: $selected_package"
      add_package_to_json "$linux_formulae_file" "$selected_package"
    fi
  fi
}

# Prompt for winget package ID
prompt_winget_package() {
  local package="$1"
  local root_dir
  root_dir="$(get_root_dir)"
  local winget_file="$root_dir/configs/windows/winget.json"

  echo ""
  info "Enter the winget package ID for '$package' (or press Enter to skip):"
  info "Hint: Search at https://winget.run or https://winstall.app"
  echo ""

  local winget_id
  read -r -p "Winget package ID: " winget_id

  if [[ -n "$winget_id" ]]; then
    info "Adding winget package: $winget_id"
    add_package_to_json "$winget_file" "$winget_id"
  fi
}

# Search for cross-platform equivalents
search_cross_platform_packages() {
  local package="$1"
  [[ -z "$package" ]] && return 0

  log "Searching for cross-platform package equivalents..."
  search_linuxbrew_package "$package"
  prompt_winget_package "$package"
}

# Update package manager cache
update_package_cache() {
  if is_linux; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get update
    elif command -v dnf &> /dev/null; then
      sudo dnf check-update || true
    elif command -v yum &> /dev/null; then
      sudo yum check-update || true
    elif command -v pacman &> /dev/null; then
      sudo pacman -Sy
    elif command -v apk &> /dev/null; then
      sudo apk update
    elif command -v zypper &> /dev/null; then
      sudo zypper refresh
    fi
  fi
}

# Install a package using the system package manager
install_package() {
  local package="$1"

  if is_macos; then
    if command -v brew &> /dev/null; then
      brew install "$package"
    else
      warn "No package manager available on macOS"
      return 1
    fi
  elif is_linux; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get install -y "$package"
    elif command -v dnf &> /dev/null; then
      sudo dnf install -y "$package"
    elif command -v yum &> /dev/null; then
      sudo yum install -y "$package"
    elif command -v pacman &> /dev/null; then
      sudo pacman -S --noconfirm "$package"
    elif command -v apk &> /dev/null; then
      sudo apk add "$package"
    elif command -v zypper &> /dev/null; then
      sudo zypper install -y "$package"
    else
      warn "No supported package manager found"
      return 1
    fi
  else
    warn "Unsupported operating system"
    return 1
  fi
}

# Upgrade all packages
upgrade_packages() {
  if is_macos; then
    if command -v brew &> /dev/null; then
      brew update && brew upgrade
    fi
  elif is_linux; then
    if command -v apt-get &> /dev/null; then
      sudo apt-get update && sudo apt-get upgrade -y
    elif command -v dnf &> /dev/null; then
      sudo dnf upgrade -y
    elif command -v yum &> /dev/null; then
      sudo yum update -y
    elif command -v pacman &> /dev/null; then
      sudo pacman -Syu --noconfirm
    elif command -v apk &> /dev/null; then
      sudo apk upgrade
    elif command -v zypper &> /dev/null; then
      sudo zypper update -y
    fi
  fi
}
