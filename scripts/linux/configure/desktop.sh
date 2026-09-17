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
    [[ $(xfconf-query -c "${channel}" -p "${property}") == "${value}" ]] ||
      xfconf-query -c "${channel}" -p "${property}" -s "${value}" > /dev/null
  else
    xfconf-query -c "${channel}" -p "${property}" -n -t "${type}" -s "${value}" > /dev/null
  fi
}

configure_wallpaper() {
  "${SCRIPT_DIR}/wallpaper.sh"
}

managed_plugin() {
  local type=$1
  local role="${2:-$1}"
  local id managed plugin_type plugin_role max_id
  while IFS= read -r id; do
    [[ "${id}" =~ ^[0-9]+$ ]] || continue
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2> /dev/null || true)
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-managed" 2> /dev/null || true)
    plugin_role=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-role" 2> /dev/null || true)
    if [[ "${plugin_type}" == "${type}" && "${managed}" == true ]]; then
      if [[ "${plugin_role}" == "${role}" || ( -z "${plugin_role}" && "${role}" == "${type}" ) ]]; then
        xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-role" string "${role}"
        printf '%s\n' "${id}"
        return
      fi
    fi
  done < <(xfconf-query -c xfce4-panel -lv 2> /dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\)[[:space:]].*|\1|p' | sort -nu)

  max_id=$(xfconf-query -c xfce4-panel -lv 2> /dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
  id=$((${max_id:-0} + 1))
  xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" -n -t string -s "${type}" > /dev/null
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-managed" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-role" string "${role}"
  printf '%s\n' "${id}"
}

configure_panel() {
  local panel_id cpu_id load_id net_id fs_id audio_id cafe_id id plugin_id ptype
  local -a plugin_ids=() arguments=()
  panel_id=$(xfconf-query -c xfce4-panel -p /panels 2> /dev/null | grep -E '^[0-9]+$' | head -n 1)
  [[ "${panel_id}" =~ ^[0-9]+$ ]] || {
    jsh_note "Skipping panel monitors: no XFCE panel is available."
    return
  }

  cpu_id=$(managed_plugin cpugraph)
  load_id=$(managed_plugin systemload)
  fs_id=$(managed_plugin fsguard)
  net_id=$(managed_plugin genmon net)
  audio_id=$(managed_plugin pulseaudio)
  cafe_id=$(managed_plugin genmon cafe)

  while IFS= read -r id; do
    [[ "${id}" =~ ^[0-9]+$ ]] && plugin_ids+=("${id}")
  done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2> /dev/null)

  local systray_id='' clock_id='' actions_id=''
  local -a base_ids=()
  for plugin_id in "${plugin_ids[@]}"; do
    ptype=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" 2> /dev/null || true)
    case "${ptype}" in
      docklike | netload)
        continue
        ;;
      systray) systray_id="${plugin_id}" ;;
      clock) clock_id="${plugin_id}" ;;
      actions) actions_id="${plugin_id}" ;;
      cpugraph | systemload | fsguard | genmon | pulseaudio)
        continue
        ;;
      *)
        base_ids+=("${plugin_id}")
        ;;
    esac
  done

  if [[ -z "${clock_id}" ]]; then
    clock_id=$(managed_plugin clock)
  fi

  # Desired layout on panel 1:
  # Base left items -> cpu -> load (cpu/mem/swap) -> disk -> net (genmon) -> systray (network status) -> cafe -> audio -> clock -> actions
  plugin_ids=("${base_ids[@]}" "${cpu_id}" "${load_id}" "${fs_id}" "${net_id}")
  [[ -n "${systray_id}" ]] && plugin_ids+=("${systray_id}")
  plugin_ids+=("${cafe_id}" "${audio_id}")
  [[ -n "${clock_id}" ]] && plugin_ids+=("${clock_id}")
  [[ -n "${actions_id}" ]] && plugin_ids+=("${actions_id}")

  for id in "${plugin_ids[@]}"; do
    arguments+=(-t int -s "${id}")
  done
  xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${arguments[@]}" > /dev/null

  # CPU monitor (graph)
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/mode" int 0
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/per-core" int 1
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/size" int 64
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/update-interval" int 2
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/command" string xfce4-taskmanager
  xfconf_set xfce4-panel "/plugins/plugin-${cpu_id}/in-terminal" int 0

  # CPU, memory & swap monitor (bars)
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/timeout-seconds" uint 1
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/cpu/enabled" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/memory/enabled" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/swap/enabled" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/network/enabled" bool false
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/uptime/enabled" bool false
  xfconf_set xfce4-panel "/plugins/plugin-${load_id}/command" string xfce4-taskmanager

  # Storage / Filesystem monitor
  xfconf_set xfce4-panel "/plugins/plugin-${fs_id}/mountpoint" string /
  mkdir -p "${HOME}/.config/xfce4/panel"
  cat > "${HOME}/.config/xfce4/panel/fsguard-${fs_id}.rc" << EOF
