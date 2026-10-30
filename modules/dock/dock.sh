#!/usr/bin/env bash
# Configure the Linux application dock and managed pins.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

find_desktop_file() {
  local candidate directory
  for candidate in "$@"; do
    for directory in \
      "${HOME}/.local/share/applications" \
      /usr/share/applications \
      /usr/local/share/applications \
      /var/lib/flatpak/exports/share/applications \
      "${HOME}/.local/share/flatpak/exports/share/applications"; do
      if [[ -f ${directory}/${candidate} ]]; then
        printf '%s\n' "${directory}/${candidate}"
        return
      fi
    done
  done
  return 1
}

dock_pins() {
  local pins='' desktop_file
  desktop_file=$(find_desktop_file com.mitchellh.ghostty.desktop xfce4-terminal.desktop \
    xfce4-terminal-emulator.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file waterfox.desktop net.waterfox.waterfox.desktop) &&
    pins+="${desktop_file};"
  desktop_file=$(find_desktop_file helium.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file code.desktop visual-studio-code.desktop \
    com.visualstudio.code.desktop code-oss.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file com.spotify.Client.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file com.todoist.Todoist.desktop) && pins+="${desktop_file};"
  printf '%s\n' "${pins}"
}

managed_dock_target() {
  local panel_dir=$1 candidate filename plugin_id managed plugin_type
  while IFS= read -r candidate; do
    filename=${candidate##*/}
    plugin_id=${filename#docklike-}
    plugin_id=${plugin_id%.rc}
    [[ ${plugin_id} =~ ^[0-9]+$ ]] || continue
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}/jsh-managed" \
      2>/dev/null || true)
    [[ ${managed} == true ]] || continue
    printf '%s\n' "${candidate}"
    return
  done < <(find "${panel_dir}" -maxdepth 1 -name 'docklike-*.rc' -print 2>/dev/null | sort)
  while IFS= read -r plugin_id; do
    [[ ${plugin_id} =~ ^[0-9]+$ ]] || continue
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" \
      2>/dev/null || true)
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}/jsh-managed" \
      2>/dev/null || true)
    if [[ ${plugin_type} == docklike && ${managed} == true ]]; then
      printf '%s/docklike-%s.rc\n' "${panel_dir}" "${plugin_id}"
      return
    fi
  done < <(xfconf-query -c xfce4-panel -lv 2>/dev/null |
    sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -nu)
  return 1
}

