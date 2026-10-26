#!/usr/bin/env bash
# Configure Linux desktop appearance and XFCE panel features.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

panel_files_changed=0

xfconf_set() {
  local channel=$1 property=$2 type=$3 value=$4
  if xfconf-query -c "${channel}" -p "${property}" >/dev/null 2>&1; then
    [[ $(xfconf-query -c "${channel}" -p "${property}") == "${value}" ]] ||
      xfconf-query -c "${channel}" -p "${property}" -s "${value}" >/dev/null
  else
    xfconf-query -c "${channel}" -p "${property}" -n -t "${type}" -s "${value}" >/dev/null
  fi
}

write_if_changed() {
  local target=$1 mode=$2 temporary
  mkdir -p -- "${target%/*}"
  temporary=$(mktemp "${target}.XXXXXX")
  command cat >"${temporary}"
  if cmp -s "${temporary}" "${target}"; then
    rm -f -- "${temporary}"
    return
  fi
  install -m "${mode}" "${temporary}" "${target}"
  rm -f -- "${temporary}"
  panel_files_changed=1
}

managed_plugin() {
  local type=$1 role=${2:-$1} id managed plugin_type plugin_role max_id
  while IFS= read -r id; do
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2>/dev/null || true)
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-managed" 2>/dev/null || true)
    plugin_role=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-role" 2>/dev/null || true)
    if [[ ${plugin_type} == "${type}" && ${managed} == true &&
      ( ${plugin_role} == "${role}" || ( -z ${plugin_role} && ${role} == "${type}" ) ) ]]; then
      xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-role" string "${role}"
      printf '%s\n' "${id}"
      return
    fi
  done < <(xfconf-query -c xfce4-panel -lv 2>/dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\)[[:space:]].*|\1|p' | sort -nu)
  max_id=$(xfconf-query -c xfce4-panel -lv 2>/dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
  id=$((${max_id:-0} + 1))
  xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" -n -t string -s "${type}" >/dev/null
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-managed" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-role" string "${role}"
  printf '%s\n' "${id}"
}

configure_panel() {
  local panel_id cpu_id load_id net_id fs_id audio_id cafe_id id plugin_id plugin_type
  local panel_before panel_after systray_id='' clock_id='' actions_id=''
  local -a plugin_ids=() existing_ids=() base_ids=() arguments=()
  panel_before=$(xfconf-query -c xfce4-panel -lv 2>/dev/null || true)
  panel_id=$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+$' | head -n 1)
  [[ ${panel_id} =~ ^[0-9]+$ ]] || { jsh::log_note '  › skipped panel: unavailable'; return; }
  cpu_id=$(managed_plugin cpugraph)
  load_id=$(managed_plugin systemload)
  fs_id=$(managed_plugin fsguard)
  net_id=$(managed_plugin genmon net)
  audio_id=$(managed_plugin pulseaudio)
  cafe_id=$(managed_plugin genmon cafe)
  while IFS= read -r id; do [[ ${id} =~ ^[0-9]+$ ]] && existing_ids+=("${id}"); done < <(
    xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2>/dev/null)
  for plugin_id in "${existing_ids[@]}"; do
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" 2>/dev/null || true)
    case ${plugin_type} in
      docklike | netload | cpugraph | systemload | fsguard | genmon | pulseaudio) ;;
      systray) systray_id=${plugin_id} ;;
      clock) clock_id=${plugin_id} ;;
      actions) actions_id=${plugin_id} ;;
      *) base_ids+=("${plugin_id}") ;;
    esac
  done
  [[ -n ${clock_id} ]] || clock_id=$(managed_plugin clock)
  plugin_ids=("${base_ids[@]}" "${cpu_id}" "${load_id}" "${fs_id}" "${net_id}")
  [[ -z ${systray_id} ]] || plugin_ids+=("${systray_id}")
  plugin_ids+=("${cafe_id}" "${audio_id}")
  [[ -z ${clock_id} ]] || plugin_ids+=("${clock_id}")
  [[ -z ${actions_id} ]] || plugin_ids+=("${actions_id}")
  for id in "${plugin_ids[@]}"; do arguments+=(-t int -s "${id}"); done
  [[ ${plugin_ids[*]} == "${existing_ids[*]}" ]] ||
    xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${arguments[@]}" >/dev/null

  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/mode" int 0
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/per-core" int 1
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/size" int 64
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/update-interval" int 2
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/command" string xfce4-taskmanager
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/in-terminal" int 0
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/timeout-seconds" uint 1
  for id in cpu memory swap; do xfconf_set xfce4-panel "/plugins/plugin-${load_id}/${id}/enabled" bool true; done
  for id in network uptime; do xfconf_set xfce4-panel "/plugins/plugin-${load_id}/${id}/enabled" bool false; done
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/command" string xfce4-taskmanager
  xfconf_set xfce4-panel "/plugins/plugin-${fs_id}/mountpoint" string /
  write_if_changed "${HOME}/.config/xfce4/panel/fsguard-${fs_id}.rc" 0644 <<'EOF'
