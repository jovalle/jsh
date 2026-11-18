#!/usr/bin/env bash
# Reconcile XFCE docklike pins with installed desktop entries.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT:?}/scripts/lib/common.sh" "$@"
# shellcheck source=ansible/helpers/desktop.sh
. "${JSH_ROOT:?}/ansible/helpers/desktop.sh"

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
    local old_names new_names
    old_names=$(jsh::desktop_names "${old_pins}")
    new_names=$(jsh::desktop_names "${pins}")
    if [[ ${old_names} == "${new_names}" ]]; then
      dock_details+=("pin locations updated: ${new_names}")
    else
      dock_details+=("pins: ${old_names} → ${new_names}")
    fi
  fi
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
    jsh::fail 'No XFCE dock panel is available.'
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
  if [[ ${JSH_KEEP_APPS:-0} == 1 ]] && pgrep -x xfce4-panel >/dev/null 2>&1; then
    jsh::notice 'restart the XFCE panel to apply dock pins: `xfce4-panel -r`'
  elif pgrep -x xfce4-panel >/dev/null 2>&1; then
    jsh::status "XFCE panel"
    if timeout 5 xfce4-panel -r >/dev/null 2>&1; then
      jsh::changed "XFCE panel restarted" "XFCE panel needs a restart"
    else
      sleep 1
      if pgrep -x xfce4-panel >/dev/null 2>&1; then
        jsh::info "XFCE panel was not restarted"
      else
        jsh::detach env DISPLAY="${DISPLAY:-:0}" xfce4-panel
        for _ in {1..50}; do
          pgrep -x xfce4-panel >/dev/null 2>&1 && break
          sleep 0.1
        done
        if pgrep -x xfce4-panel >/dev/null 2>&1; then
          jsh::changed "XFCE panel restarted" "XFCE panel needs a restart"
        else
          jsh::info "XFCE panel was not restarted"
        fi
      fi
    fi
  fi
}

mode=apply
for argument in "$@"; do
  case ${argument} in apply | list) mode=${argument} ;; esac
done
case ${mode} in
  list)
    dock_pins
    ;;
  apply)
    dock_changed=0
    dock_details=()
    pins=$(dock_pins)
    [[ -n ${pins} ]] || jsh::skip "dock: no managed applications are installed"
    command -v xfconf-query >/dev/null 2>&1 || jsh::skip "dock: xfconf-query is not installed"
    desired_names=$(jsh::desktop_names "${pins}")
    if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
      jsh::info "XFCE dock pins are unchecked in preview: ${desired_names}"
      exit 0
    fi
    configure_xfce_dock "${pins}"
    if ((dock_changed)); then
      jsh::changed "XFCE dock pins set ${desired_names}" \
        "XFCE dock pins are not ${desired_names}"
      for detail in "${dock_details[@]}"; do jsh::info "${detail}"; done
    else
      jsh::ok "XFCE dock pins are ${desired_names}"
    fi
    ;;
  *) jsh::fail "Usage: $0 [apply|list]"; exit 2 ;;
esac
