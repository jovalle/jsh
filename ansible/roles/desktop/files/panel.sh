#!/usr/bin/env bash
# Reconcile XFCE panel plugins and their managed settings.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT:?}/scripts/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${JSH_ROOT:?}/scripts/lib/desktop.sh"
[[ ${JSH_DESKTOP} == xfce ]] || jsh::skip "XFCE panel: not an XFCE session"
panel_quiet=0

xfconf_set() {
  local channel=$1 property=$2 type=$3 value=$4 before
  ((panel_quiet)) || jsh::status "${channel}${property}"
  if before=$(xfconf-query -c "${channel}" -p "${property}" 2>/dev/null); then
    if [[ ${before} == "${value}" ]]; then
      ((panel_quiet)) || jsh::ok "${channel}${property} is ${value}"
      return 0
    fi
    jsh::run xfconf-query -c "${channel}" -p "${property}" -s "${value}" >/dev/null
  else
    before='(unset)'
    jsh::run xfconf-query -c "${channel}" -p "${property}" -n -t "${type}" -s "${value}" >/dev/null
  fi
  before=${before//$'\n'/, }
  if ((!panel_quiet)); then
    jsh::changed "${channel}${property} set ${value}" \
      "${channel}${property} is not ${value}"
  fi
}

write_if_changed() {
  local target=$1 mode=$2 temporary
  ((panel_quiet)) || jsh::status "${target}"
  temporary=$(jsh::temp)/managed
  command cat >"${temporary}"
  if cmp -s "${temporary}" "${target}"; then
    rm -f -- "${temporary}"
    ((panel_quiet)) || jsh::ok "${target/#${HOME}/\~} is current"
    return
  fi
  jsh::run mkdir -p -- "${target%/*}"
  jsh::run install -m "${mode}" "${temporary}" "${target}"
  rm -f -- "${temporary}"
  if ((!panel_quiet)); then
    jsh::changed "${target/#${HOME}/\~} written" \
      "${target/#${HOME}/\~} differs"
  fi
}

# Plugins rewrite their rc files on exit, so compare only the keys jsh manages.
write_rc() {
  local target=$1 mode=$2 line key current=1
  local -a wanted=()
  local -A keys=()
  while IFS= read -r line; do
    wanted+=("${line}")
    keys[${line%%=*}]=1
    grep -Fqx -- "${line}" "${target}" 2>/dev/null || current=0
  done
  if ((current)); then
    ((panel_quiet)) || jsh::ok "${target/#${HOME}/\~} settings are current"
    return 0
  fi
  write_if_changed "${target}" "${mode}" < <(
    printf '%s\n' "${wanted[@]}"
    [[ ! -f ${target} ]] || while IFS= read -r line; do
      key=${line%%=*}
      [[ -z ${key} || -n ${keys[${key}]:-} ]] || printf '%s\n' "${line}"
    done <"${target}"
  )
}

managed_plugin() {
  local type=$1 role=${2:-$1} id managed plugin_type plugin_role max_id
  while IFS= read -r id; do
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2>/dev/null || true)
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-managed" 2>/dev/null || true)
    plugin_role=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/jsh-role" 2>/dev/null || true)
    if [[ ${plugin_type} == "${type}" && ${managed} == true &&
      (${plugin_role} == "${role}" || (-z ${plugin_role} && ${role} == "${type}")) ]]; then
      xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-role" string "${role}"
      managed_id=${id}
      return
    fi
  done < <(xfconf-query -c xfce4-panel -lv 2>/dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\)[[:space:]].*|\1|p' | sort -nu)
  max_id=$(xfconf-query -c xfce4-panel -lv 2>/dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
  id=$((${max_id:-0} + 1))
  jsh::run xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" -n -t string -s "${type}" >/dev/null
  ((panel_quiet)) || jsh::added "panel plugin ${id} is ${type}" \
    "panel plugin ${id} is missing"
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-managed" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${id}/jsh-role" string "${role}"
  managed_id=${id}
}

apply_panel() {
  ((panel_quiet)) || jsh::status "panel layout"
  local panel_id cpu_id load_id net_id fs_id audio_id cafe_id mic_id='' id plugin_id plugin_type
  local systray_id='' clock_id='' actions_id=''
  local audio_type=pulseaudio
  local -a plugin_ids=() existing_ids=() base_ids=() arguments=()
  panel_id=$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+$' | head -n 1)
  [[ ${panel_id} =~ ^[0-9]+$ ]] || {
    ((panel_quiet)) || jsh::info "XFCE panel is unavailable"
    return
  }
  managed_plugin cpugraph
  cpu_id=${managed_id}
  managed_plugin systemload
  load_id=${managed_id}
  managed_plugin fsguard
  fs_id=${managed_id}
  managed_plugin genmon net
  net_id=${managed_id}
  if [[ ${JSH_HOST:-} == colossus && -f /usr/share/xfce4/panel/plugins/jsh-pulseaudio.desktop ]] &&
    compgen -G '/usr/lib/*/xfce4/panel/plugins/libjsh-pulseaudio.so' >/dev/null; then
    audio_type=jsh-pulseaudio
  fi
  managed_plugin "${audio_type}" pulseaudio
  audio_id=${managed_id}
  managed_plugin genmon cafe
  cafe_id=${managed_id}
  if [[ ${JSH_HOST:-} == colossus && ${audio_type} == pulseaudio ]]; then
    managed_plugin genmon microphone
    mic_id=${managed_id}
  fi
  while IFS= read -r id; do [[ ${id} =~ ^[0-9]+$ ]] && existing_ids+=("${id}"); done < <(
    xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2>/dev/null
  )
  for plugin_id in "${existing_ids[@]}"; do
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" 2>/dev/null || true)
    case ${plugin_type} in
      docklike | netload | cpugraph | systemload | fsguard | genmon | pulseaudio | jsh-pulseaudio) ;;
      systray) systray_id=${plugin_id} ;;
      clock) clock_id=${plugin_id} ;;
      actions) actions_id=${plugin_id} ;;
      *) base_ids+=("${plugin_id}") ;;
    esac
  done
  if [[ -z ${clock_id} ]]; then
    managed_plugin clock
    clock_id=${managed_id}
  fi
  plugin_ids=("${base_ids[@]}" "${cpu_id}" "${load_id}" "${fs_id}" "${net_id}")
  [[ -z ${systray_id} ]] || plugin_ids+=("${systray_id}")
  plugin_ids+=("${cafe_id}")
  plugin_ids+=("${audio_id}")
  [[ -z ${mic_id} ]] || plugin_ids+=("${mic_id}")
  [[ -z ${clock_id} ]] || plugin_ids+=("${clock_id}")
  [[ -z ${actions_id} ]] || plugin_ids+=("${actions_id}")
  for id in "${plugin_ids[@]}"; do arguments+=(-t int -s "${id}"); done
  if [[ ${plugin_ids[*]} != "${existing_ids[*]}" ]]; then
    jsh::run xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${arguments[@]}" >/dev/null
  fi

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
  write_rc "${HOME}/.config/xfce4/panel/fsguard-${fs_id}.rc" 0644 <<'EOF'
