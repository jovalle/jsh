#!/usr/bin/env bash
# shellcheck disable=SC2207
# SC2207: Prefer mapfile or read -a to split command output (we use portable syntax)

set -e
set -u
set -o pipefail

# ============================================================================
# brew.sh
# ============================================================================
# Comprehensive Homebrew management tool with multiple subcommands:
#
# Commands:
#   align       - Compare installed packages against taskfile declarations
#   sync        - Synchronize formulae between Darwin and Linux taskfiles
#   check       - Check for outdated packages (used by shell integration)
#   uninstall   - Completely uninstall Homebrew and all packages
#
# Only checks explicitly requested packages (dependencies are ignored).
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

# Function to print colored messages
error() {
    echo -e "${RED}❌ $1${RESET}" >&2
}

success() {
    echo -e "${GREEN}✅ $1${RESET}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${RESET}"
}

info() {
    echo -e "$1"
}

# Function to prompt for confirmation
confirm() {
    local prompt="$1"
    local response
    read -r -n 1 -p "$prompt (y/N): " response
    echo  # Add newline after single character input
    case "$response" in
        y|Y)
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
    elif [[ "${OSTYPE}" == "linux"* ]] || grep -qi microsoft /proc/version 2>/dev/null; then
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
INTERACTIVE=0
DRY_RUN=0
COMMAND=""

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  align       Compare installed packages against taskfile declarations
  sync        Synchronize formulae between Darwin and Linux taskfiles
  check       Check for outdated packages (background-friendly)
  uninstall   Completely uninstall Homebrew and all packages

Align Options:
  -i, --interactive   Prompt for each extra package to keep/declare/remove

Sync Options:
  -d, --dry-run       Show what would be changed without modifying files

Check Options:
  --force             Force immediate cache update (skip 24-hour interval)

Examples:
  $0 align --interactive
  $0 sync --dry-run
  $0 check
  $0 check --force
  $0 uninstall
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
    -i|--interactive)
      INTERACTIVE=1
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    --force)
      # Preserve --force flag for check command
      REMAINING_ARGS+=("$1")
      shift
      ;;
    *)
      shift
      ;;
  esac
done


# Extract package names from taskfile YAML (handles both single-line and multi-line format)
extract_packages() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi

  # Use awk to extract packages from vars section
  # Looking for pattern: vars: -> casks/formulae: -> list items
  # Deduplicate results with sort -u
  awk -v key="$key" '
    /^vars:/ {
      in_vars = 1
      next
    }
    # Exit vars section when we hit another top-level key
    in_vars && /^[a-zA-Z_-]+:/ && !/^  / {
      in_vars = 0
    }
    # Found our key within vars section
    in_vars && $0 ~ "^  " key ":" {
      in_section = 1
      next
    }
    # Exit section when we hit another vars subsection or end of vars
    in_section && /^  [a-zA-Z_-]+:/ {
      in_section = 0
    }
    # Extract package names (with 4-space indentation under vars subsections)
    in_section && /^    - / {
      # Extract package name (strip "- " prefix and everything after "#")
      sub(/^    - /, "")
      sub(/ #.*$/, "")
      gsub(/ /, "")
      if ($0 != "") print $0
    }
  ' "$file" | sort -u
}