yellow=8
red=2
lab_size_visible=false
progress_bar_visible=true
hide_button=true
label=disk
label_visible=true
mnt=/
EOF
  write_if_changed "${HOME}/.config/xfce4/panel/net-led.sh" 0755 <"${JSH_ROOT}/conf/xfce/net.sh"
  write_if_changed "${HOME}/.config/xfce4/panel/genmon-${net_id}.rc" 0644 <<EOF
Command=${HOME}/.config/xfce4/panel/net-led.sh
UseLabel=false
Text=
UpdatePeriod=100
EOF
  if [[ -e ${HOME}/.config/xfce4/panel/cafe-status.sh || -e ${HOME}/.config/xfce4/panel/cafe-toggle.sh ]]; then
    rm -f "${HOME}/.config/xfce4/panel/cafe-status.sh" "${HOME}/.config/xfce4/panel/cafe-toggle.sh"
    panel_files_changed=1
  fi
  write_if_changed "${HOME}/.config/xfce4/panel/genmon-${cafe_id}.rc" 0644 <<EOF
Command=${JSH_ROOT}/bin/cafe --xfce-status
UseLabel=false
Text=
UpdatePeriod=500
Action=${JSH_ROOT}/bin/cafe --xfce-toggle
EOF
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-keyboard-shortcuts" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-mpris" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-multimedia-keys" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/mixer-command" string pavucontrol
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/jsh-managed" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/mode" int 2
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/digital-layout" int 3
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/digital-time-format" string '%Y-%m-%d %H:%M:%S'
  panel_after=$(xfconf-query -c xfce4-panel -lv 2>/dev/null || true)
  [[ ${panel_before} != "${panel_after}" || ${panel_files_changed} != 0 ]] || return
  if pgrep -x xfce4-panel >/dev/null 2>&1; then
    DISPLAY=${DISPLAY:-:0} timeout 5 xfce4-panel -r >/dev/null 2>&1 || true
    sleep 1
    pgrep -x xfce4-panel >/dev/null 2>&1 || DISPLAY=${DISPLAY:-:0} nohup xfce4-panel >/dev/null 2>&1 &
  fi
}

configure_screensaver() {
  local autostart=${HOME}/.config/autostart/light-locker.desktop
  pgrep -x light-locker >/dev/null 2>&1 && pkill -x light-locker 2>/dev/null || true
  write_if_changed "${autostart}" 0644 <<'EOF'
[Desktop Entry]
Type=Application
Name=Screen Locker
Exec=light-locker
Hidden=true
EOF
  xfconf_set xfce4-session /general/LockCommand string xflock4
  if command -v xfce4-screensaver >/dev/null 2>&1; then
    xfconf_set xfce4-screensaver /saver/enabled bool true
    xfconf_set xfce4-screensaver /saver/mode int 0
    xfconf_set xfce4-screensaver /lock/enabled bool true
    xfconf_set xfce4-screensaver /lock/saver-activation/enabled bool true
    xfconf_set xfce4-screensaver /lock/saver-activation/delay int 0
    pgrep -f '[x]fce4-screensaver' >/dev/null 2>&1 ||
      DISPLAY=${DISPLAY:-:0} xfce4-screensaver </dev/null >/dev/null 2>&1 &
  fi
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-enabled bool true
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-on-ac-sleep uint 10
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-on-ac-off uint 15
  xfconf_set xfce4-power-manager /xfce4-power-manager/lock-screen-suspend-hibernate bool true
  xfconf_set xfce4-power-manager /xfce4-power-manager/power-button-action uint 1
}