yellow=8
red=2
lab_size_visible=false
progress_bar_visible=true
hide_button=true
label=disk
label_visible=true
mnt=/
EOF
  write_if_changed "${HOME}/.config/xfce4/panel/net-led.sh" 0755 <"${SCRIPT_DIR}/net.sh"
  write_rc "${HOME}/.config/xfce4/panel/genmon-${net_id}.rc" 0644 <<EOF
Command=${HOME}/.config/xfce4/panel/net-led.sh
UseLabel=0
Text=
UpdatePeriod=100
EOF
  if [[ -e ${HOME}/.config/xfce4/panel/cafe-status.sh || -e ${HOME}/.config/xfce4/panel/cafe-toggle.sh ]]; then
    jsh::run rm -f "${HOME}/.config/xfce4/panel/cafe-status.sh" "${HOME}/.config/xfce4/panel/cafe-toggle.sh"
    fi
  write_rc "${HOME}/.config/xfce4/panel/genmon-${cafe_id}.rc" 0644 <<EOF
Command=${JSH_ROOT}/bin/cafe --xfce-status
UseLabel=0
Text=
UpdatePeriod=500
Action=${JSH_ROOT}/bin/cafe --xfce-toggle
EOF
  if [[ -n ${mic_id} ]]; then
    write_rc "${HOME}/.config/xfce4/panel/genmon-${mic_id}.rc" 0644 <<EOF