yellow=8
red=2
lab_size_visible=false
progress_bar_visible=true
hide_button=true
label=disk
label_visible=true
mnt=/
EOF

  # Network LED monitor
  cat > "${HOME}/.config/xfce4/panel/net-led.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="/dev/shm/jsh-net"
mkdir -p "${state_dir}"

iface=""
if [[ -r "${state_dir}/iface" ]]; then
  read -r iface < "${state_dir}/iface" 2>/dev/null || true
fi

if [[ -z "${iface}" || ! -d "/sys/class/net/${iface}" ]]; then
  iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
  [[ -n "${iface}" ]] || iface=$(ls /sys/class/net 2>/dev/null | grep -v -E '^(lo|docker|veth|br-)' | head -n 1)
  printf '%s\n' "${iface}" > "${state_dir}/iface"
fi

carrier=0
if [[ -n "${iface}" && -r "/sys/class/net/${iface}/carrier" ]]; then
  read -r carrier < "/sys/class/net/${iface}/carrier" 2>/dev/null || carrier=0
elif [[ -n "${iface}" && -r "/sys/class/net/${iface}/operstate" ]]; then
  read -r operstate < "/sys/class/net/${iface}/operstate" 2>/dev/null || operstate="down"
  [[ "${operstate}" == "up" ]] && carrier=1
fi

# Tick counter for slow blinking (100ms * 10 ticks = 1s period)
tick=0
if [[ -r "${state_dir}/tick" ]]; then
  read -r tick < "${state_dir}/tick" 2>/dev/null || tick=0
fi
tick=$(( (tick + 1) % 10 ))
printf '%d\n' "${tick}" > "${state_dir}/tick"

# Async internet reachability check (every 3 seconds)
now=$(date +%s)
last_check=0
if [[ -r "${state_dir}/last_ping" ]]; then
  read -r last_check < "${state_dir}/last_ping" 2>/dev/null || last_check=0
fi

if (( now - last_check >= 3 )); then
  printf '%d\n' "${now}" > "${state_dir}/last_ping"
  (
    if ping -c 1 -W 1 -n 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 -n 8.8.8.8 >/dev/null 2>&1; then
      printf '1\n' > "${state_dir}/online.tmp"
    else
      printf '0\n' > "${state_dir}/online.tmp"
    fi
    mv -f "${state_dir}/online.tmp" "${state_dir}/online"
  ) >/dev/null 2>&1 &
fi

online=1
if [[ -r "${state_dir}/online" ]]; then
  read -r online < "${state_dir}/online" 2>/dev/null || online=1
fi

rx=0; tx=0; rx_packets=0; tx_packets=0
if [[ -n "${iface}" && -r "/sys/class/net/${iface}/statistics/rx_bytes" ]]; then
  read -r rx < "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || rx=0
  read -r tx < "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || tx=0
  read -r rx_packets < "/sys/class/net/${iface}/statistics/rx_packets" 2>/dev/null || rx_packets=0
  read -r tx_packets < "/sys/class/net/${iface}/statistics/tx_packets" 2>/dev/null || tx_packets=0
fi

prev_rx=0; prev_tx=0; prev_rx_packets=0; prev_tx_packets=0
state_file="${state_dir}/stats"
if [[ -r "${state_file}" ]]; then
  read -r prev_rx prev_tx prev_rx_packets prev_tx_packets < "${state_file}" 2>/dev/null || true
fi
printf '%s %s %s %s\n' "${rx}" "${tx}" "${rx_packets}" "${tx_packets}" > "${state_file}"

rx_delta=$(( rx >= prev_rx ? rx - prev_rx : 0 ))
tx_delta=$(( tx >= prev_tx ? tx - prev_tx : 0 ))
total_delta=$(( rx_delta + tx_delta ))
rx_activity=$(( rx_packets >= prev_rx_packets ? rx_packets - prev_rx_packets : 0 ))
tx_activity=$(( tx_packets >= prev_tx_packets ? tx_packets - prev_tx_packets : 0 ))

# UpdatePeriod is 100ms (0.1s), rate = delta * 10
rate=$(( total_delta * 10 ))
if (( rate >= 1048576 )); then
  rate_str=$(printf '%d.%d MB/s' $(( rate / 1048576 )) $(( (rate % 1048576) * 10 / 1048576 )))