# Get brew description for a package
get_brew_description() {
  local pkg="$1"
  local pkg_type="$2"  # "formula" or "cask"

  local desc=""
  if [[ "$pkg_type" == "cask" ]]; then
    # For casks, try to get the name/description from the first line after the version
    # Format: ==> name: version
    # Second line is usually the URL, not helpful
    # Try to extract from JSON output instead
    desc=$(brew info --cask --json=v2 "$pkg" 2>/dev/null | jq -r '.casks[0].desc // empty' 2>/dev/null || echo "")
    if [[ -z "$desc" ]]; then
      # Fallback to name if no description
      desc=$(brew info --cask --json=v2 "$pkg" 2>/dev/null | jq -r '.casks[0].name[0] // empty' 2>/dev/null || echo "")
    fi
  else
    # For formulae, the description is on the second line
    desc=$(brew info "$pkg" 2>/dev/null | sed -n '2p' || echo "")
  fi

  # Clean up description - remove trailing newlines and extra spaces
  desc=$(echo "$desc" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

  echo "$desc"
}

# Add a package to the OS taskfile under the given key (formulae or casks)
add_package_to_taskfile() {
  local file="$1"
  local key="$2"
  local pkg="$3"

  # If file doesn't exist, bail
  if [[ ! -f "$file" ]]; then
    echo -e "${YELLOW}Warning: taskfile $file not found; cannot declare $pkg${RESET}"
    return 1
  fi

  # Check if already declared
  if grep -qE "^[[:space:]]*- ${pkg}([[:space:]]|$)" "$file"; then
    echo -e "${CYAN}$pkg already declared in $file${RESET}"
    return 0
  fi

  # Get package description
  local pkg_type="formula"
  if [[ "$key" == "casks" ]]; then
    pkg_type="cask"
  fi

  echo -e "${CYAN}Fetching description for $pkg...${RESET}"
  local description
  description=$(get_brew_description "$pkg" "$pkg_type")

  # Simple approach: read file into array, extract packages, add new one, sort, rebuild
  local tmp
  tmp=$(mktemp)

  awk -v key="$key" -v pkg="$pkg" -v desc="$description" '
    BEGIN {
      in_vars = 0
      found_key = 0
      pkg_count = 0
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
    # Collect existing packages
    found_key && /^    - / {
      pkg_count++
      packages[pkg_count] = $0
    }
    END {
      if (found_key) {
        # Find the section boundaries
        section_start = key_line
        section_end = key_line
        for (i = key_line + 1; i <= NR; i++) {
          if (lines[i] ~ /^    - /) {
            section_end = i
          } else if (lines[i] !~ /^[[:space:]]*$/ && lines[i] !~ /^    /) {
            break
          }
        }

        # Add new package to array
        if (desc != "") {
          packages[pkg_count + 1] = "    - " pkg " # " desc
        } else {
          packages[pkg_count + 1] = "    - " pkg
        }
        pkg_count++

        # Sort packages (simple bubble sort in awk)
        for (i = 1; i <= pkg_count; i++) {
          for (j = i + 1; j <= pkg_count; j++) {
            # Extract package name for comparison (without comment)
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

        # Print everything up to the key line
        for (i = 1; i <= section_start; i++) {
          print lines[i]
        }

        # Print sorted packages
        for (i = 1; i <= pkg_count; i++) {
          print packages[i]
        }

        # Print remaining lines after the section
        for (i = section_end + 1; i <= NR; i++) {
          print lines[i]
        }
      } else {
        # Key not found, just print original file
        for (i = 1; i <= NR; i++) {
          print lines[i]
        }
        # Append new section if vars exists
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
  ' "$file" > "$tmp" && mv "$tmp" "$file"

  echo -e "${GREEN}✓ Declared $pkg in $file under $key${RESET}"
  return 0
}

# Interactive TUI for package management with arrow key navigation
interactive_tui() {
  local formulae_var=$1
  local casks_var=$2

  # Combine packages with their types
  local -a all_packages=()
  declare -A pkg_types=()
  declare -A pkg_actions=()

  # Use nameref to access arrays by variable name
  local -n formulae_ref="$formulae_var"
  local -n casks_ref="$casks_var"

  for pkg in "${formulae_ref[@]}"; do
    all_packages+=("$pkg")
    pkg_types[$pkg]="formula"
    pkg_actions[$pkg]="skip"
  done

  for pkg in "${casks_ref[@]}"; do
    all_packages+=("$pkg")
    pkg_types[$pkg]="cask"
    pkg_actions[$pkg]="skip"
  done

  # Sort packages alphabetically (case-insensitive)
  IFS=$'\n' all_packages=($(sort -f <<<"${all_packages[*]}"))
  unset IFS

  if [[ ${#all_packages[@]} -eq 0 ]]; then
    return 0
  fi

  # Filter state for fuzzy search
  local search_filter=""
  local -a filtered_packages=("${all_packages[@]}")
  local current_index=0
  local scroll_offset=0

  # Action cycle: skip -> declare -> decom
  local -a action_cycle=("skip" "declare" "decom")

  # Track cancellation
  local cancelled=0

  # Function to cleanup terminal state
  cleanup_terminal() {
    tput rmcup 2>/dev/null || true  # Restore screen
    stty echo 2>/dev/null || true   # Show input
    tput cnorm 2>/dev/null || true  # Show cursor
    tput sgr0 2>/dev/null || true   # Reset colors
    printf '\e[r' 2>/dev/null || true  # Reset scrolling region
    printf '\e[?1049l' 2>/dev/null || true  # Exit alternate screen buffer (backup method)
  }

  # Function to handle interrupt (CTRL-C)
  handle_interrupt() {
    running=0
    trap - EXIT INT TERM  # Remove trap to prevent double cleanup
    cleanup_terminal
    echo -e "${YELLOW}Interrupted. No changes made.${RESET}"
    exit 130  # Standard exit code for SIGINT
  }

  # Set up traps to ensure cleanup on exit
  trap cleanup_terminal EXIT TERM
  trap handle_interrupt INT

  # Save terminal state
  tput smcup  # Save screen
  stty -echo  # Hide input
  tput civis  # Hide cursor

  local running=1

  # Function to filter packages based on search
  filter_packages() {
    filtered_packages=()
    if [[ -z "$search_filter" ]]; then
      if [[ ${#all_packages[@]} -gt 0 ]]; then
        filtered_packages=("${all_packages[@]}")
      fi
    else
      if [[ ${#all_packages[@]} -gt 0 ]]; then
        for pkg in "${all_packages[@]}"; do
          if [[ "$pkg" == *"$search_filter"* ]]; then
            filtered_packages+=("$pkg")
          fi
        done
      fi
    fi
    # Reset index if out of bounds
    if [[ $current_index -ge ${#filtered_packages[@]} ]]; then
      current_index=$((${#filtered_packages[@]} - 1))
    fi
    if [[ $current_index -lt 0 ]]; then
      current_index=0
    fi
  }

  # Function to cycle action for current package
  cycle_action() {
    local direction=$1  # 1 for forward, -1 for backward
    if [[ ${#filtered_packages[@]} -eq 0 ]]; then return; fi

    local pkg="${filtered_packages[$current_index]}"
    local current_action="${pkg_actions[$pkg]}"
    local current_idx=0

    # Find current action index
    for i in {0..2}; do
      if [[ "${action_cycle[$i]}" == "$current_action" ]]; then
        current_idx=$i
        break
      fi
    done

    # Cycle to next/prev action
    local new_idx=$(( (current_idx + direction + 3) % 3 ))
    pkg_actions[$pkg]="${action_cycle[$new_idx]}"
  }

  # Function to render the UI
  render_ui() {
    tput clear
    tput cup 0 0

    # Header (each line must be exactly 72 chars between the ║ characters)
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════╗${RESET}"
    printf "${CYAN}║${RESET}%-72s${CYAN}║${RESET}\n" "  Interactive Package Manager"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════╣${RESET}"
    printf "${CYAN}║${RESET}%-74s${CYAN}║${RESET}\n" "  Navigation: ↑/↓ | Toggle: ←/→/SPACE | Submit: ENTER | Cancel: ESC"
    # Legend line with color markers
    printf "${CYAN}║${RESET}  Legend: ${CYAN}●${RESET} formula  ${YELLOW}■${RESET} cask%*s${CYAN}║${RESET}\n" 45 ""
    if [[ -n "$search_filter" ]]; then
      local search_line="  Search: ${search_filter}"
      local search_pad=$((72 - ${#search_line}))
      printf "${CYAN}║${RESET}  Search: ${GREEN}%s${RESET}%*s${CYAN}║${RESET}\n" "$search_filter" "$search_pad" ""
    else
      printf "${CYAN}║${RESET}%-72s${CYAN}║${RESET}\n" "  Search: (type to filter)"
    fi
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════╣${RESET}"
    printf "${CYAN}║${RESET} %-50s %-20s${CYAN}║${RESET}\n" "PACKAGE" "ACTION"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════╣${RESET}"

    # Calculate visible window (header is now 13 lines instead of 12)
    local term_height=$(($(tput lines) - 13))
    local visible_count=$term_height

    # Adjust scroll offset
    if [[ $current_index -lt $scroll_offset ]]; then
      scroll_offset=$current_index
    elif [[ $current_index -ge $((scroll_offset + visible_count)) ]]; then
      scroll_offset=$((current_index - visible_count + 1))
    fi

    # Display packages
    local display_count=0
    local i=$scroll_offset
    if [[ ${#filtered_packages[@]} -gt 0 ]]; then
      while [[ $i -lt ${#filtered_packages[@]} && $display_count -lt $visible_count ]]; do
        local pkg="${filtered_packages[$i]}"
        local action="${pkg_actions[$pkg]}"
        local pkg_type="${pkg_types[$pkg]}"

        # Color code actions
        local action_display=""
        case "$action" in
          skip) action_display="${CYAN}skip${RESET}" ;;
          declare) action_display="${GREEN}declare${RESET}" ;;
          decom) action_display="${RED}decom${RESET}" ;;
        esac

        # Color marker for type (blue circle for formula, magenta square for cask)
        local type_marker=""
        if [[ "$pkg_type" == "formula" ]]; then
          type_marker="${CYAN}●${RESET}"  # Blue circle for formulae
        else
          type_marker="${YELLOW}■${RESET}"  # Yellow square for casks
        fi

        # Format package name (trimmed to fit with marker)
        local pkg_display="${pkg:0:47}"

        # Highlight current line
        if [[ $i -eq $current_index ]]; then
          printf "${CYAN}║${RESET}${YELLOW}▶${RESET} ${type_marker} %-47s ${action_display}%*s${CYAN}║${RESET}\n" "$pkg_display" $((20 - ${#action})) ""
        else
          printf "${CYAN}║${RESET}  ${type_marker} %-47s ${action_display}%*s${CYAN}║${RESET}\n" "$pkg_display" $((20 - ${#action})) ""
        fi
        display_count=$((display_count + 1))
        i=$((i + 1))
      done
    fi

    # Fill remaining space
    for ((i=display_count; i<visible_count; i++)); do
      echo -e "${CYAN}║${RESET}$(printf '%-72s' '')${CYAN}║${RESET}"
    done

    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo -e "Showing ${#filtered_packages[@]} of ${#all_packages[@]} packages"
  }

  # Main event loop
  while [[ $running -eq 1 ]]; do
    render_ui

    # Read single character (bash-compatible)
    IFS= read -rsn1 key

    # Handle escape sequences (arrow keys)
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 -t 0.1 key2 2>/dev/null || true
      case "$key2" in
        '[A') # Up arrow
          if [[ $current_index -gt 0 ]]; then
            current_index=$((current_index - 1))
          fi
          ;;
        '[B') # Down arrow
          if [[ $current_index -lt $((${#filtered_packages[@]} - 1)) ]]; then
            current_index=$((current_index + 1))
          fi
          ;;
        '[C') # Right arrow
          cycle_action 1
          ;;
        '[D') # Left arrow
          cycle_action -1
          ;;
        *)
          # ESC key (cancel)
          cancelled=1
          running=0
          ;;
      esac
    else
      case "$key" in
        ' ') # Space
          cycle_action 1
          ;;
        $'\n'|$'\r'|'') # Enter - Submit (newline, carriage return, or empty)
          running=0
          ;;
        x|X) # Also allow x for submit (legacy)
          running=0
          ;;
        $'\x7f'|$'\x08') # Backspace
          if [[ -n "$search_filter" ]]; then
            search_filter="${search_filter%?}"
            filter_packages
          fi
          ;;
        [a-zA-Z0-9\-_\.]) # Alphanumeric for search
          search_filter="${search_filter}${key}"
          filter_packages
          ;;
      esac
    fi
  done

  # Restore terminal - remove trap first, then cleanup
  trap - EXIT INT TERM
  cleanup_terminal

  # Check if user cancelled
  if [[ $cancelled -eq 1 ]]; then
    echo -e "${YELLOW}Cancelled. No changes made.${RESET}"
    return 1
  fi

  # Process actions
  local -a to_declare_formulae=()
  local -a to_declare_casks=()
  local -a to_decom_formulae=()
  local -a to_decom_casks=()

  for pkg in "${all_packages[@]}"; do
    local action="${pkg_actions[$pkg]}"
    local type="${pkg_types[$pkg]}"

    if [[ "$action" == "declare" ]]; then
      if [[ "$type" == "formula" ]]; then
        to_declare_formulae+=("$pkg")
      else
        to_declare_casks+=("$pkg")
      fi
    elif [[ "$action" == "decom" ]]; then
      if [[ "$type" == "formula" ]]; then
        to_decom_formulae+=("$pkg")
      else
        to_decom_casks+=("$pkg")
      fi
    fi
  done

  # Show summary
  local total_changes=$((${#to_declare_formulae[@]} + ${#to_declare_casks[@]} + ${#to_decom_formulae[@]} + ${#to_decom_casks[@]}))

  if [[ $total_changes -eq 0 ]]; then
    echo -e "${CYAN}No changes selected.${RESET}"
    return 0
  fi

  echo ""
  echo -e "${CYAN}═══════════════════════════════════════${RESET}"
  echo -e "${YELLOW}Proposed Changes Summary:${RESET}"
  echo -e "${CYAN}═══════════════════════════════════════${RESET}"

  if [[ ${#to_declare_formulae[@]} -gt 0 ]]; then
    echo -e "\n${GREEN}Declare Formulae (${#to_declare_formulae[@]}):${RESET}"
    for pkg in "${to_declare_formulae[@]}"; do
      echo "  + $pkg"
    done
  fi

  if [[ ${#to_declare_casks[@]} -gt 0 ]]; then
    echo -e "\n${GREEN}Declare Casks (${#to_declare_casks[@]}):${RESET}"
    for pkg in "${to_declare_casks[@]}"; do
      echo "  + $pkg"
    done
  fi

  if [[ ${#to_decom_formulae[@]} -gt 0 ]]; then
    echo -e "\n${RED}Decommission Formulae (${#to_decom_formulae[@]}):${RESET}"
    for pkg in "${to_decom_formulae[@]}"; do
      echo "  - $pkg"
    done
  fi

  if [[ ${#to_decom_casks[@]} -gt 0 ]]; then
    echo -e "\n${RED}Decommission Casks (${#to_decom_casks[@]}):${RESET}"
    for pkg in "${to_decom_casks[@]}"; do
      echo "  - $pkg"
    done
  fi

  echo ""
  echo -ne "${CYAN}Apply these changes? [y/N] ${RESET}"
  read -rsn1 CONFIRM
  echo  # Newline after response

  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Changes cancelled.${RESET}"
    return 1
  fi

  # Apply declarations
  for pkg in "${to_declare_formulae[@]}"; do
    add_package_to_taskfile "$OS_TASKFILE" "formulae" "$pkg"
  done

  for pkg in "${to_declare_casks[@]}"; do
    add_package_to_taskfile "$OS_TASKFILE" "casks" "$pkg"
  done

  # Apply decommissions
  for pkg in "${to_decom_formulae[@]}"; do
    echo -e "${RED}Uninstalling formula: $pkg${RESET}"
    brew uninstall --ignore-dependencies "$pkg" 2>&1 | sed 's/^/  /'
  done

  for pkg in "${to_decom_casks[@]}"; do
    echo -e "${RED}Uninstalling cask: $pkg${RESET}"
    brew uninstall --cask "$pkg" 2>&1 | sed 's/^/  /'
  done

  # Update cache after package changes
  update_brew_cache

  echo ""
  echo -e "${GREEN}✓ Changes applied successfully${RESET}"
}

# ============================================================================
# Helper Functions for Cache Management
# ============================================================================

# Update the outdated package count cache
update_brew_cache() {
    local BREW_CACHE_DIR="${HOME}/.cache/brew"
    local BREW_OUTDATED_COUNT="${BREW_CACHE_DIR}/outdated_count"

    # Ensure cache directory exists
    [[ -d "${BREW_CACHE_DIR}" ]] || mkdir -p "${BREW_CACHE_DIR}" 2>/dev/null

    # Update the outdated count
    brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ' > "${BREW_OUTDATED_COUNT}"
}

# ============================================================================
# Check Command - Background update checker with smart caching
# ============================================================================

brew_check() {
    # Only run if brew is available
    if ! command -v brew &>/dev/null; then
        return 0
    fi

    # Check for --force flag
    local force_update=0
    if [[ "${1:-}" == "--force" ]]; then
        force_update=1
    fi

    # Configuration
    local BREW_CACHE_DIR="${HOME}/.cache/brew"
    local BREW_UPDATE_STAMP="${BREW_CACHE_DIR}/last_update_check"
    local BREW_OUTDATED_COUNT="${BREW_CACHE_DIR}/outdated_count"
    local UPDATE_INTERVAL=86400  # 24 hours in seconds

    # Ensure cache directory exists
    [[ -d "${BREW_CACHE_DIR}" ]] || mkdir -p "${BREW_CACHE_DIR}" 2>/dev/null

    # Check if we should update (>24 hours since last check or forced)
    local should_update=0
    if [[ ${force_update} -eq 1 ]]; then
        should_update=1
    elif [[ ! -f "${BREW_UPDATE_STAMP}" ]]; then
        should_update=1
    else
        local last_update
        last_update=$(cat "${BREW_UPDATE_STAMP}" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local time_diff=$((now - last_update))

        if [[ ${time_diff} -ge ${UPDATE_INTERVAL} ]]; then
            should_update=1
        fi
    fi

    # Run background update if needed (or force immediate update if --force flag)
    if [[ ${should_update} -eq 1 ]]; then
        if [[ ${force_update} -eq 1 ]]; then
            # Force immediate update (synchronous)
            brew update &>/dev/null
            date +%s > "${BREW_UPDATE_STAMP}"
            brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ' > "${BREW_OUTDATED_COUNT}"
        else
            # Background update (asynchronous)
            {
                brew update &>/dev/null
                date +%s > "${BREW_UPDATE_STAMP}"
                brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ' > "${BREW_OUTDATED_COUNT}"
            } &
        fi
    fi

    # Display outdated package count if available (instant)
    if [[ -f "${BREW_OUTDATED_COUNT}" ]]; then
        local count
        count=$(cat "${BREW_OUTDATED_COUNT}" 2>/dev/null || echo 0)
        if [[ ${count} -gt 0 ]]; then
            # Use warn function if available, otherwise use fallback
            if command -v warn &>/dev/null; then
                warn "📦 ${count} Homebrew package(s) can be upgraded (run 'brew upgrade' or 'task update')"
            else
                echo -e "${YELLOW}📦 ${count} Homebrew package(s) can be upgraded (run 'brew upgrade' or 'task update')${RESET}"
            fi
        fi
    fi
}

# ============================================================================
# Uninstall Command - Complete Homebrew removal
# ============================================================================

brew_uninstall() {
    local BREW_PREFIX
    BREW_PREFIX=$(detect_brew_path)

    # Check if Homebrew is installed
    if [[ -z "$BREW_PREFIX" ]]; then
        error "Homebrew installation not found."
        exit 1
    fi

    info "Found Homebrew at: $BREW_PREFIX"
    echo ""

    warning "WARNING: This will completely uninstall Homebrew and all packages!"
    echo ""
    info "This process will:"
    info "  1. Stop all Homebrew services"
    info "  2. Uninstall all casks and formulae"
    info "  3. Run the official Homebrew uninstall script"
    info "  4. Remove all Homebrew directories from $BREW_PREFIX"
    echo ""

    if ! confirm "Are you ABSOLUTELY sure you want to continue?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    # Step 1: Stop services
    echo ""
    info "Step 1/4: Stopping all Homebrew services..."
    if ! confirm "Continue with stopping services?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    if brew services stop --all 2>/dev/null; then
        success "Services stopped"
    else
        warning "No services running or failed to stop services"
    fi

    # Step 2: Unlink formulae
    echo ""
    info "Step 2/4: Unlinking all Homebrew formulae..."
    if brew list --formula 2>/dev/null | xargs -n1 brew unlink 2>/dev/null; then
        success "Formulae unlinked"
    else
        warning "No formulae to unlink or unlinking failed"
    fi

    # Step 3: Uninstall packages
    echo ""
    info "Step 3/4: Uninstalling all casks and formulae..."
    if ! confirm "Continue with uninstalling all packages?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    info "Uninstalling casks..."
    if brew list --cask 2>/dev/null | xargs -n1 brew uninstall --cask --force 2>/dev/null; then
        success "Casks uninstalled"
    else
        warning "No casks installed or uninstall failed"
    fi

    info "Uninstalling formulae..."
    if brew list --formula 2>/dev/null | xargs -n1 brew uninstall --force --ignore-dependencies 2>/dev/null; then
        success "Formulae uninstalled"
    else
        warning "No formulae installed or uninstall failed"
    fi

    # Step 4: Run official uninstall script
    echo ""
    info "Step 4/4: Running official Homebrew uninstall script..."
    if ! confirm "Continue with running Homebrew uninstall script?"; then
        error "Uninstall cancelled."
        exit 1
    fi

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"

    # Step 5: Clean up remaining directories
    echo ""
    info "Step 5/5: Removing remaining Homebrew directories..."
    info "The following directories will be deleted from $BREW_PREFIX:"

    # Common directories across macOS and Linux
    local dirs_to_remove=(
        "bin"
        "etc"
        "include"
        "lib"
        "opt"
        "sbin"
        "share"
        "var"
    )

    # macOS-specific directories
    if [[ "${OSTYPE}" == "darwin"* ]]; then
        dirs_to_remove+=(
            ".DS_Store"
            "AGENTS.md"
            "CHANGES.rst"
            "Frameworks"
            "README.rst"
        )
    fi

    # List directories to be removed
    for item in "${dirs_to_remove[@]}"; do
        info "  - $BREW_PREFIX/$item"
    done
    echo ""

    if ! confirm "Continue with removing directories?"; then
        warning "Uninstall cancelled at final step. Homebrew may be partially uninstalled."
        exit 1
    fi

    # Remove directories and files
    for item in "${dirs_to_remove[@]}"; do
        local path="$BREW_PREFIX/$item"
        if [[ -d "$path" ]]; then
            sudo rm -rf "$path" 2>/dev/null || true
        elif [[ -f "$path" ]]; then
            sudo rm -f "$path" 2>/dev/null || true
        fi
    done

    echo ""
    success "Homebrew uninstallation complete!"
}

# ============================================================================
# Synchronization Functions
# ============================================================================

# Get unique formulae from a taskfile (package name only, no comments)
get_unique_formulae() {
  local file="$1"
  extract_packages "$file" "formulae" | sort -u
}

# Synchronize, sort, and comment formulae between darwin and linux
sync_formulae() {
  echo -e "${CYAN}🔄 Synchronizing formulae between Darwin and Linux...${RESET}\n"

  # Check if taskfiles exist
  if [[ ! -f "$DARWIN_TASKFILE" ]]; then
    echo -e "${RED}Error: Darwin taskfile not found: $DARWIN_TASKFILE${RESET}" >&2
    return 1
  fi

  if [[ ! -f "$LINUX_TASKFILE" ]]; then
    echo -e "${RED}Error: Linux taskfile not found: $LINUX_TASKFILE${RESET}" >&2
    return 1
  fi

  # Extract formulae from both taskfiles
  local darwin_formulae
  darwin_formulae=$(get_unique_formulae "$DARWIN_TASKFILE")
  local linux_formulae
  linux_formulae=$(get_unique_formulae "$LINUX_TASKFILE")

  # Combine and get unique list
  local -a all_formulae=()
  if [[ -n "$darwin_formulae" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && all_formulae+=("$line")
    done <<< "$darwin_formulae"
  fi
  if [[ -n "$linux_formulae" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && all_formulae+=("$line")
    done <<< "$linux_formulae"
  fi

  # Sort and deduplicate
  if [[ ${#all_formulae[@]} -gt 0 ]]; then
    IFS=$'\n' all_formulae=($(printf '%s\n' "${all_formulae[@]}" | sort -u))
    unset IFS
  fi

  # Platform-specific packages (known to be OS-specific)
  local -a darwin_only=(
    "ntfs-3g-mac"
    "gromgit/fuse/ntfs-3g-mac"
    "speedtest-cli"
    "timeout"
  )

  local -a linux_only=(
    # Add any Linux-only packages here if needed
    # These would be packages that don't exist or don't make sense on macOS
  )

  # Build synchronized lists
  local -a darwin_sync=()
  local -a linux_sync=()
  local -a common_formulae=()
  local -a darwin_specific=()
  local -a linux_specific=()

  echo -e "${CYAN}📦 Analyzing packages...${RESET}"

  for pkg in "${all_formulae[@]}"; do
    local is_darwin_only=0
    local is_linux_only=0

    # Check if package is platform-specific
    for darwin_pkg in "${darwin_only[@]}"; do
      if [[ "$pkg" == "$darwin_pkg" ]]; then
        is_darwin_only=1
        break
      fi
    done

    if [[ $is_darwin_only -eq 0 ]]; then
      for linux_pkg in "${linux_only[@]}"; do
        if [[ "$pkg" == "$linux_pkg" ]]; then
          is_linux_only=1
          break
        fi
      done
    fi

    # Add to appropriate lists
    if [[ $is_darwin_only -eq 1 ]]; then
      darwin_sync+=("$pkg")
      darwin_specific+=("$pkg")
    elif [[ $is_linux_only -eq 1 ]]; then
      linux_sync+=("$pkg")
      linux_specific+=("$pkg")
    else
      # Common package - add to both
      darwin_sync+=("$pkg")
      linux_sync+=("$pkg")
      common_formulae+=("$pkg")
    fi
  done

  echo -e "${CYAN}ℹ  Common formulae: ${#common_formulae[@]}${RESET}"
  echo -e "${CYAN}ℹ  Darwin-only formulae: ${#darwin_specific[@]}${RESET}"
  echo -e "${CYAN}ℹ  Linux-only formulae: ${#linux_specific[@]}${RESET}"
  echo ""

  # Show what will be synchronized
  if [[ ${#darwin_specific[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Darwin-only packages (will not be added to Linux):${RESET}"
    for pkg in "${darwin_specific[@]}"; do
      echo "  - $pkg"
    done
    echo ""
  fi

  if [[ ${#linux_specific[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Linux-only packages (will not be added to Darwin):${RESET}"
    for pkg in "${linux_specific[@]}"; do
      echo "  - $pkg"
    done
    echo ""
  fi

  # Prompt for confirmation
  echo -ne "${YELLOW}Synchronize and update both taskfiles? [y/N] ${RESET}"
  read -rsn1 REPLY
  echo  # Newline

  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    echo -e "${YELLOW}Synchronization cancelled.${RESET}"
    return 0
  fi

  # Check for dry-run mode
  if [[ $DRY_RUN -eq 1 ]]; then
    echo -e "${YELLOW}🔍 DRY RUN MODE - No files will be modified${RESET}"
    echo ""
    echo -e "${CYAN}Would update Darwin taskfile with ${#darwin_sync[@]} formulae${RESET}"
    echo -e "${CYAN}Would update Linux taskfile with ${#linux_sync[@]} formulae${RESET}"
    echo ""
    echo -e "${GREEN}✅ Dry run complete. Use without --dry-run to apply changes.${RESET}"
    return 0
  fi

  # Update Darwin taskfile
  echo -e "${CYAN}📝 Updating Darwin taskfile...${RESET}"
  update_formulae_section "$DARWIN_TASKFILE" darwin_sync

  # Update Linux taskfile
  echo -e "${CYAN}📝 Updating Linux taskfile...${RESET}"
  update_formulae_section "$LINUX_TASKFILE" linux_sync

  echo ""
  echo -e "${GREEN}✅ Synchronization complete!${RESET}"
  echo -e "${GREEN}   Both taskfiles have been updated, sorted, and commented.${RESET}"
}

# Update the formulae section in a taskfile with sorted and commented packages
update_formulae_section() {
  local file="$1"
  local packages_var=$2

  # Get the array via nameref
  local -n packages_ref="$packages_var"

  if [[ ! -f "$file" ]]; then
    echo -e "${RED}Error: File not found: $file${RESET}" >&2
    return 1
  fi

  # Build package list with descriptions
  declare -A pkg_descriptions=()
  local -a sorted_packages=()

  echo -e "${CYAN}  Fetching descriptions for ${#packages_ref[@]} packages...${RESET}"

  for pkg in "${packages_ref[@]}"; do
    sorted_packages+=("$pkg")

    # Get description
    local desc
    desc=$(get_brew_description "$pkg" "formula")
    pkg_descriptions[$pkg]="$desc"

    # Show progress
    echo -ne "  "
    if [[ -n "$desc" ]]; then
      echo -e "${GREEN}✓${RESET} $pkg"
    else
      echo -e "${YELLOW}○${RESET} $pkg (no description)"
    fi
  done

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
      vars_line = NR
    }
    in_vars && /^  formulae:/ {
      found_formulae = 1
      formulae_start = NR
    }
    # Track end of formulae section
    found_formulae && /^    - / {
      formulae_end = NR
    }
    # Exit formulae section when we hit another vars key or end of vars
    found_formulae && /^  [a-zA-Z_-]+:/ && !/^  formulae:/ {
      found_formulae = 0
    }
    END {
      if (formulae_start > 0) {
        # Print everything up to formulae section start
        for (i = 1; i <= formulae_start; i++) {
          print lines[i]
        }

        # New packages will be inserted here via external script
        print "PACKAGES_PLACEHOLDER"

        # Print everything after formulae section
        for (i = formulae_end + 1; i <= NR; i++) {
          print lines[i]
        }
      } else {
        # No formulae section found, print original
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
    if [[ -n "$desc" ]]; then
      package_lines+="    - ${pkg} # ${desc}\n"
    else
      package_lines+="    - ${pkg}\n"
    fi
  done

  # Replace placeholder with actual package lines
  # Use a temporary file for the sed operation
  local tmp2
  tmp2=$(mktemp)

  # Replace PACKAGES_PLACEHOLDER with actual lines (no escaping needed with awk)
  awk -v pkg_lines="$package_lines" '
    /PACKAGES_PLACEHOLDER/ {
      printf "%s", pkg_lines
      next
    }
    { print }
  ' "$tmp" > "$tmp2" && mv "$tmp2" "$file"

  rm -f "$tmp"

  echo -e "${GREEN}  ✓ Updated $file${RESET}"
}

# ============================================================================
# Main Logic
# ============================================================================

# Route to appropriate command
case "$COMMAND" in
  check)
    brew_check "${REMAINING_ARGS[@]}"
    exit 0
    ;;
  uninstall)
    brew_uninstall
    exit 0
    ;;
  sync)
    # Check if brew is installed
    if ! command -v brew &>/dev/null; then
      echo -e "${RED}Error: Homebrew is not installed${RESET}" >&2
      echo -e "${YELLOW}Sync mode requires brew to fetch package descriptions${RESET}" >&2
      exit 1
    fi
    sync_formulae
    exit 0
    ;;
  align)
    # Continue to alignment logic below
    ;;
  *)
    echo -e "${RED}Error: Unknown command '$COMMAND'${RESET}" >&2
    echo ""
    show_usage
    ;;
esac

# ============================================================================
# Align Command - Package alignment logic
# ============================================================================

echo -e "${CYAN}🔍 Checking Homebrew package alignment...${RESET}\n"

# Check if brew is installed
if ! command -v brew &>/dev/null; then
  echo -e "${RED}Error: Homebrew is not installed${RESET}" >&2
  exit 1
fi

# Extract declared packages from taskfiles
echo -e "${CYAN}📋 Reading declared packages from taskfiles...${RESET}"
DECLARED_FORMULAE=$(extract_packages "$OS_TASKFILE" "formulae")
DECLARED_CASKS=$(extract_packages "$OS_TASKFILE" "casks")

# Get currently installed packages (only those explicitly requested, not dependencies)
echo -e "${CYAN}📦 Reading installed packages from Homebrew...${RESET}"
mapfile -t INSTALLED_FORMULAE_ARRAY < <(brew list --formula --installed-on-request -1 2>/dev/null || true)
mapfile -t INSTALLED_CASKS_ARRAY < <(brew list --cask -1 2>/dev/null || true)

# Find extra formulae (installed but not declared)
# Since we're using --installed-on-request, dependencies are already excluded
EXTRA_FORMULAE=()
for installed in "${INSTALLED_FORMULAE_ARRAY[@]}"; do
  if ! echo "$DECLARED_FORMULAE" | grep -qx "$installed"; then
    EXTRA_FORMULAE+=("$installed")
  fi
done

# Find extra casks (installed but not declared)
EXTRA_CASKS=()
for installed in "${INSTALLED_CASKS_ARRAY[@]}"; do
  if ! echo "$DECLARED_CASKS" | grep -qx "$installed"; then
    EXTRA_CASKS+=("$installed")
  fi
done

# Count declared packages
DECLARED_FORMULAE_COUNT=$(echo "$DECLARED_FORMULAE" | grep -c . || echo 0)
DECLARED_CASKS_COUNT=$(echo "$DECLARED_CASKS" | grep -c . || echo 0)

# Display results
echo ""
echo -e "${GREEN}✓ Declared formulae: ${DECLARED_FORMULAE_COUNT}${RESET}"
echo -e "${GREEN}✓ Declared casks: ${DECLARED_CASKS_COUNT}${RESET}"
echo -e "${CYAN}ℹ Installed formulae: ${#INSTALLED_FORMULAE_ARRAY[@]}${RESET}"
echo -e "${CYAN}ℹ Installed casks: ${#INSTALLED_CASKS_ARRAY[@]}${RESET}"

# Check if there are any extra packages
TOTAL_EXTRA=$((${#EXTRA_FORMULAE[@]} + ${#EXTRA_CASKS[@]}))

if [[ $TOTAL_EXTRA -eq 0 ]]; then
  echo ""
  echo -e "${GREEN}✅ All installed packages are declared in taskfiles!${RESET}"
  echo -e "${GREEN}   Your system is aligned with IaC.${RESET}"
  exit 0
fi

# Display extra packages
echo ""
echo -e "${YELLOW}⚠️  Found ${TOTAL_EXTRA} extra package(s) not declared in taskfiles:${RESET}"
echo ""

if [[ ${#EXTRA_FORMULAE[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Formulae (${#EXTRA_FORMULAE[@]}):${RESET}"
  for pkg in "${EXTRA_FORMULAE[@]}"; do
    echo "  - $pkg"
  done
  echo ""
fi

if [[ ${#EXTRA_CASKS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Casks (${#EXTRA_CASKS[@]}):${RESET}"
  for pkg in "${EXTRA_CASKS[@]}"; do
    echo "  - $pkg"
  done
  echo ""
fi

if [[ $INTERACTIVE -eq 1 ]]; then
  echo -e "${CYAN}🧭 Interactive mode: launching TUI...${RESET}"
  echo ""
  interactive_tui EXTRA_FORMULAE EXTRA_CASKS
  echo ""
  echo -e "${GREEN}Interactive session complete.${RESET}"
else
  # Prompt user for action (non-interactive batch mode)
  echo -ne "${CYAN}Would you like to uninstall these packages to align with IaC declarations? [y/N] ${RESET}"
  read -rsn1 REPLY
  echo  # Newline after response

  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    echo -e "${YELLOW}Skipping package removal.${RESET}"
    exit 0
  fi

  # Uninstall extra packages
  echo ""
  echo -e "${CYAN}🗑️  Uninstalling extra packages...${RESET}\n"

  if [[ ${#EXTRA_FORMULAE[@]} -gt 0 ]]; then
    echo -e "${CYAN}Removing formulae...${RESET}"
    for pkg in "${EXTRA_FORMULAE[@]}"; do
      echo -e "  ${RED}✗${RESET} Uninstalling: $pkg"
      brew uninstall --ignore-dependencies "$pkg" 2>&1 | sed 's/^/    /'
    done
    echo ""
  fi

  if [[ ${#EXTRA_CASKS[@]} -gt 0 ]]; then
    echo -e "${CYAN}Removing casks...${RESET}"
    for pkg in "${EXTRA_CASKS[@]}"; do
      echo -e "  ${RED}✗${RESET} Uninstalling: $pkg"
      brew uninstall --cask "$pkg" 2>&1 | sed 's/^/    /'
    done
    echo ""
  fi

  # Update cache after package changes
  update_brew_cache
fi

echo -e "${GREEN}✅ Package cleanup complete!${RESET}"
echo -e "${GREEN}   Your system is now aligned with IaC.${RESET}"

# Optionally run brew cleanup to remove old versions
echo ""
echo -ne "${CYAN}Run 'brew cleanup' to remove old package versions? [y/N] ${RESET}"
read -rsn1 CLEANUP
echo  # Newline after response

if [[ "$CLEANUP" == "y" || "$CLEANUP" == "Y" ]]; then
  echo -e "${CYAN}🧹 Running brew cleanup...${RESET}"
  brew cleanup
  echo -e "${GREEN}✅ Cleanup complete!${RESET}"
fi