find_xfce_dock_panel() {
  local id position size
  while IFS= read -r id; do
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    position=$(xfconf-query -c xfce4-panel -p "/panels/panel-${id}/position" 2>/dev/null || true)
    size=$(xfconf-query -c xfce4-panel -p "/panels/panel-${id}/size" 2>/dev/null || true)
    if [[ ${position} =~ p=(8|9|10|11|12) ]] || ((${size:-0} >= 36)); then
      printf '%s\n' "${id}"
      return
    fi
  done < <(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+$' | sort -nr)
  xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+$' | tail -n 1
}

write_pins() {
  local target=$1 pins=$2 temporary old_pins
  old_pins=$(sed -n '/^\[user\]$/,/^\[/{s/^pinned=//p;}' "${target}" 2>/dev/null || true)
  temporary=$(mktemp "${target}.XXXXXX")
  awk -v pins="${pins}" '
    BEGIN { section=0; found=0 }
    /^\[user\]$/ { section=1; print; next }
    /^\[/ { if (section && !found) { print "pinned=" pins; found=1 } section=0 }
    section && /^pinned=/ { if (!found) print "pinned=" pins; found=1; next }
    { print }
    END { if (!found) { if (!section) print "\n[user]"; print "pinned=" pins } }
  ' "${target}" 2>/dev/null >"${temporary}" || printf '[user]\npinned=%s\n' "${pins}" >"${temporary}"
  if cmp -s "${temporary}" "${target}"; then
    rm -f -- "${temporary}"
    return
  fi
  install -m 0644 "${temporary}" "${target}"
  rm -f -- "${temporary}"
  dock_file_changed=1
  if [[ ${old_pins} != "${pins}" ]]; then
    old_pins=$(printf '%s' "${old_pins}" | tr ';' '\n' | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')
    local new_pins
    new_pins=$(printf '%s' "${pins}" | tr ';' '\n' | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')
    dock_details+=("pins: ${old_pins:-(empty)} → ${new_pins:-(empty)}")
  fi
}

configure_gnome_dock() {
  local pins=$1 file desktop_id current existing serialized separator=''
  local -a favorites=()
  current=$(gsettings get org.gnome.shell favorite-apps) || {
    jsh::log_error 'Unable to read existing GNOME favorites.'
    return 1
  }
  while IFS= read -r existing; do [[ -z ${existing} ]] || favorites+=("${existing}"); done < <(
    grep -o "'[^']*'" <<<"${current}" | tr -d "'"
  )
  while IFS= read -r file; do
    [[ -n ${file} ]] || continue
    desktop_id=${file##*/}
    [[ " ${favorites[*]} " == *" ${desktop_id} "* ]] || favorites+=("${desktop_id}")
  done < <(tr ';' '\n' <<<"${pins}")
  serialized='['
  for desktop_id in "${favorites[@]}"; do
    serialized+="${separator}'${desktop_id}'"
    separator=', '
  done
  serialized+=']'
  [[ ${current} == "${serialized}" ]] || {
    gsettings set org.gnome.shell favorite-apps "${serialized}"
    dock_changed=1
  }
}

configure_xfce_dock() {
  local pins=$1 panel_dir target plugin_id panel_id id filename plugin_type panel_before panel_after
  local other_id other_type dock_present=0
  local -a plugin_ids=() existing_ids=() arguments=() other_plugins=() other_args=() existing_other=()
  dock_file_changed=0
  panel_before=$(xfconf-query -c xfce4-panel -lv 2>/dev/null || true)
  panel_dir=${HOME}/.config/xfce4/panel
  mkdir -p "${panel_dir}"
  panel_id=$(find_xfce_dock_panel)
  [[ ${panel_id} =~ ^[0-9]+$ ]] || {
    jsh::log_error 'No XFCE dock panel is available.'
    return 1
  }
  target=$(managed_dock_target "${panel_dir}" || true)
  if [[ -z ${target} ]]; then
    plugin_id=$(xfconf-query -c xfce4-panel -lv 2>/dev/null |
      sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
    plugin_id=$((${plugin_id:-0} + 1))
    target=${panel_dir}/docklike-${plugin_id}.rc
    xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" -n -t string -s docklike >/dev/null
    xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}/jsh-managed" \
      -n -t bool -s true >/dev/null
  else
    filename=${target##*/}
    plugin_id=${filename#docklike-}
    plugin_id=${plugin_id%.rc}
  fi
  while IFS= read -r id; do
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    existing_ids+=("${id}")
    plugin_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2>/dev/null || true)
    if [[ ${id} == "${plugin_id}" ]]; then
      dock_present=1
      plugin_ids+=("${id}")
    elif [[ ${plugin_type} == launcher ]]; then
      if ((dock_present == 0)); then
        plugin_ids+=("${plugin_id}")
        dock_present=1
      fi
    else
      plugin_ids+=("${id}")
    fi
  done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2>/dev/null)
  ((dock_present)) || plugin_ids+=("${plugin_id}")
  for id in "${plugin_ids[@]}"; do arguments+=(-t int -s "${id}"); done
  [[ ${plugin_ids[*]} == "${existing_ids[*]}" ]] ||
    xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${arguments[@]}" >/dev/null
  for other_id in $(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+$'); do
    [[ ${other_id} == "${panel_id}" ]] && continue
    other_plugins=() other_args=() existing_other=()
    while IFS= read -r id; do
      [[ ${id} =~ ^[0-9]+$ ]] || continue
      other_type=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2>/dev/null || true)
      [[ ${other_type} == docklike || ${id} == "${plugin_id}" ]] || other_plugins+=("${id}")
      existing_other+=("${id}")
    done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${other_id}/plugin-ids" 2>/dev/null)
    for id in "${other_plugins[@]}"; do other_args+=(-t int -s "${id}"); done
    if ((${#other_args[@]})) && [[ ${other_plugins[*]} != "${existing_other[*]}" ]]; then
      xfconf-query -c xfce4-panel -p "/panels/panel-${other_id}/plugin-ids" -a "${other_args[@]}" >/dev/null
    fi
  done
  write_pins "${target}" "${pins}"
  panel_after=$(xfconf-query -c xfce4-panel -lv 2>/dev/null || true)
  [[ ${panel_before} != "${panel_after}" || ${dock_file_changed} != 0 ]] || return 0
  dock_changed=1
  [[ ${panel_before} == "${panel_after}" ]] || dock_details+=("panel: dock plugin configuration updated")
  if pgrep -x xfce4-panel >/dev/null 2>&1; then
    timeout 5 xfce4-panel -r >/dev/null 2>&1 || true
    sleep 1
    pgrep -x xfce4-panel >/dev/null 2>&1 || DISPLAY=${DISPLAY:-:0} nohup xfce4-panel >/dev/null 2>&1 &
  fi
}

desktop=${JSH_DESKTOP:-}
dock_changed=0
dock_details=()
pins=$(dock_pins)
[[ -n ${pins} ]] || exit 0
case ${desktop} in
  xfce) command -v xfconf-query >/dev/null 2>&1 || exit 0 ;;
  gnome) command -v gsettings >/dev/null 2>&1 || exit 0 ;;
  *) exit 0 ;;
esac
if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::changed "${desktop^^} dock pins"
  exit 0
fi
"configure_${desktop}_dock" "${pins}"
if ((dock_changed)); then
  for detail in "${dock_details[@]}"; do jsh::detail "${detail}"; done
  jsh::changed "${desktop^^} dock pins"
else
  jsh::current
fi