configure_xfce() {
  local distro_id menu_icon=tux menu_id icon_theme target_zsh
  xfconf_set xfce4-terminal /font-name string 'JetBrainsMono Nerd Font, JetBrainsMono Nerd Font Mono, FiraCode Nerd Font, Hack Nerd Font, MesloLGS Nerd Font, JetBrains Mono, DejaVu Sans Mono, Symbols Nerd Font, monospace 11'
  xfconf_set xfce4-terminal /font-use-system bool false
  xfconf_set xsettings /Gtk/MonospaceFontName string 'JetBrainsMono Nerd Font 11'
  xfconf_set xfce4-keyboard-shortcuts '/commands/custom/<Super>space' string xfce4-appfinder
  xfconf_set xfce4-keyboard-shortcuts '/commands/custom/<Super><Shift>s' string 'xfce4-screenshooter -rc'
  xfconf_set xfce4-appfinder /always-center bool true
  xfconf_set xfce4-appfinder /enable-service bool true
  distro_id=$(awk -F= '$1 == "ID" {gsub(/["\047]/, "", $2); print $2}' /etc/os-release)
  if [[ ${distro_id} == debian ]]; then menu_icon=emblem-debian-white
  elif [[ -f /usr/share/icons/Papirus/24x24/apps/distributor-logo-${distro_id}.svg ]]; then
    menu_icon=distributor-logo-${distro_id}
  fi
  while read -r menu_id; do
    xfconf_set xfce4-panel "${menu_id}/custom-menu" bool false
    xfconf_set xfce4-panel "${menu_id}/button-icon" string "${menu_icon}"
    xfconf_set xfce4-panel "${menu_id}/show-button-title" bool false
  done < <(xfconf-query -c xfce4-panel -lv | awk '$2 == "applicationsmenu" {print $1}')
  [[ ! -d /usr/share/themes/Arc-Dark && ! -d ${HOME}/.themes/Arc-Dark ]] || {
    xfconf_set xsettings /Net/ThemeName string Arc-Dark
    xfconf_set xfwm4 /general/theme string Arc-Dark
  }
  for icon_theme in Papirus-Dark Qogir-Dark Arc; do
    if [[ -d /usr/share/icons/${icon_theme} || -d ${HOME}/.icons/${icon_theme} ]]; then
      xfconf_set xsettings /Net/IconThemeName string "${icon_theme}"; break
    fi
  done
  xfconf_set xfce4-terminal /color-foreground string '#D7DAE0'
  xfconf_set xfce4-terminal /color-background string '#0D1117'
  xfconf_set xfce4-terminal /color-cursor string '#D7DAE0'
  xfconf_set xfce4-terminal /color-cursor-use-default bool false
  xfconf_set xfce4-terminal /color-use-theme bool false
  if target_zsh=$(command -v zsh 2>/dev/null) && [[ -x ${target_zsh} ]]; then
    xfconf_set xfce4-terminal /custom-command string "${target_zsh}"
    xfconf_set xfce4-terminal /run-custom-command bool true
    xfconf_set xfce4-terminal /command-login-shell bool true
  fi
  python3 "${JSH_ROOT}/scripts/customize.py" wallpaper
  configure_panel
  configure_screensaver
}

configure_gnome() {
  [[ $(gsettings get org.gnome.desktop.interface color-scheme) == "'prefer-dark'" ]] ||
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  if [[ $(gsettings writable org.gnome.desktop.interface gtk-theme 2>/dev/null) == true &&
    ( -d /usr/share/themes/Arc-Dark || -d ${HOME}/.themes/Arc-Dark ) ]]; then
    [[ $(gsettings get org.gnome.desktop.interface gtk-theme) == "'Arc-Dark'" ]] ||
      gsettings set org.gnome.desktop.interface gtk-theme Arc-Dark
  fi
}

desktop=${JSH_DESKTOP:-}
case ${desktop} in
  xfce) command -v xfconf-query >/dev/null 2>&1 || exit 0 ;;
  gnome) command -v gsettings >/dev/null 2>&1 || exit 0 ;;
  *) jsh::log_note '  › skipped desktop: GNOME or XFCE is not active'; exit 0 ;;
esac
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::log_note "  › would configure ${desktop^^} appearance, panel, identity, and screensaver"
  exit 0
fi
"configure_${desktop}"
avatar=${JSH_USER_AVATAR:-${JSH_ROOT}/assets/icons/j.jpg}
[[ ! -r ${avatar} ]] || write_if_changed "${HOME}/.face" 0644 <"${avatar}"
jsh::log_item "${desktop^^} desktop"