Command=${JSH_ROOT}/bin/microphone --panel
UseLabel=0
Text=
UpdatePeriod=250
EOF
    # XFCE colors this icon for recording activity, independently of microphone mute.
    local gtk_css=${HOME}/.config/gtk-3.0/gtk.css
    if [[ ! -f ${gtk_css} ]] || ! grep -Fqx '/* jsh: hide recording indicator */' "${gtk_css}"; then
      write_if_changed "${gtk_css}" 0644 < <(
        [[ ! -f ${gtk_css} ]] || cat "${gtk_css}"
        printf '\n%s\n%s\n' '/* jsh: hide recording indicator */' \
          '.recording-indicator { opacity: 0; }'
      )
    fi
    if ! grep -Fqx '/* jsh: white speaker icon */' "${gtk_css}"; then
      write_if_changed "${gtk_css}" 0644 < <(
        cat "${gtk_css}"
        printf '\n%s\n%s\n' '/* jsh: white speaker icon */' \
          '#pulseaudio-button > box > image:not(.recording-indicator) { color: #ffffff; }'
      )
    fi
  fi
  if [[ ${audio_type} == jsh-pulseaudio ]]; then
    local gtk_css=${HOME}/.config/gtk-3.0/gtk.css
    if [[ -f ${gtk_css} ]] &&
      grep -Fqx '#pulseaudio-button image:not(.recording-indicator) { color: #ffffff; }' "${gtk_css}"; then
      write_if_changed "${gtk_css}" 0644 < <(
        sed 's/^#pulseaudio-button image:not(.recording-indicator) { color: #ffffff; }$/#pulseaudio-button > box > image:not(.recording-indicator) { color: #ffffff; }/' "${gtk_css}"
      )
    fi
    if [[ -f ${gtk_css} ]] && grep -Fqx '/* jsh: hide recording indicator */' "${gtk_css}"; then
      write_if_changed "${gtk_css}" 0644 < <(
        awk '
          $0 == "/* jsh: hide recording indicator */" { managed=1; next }
          managed && $0 == ".recording-indicator { opacity: 0; }" { managed=0; next }
          { managed=0; print }
        ' "${gtk_css}"
      )
    fi
  fi
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-keyboard-shortcuts" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-mpris" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/enable-multimedia-keys" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${audio_id}/mixer-command" string pavucontrol
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/jsh-managed" bool true
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/mode" int 2
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/digital-layout" int 3
  xfconf_set xfce4-panel "/plugins/plugin-${clock_id}/digital-time-format" string '%Y-%m-%d %H:%M:%S'
}

restart_panel() {
  pgrep -x xfce4-panel >/dev/null 2>&1 || return 0
  if DISPLAY=${DISPLAY:-:0} timeout 5 xfce4-panel --quit >/dev/null 2>&1; then
    trap jsh::cleanup EXIT
    for _ in {1..50}; do
      pgrep -x xfce4-panel >/dev/null 2>&1 || break
      sleep 0.1
    done
    panel_quiet=1
    apply_panel
    panel_quiet=0
    jsh::detach env DISPLAY="${DISPLAY:-:0}" xfce4-panel
    trap - EXIT
    for _ in {1..50}; do
      pgrep -x xfce4-panel >/dev/null 2>&1 && break
      sleep 0.1
    done
    if pgrep -x xfce4-panel >/dev/null 2>&1; then
      jsh::changed "XFCE panel restarted" "XFCE panel needs a restart"
    else
      jsh::info "XFCE panel was not restarted"
    fi
  elif DISPLAY=${DISPLAY:-:0} timeout 5 xfce4-panel -r >/dev/null 2>&1; then
    jsh::changed "XFCE panel restarted" "XFCE panel needs a restart"
  else
    jsh::info "XFCE panel was not restarted"
  fi
}

case ${1:-apply} in
  apply) apply_panel ;;
  restart) restart_panel ;;
  *) jsh::fail "Usage: $0 [apply|restart]"; exit 2 ;;
esac
