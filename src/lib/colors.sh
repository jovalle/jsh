# Common colors and output functions for jsh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

log() { echo -e "${BLUE}🔹 $1${RESET}"; }
info() { echo -e "${CYAN}ℹ️  $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $1${RESET}"; }
error() { echo -e "${RED}❌ $1${RESET}"; exit 1; }
success() { echo -e "${GREEN}✅ $1${RESET}"; }
header() { echo -e "\n${BOLD}${BLUE}▶ $1${RESET}\n"; }

confirm() {
  local prompt="$1"
  local response
  read -n 1 -r -p "${prompt} (y/N): " response
  echo
  case "$response" in
    y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_exists() { command -v "$1" &> /dev/null; }
is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }
is_wsl() { grep -qi microsoft /proc/version 2> /dev/null; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Get jsh root directory
get_root_dir() {
  if [[ -n "${JSH_ROOT:-}" ]]; then
    echo "$JSH_ROOT"
  else
    # When compiled by bashly, the script is at the repo root
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Check if we're the compiled jsh script at root
    if [[ -f "$script_path/src/bashly.yml" ]]; then
      echo "$script_path"
    elif [[ -f "$script_path/../src/bashly.yml" ]]; then
      # We're in bin/
      dirname "$script_path"
    else
      # Fallback: look for .git directory
      local dir="$script_path"
      while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]]; then
          echo "$dir"
          return
        fi
        dir="$(dirname "$dir")"
      done
      echo "$script_path"
    fi
  fi
}
