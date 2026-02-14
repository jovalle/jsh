#!/usr/bin/env bash
# jsh - J Shell Management CLI
# Install, configure, and manage your shell environment
#
# Quick Install:
#   curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/jsh | bash

# Only set options if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

VERSION="0.2.0"
JSH_DIR="${JSH_DIR:-${HOME}/.jsh}"
JSH_INSTALL_REPO="${JSH_INSTALL_REPO:-https://github.com/jovalle/jsh.git}"
JSH_INSTALL_REF="${JSH_INSTALL_REF:-main}"

# Source core utilities for platform detection and helpers
# shellcheck disable=SC1091
if [[ -f "${JSH_DIR}/src/core.sh" ]]; then
  source "${JSH_DIR}/src/core.sh" 2>/dev/null || true
fi

# Minimal fallback helpers for early initialization scenarios.
if ! declare -f info >/dev/null 2>&1; then
  info() { echo "[INFO] $*"; }
  warn() { echo "[WARN] $*" >&2; }
  error() { echo "[ERROR] $*" >&2; }
  success() { echo "[OK] $*"; }
  prefix_info() { echo "[i] $*"; }
  prefix_warn() { echo "[WARN] $*" >&2; }
  prefix_error() { echo "[ERR] $*" >&2; }
  prefix_success() { echo "[OK] $*"; }
  has() { command -v "$1" >/dev/null 2>&1; }
  source_if() { [[ -r "$1" ]] && source "$1"; return 0; }
fi

# Bootstrap install when running standalone (for curl | bash flow).
bootstrap_install() {
  local -a forwarded=("$@")
  if [[ ${#forwarded[@]} -eq 0 ]]; then
    forwarded=(setup)
  fi

  if ! has git; then
    error "git is required for bootstrap install"
    return 1
  fi

  if [[ -e "${JSH_DIR}" ]] && [[ ! -d "${JSH_DIR}" ]]; then
    error "JSH_DIR exists but is not a directory: ${JSH_DIR}"
    return 1
  fi

  if [[ -f "${JSH_DIR}/src/core.sh" ]]; then
    info "Using existing jsh installation at ${JSH_DIR}"
  elif [[ -d "${JSH_DIR}/.git" ]]; then
    info "Using existing jsh repository at ${JSH_DIR}"
  elif [[ -d "${JSH_DIR}" ]] && [[ -n "$(ls -A "${JSH_DIR}" 2>/dev/null)" ]]; then
    error "JSH_DIR is not empty and not a jsh repo: ${JSH_DIR}"
    prefix_info "Set JSH_DIR to an empty directory or clone jsh there manually"
    return 1
  else
    info "Installing jsh into ${JSH_DIR}..."
    mkdir -p "$(dirname "${JSH_DIR}")"
    if ! git clone --depth 1 --branch "${JSH_INSTALL_REF}" "${JSH_INSTALL_REPO}" "${JSH_DIR}"; then
      error "Failed to clone jsh from ${JSH_INSTALL_REPO}"
      return 1
    fi
    success "Installed jsh in ${JSH_DIR}"
  fi

  if [[ ! -x "${JSH_DIR}/jsh" ]]; then
    error "Installed jsh entrypoint missing or not executable: ${JSH_DIR}/jsh"
    return 1
  fi

  exec "${JSH_DIR}/jsh" "${forwarded[@]}"
}

# =============================================================================
# Load Modules
# =============================================================================

source_if "${JSH_DIR}/src/symlinks.sh"
source_if "${JSH_DIR}/src/status.sh"
source_if "${JSH_DIR}/src/clean.sh"
source_if "${JSH_DIR}/src/sync.sh"
source_if "${JSH_DIR}/src/configure.sh"
source_if "${JSH_DIR}/src/commands/common.sh"
source_if "${JSH_DIR}/src/commands/brew.sh"
source_if "${JSH_DIR}/src/commands/setup.sh"

# =============================================================================
# Commands
# =============================================================================

cmd_help() {
  cat <<HELP
${BOLD}jsh${RST} - J Shell Management CLI v${VERSION}

${BOLD}QUICK INSTALL:${RST}
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/jsh | bash

${BOLD}USAGE:${RST}
jsh <command> [options]

${BOLD}SETUP COMMANDS:${RST}
${CYN}setup${RST} Setup jsh environment (use --links for link-only)
${CYN}teardown${RST} Remove jsh symlinks and optionally the entire installation
${CYN}reload${RST} Reload shell with jsh re-initialized

${BOLD}INFO COMMANDS:${RST}
${CYN}status${RST} Show installation status, symlinks, and check for issues
${CYN}doctor${RST} Comprehensive health check with diagnostics and fixes

${BOLD}MAINTENANCE:${RST}
${CYN}clean${RST} Clean caches and temporary files
${CYN}brew${RST} Run brew commands (delegates on Linux root)

${BOLD}CONFIGURATION:${RST}
${CYN}sync${RST} Sync git repo with remote (safe bidirectional)
${CYN}configure${RST} Configure system settings and applications

${BOLD}OPTIONS:${RST}
-h, --help Show this help
-v, --version Show version
-r, --reload Reload shell configuration

${BOLD}TEARDOWN OPTIONS:${RST}
--full Remove entire Jsh directory (default: only unlink dotfiles)
--restore Restore backed up dotfiles before unlinking
--restore=NAME Restore from a specific backup name
--yes, -y Skip confirmation prompt
--links Remove only managed dotfile symlinks

${BOLD}SETUP OPTIONS:${RST}
--links Create only managed dotfile symlinks
--adopt=PATH Move PATH into dotfiles and symlink it back
--decom=PATH Undo an adopted symlink and restore original path
-y, --yes Skip confirmation for --decom

${BOLD}EXAMPLES:${RST}
jsh setup # Setup jsh locally
jsh setup --links # Create dotfile symlinks only
jsh setup --adopt ~/.wezterm.lua # Adopt an existing dotfile into dotfiles/
jsh setup --decom ~/.wezterm.lua # Undo adopt and restore the real file
jsh reload # Reload shell and jsh environment
jsh teardown --links # Remove managed symlinks only
jsh teardown --links --restore # Restore from backup and unlink
jsh teardown --full # Remove everything

${BOLD}ENVIRONMENT:${RST}
JSH_DIR Jsh installation directory (default: ~/.jsh)
JSH_NO_GUM Disable optional gum UI integration (set to 1)
JSH_BREW_DELEGATE_USER Delegate user for brew commands when running as root

HELP
}

cmd_version() {
  echo "jsh ${VERSION}"
}

# =============================================================================
# Main
# =============================================================================

main() {
  local cmd="${1:-}"

  if [[ ! -f "${JSH_DIR}/src/core.sh" ]]; then
    bootstrap_install "$@"
    return $?
  fi

  if [[ -z "${cmd}" ]]; then
    cmd_help
    return
  fi

  shift || true

  case "${cmd}" in
  -h | --help | help)
    cmd_help
    ;;
  -v | --version | version)
    cmd_version
    ;;
  -r | --reload)
    cmd_reload
    ;;
  setup | init)
    cmd_setup "$@"
    ;;
  teardown | deinit)
    cmd_teardown "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  doctor | check)
    cmd_status --verbose "$@"
    ;;
  reload)
    cmd_reload "$@"
    ;;
  clean)
    cmd_clean "$@"
    ;;
  brew)
    cmd_brew "$@"
    ;;
  sync)
    cmd_sync "$@"
    ;;
  configure | config)
    cmd_configure "$@"
    ;;
  *)
    error "Unknown command: ${cmd}"
    echo ""
    cmd_help
    exit 1
    ;;
  esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
