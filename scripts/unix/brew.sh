#!/usr/bin/env bash
# shellcheck disable=SC2207
# SC2207: Prefer mapfile or read -a to split command output (we use portable syntax)

set -u
set -o pipefail

# ============================================================================
# brew.sh - Homebrew/Linuxbrew Management Tool
# ============================================================================
# Comprehensive package management tool with declarative configuration.
#
# Commands:
#   sync               - Synchronize formulae between Darwin and Linux taskfiles
#   add                - Add cask/formula/service/link to configuration
#   remove             - Remove cask/formula/service/link from configuration
#   install            - Install Homebrew/Linuxbrew
#   uninstall          - Uninstall Homebrew/Linuxbrew (--force-wipe for complete removal)
#   check              - Check for outdated packages
#
# Configuration is stored in .taskfiles/{darwin,linux}/taskfile.yaml
# ============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# Determine the root directory of the project
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# OS-specific taskfile path
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS_TYPE" in
  darwin*)
    OS_TASKFILE="${ROOT_DIR}/.taskfiles/darwin/taskfile.yaml"
    ;;
  linux*)
    OS_TASKFILE="${ROOT_DIR}/.taskfiles/linux/taskfile.yaml"
    ;;
  *)
    echo -e "${RED}Unsupported OS: ${OS_TYPE}${RESET}" >&2
    exit 1
    ;;
esac

DARWIN_TASKFILE="${ROOT_DIR}/.taskfiles/darwin/taskfile.yaml"
LINUX_TASKFILE="${ROOT_DIR}/.taskfiles/linux/taskfile.yaml"

# ============================================================================
# Helper Functions
# ============================================================================

# Function to handle CTRL+C gracefully
SECTION_SKIP=0
LAST_SIGINT_TIME=0
trap_sigint() {
  local current_time
  current_time=$(date +%s)
  local time_diff=$((current_time - LAST_SIGINT_TIME))

  # If CTRL+C pressed twice within 2 seconds, exit
  if [[ $time_diff -lt 2 && $LAST_SIGINT_TIME -ne 0 ]]; then
    echo -e "\n${RED}❌ Interrupted by user${RESET}"
    exit 130
  fi

  LAST_SIGINT_TIME=$current_time
  SECTION_SKIP=1
  echo -e "\n${YELLOW}⏭️ Skipping section... (Press CTRL+C again to exit)${RESET}"
}

# Function to print colored messages
error() {
  echo -e "${RED}❌ $1${RESET}" >&2
}

success() {
  echo -e "${GREEN}✅ $1${RESET}"
}

warning() {
  echo -e "${YELLOW}⚠️ $1${RESET}"
}

info() {
  echo -e "$1"
}

# Function to prompt for confirmation
confirm() {
  local prompt="$1"
  local response
  read -r -n 1 -p "$prompt (y/N): " response
  echo # Add newline after single character input
  case "$response" in
    y | Y)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Detect OS and set Homebrew path
detect_brew_path() {
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    # macOS - check both Apple Silicon and Intel paths
    if [[ -d "/opt/homebrew" ]]; then
      echo "/opt/homebrew"
    elif [[ -d "/usr/local/Homebrew" ]]; then
      echo "/usr/local"
    else
      echo ""
    fi
  elif [[ "${OSTYPE}" == "linux"* ]] || grep -qi microsoft /proc/version 2> /dev/null; then
    # Linux or WSL
    if [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
      echo "/home/linuxbrew/.linuxbrew"
    else
      echo ""
    fi
  else
    echo ""
  fi
}

# Parse args
DRY_RUN=0
FORCE_UPDATE=0
FORCE_WIPE=0
SKIP_CONFIRM=0
IS_CASK=0
IS_SERVICE=0
AS_LINK=0
FORCE_REINSTALL=0
SILENT_MODE=0
COMMAND=""

# Show usage
show_usage() {
  cat << EOF
Usage: $0 <command> [options] [args]

Commands:
  sync               Synchronize formulae between Darwin and Linux taskfiles
  add <name>         Add package to configuration
  remove <name>      Remove package from configuration
  install            Install Homebrew/Linuxbrew
  uninstall          Uninstall Homebrew/Linuxbrew
  check              Check for outdated packages

Sync Options:
  -d, --dry-run      Show what would be changed without modifying files
  -f, --force        Force update all package descriptions

Add/Remove Options:
  -y, --yes          Skip confirmation prompts
  -f, --force        Force reinstall, re-add to lists, and update description
  --cask             Treat package as a cask (GUI application)
  --service          Install as a service (auto-start)
  --link             Create link for formula

Uninstall Options:
  --force-wipe       Remove all packages, services, and links before uninstalling

Check Options:
  --force            Run comprehensive interactive check (validate packages, descriptions, and prompt for undeclared packages)
  --silent           Suppress all output unless issues are found (useful for shell integrations)

Examples:
  $0 sync
  $0 sync --force
  $0 add jq
  $0 add firefox --cask
  $0 add syncthing --service
  $0 add jq --force              # Reinstall and update description
  $0 remove tldr -y
  $0 remove firefox --cask
  $0 uninstall --force-wipe
  $0 check                       # Quick check for outdated packages
  $0 check --force               # Comprehensive check with interactive prompts
  $0 check --silent              # Silent check for shell integrations
EOF
  exit 0
}

# Parse command and arguments
if [[ $# -eq 0 ]]; then
  show_usage
fi

COMMAND="$1"
shift

# Preserve remaining args for commands that need them
REMAINING_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y | --yes)
      SKIP_CONFIRM=1
      shift
      ;;
    -d | --dry-run)
      DRY_RUN=1
      shift
      ;;
    -f | --force)
      # Check if this is for the 'add' command
      if [[ "$COMMAND" == "add" ]]; then
        FORCE_REINSTALL=1
      else
        FORCE_UPDATE=1
        REMAINING_ARGS+=("$1")
      fi
      shift
      ;;
    --force-wipe)
      FORCE_WIPE=1
      shift
      ;;
    --cask)
      IS_CASK=1
      shift
      ;;
    --service)
      IS_SERVICE=1
      shift
      ;;
    --link)
      AS_LINK=1
      shift
      ;;
    --silent)
      SILENT_MODE=1
      shift
      ;;
    -h | --help)
      show_usage
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift
      ;;
  esac
done

# ============================================================================
# Package Extraction Functions
# ============================================================================

# Extract package names from taskfile YAML
extract_packages() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi

  awk -v key="$key" '
    /^vars:/ {
      in_vars = 1
      next
    }
    in_vars && /^[a-zA-Z_-]+:/ && !/^  / {
      in_vars = 0
    }
    in_vars && $0 ~ "^  " key ":" {
      in_section = 1
      next
    }
    in_section && /^  [a-zA-Z_-]+:/ {
      in_section = 0
    }
    in_section && /^    - / {
      sub(/^    - /, "")
      sub(/ #.*$/, "")
      gsub(/ /, "")
      if ($0 != "") print $0
    }
  ' "$file" | sort -u
}

# Extract packages with their descriptions
extract_packages_with_descriptions() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    return
  fi

  awk -v key="$key" '
    /^vars:/ {
      in_vars = 1
      next
    }
    in_vars && /^[a-zA-Z_-]+:/ && !/^  / {
      in_vars = 0
    }
    in_vars && $0 ~ "^  " key ":" {
      in_section = 1
      next
    }
    in_section && /^  [a-zA-Z_-]+:/ {
      in_section = 0
    }
    in_section && /^    - / {
      line = $0
      sub(/^    - /, "", line)

      if (match(line, / # /)) {
        pkg = substr(line, 1, RSTART - 1)
        desc = substr(line, RSTART + 3)
        gsub(/ /, "", pkg)
        print pkg "|||" desc
      } else {
        gsub(/ /, "", line)
        print line "|||"
      }
    }
  ' "$file"
}

# Check if a package is available in Homebrew repos
check_package_availability() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  if [[ "$pkg_type" == "cask" ]]; then
    brew info --cask "$pkg" &> /dev/null
    return $?
  else
    brew info --formula "$pkg" &> /dev/null
    return $?
  fi
}