elif (( rate >= 1024 )); then
  rate_str=$(printf '%d.%d KB/s' $(( rate / 1024 )) $(( (rate % 1024) * 10 / 1024 )))
else
  rate_str="${rate} B/s"
fi

if [[ "${carrier}" != "1" ]]; then
  # Solid gray if not connected
  led="<span color='#888888'>●</span>"
  status_str="Disconnected (no link)"
elif [[ "${online}" == "0" ]]; then
  # Slow-blinking yellow if connected but no internet access (ticks 0..4 on, 5..9 off)
  if (( tick < 5 )); then
    led="<span color='#FFCC00' font_weight='bold'>●</span>"
  else
    led="<span color='#554400'>●</span>"
  fi
  status_str="No Internet Access"
elif (( rx_activity > 0 || tx_activity > 0 )); then
  # Connected with internet - RX/TX packet activity
  led="<span color='#00FF66' font_weight='bold'>●</span>"
  status_str="Online (${rate_str})"
else
  # Connected with internet - idle
  led="<span color='#1A5226'>●</span>"
  status_str="Online (${rate_str})"
fi

printf '<txt>net %s&#160;</txt><tool>%s: %s (Rx: %d B, Tx: %d B)</tool><txtclick>xfce4-taskmanager</txtclick><click>xfce4-taskmanager</click>\n' \
  "${led}" "${iface:-none}" "${status_str}" "${rx_delta}" "${tx_delta}"
EOF
  chmod +x "${HOME}/.config/xfce4/panel/net-led.sh"

  cat > "${HOME}/.config/xfce4/panel/genmon-${net_id}.rc" << EOF
Command=${HOME}/.config/xfce4/panel/net-led.sh
UseLabel=false
Text=
UpdatePeriod=100
EOF

  # Cafe sleep / screensaver inhibition toggle
  rm -f "${HOME}/.config/xfce4/panel/cafe-status.sh" \
    "${HOME}/.config/xfce4/panel/cafe-toggle.sh"

  cat > "${HOME}/.config/xfce4/panel/genmon-${cafe_id}.rc" << EOF
Command=${JSH_ROOT}/bin/cafe --xfce-status
UseLabel=false
Text=
UpdatePeriod=500
Action=${JSH_ROOT}/bin/cafe --xfce-toggle
EOF

  # Audio output and input controls
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-keyboard-shortcuts" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-mpris" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-multimedia-keys" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/mixer-command" string pavucontrol

  # Clock / Date monitor
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/jsh-managed" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/mode" int 2
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/digital-layout" int 3
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/digital-time-format" string '%Y-%m-%d %H:%M:%S'

  pkill -f "wrapper-2.0.*libfsguard.so" 2> /dev/null || true
  pkill -f "wrapper-2.0.*libgenmon.so" 2> /dev/null || true
  if pgrep -x xfce4-panel > /dev/null 2>&1; then
    DISPLAY="${DISPLAY:-:0}" timeout 5 xfce4-panel -r > /dev/null 2>&1 || true
    sleep 1
    if ! pgrep -x xfce4-panel > /dev/null 2>&1; then
      DISPLAY="${DISPLAY:-:0}" nohup xfce4-panel > /dev/null 2>&1 &
    fi
  fi
}

configure_identity() {
  local avatar="${JSH_USER_AVATAR:-${JSH_ROOT}/.github/assets/j.jpg}"

  [[ ! -r "${avatar}" ]] || install -m 0644 "${avatar}" "${HOME}/.face"
}

