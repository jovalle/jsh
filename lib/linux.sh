#!/usr/bin/env bash
# Provide shared Linux platform and desktop capability helpers.

jsh_linux_family() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  local ID='' ID_LIKE=''

  [[ "${JSH_UNAME:-$(uname -s)}" == Linux && -r "${os_release}" ]] || return 1
  # shellcheck source=/dev/null
  . "${os_release}"
  case " ${ID:-} ${ID_LIKE:-} " in
    *' arch '* | *' archlinux '* | *' endeavouros '*) printf '%s\n' arch ;;
    *' fedora '* | *' rhel '* | *' centos '*) printf '%s\n' fedora ;;
    *' debian '* | *' ubuntu '*) printf '%s\n' debian ;;
    *) printf '%s\n' unknown ;;
  esac
}

jsh_linux_desktop() {
  local desktop="${JSH_DESKTOP:-${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}}"
  desktop=${desktop,,}
  case "${desktop}" in
    *xfce*) printf '%s\n' xfce ;;
    *gnome*) printf '%s\n' gnome ;;
    *) printf '%s\n' unknown ;;
  esac
}

jsh_run_root() {
  if [[ "${JSH_CONFIGURE_DRY_RUN:-0}" == 1 || "${JSH_INSTALL_DRY_RUN:-0}" == 1 ]]; then
    jsh_detail "Would run as root: $*"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif [[ -r /proc/self/status ]] && grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status; then
    jsh_error "Cannot run sudo: this process has Linux no-new-privileges enabled."
    jsh_detail "Rerun Jsh from a regular terminal outside this restricted session."
    return 1
  elif command -v sudo > /dev/null 2>&1; then
    sudo -- "$@"
  else
    jsh_error "sudo is required to modify the system."
    return 1
  fi
}

jsh_gnome_custom_shortcut() {
  local name=$1 binding=$2 command=$3
  local base='/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings'
  local schema='org.gnome.settings-daemon.plugins.media-keys.custom-keybinding'
  local key path current existing serialized='[' separator=''
  local -a paths=()

  command -v gsettings > /dev/null 2>&1 || return 1
  key=$(printf '%s' "${name}" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')
  key=${key#jsh-}
  path="${base}/jsh-${key}/"
  if ! current=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings); then
    jsh_error "Unable to read existing GNOME custom shortcuts."
    return 1
  fi
  while IFS= read -r existing; do
    [[ -n "${existing}" ]] && paths+=("${existing}")
  done < <(grep -o "'[^']*'" <<< "${current}" | tr -d "'")
  if [[ " ${paths[*]} " != *" ${path} "* ]]; then
    paths+=("${path}")
    for existing in "${paths[@]}"; do
      serialized+="${separator}'${existing}'"
      separator=', '
    done
    serialized+=']'
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "${serialized}"
  fi
  gsettings set "${schema}:${path}" name "${name}"
  gsettings set "${schema}:${path}" binding "${binding}"
  gsettings set "${schema}:${path}" command "${command}"
}