# Check if a package exists in Homebrew API (works for both Darwin and Linux repos)
check_package_in_api() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  local api_url=""
  if [[ "$pkg_type" == "cask" ]]; then
    api_url="https://formulae.brew.sh/api/cask/${pkg}.json"
  else
    api_url="https://formulae.brew.sh/api/formula/${pkg}.json"
  fi

  # Use curl to check if the package exists in the API
  if curl -sf "$api_url" &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# Get brew description for a package
get_brew_description() {
  local pkg="$1"
  local pkg_type="$2" # "formula" or "cask"

  local desc=""

  # Try API first (works cross-platform), fall back to local brew info
  local api_url=""
  if [[ "$pkg_type" == "cask" ]]; then
    api_url="https://formulae.brew.sh/api/cask/${pkg}.json"
  else
    api_url="https://formulae.brew.sh/api/formula/${pkg}.json"
  fi

  # Fetch from API
  local api_response
  api_response=$(curl -sf "$api_url" 2> /dev/null || echo "")

  if [[ -n "$api_response" ]]; then
    if [[ "$pkg_type" == "cask" ]]; then
      desc=$(echo "$api_response" | jq -r '.desc // empty' 2> /dev/null || echo "")
      if [[ -z "$desc" ]]; then
        desc=$(echo "$api_response" | jq -r '.name[0] // empty' 2> /dev/null || echo "")
      fi
    else
      desc=$(echo "$api_response" | jq -r '.desc // empty' 2> /dev/null || echo "")
    fi
  fi

  # Fall back to local brew info if API didn't work
  if [[ -z "$desc" ]]; then
    if [[ "$pkg_type" == "cask" ]]; then
      desc=$(brew info --cask --json=v2 "$pkg" 2> /dev/null | jq -r '.casks[0].desc // empty' 2> /dev/null || echo "")
      if [[ -z "$desc" ]]; then
        desc=$(brew info --cask --json=v2 "$pkg" 2> /dev/null | jq -r '.casks[0].name[0] // empty' 2> /dev/null || echo "")
      fi
    else
      desc=$(brew info --json=v2 "$pkg" 2> /dev/null | jq -r '.formulae[0].desc // empty' 2> /dev/null || echo "")

      if [[ -z "$desc" ]]; then
        desc=$(brew info "$pkg" 2> /dev/null | sed -n '2p' || echo "")
      fi
    fi
  fi

  # Clean up description
  desc=$(echo "$desc" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
  desc=$(echo "$desc" | sed 's/^stable [0-9][^ ]* (bottled).*$//' | sed 's/^stable [0-9][^ ]*.*HEAD$//')
  desc=$(echo "$desc" | sed 's/^ *//;s/ *$//')

  echo "$desc"
}

# ============================================================================
# Add/Remove Package Functions
# ============================================================================

# Add a package to a specific taskfile
add_package_to_file() {
  local pkg_name="$1"
  local taskfile="$2"
  local pkg_type="$3"
  local key="$4"
  local install="${5:-1}" # Whether to install (default: yes)
  local force="${6:-0}"   # Force reinstall (default: no)

  local already_exists=0
  if extract_packages "$taskfile" "$key" | grep -qx "$pkg_name"; then
    already_exists=1
  fi

  # Handle force flag
  if [[ $force -eq 1 ]]; then
    info "Force mode: Reinstalling $pkg_type: $pkg_name"

    # Only install if on current OS and install flag is set
    if [[ $install -eq 1 ]]; then
      case "$pkg_type" in
        cask)
          brew reinstall --cask "$pkg_name" 2> /dev/null || true
          ;;
        formula)
          brew reinstall "$pkg_name" 2> /dev/null || true
          ;;
        service)
          brew reinstall "$pkg_name" 2> /dev/null || true
          brew services restart "$pkg_name" 2> /dev/null || true
          ;;
        link)
          brew reinstall "$pkg_name" 2> /dev/null || true
          brew unlink "$pkg_name" 2> /dev/null || true
          brew link "$pkg_name" 2> /dev/null || true
          ;;
      esac
    fi

    # Remove existing entry to ensure fresh addition
    if [[ $already_exists -eq 1 ]]; then
      local tmp
      tmp=$(mktemp)

      awk -v key="$key" -v pkg="$pkg_name" '
        BEGIN {
          in_section = 0
        }
        /^vars:/ {
          in_vars = 1
        }
        in_vars && $0 ~ "^  " key ":" {
          in_section = 1
          print
          next
        }
        in_section && /^  [a-zA-Z_-]+:/ {
          in_section = 0
        }
        in_section && /^    - / {
          line = $0
          sub(/^    - /, "", line)
          sub(/ #.*$/, "", line)
          gsub(/ /, "", line)
          if (line != pkg) {
            print $0
          }
          next
        }
        { print }
      ' "$taskfile" > "$tmp" && mv "$tmp" "$taskfile"
    fi
  else
    # Check if already exists
    if [[ $already_exists -eq 1 ]]; then
      return 0 # Already exists, skip
    fi

    # Install the package only if on current OS and install flag is set
    if [[ $install -eq 1 ]]; then
      case "$pkg_type" in
        cask)
          brew install --cask "$pkg_name" 2> /dev/null || return 1
          ;;
        formula)
          brew install "$pkg_name" 2> /dev/null || return 1
          ;;
        service)
          brew install "$pkg_name" 2> /dev/null || return 1
          brew services start "$pkg_name" 2> /dev/null || true
          ;;
        link)
          brew install "$pkg_name" 2> /dev/null || return 1
          brew link "$pkg_name" 2> /dev/null || true
          ;;
      esac
    fi
  fi

  # Get description for casks and formulae
  local desc=""
  if [[ "$pkg_type" == "cask" || "$pkg_type" == "formula" ]]; then
    desc=$(get_brew_description "$pkg_name" "$pkg_type")
  fi

  # Add to taskfile
  local tmp
  tmp=$(mktemp)

  awk -v key="$key" -v pkg="$pkg_name" -v desc="$desc" '
    BEGIN {
      in_vars = 0
      found_key = 0
      added = 0
    }
    {
      lines[NR] = $0
    }
    /^vars:/ {
      in_vars = 1
      vars_line = NR
    }
    in_vars && $0 ~ "^  " key ":" {
      found_key = 1
      key_line = NR
    }
    END {
      if (found_key) {
        # Find section end
        section_end = key_line
        for (i = key_line + 1; i <= NR; i++) {
          if (lines[i] ~ /^    - /) {
            section_end = i
          } else if (lines[i] !~ /^[[:space:]]*$/ && lines[i] !~ /^    /) {
            break
          }
        }

        # Collect existing packages
        pkg_count = 0
        for (i = key_line + 1; i <= section_end; i++) {
          if (lines[i] ~ /^    - /) {
            pkg_count++
            packages[pkg_count] = lines[i]
          }
        }

        # Add new package
        if (desc != "") {
          packages[pkg_count + 1] = "    - " pkg " # " desc
        } else {
          packages[pkg_count + 1] = "    - " pkg
        }
        pkg_count++

        # Sort packages
        for (i = 1; i <= pkg_count; i++) {
          for (j = i + 1; j <= pkg_count; j++) {
            pkg_i = packages[i]
            pkg_j = packages[j]
            sub(/^[[:space:]]*- /, "", pkg_i)
            sub(/ #.*$/, "", pkg_i)
            sub(/^[[:space:]]*- /, "", pkg_j)
            sub(/ #.*$/, "", pkg_j)

            if (tolower(pkg_i) > tolower(pkg_j)) {
              temp = packages[i]
              packages[i] = packages[j]
              packages[j] = temp
            }
          }
        }

        # Print everything up to key line
        for (i = 1; i <= key_line; i++) {
          print lines[i]
        }

        # Print sorted packages
        for (i = 1; i <= pkg_count; i++) {
          print packages[i]
        }

        # Print remaining lines
        for (i = section_end + 1; i <= NR; i++) {
          print lines[i]
        }
      } else {
        # Key not found, print original and append
        for (i = 1; i <= NR; i++) {
          print lines[i]
        }

        if (desc != "") {
          pkg_line = "    - " pkg " # " desc
        } else {
          pkg_line = "    - " pkg
        }

        if (in_vars) {
          printf("\n  %s:\n%s\n", key, pkg_line)
        } else {
          printf("\nvars:\n  %s:\n%s\n", key, pkg_line)
        }
      }
    }
  ' "$taskfile" > "$tmp" && mv "$tmp" "$taskfile"

  return 0
}

# Add a package to the taskfile(s)
add_package() {
  local pkg_name="$1"

  if [[ -z "$pkg_name" ]]; then
    error "Package name is required"
    info "Usage: $0 add <name> [--cask|--service|--link] [--force]"
    exit 1
  fi

  # Determine package type from flags
  local pkg_type="formula"
  local key="formulae"

  if [[ $IS_CASK -eq 1 ]]; then
    pkg_type="cask"
    key="casks"
  elif [[ $IS_SERVICE -eq 1 ]]; then
    pkg_type="service"
    key="services"
  elif [[ $AS_LINK -eq 1 ]]; then
    pkg_type="link"
    key="links"
  fi

  # Casks are Darwin-only by nature
  local is_darwin_only=0
  local is_linux_only=0

  if [[ $IS_CASK -eq 1 ]]; then
    is_darwin_only=1
  fi

  # Confirm installation
  if [[ $SKIP_CONFIRM -eq 0 && $FORCE_REINSTALL -eq 0 ]]; then
    if ! confirm "Install $pkg_name?"; then
      warning "Installation cancelled"
      exit 1
    fi
  fi

  # Determine which platforms to add to
  local add_to_darwin=0
  local add_to_linux=0
  local current_os=""

  if [[ "${OSTYPE}" == "darwin"* ]]; then
    current_os="darwin"
  else
    current_os="linux"
  fi

  # Check package availability and determine target platforms
  if [[ $is_darwin_only -eq 1 ]]; then
    add_to_darwin=1
    info "Package is Darwin-specific"
  elif [[ $is_linux_only -eq 1 ]]; then
    add_to_linux=1
    info "Package is Linux-specific"
  else
    # Check availability in Homebrew API
    info "Checking package availability across platforms..."

    if check_package_in_api "$pkg_name" "$pkg_type"; then
      success "Package found in Homebrew repository"

      # Verify locally on current platform
      if check_package_availability "$pkg_name" "$pkg_type"; then
        if [[ "$current_os" == "darwin" ]]; then
          add_to_darwin=1
          success "Verified in local Homebrew (Darwin)"
        else
          add_to_linux=1
          success "Verified in local Linuxbrew"
        fi
      else
        warning "Package exists in API but not available locally - this might be platform-specific"
        if [[ "$current_os" == "darwin" ]]; then
          add_to_darwin=1
        else
          add_to_linux=1
        fi
      fi

      # For formulae (not casks), add to both platforms since API confirms availability
      # Casks are Darwin-only by design
      if [[ $IS_CASK -eq 0 ]]; then
        add_to_darwin=1
        add_to_linux=1
        info "Will add to both platforms (cross-platform formula)"
      fi
    else
      error "Package '$pkg_name' not found in Homebrew repository"
      exit 1
    fi
  fi

  # Track success/failure for each platform
  local darwin_success=0
  local linux_success=0

  # Add to Darwin taskfile
  if [[ $add_to_darwin -eq 1 ]]; then
    if [[ ! -f "$DARWIN_TASKFILE" ]]; then
      warning "Darwin taskfile not found: $DARWIN_TASKFILE"
    else
      local should_install=0
      [[ "$current_os" == "darwin" ]] && should_install=1

      if [[ $should_install -eq 1 ]]; then
        info "Adding to Darwin and installing..."
      else
        info "Adding to Darwin taskfile (no install)..."
      fi

      if add_package_to_file "$pkg_name" "$DARWIN_TASKFILE" "$pkg_type" "$key" "$should_install" "$FORCE_REINSTALL"; then
        success "Added to Darwin taskfile"
        darwin_success=1
      else
        warning "Failed to add to Darwin taskfile"
      fi
    fi
  fi

  # Add to Linux taskfile (formulae only, no casks)
  if [[ $add_to_linux -eq 1 && $IS_CASK -eq 0 ]]; then
    if [[ ! -f "$LINUX_TASKFILE" ]]; then
      warning "Linux taskfile not found: $LINUX_TASKFILE"
    else
      local should_install=0
      [[ "$current_os" == "linux" ]] && should_install=1

      if [[ $should_install -eq 1 ]]; then
        info "Adding to Linux and installing..."
      else
        info "Adding to Linux taskfile (no install)..."
      fi

      if add_package_to_file "$pkg_name" "$LINUX_TASKFILE" "$pkg_type" "$key" "$should_install" "$FORCE_REINSTALL"; then
        success "Added to Linux taskfile"
        linux_success=1
      else
        warning "Failed to add to Linux taskfile"
      fi
    fi
  fi

  # Final status
  echo ""
  if [[ $darwin_success -eq 1 || $linux_success -eq 1 ]]; then
    if [[ $darwin_success -eq 1 && $linux_success -eq 1 ]]; then
      success "$pkg_name added to both Darwin and Linux"
    elif [[ $darwin_success -eq 1 ]]; then
      success "$pkg_name added to Darwin"
    else
      success "$pkg_name added to Linux"
    fi
  else
    error "Failed to add $pkg_name to any platform"
    exit 1
  fi
}

# Remove a package from the taskfile
remove_package() {
  local pkg_name="$1"

  if [[ -z "$pkg_name" ]]; then
    error "Package name is required"
    info "Usage: $0 remove <name> [--cask|--service|--link]"
    exit 1
  fi

  # Determine package type from flags
  local pkg_type="formula"
  local key="formulae"

  if [[ $IS_CASK -eq 1 ]]; then
    pkg_type="cask"
    key="casks"
  elif [[ $IS_SERVICE -eq 1 ]]; then
    pkg_type="service"
    key="services"
  elif [[ $AS_LINK -eq 1 ]]; then
    pkg_type="link"
    key="links"
  fi

  info "Removing $pkg_type: $pkg_name from $OS_TASKFILE"

  # Check if exists
  if ! extract_packages "$OS_TASKFILE" "$key" | grep -qx "$pkg_name"; then
    warning "$pkg_name not found in $key section"
    exit 1
  fi

  # Confirm removal
  if [[ $SKIP_CONFIRM -eq 0 ]]; then
    if ! confirm "Remove $pkg_name from system and configuration?"; then
      warning "Removal cancelled"
      exit 1
    fi
  fi

  # Stop service if applicable
  if [[ "$pkg_type" == "service" ]]; then
    info "Stopping service: $pkg_name"
    brew services stop "$pkg_name" 2> /dev/null || true
  fi

  # Uninstall the package
  case "$pkg_type" in
    cask)
      info "Uninstalling cask: $pkg_name"
      brew uninstall --cask "$pkg_name"
      ;;
    formula | service | link)
      info "Uninstalling formula: $pkg_name"
      brew uninstall --ignore-dependencies "$pkg_name"
      ;;
  esac

  # Remove from taskfile
  local tmp
  tmp=$(mktemp)

  awk -v key="$key" -v pkg="$pkg_name" '
    BEGIN {
      in_section = 0
    }
    /^vars:/ {
      in_vars = 1
    }
    in_vars && $0 ~ "^  " key ":" {
      in_section = 1
      print
      next
    }
    in_section && /^  [a-zA-Z_-]+:/ {
      in_section = 0
    }
    in_section && /^    - / {
      line = $0
      sub(/^    - /, "", line)
      sub(/ #.*$/, "", line)
      gsub(/ /, "", line)
      if (line != pkg) {
        print $0
      }
      next
    }
    { print }
  ' "$OS_TASKFILE" > "$tmp" && mv "$tmp" "$OS_TASKFILE"

  success "$pkg_name removed from $key section"
}

