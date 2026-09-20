#!/usr/bin/env bash
# Reconcile Visual Studio Code shell settings and managed keybindings.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

configure_vscode() {
  local platform destination flatpak_source shell_path settings current temporary ensure_status
  local bindings desired
  command -v code >/dev/null 2>&1 || return
  shell_path=$(command -v zsh || true)
  [[ -n ${shell_path} ]] || return
  if [[ $(uname -s) == Darwin ]]; then
    platform=osx
    destination=${HOME}/Library/Application Support/Code/User
  else
    platform=linux
    destination=${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User
    flatpak_source=${HOME}/.var/app/com.visualstudio.code/config/Code/User
  fi
  mkdir -p "${JSH_ROOT}/tmp"

  settings=${destination}/settings.json
  if [[ ! -e ${settings} && -n ${flatpak_source:-} && -f ${flatpak_source}/settings.json ]]; then
    jsh_ensure_file "${settings}" "${flatpak_source}/settings.json" 0644 || {
      ensure_status=$?
      [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
    }
  fi
  current=${settings}
  [[ -f ${current} ]] || current=/dev/null
  temporary=$(mktemp "${JSH_ROOT}/tmp/vscode-settings.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  if [[ ${current} == /dev/null ]]; then
    printf '{}\n' > "${temporary}.input"
    current=${temporary}.input
  fi
  if ! jq --arg platform "${platform}" --arg shell "${shell_path}" '
    ("terminal.integrated.profiles." + $platform) as $profiles
    | ("terminal.integrated.defaultProfile." + $platform) as $default
    | .[$profiles] = ((.[$profiles] // {})
      | .zsh = ((.zsh // {})
        | if (.path != "zsh" and .path != $shell) then .path = $shell else . end))
    | .[$default] = "zsh"
  ' "${current}" > "${temporary}"; then
    rm -f -- "${temporary}" "${temporary}.input"
    jsh::log_error "Invalid VS Code settings JSON: ${settings}"
    return 1
  fi
  rm -f -- "${temporary}.input"
  jsh_ensure_file "${settings}" "${temporary}" 0644 || {
    ensure_status=$?
    rm -f -- "${temporary}"
    [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
  }
  rm -f -- "${temporary}"

  bindings=${destination}/keybindings.json
  desired=${JSH_ROOT}/dotfiles/.config/Code/User/keybindings.json
  current=${bindings}
  [[ -f ${current} ]] || current=/dev/null
  temporary=$(mktemp "${JSH_ROOT}/tmp/vscode-bindings.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  if [[ ${current} == /dev/null ]]; then
    printf '[]\n' > "${temporary}.input"
    current=${temporary}.input
  fi
  if ! jq -s '
    .[0] as $current | .[1] as $desired
    | ($current | map(. as $existing
      | select(any($desired[]; .key == $existing.key and .when == $existing.when) | not)))
      + $desired
  ' "${current}" "${desired}" > "${temporary}"; then
    rm -f -- "${temporary}" "${temporary}.input"
    jsh::log_error "Invalid VS Code keybindings JSON: ${bindings}"
    return 1
  fi
  rm -f -- "${temporary}.input"
  jsh_ensure_file "${bindings}" "${temporary}" 0644 || {
    ensure_status=$?
    rm -f -- "${temporary}"
    [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
  }
  rm -f -- "${temporary}"

  if [[ $(uname -s) == Linux ]]; then
    temporary=$(mktemp "${JSH_ROOT}/tmp/vscode-hidden.XXXXXXXXXX")
    jsh_interrupt_cleanup_path "${temporary}"
    printf '[Desktop Entry]\nType=Application\nHidden=true\n' > "${temporary}"
    jsh_ensure_file "${XDG_DATA_HOME:-${HOME}/.local/share}/applications/com.visualstudio.code.desktop" \
      "${temporary}" 0644 || {
      ensure_status=$?
      rm -f -- "${temporary}"
      [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
    }
    rm -f -- "${temporary}"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  configure_vscode
fi
