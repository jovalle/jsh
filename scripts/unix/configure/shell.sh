#!/usr/bin/env bash
# Configure the default login shell for the current user.

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

get_target_user() {
  if [[ -n "${JSH_TARGET_USER:-}" ]]; then
    printf '%s\n' "${JSH_TARGET_USER}"
  elif [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
  else
    id -un
  fi
}

get_current_shell() {
  local user=$1 shell_path=""
  local passwd_file=${JSH_PASSWD_FILE:-/etc/passwd}

  if [[ -n "${JSH_CURRENT_SHELL:-}" ]]; then
    printf '%s\n' "${JSH_CURRENT_SHELL}"
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]] && command -v dscl > /dev/null 2>&1; then
    shell_path=$(dscl . -read "/Users/${user}" UserShell 2> /dev/null | awk '{ print $2 }')
  fi

  if [[ -z "${shell_path}" ]] && command -v getent > /dev/null 2>&1 && [[ "${passwd_file}" == "/etc/passwd" ]]; then
    shell_path=$(getent passwd "${user}" 2> /dev/null | cut -d: -f7)
  fi

  if [[ -z "${shell_path}" && -r "${passwd_file}" ]]; then
    shell_path=$(awk -F: -v u="${user}" '$1 == u { print $7 }' "${passwd_file}" 2> /dev/null)
  fi

  if [[ -z "${shell_path}" ]]; then
    shell_path=${SHELL:-}
  fi

  printf '%s\n' "${shell_path}"
}

find_target_shell() {
  local candidate
  local shells_file=${JSH_SHELLS_FILE:-/etc/shells}

  if [[ -r "${shells_file}" ]]; then
    for candidate in /usr/bin/zsh /bin/zsh /usr/local/bin/zsh /opt/homebrew/bin/zsh; do
      if grep -Fxq "${candidate}" "${shells_file}" 2> /dev/null && [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done

    while IFS= read -r candidate; do
      if [[ "${candidate##*/}" == "zsh" && -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done < "${shells_file}"
  fi

  if candidate=$(command -v zsh 2> /dev/null) && [[ -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

confirm() {
  local prompt=$1
  local answer

  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  while :; do
    jsh_prompt "${prompt} [Y/n]: "
    if ! read -r answer; then
      return 0
    fi
    case "${answer}" in
      '' | y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) jsh_warn "Please answer yes or no." ;;
    esac
  done
}

ensure_shell_registered() {
  local target_shell=$1
  local shells_file=${JSH_SHELLS_FILE:-/etc/shells}

  [[ -r "${shells_file}" ]] || return 0
  if grep -Fxq "${target_shell}" "${shells_file}" 2> /dev/null; then
    return 0
  fi

  if [[ "${JSH_CONFIGURE_DRY_RUN:-0}" == 1 || "${JSH_INSTALL_DRY_RUN:-0}" == 1 ]]; then
    jsh_detail "Would register ${target_shell} in ${shells_file}"
    return 0
  fi

  if declare -F jsh_run_root > /dev/null 2>&1; then
    jsh_detail "Registering ${target_shell} in ${shells_file}..."
    printf '%s\n' "${target_shell}" | jsh_run_root tee -a "${shells_file}" > /dev/null
  elif [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "${target_shell}" >> "${shells_file}"
  fi
}

change_shell() {
  local target_shell=$1 user_name=$2

  if [[ "${JSH_CONFIGURE_DRY_RUN:-0}" == 1 || "${JSH_INSTALL_DRY_RUN:-0}" == 1 ]]; then
    jsh_detail "Would change default shell for ${user_name} to ${target_shell}"
    return 0
  fi

  ensure_shell_registered "${target_shell}"

  if [[ "$(id -u)" -eq 0 ]]; then
    if command -v usermod > /dev/null 2>&1; then
      usermod -s "${target_shell}" "${user_name}" && return 0
    fi
    if command -v chsh > /dev/null 2>&1; then
      chsh -s "${target_shell}" "${user_name}" && return 0
    fi
    return 1
  fi

  if declare -F jsh_run_root > /dev/null 2>&1; then
    if command -v usermod > /dev/null 2>&1; then
      if jsh_run_root usermod -s "${target_shell}" "${user_name}"; then
        return 0
      fi
    fi
    if command -v chsh > /dev/null 2>&1; then
      if jsh_run_root chsh -s "${target_shell}" "${user_name}"; then
        return 0
      fi
    fi
  fi

  if command -v chsh > /dev/null 2>&1; then
    chsh -s "${target_shell}" && return 0
  fi

  jsh_error "Unable to change default shell: neither chsh nor usermod succeeded."
  return 1
}

main() {
  local user_name current_shell target_shell new_shell

  user_name=$(get_target_user)
  current_shell=$(get_current_shell "${user_name}")

  if [[ "${current_shell##*/}" == "zsh" ]]; then
    jsh_note "Default shell is already Zsh (${current_shell})."
    return 0
  fi

  target_shell=$(find_target_shell || true)
  if [[ -z "${target_shell}" ]]; then
    jsh_error "Zsh is unavailable; install it before configuring the default shell."
    return 1
  fi

  jsh_detail "Current login shell for ${user_name} is ${current_shell:-unknown}."
  if ! confirm "Change default shell to Zsh (${target_shell})?"; then
    jsh_note "Skipping default shell change."
    return 0
  fi

  if change_shell "${target_shell}" "${user_name}"; then
    new_shell=$(get_current_shell "${user_name}")
    if [[ "${new_shell##*/}" == "zsh" ]]; then
      jsh_success "Default shell changed to Zsh (${new_shell})."
      jsh_note "You may need to log out and log back in for the change to take effect in new sessions."
    elif [[ "${JSH_CONFIGURE_DRY_RUN:-0}" == 1 || "${JSH_INSTALL_DRY_RUN:-0}" == 1 ]]; then
      jsh_success "Dry run: would change default shell to Zsh (${target_shell})."
    else
      jsh_error "Shell change command completed, but default shell is currently ${new_shell}."
      return 1
    fi
  else
    jsh_error "Failed to change default shell to ${target_shell}."
    return 1
  fi
}

main "$@"
