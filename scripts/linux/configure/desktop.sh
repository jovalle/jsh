#!/usr/bin/env bash
# Configure opt-in Linux desktop appearance and panel features.

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

xfconf_set() {
  local channel=$1 property=$2 type=$3 value=$4
  if xfconf-query -c "${channel}" -p "${property}" > /dev/null 2>&1; then
    xfconf-query -c "${channel}" -p "${property}" -s "${value}" > /dev/null
  else
    xfconf-query -c "${channel}" -p "${property}" -n -t "${type}" -s "${value}" > /dev/null
  fi
}

configure_wallpaper() {
  local property backdrop
  xfconf_set xfwm4 /general/use_compositing bool false
  while IFS= read -r property; do
    [[ "${property}" == */image-style ]] || continue
    backdrop=${property%/image-style}
    xfconf_set xfce4-desktop "${property}" int 0
    xfconf_set xfce4-desktop "${backdrop}/color-style" int 0
  done < <(xfconf-query -c xfce4-desktop -l 2> /dev/null || true)
  xfdesktop --reload > /dev/null 2>&1 || true
}

managed_plugin() {
  local type=$1 id managed plugin_type max_id
  while IFS= read -r id; do
    [[ "${id}" =~ ^[0-9]+$ ]] || continue
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2> /dev/null || true)
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-managed" 2> /dev/null || true)
    if [[ "${plugin_type}" == "${type}" && "${managed}" == true ]]; then
      printf '%s\n' "${id}"
      return
    fi
  done < <(xfconf-query -c xfce4-panel -lv 2> /dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\)[[:space:]].*|\1|p' | sort -nu)

  max_id=$(xfconf-query -c xfce4-panel -lv 2> /dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
  id=$((${max_id:-0} + 1))
  xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" -n -t string -s "${type}" > /dev/null
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-managed" bool true
  printf '%s\n' "${id}"
}

configure_panel() {
  local panel_id cpu_id load_id id present
  local -a plugin_ids=() arguments=()
  panel_id=$(xfconf-query -c xfce4-panel -p /panels 2> /dev/null | sed -n '1p')
  [[ "${panel_id}" =~ ^[0-9]+$ ]] || {
    jsh_note "Skipping panel monitors: no XFCE panel is available."
    return
  }
  cpu_id=$(managed_plugin cpugraph)
  load_id=$(managed_plugin systemload)

  while IFS= read -r id; do
    [[ "${id}" =~ ^[0-9]+$ ]] && plugin_ids+=("${id}")
  done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2> /dev/null)
  for id in "${cpu_id}" "${load_id}"; do
    present=0
    for plugin_id in "${plugin_ids[@]}"; do
      [[ "${plugin_id}" == "${id}" ]] && present=1
    done
    ((present)) || plugin_ids+=("${id}")
  done
  for id in "${plugin_ids[@]}"; do
    arguments+=(-t int -s "${id}")
  done
  xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${arguments[@]}" > /dev/null

  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/mode" int 0
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/per-core" int 1
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/size" int 64
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/update-interval" int 2
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/command" string xfce4-taskmanager
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/timeout-seconds" uint 1
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/cpu/enabled" bool false
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/memory/enabled" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/network/enabled" bool true
  xfce4-panel -r > /dev/null 2>&1 || true
}

configure_identity() {
  local avatar="${JSH_USER_AVATAR:-${JSH_ROOT}/.github/assets/j.jpg}"

  [[ ! -r "${avatar}" ]] || install -m 0644 "${avatar}" "${HOME}/.face"
}

configure_xfce() {
  if [[ -d /usr/share/themes/Arc-Dark || -d "${HOME}/.themes/Arc-Dark" ]]; then
    xfconf_set xsettings /Net/ThemeName string Arc-Dark
    xfconf_set xfwm4 /general/theme string Arc-Dark
  fi
  if [[ -d /usr/share/icons/Qogir-Dark || -d "${HOME}/.icons/Qogir-Dark" ]]; then
    xfconf_set xsettings /Net/IconThemeName string Qogir-Dark
  fi
  xfconf_set xfce4-terminal /color-foreground string '#D7DAE0'
  xfconf_set xfce4-terminal /color-background string '#0D1117'
  xfconf_set xfce4-terminal /color-cursor string '#D7DAE0'
  xfconf_set xfce4-terminal /color-cursor-use-default bool false
  xfconf_set xfce4-terminal /color-use-theme bool false
  configure_wallpaper
  configure_panel
}

configure_gnome() {
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  if [[ "$(gsettings writable org.gnome.desktop.interface gtk-theme 2> /dev/null)" == true ]] &&
    [[ -d /usr/share/themes/Arc-Dark || -d "${HOME}/.themes/Arc-Dark" ]]; then
    gsettings set org.gnome.desktop.interface gtk-theme Arc-Dark
  fi
}

main() {
  local desktop
  [[ "$(uname -s)" == Linux ]] || return
  desktop=$(jsh_linux_desktop)
  case "${desktop}" in
    xfce)
      command -v xfconf-query > /dev/null 2>&1 || {
        jsh_note "Skipping XFCE configuration: xfconf-query is unavailable."
        return
      }
      ;;
    gnome)
      command -v gsettings > /dev/null 2>&1 || {
        jsh_note "Skipping GNOME configuration: gsettings is unavailable."
        return
      }
      ;;
    *)
      jsh_note "Skipping desktop configuration: XFCE or GNOME is not active."
      return
      ;;
  esac

  jsh_detail "This will replace managed ${desktop^^} appearance and desktop settings."
  jsh_prompt "Configure the ${desktop^^} desktop? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_note "Skipping desktop configuration."
    return
  }

  "configure_${desktop}"
  configure_identity
  jsh_success "${desktop^^} desktop configured."
}

main "$@"