configure_xfce_screensaver() {
  local autostart="${HOME}/.config/autostart/light-locker.desktop"
  local temporary

  # Disable light-locker which causes black screen and unresponsive wake on Debian
  pkill -x light-locker 2> /dev/null || true
  mkdir -p "$(dirname -- "${autostart}")"
  temporary=$(mktemp "${autostart}.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Screen Locker' \
    'Exec=light-locker' 'Hidden=true' > "${temporary}"
  install -m 0644 "${temporary}" "${autostart}"
  rm -f "${temporary}"

  # Configure xfce4-session lock command
  xfconf_set xfce4-session /general/LockCommand string xflock4

  # Configure xfce4-screensaver
  if command -v xfce4-screensaver > /dev/null 2>&1; then
    xfconf_set xfce4-screensaver /saver/enabled bool true
    xfconf_set xfce4-screensaver /saver/mode int 0
    xfconf_set xfce4-screensaver /lock/enabled bool true
    xfconf_set xfce4-screensaver /lock/saver-activation/enabled bool true
    xfconf_set xfce4-screensaver /lock/saver-activation/delay int 0
    if ! pgrep -f '[x]fce4-screensaver' > /dev/null 2>&1; then
      DISPLAY="${DISPLAY:-:0}" xfce4-screensaver < /dev/null > /dev/null 2>&1 &
    fi
  fi

  # Configure xfce4-power-manager for responsive DPMS and sleep handling
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-enabled bool true
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-on-ac-sleep uint 10
  xfconf_set xfce4-power-manager /xfce4-power-manager/dpms-on-ac-off uint 15
  xfconf_set xfce4-power-manager /xfce4-power-manager/lock-screen-suspend-hibernate bool true
  xfconf_set xfce4-power-manager /xfce4-power-manager/power-button-action uint 1
}

configure_xfce() {
  xfconf_set xfce4-terminal /font-name string 'JetBrainsMono Nerd Font Mono 11'
  xfconf_set xfce4-terminal /font-use-system bool false
  xfconf_set xsettings /Gtk/MonospaceFontName string 'JetBrainsMono Nerd Font Mono 11'
  xfconf_set xfce4-keyboard-shortcuts '/commands/custom/<Super>space' string xfce4-appfinder
  xfconf_set xfce4-keyboard-shortcuts '/commands/custom/<Super><Shift>s' string 'xfce4-screenshooter -rc'
  xfconf_set xfce4-appfinder /always-center bool true
  xfconf_set xfce4-appfinder /enable-service bool true
  local distro_id=linux menu_icon=tux menu_id
  distro_id=$(awk -F= '$1 == "ID" {gsub(/["\047]/, "", $2); print $2}' "${JSH_OS_RELEASE:-/etc/os-release}")
  if [[ ${distro_id} == debian ]]; then
    menu_icon=emblem-debian-white
  elif [[ -f /usr/share/icons/Papirus/24x24/apps/distributor-logo-${distro_id}.svg ]]; then
    menu_icon=distributor-logo-${distro_id}
  fi
  while read -r menu_id; do
    xfconf_set xfce4-panel "${menu_id}/custom-menu" bool false
    xfconf_set xfce4-panel "${menu_id}/button-icon" string "${menu_icon}"
    xfconf_set xfce4-panel "${menu_id}/show-button-title" bool false
  done < <(xfconf-query -c xfce4-panel -lv | awk '$2 == "applicationsmenu" {print $1}')
  if [[ -d /usr/share/themes/Arc-Dark || -d "${HOME}/.themes/Arc-Dark" ]]; then
    xfconf_set xsettings /Net/ThemeName string Arc-Dark
    xfconf_set xfwm4 /general/theme string Arc-Dark
  fi
  local icon_theme
  for icon_theme in Papirus-Dark Qogir-Dark Arc; do
    if [[ -d "/usr/share/icons/${icon_theme}" || -d "${HOME}/.icons/${icon_theme}" ]]; then
      xfconf_set xsettings /Net/IconThemeName string "${icon_theme}"
      break
    fi
  done
  xfconf_set xfce4-terminal /color-foreground string '#D7DAE0'
  xfconf_set xfce4-terminal /color-background string '#0D1117'
  xfconf_set xfce4-terminal /color-cursor string '#D7DAE0'
  xfconf_set xfce4-terminal /color-cursor-use-default bool false
  xfconf_set xfce4-terminal /color-use-theme bool false
  local target_zsh
  if target_zsh=$(command -v zsh 2> /dev/null) && [[ -x "${target_zsh}" ]]; then
    xfconf_set xfce4-terminal /custom-command string "${target_zsh}"
    xfconf_set xfce4-terminal /run-custom-command bool true
    xfconf_set xfce4-terminal /command-login-shell bool true
  fi
  configure_wallpaper
  configure_panel
  configure_xfce_screensaver
}

configure_gnome() {
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  if [[ "$(gsettings writable org.gnome.desktop.interface gtk-theme 2> /dev/null)" == true ]] &&
    [[ -d /usr/share/themes/Arc-Dark || -d "${HOME}/.themes/Arc-Dark" ]]; then
    gsettings set org.gnome.desktop.interface gtk-theme Arc-Dark
  fi
}

main() {
  local desktop arg answer
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) JSH_ASSUME_YES=1 ;;
    esac
  done

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
  if [[ ${JSH_ASSUME_YES:-0} != 1 ]]; then
    jsh_prompt "Configure the ${desktop^^} desktop? [y/N]: "
    read -r answer || answer=
    [[ "${answer}" =~ ^[Yy]$ ]] || {
      jsh_note "Skipping desktop configuration."
      return
    }
  fi

  "configure_${desktop}"
  configure_identity
  jsh_success "${desktop^^} desktop configured."
}

main "$@"
