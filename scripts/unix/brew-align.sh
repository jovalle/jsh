#!/usr/bin/env zsh
# shellcheck shell=bash
# shellcheck disable=SC1073,SC1072,SC2296,SC2034
# SC1073/SC1072: Zsh-specific syntax (parameter expansion flags)
# SC2296: Zsh parameter expansion with flags like ${(f)var}
# SC2034: Variables used in zsh-specific ways

set -e
set -u
set -o pipefail

# ============================================================================
# brew-align.sh
# ============================================================================
# Compares installed Homebrew packages against declared packages in taskfile
# and prompts user to uninstall extras to align with Infrastructure as Code.
# Only checks explicitly requested packages (dependencies are ignored).
# ============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# Determine the root directory of the project
SCRIPT_DIR="${0:a:h}"
ROOT_DIR="${SCRIPT_DIR}/../.."

# OS-specific taskfile path
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS_TYPE" in
  darwin*) OS_TASKFILE="${ROOT_DIR}/.taskfiles/darwin/taskfile.yaml" ;;
  linux*) OS_TASKFILE="${ROOT_DIR}/.taskfiles/linux/taskfile.yaml" ;;
  *)
    echo -e "${RED}Unsupported OS: ${OS_TYPE}${RESET}" >&2
    exit 1
    ;;
esac

# ============================================================================
# Helper Functions
# ============================================================================

# Parse args
INTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interactive)
      INTERACTIVE=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-i|--interactive]"
      echo "  -i, --interactive   Prompt for each extra package to keep/declare/remove"
      exit 0
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
  ' "$file"
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

  # Simple approach: read file into array, find insertion point, rebuild
  local tmp
  tmp=$(mktemp)

  awk -v key="$key" -v pkg="$pkg" '
    BEGIN {
      in_vars = 0
      found_key = 0
      inserted = 0
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
        # Find last item in the list
        last_item = key_line
        for (i = key_line + 1; i <= NR; i++) {
          if (lines[i] ~ /^    - /) {
            last_item = i
          } else if (lines[i] !~ /^[[:space:]]*$/ && lines[i] !~ /^    /) {
            break
          }
        }
        # Print everything up to and including last item
        for (i = 1; i <= last_item; i++) {
          print lines[i]
        }
        # Insert new package
        printf("    - %s\n", pkg)
        # Print remaining lines
        for (i = last_item + 1; i <= NR; i++) {
          print lines[i]
        }
      } else {
        # Key not found, just print original file
        for (i = 1; i <= NR; i++) {
          print lines[i]
        }
        # Append new section if vars exists
        if (in_vars) {
          printf("\n  %s:\n    - %s\n", key, pkg)
        } else {
          printf("\nvars:\n  %s:\n    - %s\n", key, pkg)
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
  local -A pkg_types=()
  local -A pkg_actions=()

  # Use indirect parameter expansion to access the arrays
  # Must expand BEFORE setting KSH_ARRAYS to avoid indexing issues
  local -a formulae_ref
  formulae_ref=("${(@P)formulae_var}")
  local -a casks_ref
  casks_ref=("${(@P)casks_var}")

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
  all_packages=("${(@on)all_packages}")

  # Use 0-indexed arrays for consistency - set AFTER array expansion
  setopt LOCAL_OPTIONS KSH_ARRAYS

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

  # Function to cleanup terminal state
  cleanup_terminal() {
    tput rmcup 2>/dev/null || true  # Restore screen
    stty echo 2>/dev/null || true   # Show input
    tput cnorm 2>/dev/null || true  # Show cursor
    tput sgr0 2>/dev/null || true   # Reset colors
    printf '\e[r' 2>/dev/null || true  # Reset scrolling region
    printf '\e[?1049l' 2>/dev/null || true  # Exit alternate screen buffer (backup method)
  }

  # Set up trap to ensure cleanup on exit
  trap cleanup_terminal EXIT INT TERM

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
    printf "${CYAN}║${RESET}%-72s${CYAN}║${RESET}\n" "  Navigation: ↑/↓ | Toggle: ←/→/SPACE | Submit: ENTER | Cancel: ESC"
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

    # Read single character (zsh-compatible)
    IFS= read -rsk1 key

    # Handle escape sequences (arrow keys)
    if [[ "$key" == $'\x1b' ]]; then
      read -rsk2 -t 0.1 key2
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
          running=0
          trap - EXIT INT TERM  # Remove trap before cleanup
          cleanup_terminal
          echo -e "${YELLOW}Cancelled. No changes made.${RESET}"
          return 1
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
  read -rsk1 CONFIRM
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

  echo ""
  echo -e "${GREEN}✓ Changes applied successfully${RESET}"
}

# ============================================================================
# Main Logic
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
INSTALLED_FORMULAE=$(brew list --formula --installed-on-request -1 2>/dev/null || true)
INSTALLED_CASKS=$(brew list --cask -1 2>/dev/null || true)

# Find extra formulae (installed but not declared)
# Since we're using --installed-on-request, dependencies are already excluded
EXTRA_FORMULAE=()
for installed in ${(f)INSTALLED_FORMULAE}; do
  if ! echo "$DECLARED_FORMULAE" | grep -qx "$installed"; then
    EXTRA_FORMULAE+=("$installed")
  fi
done

# Find extra casks (installed but not declared)
EXTRA_CASKS=()
for installed in ${(f)INSTALLED_CASKS}; do
  if ! echo "$DECLARED_CASKS" | grep -qx "$installed"; then
    EXTRA_CASKS+=("$installed")
  fi
done

# Display results
echo ""
echo -e "${GREEN}✓ Declared formulae: ${#${(f)DECLARED_FORMULAE}}${RESET}"
echo -e "${GREEN}✓ Declared casks: ${#${(f)DECLARED_CASKS}}${RESET}"
echo -e "${CYAN}ℹ Installed formulae: ${#${(f)INSTALLED_FORMULAE}}${RESET}"
echo -e "${CYAN}ℹ Installed casks: ${#${(f)INSTALLED_CASKS}}${RESET}"

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
  read -rsk1 REPLY
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
fi

echo -e "${GREEN}✅ Package cleanup complete!${RESET}"
echo -e "${GREEN}   Your system is now aligned with IaC.${RESET}"

# Optionally run brew cleanup to remove old versions
echo ""
echo -ne "${CYAN}Run 'brew cleanup' to remove old package versions? [y/N] ${RESET}"
read -rsk1 CLEANUP
echo  # Newline after response

if [[ "$CLEANUP" == "y" || "$CLEANUP" == "Y" ]]; then
  echo -e "${CYAN}🧹 Running brew cleanup...${RESET}"
  brew cleanup
  echo -e "${GREEN}✅ Cleanup complete!${RESET}"
fi
