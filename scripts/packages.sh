#!/usr/bin/env bash
# Install or update the declared packages for the named groups.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/packages.sh
. "${SCRIPT_DIR}/lib/packages.sh"

# Package choices are ordinary shell, grouped by purpose and platform. Groups with an Ansible
# role declare their packages in ansible/roles/GROUP/defaults/main.yml instead.
install_group() {
  case $1 in
    maintenance)
      if command -v brew >/dev/null 2>&1 || [[ ${JSH_PLATFORM} == darwin ]]; then
        jsh::brew formulae || return
        jsh::brew casks || return
        jsh::mas || return
      fi
      ;;
    core)
      if [[ ${JSH_PLATFORM} == darwin ]]; then
        jsh::brew formulae bash curl git python zsh jq uv || return
      fi
      if [[ ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt bash ca-certificates curl git python3 zsh procps jq || return
      fi
      if [[ ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf bash ca-certificates curl git python3 zsh procps-ng jq || return
      fi
      ;;
    desktop)
      if [[ ${JSH_DESKTOP} == xfce && ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal || return
      fi
      if [[ ${JSH_DESKTOP} == xfce && ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal || return
      fi
      if [[ ${JSH_DESKTOP} == xfce && ${JSH_PLATFORM} == debian && ${JSH_HOST} == colossus ]]; then
        jsh::native apt build-essential pkg-config patch gettext meson libgtk-3-dev libpulse-dev libxfce4panel-2.0-dev libxfce4ui-2-dev libxfconf-0-dev libkeybinder-3.0-dev libnotify-dev libwnck-3-dev libexo-2-dev libxfce4windowing-0-dev || return
      fi
      ;;
    *)
      # Groups configured entirely by their own scripts declare no packages here.
      jsh::is_group "$1" && return 0
      jsh::fail "unknown package group: $1"
      return 2
      ;;
  esac
}

# Any failed group exits 1; an unknown group exits 2.
status=0
for group in "$@"; do
  case ${group} in --dry-run | --update) continue ;; -*)
    jsh::fail "unknown option: ${group}"
    exit 2
    ;;
  esac
  install_group "${group}" || case $? in
    2) status=2 ;;
    *) ((status)) || status=1 ;;
  esac
done
exit "${status}"