# ============================================================================
# Sync Functions
# ============================================================================

# Get unique formulae from a taskfile
get_unique_formulae() {
  local file="$1"
  extract_packages "$file" "formulae" | sort -u
}

# Check if a package is a cask
is_cask() {
  local pkg="$1"
  brew info --cask "$pkg" &> /dev/null
  return $?
}

# Synchronize formulae between darwin and linux
sync_formulae() {
  echo -e "${CYAN}🔄 Synchronizing formulae between Darwin and Linux...${RESET}\n"

  # Check if taskfiles exist
  if [[ ! -f "$DARWIN_TASKFILE" ]]; then
    error "Darwin taskfile not found: $DARWIN_TASKFILE"
    exit 1
  fi

  if [[ ! -f "$LINUX_TASKFILE" ]]; then
    error "Linux taskfile not found: $LINUX_TASKFILE"
    exit 1
  fi

  # Extract packages with descriptions from both taskfiles
  declare -A darwin_formulae_desc=()
  declare -A darwin_casks_desc=()
  declare -A linux_formulae_desc=()

  while IFS='|||' read -r pkg desc; do
    if [[ -n "$pkg" ]]; then
      darwin_formulae_desc[$pkg]="$desc"
    fi
  done < <(extract_packages_with_descriptions "$DARWIN_TASKFILE" "formulae")

  while IFS='|||' read -r pkg desc; do
    if [[ -n "$pkg" ]]; then
      darwin_casks_desc[$pkg]="$desc"
    fi
  done < <(extract_packages_with_descriptions "$DARWIN_TASKFILE" "casks")

  while IFS='|||' read -r pkg desc; do
    if [[ -n "$pkg" ]]; then
      linux_formulae_desc[$pkg]="$desc"
    fi
  done < <(extract_packages_with_descriptions "$LINUX_TASKFILE" "formulae")

  # Get unique package names
  local -a darwin_formulae=()
  local -a linux_formulae=()

  for pkg in "${!darwin_formulae_desc[@]}"; do
    darwin_formulae+=("$pkg")
  done
  for pkg in "${!linux_formulae_desc[@]}"; do
    linux_formulae+=("$pkg")
  done

  # Build lists of packages to process
  local -a all_formulae=()
  local -a packages_to_add_darwin=()
  local -a packages_to_add_linux=()
  local -a packages_to_update=()

  # Combine all formula packages
  for pkg in "${darwin_formulae[@]}"; do
    local pkg_exists=0
    for existing in "${all_formulae[@]}"; do
      if [[ "$existing" == "$pkg" ]]; then
        pkg_exists=1
        break
      fi
    done
    if [[ $pkg_exists -eq 0 ]]; then
      all_formulae+=("$pkg")
    fi
  done
  for pkg in "${linux_formulae[@]}"; do
    local pkg_exists=0
    for existing in "${all_formulae[@]}"; do
      if [[ "$existing" == "$pkg" ]]; then
        pkg_exists=1
        break
      fi
    done
    if [[ $pkg_exists -eq 0 ]]; then
      all_formulae+=("$pkg")
    fi
  done

  # Sort all formulae
  if [[ ${#all_formulae[@]} -gt 0 ]]; then
    IFS=$'\n' all_formulae=($(printf '%s\n' "${all_formulae[@]}" | sort -u))
    unset IFS
  fi

  info "📦 Analyzing packages..."
  echo ""

  # Analyze each package
  for pkg in "${all_formulae[@]}"; do
    local in_darwin=0
    local in_linux=0

    [[ -n "${darwin_formulae_desc[$pkg]:-}" ]] && in_darwin=1
    [[ -n "${linux_formulae_desc[$pkg]:-}" ]] && in_linux=1

    # Package exists in both - check for description mismatch
    if [[ $in_darwin -eq 1 && $in_linux -eq 1 ]]; then
      local darwin_desc="${darwin_formulae_desc[$pkg]}"
      local linux_desc="${linux_formulae_desc[$pkg]}"

      if [[ "$darwin_desc" != "$linux_desc" ]]; then
        packages_to_update+=("$pkg")
      fi
    # Package only in darwin - candidate for linux
    elif [[ $in_darwin -eq 1 && $in_linux -eq 0 ]]; then
      packages_to_add_linux+=("$pkg")
    # Package only in linux - candidate for darwin
    elif [[ $in_darwin -eq 0 && $in_linux -eq 1 ]]; then
      packages_to_add_darwin+=("$pkg")
    fi
  done

  # Report findings
  if [[ ${#packages_to_update[@]} -gt 0 ]]; then
    warning "Found ${#packages_to_update[@]} package(s) with mismatched descriptions:"
    for pkg in "${packages_to_update[@]}"; do
      local darwin_desc="${darwin_formulae_desc[$pkg]}"
      local linux_desc="${linux_formulae_desc[$pkg]}"
      # Strip delimiter artifacts for display
      darwin_desc="${darwin_desc#|||}"
      darwin_desc="${darwin_desc#||}"
      darwin_desc="${darwin_desc#|}"
      linux_desc="${linux_desc#|||}"
      linux_desc="${linux_desc#||}"
      linux_desc="${linux_desc#|}"
      echo "  - $pkg"
      echo "    Darwin: ${darwin_desc}"
      echo "    Linux:  ${linux_desc}"
    done
    echo ""
  fi

  if [[ ${#packages_to_add_darwin[@]} -gt 0 ]]; then
    info "Found ${#packages_to_add_darwin[@]} package(s) only in Linux"
  fi

  if [[ ${#packages_to_add_linux[@]} -gt 0 ]]; then
    info "Found ${#packages_to_add_linux[@]} package(s) only in Darwin"
  fi

  echo ""

  if [[ $DRY_RUN -eq 1 ]]; then
    warning "🔍 DRY RUN MODE - No files will be modified"
    echo ""
    success "Dry run complete. Use without --dry-run to apply changes."
    exit 0
  fi

  # Process packages to add to darwin (check API availability)
  local -a confirmed_darwin_formulae=()
  local -a confirmed_darwin_casks=()

  if [[ ${#packages_to_add_darwin[@]} -gt 0 ]]; then
    info "Checking availability for packages to add to Darwin..."
    for pkg in "${packages_to_add_darwin[@]}"; do
      # Check if it's a cask
      if is_cask "$pkg"; then
        if check_package_in_api "$pkg" "cask"; then
          confirmed_darwin_casks+=("$pkg")
          success "  ✓ Will add $pkg as cask to Darwin (API confirmed)"
        else
          warning "  ✗ Skipping $pkg - not available as cask"
        fi
      else
        # Check if available as formula
        if check_package_in_api "$pkg" "formula"; then
          confirmed_darwin_formulae+=("$pkg")
          success "  ✓ Will add $pkg as formula to Darwin (API confirmed)"
        else
          warning "  ✗ Skipping $pkg - not available on Darwin"
        fi
      fi
    done
    echo ""
  fi

  # Process packages to add to linux (check API availability)
  local -a confirmed_linux_formulae=()

  if [[ ${#packages_to_add_linux[@]} -gt 0 ]]; then
    info "Checking availability for packages to add to Linux..."
    for pkg in "${packages_to_add_linux[@]}"; do
      # Casks are darwin-only, so only check as formula
      if check_package_in_api "$pkg" "formula"; then
        confirmed_linux_formulae+=("$pkg")
        success "  ✓ Will add $pkg as formula to Linux (API confirmed)"
      else
        warning "  ✗ Skipping $pkg - not available on Linux"
      fi
    done
    echo ""
  fi

  # Update descriptions for mismatched packages and build final lists
  # shellcheck disable=SC2034
  declare -A final_darwin_formulae_desc=()
  # shellcheck disable=SC2034
  declare -A final_darwin_casks_desc=()
  # shellcheck disable=SC2034
  declare -A final_linux_formulae_desc=()

  # Copy existing descriptions
  for pkg in "${!darwin_formulae_desc[@]}"; do
    final_darwin_formulae_desc[$pkg]="${darwin_formulae_desc[$pkg]}"
  done
  for pkg in "${!darwin_casks_desc[@]}"; do
    final_darwin_casks_desc[$pkg]="${darwin_casks_desc[$pkg]}"
  done
  for pkg in "${!linux_formulae_desc[@]}"; do
    final_linux_formulae_desc[$pkg]="${linux_formulae_desc[$pkg]}"
  done

  # Update mismatched descriptions
  if [[ ${#packages_to_update[@]} -gt 0 ]]; then
    info "📝 Updating mismatched descriptions..."
    for pkg in "${packages_to_update[@]}"; do
      local new_desc
      new_desc=$(get_brew_description "$pkg" "formula")
      # shellcheck disable=SC2034
      final_darwin_formulae_desc[$pkg]="$new_desc"
      # shellcheck disable=SC2034
      final_linux_formulae_desc[$pkg]="$new_desc"
      echo "  ✓ Updated $pkg"
    done
    echo ""
  fi

  # Add new packages with descriptions
  if [[ ${#confirmed_darwin_formulae[@]} -gt 0 || ${#confirmed_darwin_casks[@]} -gt 0 ]]; then
    info "📝 Fetching descriptions for new Darwin packages..."
    for pkg in "${confirmed_darwin_formulae[@]}"; do
      local desc
      desc=$(get_brew_description "$pkg" "formula")
      # shellcheck disable=SC2034
      final_darwin_formulae_desc[$pkg]="$desc"
      echo "  ✓ $pkg"
    done
    for pkg in "${confirmed_darwin_casks[@]}"; do
      local desc
      desc=$(get_brew_description "$pkg" "cask")
      # shellcheck disable=SC2034
      final_darwin_casks_desc[$pkg]="$desc"
      echo "  ✓ $pkg (cask)"
    done
    echo ""
  fi

  if [[ ${#confirmed_linux_formulae[@]} -gt 0 ]]; then
    info "📝 Fetching descriptions for new Linux packages..."
    for pkg in "${confirmed_linux_formulae[@]}"; do
      local desc
      desc=$(get_brew_description "$pkg" "formula")
      # shellcheck disable=SC2034
      final_linux_formulae_desc[$pkg]="$desc"
      echo "  ✓ $pkg"
    done
    echo ""
  fi

  # Update taskfiles
  info "📝 Updating Darwin taskfile..."
  update_section_with_descriptions "$DARWIN_TASKFILE" "formulae" final_darwin_formulae_desc
  update_section_with_descriptions "$DARWIN_TASKFILE" "casks" final_darwin_casks_desc

  info "📝 Updating Linux taskfile..."
  update_section_with_descriptions "$LINUX_TASKFILE" "formulae" final_linux_formulae_desc

  echo ""
  success "Synchronization complete!"
  info "Both taskfiles have been updated, sorted, and commented."
  info "Review changes with: git diff"

  # Run comprehensive check if --force flag was provided
  if [[ $FORCE_UPDATE -eq 1 ]]; then
    echo ""
    brew_check --force
  fi
}

# Update the formulae section in a taskfile
update_formulae_section() {
  local file="$1"
  local packages_var=$2

  local -n packages_ref="$packages_var"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    exit 1
  fi

  # Extract existing packages with descriptions
  declare -A existing_descriptions=()
  if [[ $FORCE_UPDATE -eq 0 ]]; then
    while IFS='|||' read -r pkg desc; do
      if [[ -n "$pkg" ]]; then
        existing_descriptions[$pkg]="$desc"
      fi
    done < <(extract_packages_with_descriptions "$file" "formulae")
  fi

  # Build package list with descriptions
  declare -A pkg_descriptions=()
  local -a sorted_packages=()
  local -a packages_to_fetch=()

  # Determine which packages need description fetching
  for pkg in "${packages_ref[@]}"; do
    sorted_packages+=("$pkg")

    if [[ $FORCE_UPDATE -eq 1 ]]; then
      packages_to_fetch+=("$pkg")
    elif [[ -z "${existing_descriptions[$pkg]:-}" ]]; then
      packages_to_fetch+=("$pkg")
    else
      pkg_descriptions[$pkg]="${existing_descriptions[$pkg]}"
    fi
  done

  # Fetch descriptions only for packages that need them
  if [[ ${#packages_to_fetch[@]} -gt 0 ]]; then
    info "Fetching descriptions for ${#packages_to_fetch[@]} package(s)... ${CYAN}(CTRL+C to skip, twice to exit)${RESET}"

    # Enable CTRL+C trap
    SECTION_SKIP=0
    trap trap_sigint SIGINT

    for pkg in "${packages_to_fetch[@]}"; do
      # Check if section was skipped
      if [[ $SECTION_SKIP -eq 1 ]]; then
        info "Skipped remaining description fetches"
        trap - SIGINT
        SECTION_SKIP=0 # Reset flag
        break
      fi

      local desc
      desc=$(get_brew_description "$pkg" "formula")
      pkg_descriptions[$pkg]="$desc"

      echo -ne "  "
      if [[ -n "$desc" ]]; then
        echo -e "${GREEN}✓${RESET} $pkg"
      else
        echo -e "${YELLOW}○${RESET} $pkg (no description)"
      fi
    done

    # Remove trap
    trap - SIGINT
  else
    info "All descriptions up to date (use --force to refresh)"
  fi

  # Sort packages case-insensitively
  IFS=$'\n' sorted_packages=($(printf '%s\n' "${sorted_packages[@]}" | sort -f))
  unset IFS

  # Create new formulae section
  local tmp
  tmp=$(mktemp)

  awk -v key="formulae" '
    BEGIN {
      in_vars = 0
      found_formulae = 0
      formulae_start = 0
      formulae_end = 0
    }
    {
      lines[NR] = $0
    }
    /^vars:/ {
      in_vars = 1
    }
    in_vars && /^  formulae:/ {
      found_formulae = 1
      formulae_start = NR
    }
    found_formulae && /^    - / {
      formulae_end = NR
    }
    found_formulae && /^  [a-zA-Z_-]+:/ && !/^  formulae:/ {
      found_formulae = 0
    }
    END {
      if (formulae_start > 0) {
        for (i = 1; i <= formulae_start; i++) {
          print lines[i]
        }
        print "PACKAGES_PLACEHOLDER"
        for (i = formulae_end + 1; i <= NR; i++) {
          print lines[i]
        }
      } else {
        for (i = 1; i <= NR; i++) {
          print lines[i]
        }
      }
    }
  ' "$file" > "$tmp"

  # Build the package lines
  local package_lines=""
  for pkg in "${sorted_packages[@]}"; do
    local desc="${pkg_descriptions[$pkg]}"
    # Strip delimiter artifacts
    desc="${desc#|||}"
    desc="${desc#||}"
    desc="${desc#|}"
    if [[ -n "$desc" ]]; then
      package_lines+="    - ${pkg} # ${desc}\n"
    else
      package_lines+="    - ${pkg}\n"
    fi
  done

  # Replace placeholder
  local tmp2
  tmp2=$(mktemp)

  awk -v pkg_lines="$package_lines" '
    /PACKAGES_PLACEHOLDER/ {
      printf "%s", pkg_lines
      next
    }
    { print }
  ' "$tmp" > "$tmp2" && mv "$tmp2" "$file"

  rm -f "$tmp"

  success "Updated $file"
}

# Update a section with descriptions from an associative array
update_section_with_descriptions() {
  local file="$1"
  local section="$2"
  local descriptions_var=$3

  local -n descriptions_ref="$descriptions_var"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    exit 1
  fi

  # Get sorted package list
  local -a sorted_packages=()
  for pkg in "${!descriptions_ref[@]}"; do
    sorted_packages+=("$pkg")
  done

  # Sort packages case-insensitively
  if [[ ${#sorted_packages[@]} -gt 0 ]]; then
    IFS=$'\n' sorted_packages=($(printf '%s\n' "${sorted_packages[@]}" | sort -f))
    unset IFS
  fi

  # Create new section
  local tmp
  tmp=$(mktemp)

  awk -v key="$section" '
    BEGIN {
      in_vars = 0
      found_section = 0
      section_start = 0
      section_end = 0
    }
    {
      lines[NR] = $0
    }
    /^vars:/ {
      in_vars = 1
    }
    in_vars && $0 ~ "^  " key ":" {
      found_section = 1
      section_start = NR
    }
    found_section && /^    - / {
      section_end = NR
    }
    found_section && /^  [a-zA-Z_-]+:/ && $0 !~ "^  " key ":" {
      found_section = 0
    }
    END {
      if (section_start > 0) {
        for (i = 1; i <= section_start; i++) {
          print lines[i]
        }
        print "PACKAGES_PLACEHOLDER"
        for (i = section_end + 1; i <= NR; i++) {
          print lines[i]
        }
      } else {
        for (i = 1; i <= NR; i++) {
          print lines[i]
        }
      }
    }
  ' "$file" > "$tmp"

  # Build the package lines
  local package_lines=""
  for pkg in "${sorted_packages[@]}"; do
    local desc="${descriptions_ref[$pkg]}"
    # Strip delimiter artifacts
    desc="${desc#|||}"
    desc="${desc#||}"
    desc="${desc#|}"
    if [[ -n "$desc" ]]; then
      package_lines+="    - ${pkg} # ${desc}\n"
    else
      package_lines+="    - ${pkg}\n"
    fi
  done

  # Replace placeholder
  local tmp2
  tmp2=$(mktemp)

  awk -v pkg_lines="$package_lines" '
    /PACKAGES_PLACEHOLDER/ {
      printf "%s", pkg_lines
      next
    }
    { print }
  ' "$tmp" > "$tmp2" && mv "$tmp2" "$file"

  rm -f "$tmp"

  success "Updated $file - $section"
}

# ============================================================================
# Install/Uninstall Homebrew
# ============================================================================

# Install Homebrew/Linuxbrew
brew_install() {
  local BREW_PREFIX
  BREW_PREFIX=$(detect_brew_path)

  if [[ -n "$BREW_PREFIX" ]]; then
    warning "Homebrew is already installed at: $BREW_PREFIX"
    exit 0
  fi

  info "Installing Homebrew/Linuxbrew..."
  echo ""

  # Run official install script
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  success "Homebrew installation complete!"
  info "Add Homebrew to your PATH by following the instructions above"
}

# Uninstall Homebrew/Linuxbrew
brew_uninstall() {
  local BREW_PREFIX
  BREW_PREFIX=$(detect_brew_path)

  if [[ -z "$BREW_PREFIX" ]]; then
    error "Homebrew installation not found."
    exit 1
  fi

  info "Found Homebrew at: $BREW_PREFIX"
  echo ""

  if [[ $FORCE_WIPE -eq 1 ]]; then
    warning "WARNING: --force-wipe will remove ALL packages, services, and links!"
    echo ""
    info "This process will:"
    info "  1. Stop all services"
    info "  2. Uninstall all casks"
    info "  3. Uninstall all formulae"
    info "  4. Run Homebrew uninstall script"
    info "  5. Remove all Homebrew directories"
    echo ""

    if ! confirm "Are you ABSOLUTELY sure you want to continue?"; then
      error "Uninstall cancelled."
      exit 1
    fi

    # Stop all services
    info "Stopping all services..."
    brew services stop --all 2> /dev/null || true

    # Uninstall all casks
    info "Uninstalling all casks..."
    brew list --cask 2> /dev/null | xargs -n1 brew uninstall --cask --force 2> /dev/null || true

    # Uninstall all formulae
    info "Uninstalling all formulae..."
    brew list --formula 2> /dev/null | xargs -n1 brew uninstall --force --ignore-dependencies 2> /dev/null || true
  else
    warning "WARNING: This will uninstall Homebrew (packages will be left installed)"
    echo ""
    info "Use --force-wipe to also remove all packages before uninstalling"
    echo ""

    if ! confirm "Continue with uninstalling Homebrew?"; then
      error "Uninstall cancelled."
      exit 1
    fi
  fi

  # Run official uninstall script
  info "Running Homebrew uninstall script..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"

  # Clean up remaining directories
  info "Cleaning up remaining directories..."
  local dirs_to_remove=("bin" "etc" "include" "lib" "opt" "sbin" "share" "var")

  for item in "${dirs_to_remove[@]}"; do
    local path="$BREW_PREFIX/$item"
    if [[ -d "$path" ]] || [[ -f "$path" ]]; then
      sudo rm -rf "$path" 2> /dev/null || true
    fi
  done

  success "Homebrew uninstallation complete!"
}

# ============================================================================
# Check Command
# ============================================================================

brew_check() {
  if ! command -v brew &> /dev/null; then
    return 0
  fi

  local force_update=0
  if [[ "${1:-}" == "--force" ]]; then
    force_update=1
  fi

  # Quick check mode (default when called from shell initialization)
  if [[ ${force_update} -eq 0 ]]; then
    # Show status message unless in silent mode
    if [[ ${SILENT_MODE} -eq 0 ]]; then
      info "🔄 Checking Homebrew packages..."
    fi

    # Check for outdated packages (quick, no update)
    local count
    count=$(brew outdated --quiet 2> /dev/null | wc -l | tr -d ' ')

    if [[ ${count} -gt 0 ]]; then
      warning "📦 ${count} Homebrew package(s) can be upgraded (run 'brew upgrade')"
    elif [[ ${SILENT_MODE} -eq 0 ]]; then
      success "All Homebrew packages are up to date"
    fi
    return 0
  fi

  # ===== Full Interactive Check (when --force is used) =====

  info "🔍 Running comprehensive Homebrew check..."
  echo ""

  local issues_found=0

  # 1. Check for outdated packages
  info "📦 Checking for outdated packages..."
  local outdated_formulae
  local outdated_casks
  outdated_formulae=$(brew outdated --formula --quiet 2> /dev/null || echo "")
  if [[ -n "$outdated_formulae" ]]; then
    warning "Found outdated formulae:"
    echo "$outdated_formulae" | while IFS= read -r pkg; do
      echo "  - $pkg"
    done
    ((issues_found++))
  else
    success "All formulae are up to date"
  fi

  if [[ "${OSTYPE}" == "darwin"* ]]; then
    outdated_casks=$(brew outdated --cask --quiet 2> /dev/null || echo "")
    if [[ -n "$outdated_casks" ]]; then
      warning "Found outdated casks:"
      echo "$outdated_casks" | while IFS= read -r pkg; do
        echo "  - $pkg"
      done
      ((issues_found++))
    else
      success "All casks are up to date"
    fi
  fi
  echo ""

  # 2. Validate and update packages (casks and formulae)
  info "🔄 Validating and updating package info..."
  local darwin_taskfile="$HOME/.jsh/.taskfiles/darwin/taskfile.yaml"
  local linux_taskfile="$HOME/.jsh/.taskfiles/linux/taskfile.yaml"

  if [[ -f "$darwin_taskfile" ]] && [[ -f "$linux_taskfile" ]]; then
    # Extract all packages from both taskfiles with descriptions
    declare -A darwin_formulae_desc
    declare -A darwin_casks_desc
    declare -A linux_formulae_desc

    while IFS='|||' read -r pkg desc; do
      [[ -n "$pkg" ]] && darwin_formulae_desc["$pkg"]="$desc"
    done < <(extract_packages_with_descriptions "$darwin_taskfile" "formulae")

    while IFS='|||' read -r pkg desc; do
      [[ -n "$pkg" ]] && darwin_casks_desc["$pkg"]="$desc"
    done < <(extract_packages_with_descriptions "$darwin_taskfile" "casks")

    while IFS='|||' read -r pkg desc; do
      [[ -n "$pkg" ]] && linux_formulae_desc["$pkg"]="$desc"
    done < <(extract_packages_with_descriptions "$linux_taskfile" "formulae")

    local packages_updated=0
    local packages_synced=0
    local total_issues=0

    # Generic validation function
    validate_package_set() {
      local -n pkg_desc_ref=$1
      local pkg_type=$2            # "cask" or "formula"
      local platform=$3            # "darwin" or "linux"
      local icon=$4                # emoji for display
      local sync_target_var=${5:-} # optional: target platform desc array name for cross-platform sync
      local skip_if_in=${6:-}      # optional: skip packages already in this array

      local -a pkg_list=()
      for pkg in "${!pkg_desc_ref[@]}"; do
        pkg_list+=("$pkg")
      done

      # Sort packages
      if [[ ${#pkg_list[@]} -gt 0 ]]; then
        IFS=$'\n' pkg_list=($(printf '%s\n' "${pkg_list[@]}" | sort -f))
        unset IFS
      fi

      local pkg_count=${#pkg_list[@]}
      local pkg_idx=0
      local pkg_issues=0

      [[ $pkg_count -eq 0 ]] && return 0

      info "${icon} Validating ${platform} ${pkg_type}s... ${CYAN}(CTRL+C to skip, twice to exit)${RESET}"

      # Enable CTRL+C trap for this section
      SECTION_SKIP=0
      trap trap_sigint SIGINT

      for pkg in "${pkg_list[@]}"; do
        ((pkg_idx++)) || true

        # Check if section was skipped
        if [[ $SECTION_SKIP -eq 1 ]]; then
          echo -ne "\033[2K" # Clear line
          info "Skipped remaining ${pkg_type} validation"
          trap - SIGINT  # Remove trap
          SECTION_SKIP=0 # Reset flag
          return 0
        fi

        echo -ne "[$pkg_idx/$pkg_count] Validating ${pkg}...\r"

        # Skip if already processed
        if [[ -n "$skip_if_in" ]]; then
          local -n skip_ref=$skip_if_in
          if [[ -v "skip_ref[$pkg]" ]]; then
            continue
          fi
        fi

        # Check skip again before running brew commands (in case CTRL+C was pressed during echo)
        if [[ $SECTION_SKIP -eq 1 ]]; then
          echo -ne "\033[2K" # Clear line
          info "Skipped remaining ${pkg_type} validation"
          trap - SIGINT  # Remove trap
          SECTION_SKIP=0 # Reset flag
          return 0
        fi

        # Validate package exists
        brew info --${pkg_type} "$pkg" &> /dev/null
        local brew_exit_code=$?

        # Check if interrupted by signal (exit code 130 is SIGINT)
        if [[ $brew_exit_code -eq 130 ]] || [[ $SECTION_SKIP -eq 1 ]]; then
          echo -ne "\033[2K" # Clear line
          info "Skipped remaining ${pkg_type} validation"
          trap - SIGINT  # Remove trap
          SECTION_SKIP=0 # Reset flag
          return 0
        fi

        if [[ $brew_exit_code -ne 0 ]]; then
          echo -ne "\033[2K" # Clear line
          # Only flag as cask if it's ONLY a cask and NOT also a formula
          if [[ "$pkg_type" == "formula" ]] && ! brew info --formula "$pkg" &> /dev/null && brew info --cask "$pkg" &> /dev/null; then
            echo -e "  ${YELLOW}!${RESET} '$pkg' is a cask, not a formula (should be in casks list)"
          else
            echo -e "  ${RED}✗${RESET} '$pkg' is not a valid $pkg_type"
          fi
          ((pkg_issues++))
          ((issues_found++))
          continue
        fi

        # Get current and stored descriptions
        local stored_desc="${pkg_desc_ref[$pkg]}"
        local action_taken=0

        # Only fetch if description is missing
        if [[ -z "$stored_desc" ]]; then
          # Missing description - fetch it
          local current_desc
          current_desc=$(get_brew_description "$pkg" "$pkg_type" 2> /dev/null || true)
          if [[ -n "$current_desc" ]]; then
            echo -ne "\033[2K" # Clear line
            echo -e "  ${CYAN}+${RESET} Adding missing description: $pkg"
            pkg_desc_ref["$pkg"]="$current_desc"
            ((packages_updated++))
            action_taken=1
          fi
        fi
        # If description exists, skip fetching (regardless of --force flag)

        # Handle cross-platform sync for formulae
        if [[ "$pkg_type" == "formula" && -n "$sync_target_var" ]]; then
          local -n sync_target_ref=$sync_target_var
          if [[ ! -v "sync_target_ref[$pkg]" ]]; then
            # Package not in target platform - check if it should be added
            if check_package_in_api "$pkg" "formula"; then
              echo -ne "\033[2K" # Clear line
              local target_platform="linux"
              [[ "$platform" == "linux" ]] && target_platform="darwin"
              echo -e "  ${CYAN}↔${RESET} Adding to ${target_platform} (cross-platform formula): $pkg"
              # Get description if we have it, otherwise fetch it
              local sync_desc="${stored_desc:-${current_desc:-$(get_brew_description "$pkg" "formula")}}"
              sync_target_ref["$pkg"]="$sync_desc"
              ((packages_synced++))
              action_taken=1
            fi
          elif [[ -z "${sync_target_ref[$pkg]}" ]]; then
            # Package exists on target platform but has no description - sync only if we have one
            local our_desc="${stored_desc:-$current_desc}"
            if [[ -n "$our_desc" ]]; then
              echo -ne "\033[2K" # Clear line
              local target_platform="linux"
              [[ "$platform" == "linux" ]] && target_platform="darwin"
              echo -e "  ${CYAN}→${RESET} Syncing description (${platform} -> ${target_platform}): $pkg"
              sync_target_ref["$pkg"]="$our_desc"
              ((packages_updated++))
              action_taken=1
            fi
          fi
        fi

        # Show rapid validation message if no action was taken
        if [[ $action_taken -eq 0 ]]; then
          echo -ne "\033[2K" # Clear line
          echo -e "  ✓ $pkg"
        fi
      done
      echo -ne "\033[2K" # Clear line

      # Remove trap
      trap - SIGINT

      if [[ $pkg_issues -eq 0 ]]; then
        echo -e "  ${GREEN}✓${RESET} All $pkg_count ${pkg_type}s are valid"
      else
        echo -e "  ${YELLOW}!${RESET} Found $pkg_issues invalid ${pkg_type}(s)"
        ((total_issues += pkg_issues))
      fi

      return 0
    }

    # Validate all package sets
    validate_package_set darwin_casks_desc "cask" "darwin" "🍺"
    validate_package_set darwin_formulae_desc "formula" "darwin" "⚗️" linux_formulae_desc
    validate_package_set linux_formulae_desc "formula" "linux" "⚗️" darwin_formulae_desc darwin_formulae_desc

    # Update taskfiles if changes were made
    if [[ $packages_updated -gt 0 || $packages_synced -gt 0 ]]; then
      echo ""
      info "📝 Writing updates to taskfiles..."
      update_section_with_descriptions "$darwin_taskfile" "formulae" darwin_formulae_desc
      update_section_with_descriptions "$darwin_taskfile" "casks" darwin_casks_desc
      update_section_with_descriptions "$linux_taskfile" "formulae" linux_formulae_desc
      success "Updated $packages_updated description(s) and synced $packages_synced package(s)"
    else
      echo ""
      success "All package info is up to date and packages are valid"
    fi
  fi
  echo ""

  # 3. Compare declared packages to locally installed
  info "📋 Checking for uninstalled declared packages..."
  local darwin_taskfile="${darwin_taskfile:-$HOME/.jsh/.taskfiles/darwin/taskfile.yaml}"
  local linux_taskfile="${linux_taskfile:-$HOME/.jsh/.taskfiles/linux/taskfile.yaml}"

  local current_os_taskfile
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    current_os_taskfile="$darwin_taskfile"
  else
    current_os_taskfile="$linux_taskfile"
  fi

  # Find uninstalled packages (declared but not installed)
  local uninstalled=()

  # Helper function to check if a formula is installed
  # Handles: tap paths (gromgit/fuse/ntfs-3g-mac), version-specific packages (python@3.14),
  # and package aliases (kubectl -> kubernetes-cli)
  is_formula_installed() {
    local declared_pkg="$1"
    local installed_list="$2"

    # Strip tap path if present (e.g., gromgit/fuse/ntfs-3g-mac -> ntfs-3g-mac)
    local pkg_name="${declared_pkg##*/}"

    # Check exact match first
    if echo "$installed_list" | grep -qx "$pkg_name"; then
      return 0
    fi

    # Check for versioned packages (e.g., python matches python@3.14)
    if echo "$installed_list" | grep -qx "${pkg_name}@[0-9].*"; then
      return 0
    fi

    # Check if it's an alias by querying brew info
    local actual_name
    actual_name=$(brew info "$pkg_name" 2>&1 | head -1 | awk -F: '{print $1}' | sed 's/^==> //')
    if [[ -n "$actual_name" ]] && [[ "$actual_name" != "$pkg_name" ]]; then
      if echo "$installed_list" | grep -qx "$actual_name"; then
        return 0
      fi
    fi

    return 1
  }

  # Get locally installed packages
  local installed_formulae
  local installed_casks
  installed_formulae=$(brew list --formula -1 2> /dev/null || echo "")
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    installed_casks=$(brew list --cask -1 2> /dev/null || echo "")
  fi

  # Get declared packages
  local declared_casks
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    declared_casks=$(extract_packages "$darwin_taskfile" "casks" | cut -d'|' -f1 | sed 's/^ *//;s/ *$//')
  fi
  local declared_formulae
  local declared_services
  local declared_links
  declared_formulae=$(extract_packages "$current_os_taskfile" "formulae" | cut -d'|' -f1 | sed 's/^ *//;s/ *$//')
  declared_services=$(extract_packages "$current_os_taskfile" "services" | cut -d'|' -f1 | sed 's/^ *//;s/ *$//')
  declared_links=$(extract_packages "$current_os_taskfile" "links" | cut -d'|' -f1 | sed 's/^ *//;s/ *$//')

  # Check declared formulae to see if they're installed
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue

    # Skip if in services or links (different categories)
    if echo "$declared_services" | grep -qx "$pkg" || echo "$declared_links" | grep -qx "$pkg"; then
      continue
    fi

    # Check if installed (using helper function for edge cases)
    if ! is_formula_installed "$pkg" "$installed_formulae"; then
      uninstalled+=("formula:$pkg")
    fi
  done <<< "$declared_formulae"

  # Check declared casks (macOS only)
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue

      # Check if installed
      if ! echo "$installed_casks" | grep -qx "$pkg"; then
        uninstalled+=("cask:$pkg")
      fi
    done <<< "$declared_casks"
  fi

  # Interactive prompts for uninstalled packages
  if [[ ${#uninstalled[@]} -gt 0 ]]; then
    warning "Found ${#uninstalled[@]} uninstalled declared package(s):"

    # List all uninstalled packages first with color coding
    for item in "${uninstalled[@]}"; do
      local pkg_type="${item%%:*}"
      local pkg_name="${item#*:}"
      if [[ "$pkg_type" == "cask" ]]; then
        echo -e "  - ${CYAN}$pkg_name${RESET}"
      else
        echo -e "  - $pkg_name"
      fi
    done
    echo ""
    info "Legend: ${CYAN}casks${RESET}, formulae | ${YELLOW}CTRL+C to skip, twice to exit${RESET}"
    echo ""

    # Enable CTRL+C trap
    SECTION_SKIP=0
    trap trap_sigint SIGINT

    # Ask for batch action first
    local batch_action=""
    # Temporarily disable trap during read to avoid skip messages after prompt
    trap - SIGINT
    read -r -n 1 -p "Action for all? [I]nstall all / [R]emove all / [S]kip all / [p]rompt each (default): " batch_response
    echo ""
    echo ""
    # Re-enable trap for processing loop
    trap trap_sigint SIGINT

    case "$batch_response" in
      I)
        batch_action="install"
        ;;
      R)
        batch_action="remove"
        ;;
      S)
        batch_action="skip"
        ;;
    esac

    # Process each package
    for item in "${uninstalled[@]}"; do
      # Check if section was skipped
      if [[ $SECTION_SKIP -eq 1 ]]; then
        info "Skipped remaining package prompts"
        trap - SIGINT
        SECTION_SKIP=0 # Reset flag
        break
      fi

      local pkg_type="${item%%:*}"
      local pkg_name="${item#*:}"
      local action="$batch_action"

      # If no batch action, prompt for individual action
      if [[ -z "$action" ]]; then
        if [[ "$pkg_type" == "cask" ]]; then
          echo -e "${CYAN}$pkg_name${RESET}"
        else
          echo -e "$pkg_name"
        fi

        # Prompt for action
        while [[ -z "$action" ]]; do
          read -r -n 1 -p "  Action? [i]nstall / [r]emove from config / [s]kip (default): " response
          echo

          case "$response" in
            i | I)
              action="install"
              ;;
            r | R)
              action="remove"
              ;;
            s | S | "")
              action="skip"
              ;;
            *)
              warning "  Invalid choice. Please enter 'i', 'r', or 's'"
              ;;
          esac
        done
      fi

      case "$action" in
        install)
          echo "    Installing '$pkg_name'..."

          if [[ "$pkg_type" == "cask" ]]; then
            brew install --cask "$pkg_name" 2> /dev/null && echo -e "    ${GREEN}✓${RESET} Installed '$pkg_name'" || echo -e "    ${YELLOW}!${RESET} Failed to install '$pkg_name'"
          else
            brew install "$pkg_name" 2> /dev/null && echo -e "    ${GREEN}✓${RESET} Installed '$pkg_name'" || echo -e "    ${YELLOW}!${RESET} Failed to install '$pkg_name'"
          fi
          ;;
        remove)
          echo "    Removing '$pkg_name' from configuration..."

          # Save current flag states
          local saved_is_cask=$IS_CASK
          local saved_is_service=$IS_SERVICE
          local saved_as_link=$AS_LINK

          # Set flags based on type
          IS_CASK=0
          IS_SERVICE=0
          AS_LINK=0

          if [[ "$pkg_type" == "cask" ]]; then
            IS_CASK=1
          fi

          # Remove from config
          remove_package "$pkg_name"

          # Restore flag states
          IS_CASK=$saved_is_cask
          IS_SERVICE=$saved_is_service
          AS_LINK=$saved_as_link

          echo -e "    ${GREEN}✓${RESET} Removed '$pkg_name' from configuration"
          ;;
        skip)
          echo "    Skipping '$pkg_name'"
          ;;
      esac
      echo ""
    done

    # Remove trap
    trap - SIGINT
  else
    success "All declared packages are installed"
  fi
  echo ""

  # Summary
  if [[ $issues_found -eq 0 ]]; then
    success "All checks passed! No issues found."
  else
    warning "Found $issues_found issue(s). Review the output above."
  fi
}

# ============================================================================
# Main Logic
# ============================================================================

case "$COMMAND" in
  sync)
    if ! command -v brew &> /dev/null; then
      error "Homebrew is not installed"
      info "Run: $0 install"
      exit 1
    fi
    sync_formulae
    ;;
  add)
    if ! command -v brew &> /dev/null; then
      error "Homebrew is not installed"
      info "Run: $0 install"
      exit 1
    fi
    if [[ ${#REMAINING_ARGS[@]} -lt 1 ]]; then
      error "Missing package name"
      info "Usage: $0 add <name> [--cask|--service|--link]"
      exit 1
    fi
    add_package "${REMAINING_ARGS[0]}"
    ;;
  remove)
    if ! command -v brew &> /dev/null; then
      error "Homebrew is not installed"
      exit 1
    fi
    if [[ ${#REMAINING_ARGS[@]} -lt 1 ]]; then
      error "Missing package name"
      info "Usage: $0 remove <name> [--cask|--service|--link]"
      exit 1
    fi
    remove_package "${REMAINING_ARGS[0]}"
    ;;
  install)
    brew_install
    ;;
  uninstall)
    brew_uninstall
    ;;
  check)
    brew_check "${REMAINING_ARGS[@]}"
    ;;
  *)
    error "Unknown command: $COMMAND"
    echo ""
    show_usage
    ;;
esac
