# brew.sh - jsh brew passthrough command
# shellcheck disable=SC2034,SC1091

[[ -n "${_JSH_BREW_COMMAND_LOADED:-}" ]] && return 0
_JSH_BREW_COMMAND_LOADED=1

# @jsh-cmd brew Run brew commands (delegates on Linux root)
cmd_brew() {
  local brew_cmd=""
  local brew_prefix=""
  local skip_setup_prev="${JSH_BREW_SKIP_SETUP:-}"

  export JSH_BREW_SKIP_SETUP=1
  source_if "${JSH_DIR}/src/brew.sh"
  if [[ -n "${skip_setup_prev}" ]]; then
    export JSH_BREW_SKIP_SETUP="${skip_setup_prev}"
  else
    unset JSH_BREW_SKIP_SETUP
  fi

  if declare -f _brew_find_prefix >/dev/null 2>&1; then
    brew_prefix=$(_brew_find_prefix 2>/dev/null || true)
  fi

  if [[ -n "${brew_prefix}" ]] && [[ -x "${brew_prefix}/bin/brew" ]]; then
    brew_cmd="${brew_prefix}/bin/brew"
  elif has brew; then
    brew_cmd="$(command -v brew)"
  fi

  if [[ -z "${brew_cmd}" ]]; then
    error "brew not found"
    return 1
  fi

  if declare -f _brew_run >/dev/null 2>&1; then
    _brew_run "${brew_cmd}" "$@"
  else
    "${brew_cmd}" "$@"
  fi
}
