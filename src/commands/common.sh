# common.sh - Shared CLI helpers for jsh command modules
# shellcheck disable=SC2034

[[ -n "${_JSH_COMMANDS_COMMON_LOADED:-}" ]] && return 0
_JSH_COMMANDS_COMMON_LOADED=1

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
is_linux() { [[ "$(uname -s)" == "Linux" ]]; }

jsh_section() {
  echo ""
  echo "${BOLD}${CYN}$*${RST}"
}

jsh_milestone() {
  echo "${BOLD}${BLU}==>${RST} $*"
}

jsh_note() {
  echo "${DIM}$*${RST}"
}

# Show status for initialized submodules
# Usage: _show_submodule_status <repo_dir> [submodule_paths...]
# If submodule_paths provided, only show those; otherwise show all from .gitmodules
_show_submodule_status() {
  local repo_dir="$1"
  shift
  local submodule_paths=("$@")
  local gitmodules="${repo_dir}/.gitmodules"

  # If no specific paths given, read all from .gitmodules
  if [[ ${#submodule_paths[@]} -eq 0 ]] && [[ -f "${gitmodules}" ]]; then
    while IFS= read -r line; do
      if [[ "${line}" =~ path\ =\ (.+) ]]; then
        submodule_paths+=("${BASH_REMATCH[1]}")
      fi
    done <"${gitmodules}"
  fi

  # Show status for each submodule
  for submod_path in "${submodule_paths[@]}"; do
    local full_path="${repo_dir}/${submod_path}"
    if [[ -d "${full_path}" ]] && [[ -n "$(ls -A "${full_path}" 2>/dev/null)" ]]; then
      local sub_commit
      sub_commit=$(git -C "${full_path}" rev-parse --short HEAD 2>/dev/null || echo "?")
      prefix_success "${submod_path} ${DIM}(${sub_commit})${RST}"
    fi
  done
}

# =============================================================================
# Banner and Requirements
# =============================================================================

show_banner() {
  echo ""
  echo "${BOLD}${CYN}"
  echo "      _     _"
  echo "     (_)___| |__"
  echo "     | / __| '_ \\"
  echo "     | \\__ \\ | | |"
  echo "     |_|___/_| |_|"
  echo "${RST}"
  echo ""
}

show_next_steps() {
  jsh_section "Next Steps"
  echo "${CYN}exec \$SHELL${RST}"
  jsh_section "Useful Commands"
  echo "${CYN}jsh status${RST} - Show installation status"
}
