#!/usr/bin/env bash
# Configure an opt-in Linux application dock and pins.

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

find_desktop_file() {
  local candidate directory
  for candidate in "$@"; do
    for directory in \
      "${HOME}/.local/share/applications" \
      /usr/share/applications \
      /usr/local/share/applications \
      /var/lib/flatpak/exports/share/applications \
      "${HOME}/.local/share/flatpak/exports/share/applications"; do
      if [[ -f "${directory}/${candidate}" ]]; then
        printf '%s\n' "${directory}/${candidate}"
        return
      fi
    done
  done
  return 1
}

dock_pins() {
  local pins='' desktop_file
  desktop_file=$(find_desktop_file com.mitchellh.ghostty.desktop xfce4-terminal.desktop xfce4-terminal-emulator.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file waterfox.desktop net.waterfox.waterfox.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file helium.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file code.desktop visual-studio-code.desktop com.visualstudio.code.desktop code-oss.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file com.spotify.Client.desktop) && pins+="${desktop_file};"
  desktop_file=$(find_desktop_file com.todoist.Todoist.desktop) && pins+="${desktop_file};"
  printf '%s\n' "${pins}"
}

managed_dock_target() {
  local panel_dir=$1 candidate filename plugin_id managed
  while IFS= read -r candidate; do
    filename=${candidate##*/}
    plugin_id=${filename#docklike-}
    plugin_id=${plugin_id%.rc}
    [[ "${plugin_id}" =~ ^[0-9]+$ ]] || continue
    managed=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}/jsh-managed" 2> /dev/null || true)
    [[ "${managed}" == true ]] || continue
    printf '%s\n' "${candidate}"
    return
  done < <(find "${panel_dir}" -maxdepth 1 -name 'docklike-*.rc' -print 2> /dev/null | sort)
  return 1
}

find_xfce_dock_panel() {
  local id position size
  while IFS= read -r id; do
    [[ "${id}" =~ ^[0-9]+$ ]] || continue
    position=$(xfconf-query -c xfce4-panel -p "/panels/panel-${id}/position" 2> /dev/null || true)
    size=$(xfconf-query -c xfce4-panel -p "/panels/panel-${id}/size" 2> /dev/null || true)
    if [[ "${position}" =~ p=(8|9|10|11|12) ]] || (( ${size:-0} >= 36 )); then
      printf '%s\n' "${id}"
      return
    fi
  done < <(xfconf-query -c xfce4-panel -p /panels 2> /dev/null | grep -E '^[0-9]+$' | sort -nr)

  xfconf-query -c xfce4-panel -p /panels 2> /dev/null | grep -E '^[0-9]+$' | tail -n 1
}

write_pins() {
  local target=$1 pins=$2 temporary
  temporary=$(mktemp "${target}.XXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  awk -v pins="${pins}" '
    BEGIN { section=0; found=0 }
    /^\[user\]$/ { section=1; print; next }
    /^\[/ {
      if (section && !found) { print "pinned=" pins; found=1 }
      section=0
    }
    section && /^pinned=/ { if (!found) print "pinned=" pins; found=1; next }
    { print }
    END {
      if (!found) {
        if (!section) print "\n[user]"
        print "pinned=" pins
      }
    }
  ' "${target}" 2> /dev/null > "${temporary}" || printf '[user]\npinned=%s\n' "${pins}" > "${temporary}"
  install -m 0644 "${temporary}" "${target}"
  rm -f "${temporary}"
}

configure_gnome_dock() {
  local pins=$1 path desktop_id current existing serialized separator=''
  local -a favorites=()

  if ! current=$(gsettings get org.gnome.shell favorite-apps); then
    jsh::log_error "Unable to read existing GNOME favorites."
    return 1
  fi
  while IFS= read -r existing; do
    [[ -n "${existing}" ]] && favorites+=("${existing}")
  done < <(grep -o "'[^']*'" <<< "${current}" | tr -d "'")
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    desktop_id=${path##*/}
    [[ " ${favorites[*]} " == *" ${desktop_id} "* ]] || favorites+=("${desktop_id}")
  done < <(tr ';' '\n' <<< "${pins}")

  serialized='['
  for desktop_id in "${favorites[@]}"; do
    serialized+="${separator}'${desktop_id}'"
    separator=', '
  done
  serialized+=']'
  gsettings set org.gnome.shell favorite-apps "${serialized}"
}

configure_xfce_dock() {
  local pins=$1
  local panel_dir target plugin_id panel_id id temporary filename ptype
  local -a plugin_ids=() array_args=()

  panel_dir="${HOME}/.config/xfce4/panel"
  mkdir -p "${panel_dir}"
  panel_id=$(find_xfce_dock_panel)
  [[ "${panel_id}" =~ ^[0-9]+$ ]] || {
    jsh::log_error "No XFCE panel is available for the application dock."
    return 1
  }

  target=$(managed_dock_target "${panel_dir}" || true)
  if [[ -z "${target}" ]]; then
    plugin_id=$(xfconf-query -c xfce4-panel -lv 2> /dev/null |
      sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
    plugin_id=$((${plugin_id:-0} + 1))
    target="${panel_dir}/docklike-${plugin_id}.rc"
    xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" -n -t string -s docklike > /dev/null
    xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}/jsh-managed" -n -t bool -s true > /dev/null
  else
    filename=${target##*/}
    plugin_id=${filename#docklike-}
    plugin_id=${plugin_id%.rc}
  fi

  local dock_present=0
  while IFS= read -r id; do
    [[ "${id}" =~ ^[0-9]+$ ]] || continue
    ptype=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2> /dev/null || true)
    if [[ "${id}" == "${plugin_id}" ]]; then
      dock_present=1
      plugin_ids+=("${id}")
    elif [[ "${ptype}" == launcher ]]; then
      if (( ! dock_present )); then
        plugin_ids+=("${plugin_id}")
        dock_present=1
      fi
    else
      plugin_ids+=("${id}")
    fi
  done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2> /dev/null)
  (( dock_present )) || plugin_ids+=("${plugin_id}")

  for id in "${plugin_ids[@]}"; do
    array_args+=(-t int -s "${id}")
  done
  xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${array_args[@]}" > /dev/null

  # Remove docklike from any other panel (e.g. top bar)
  local other_id other_ptype
  local -a other_plugins=() other_args=()
  for other_id in $(xfconf-query -c xfce4-panel -p /panels 2> /dev/null | grep -E '^[0-9]+$'); do
    [[ "${other_id}" == "${panel_id}" ]] && continue
    other_plugins=()
    other_args=()
    while IFS= read -r id; do
      [[ "${id}" =~ ^[0-9]+$ ]] || continue
      other_ptype=$(xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2> /dev/null || true)
      [[ "${other_ptype}" != docklike && "${id}" != "${plugin_id}" ]] && other_plugins+=("${id}")
    done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${other_id}/plugin-ids" 2> /dev/null)
    for id in "${other_plugins[@]}"; do
      other_args+=(-t int -s "${id}")
    done
    if ((${#other_args[@]} > 0)); then
      xfconf-query -c xfce4-panel -p "/panels/panel-${other_id}/plugin-ids" -a "${other_args[@]}" > /dev/null
    fi
  done

  [[ -e "${target}" ]] || printf '[user]\n' > "${target}"
  write_pins "${target}" "${pins}"
  if pgrep -x xfce4-panel > /dev/null 2>&1; then
    timeout 5 xfce4-panel -r > /dev/null 2>&1 || true
    sleep 1
    if ! pgrep -x xfce4-panel > /dev/null 2>&1; then
      DISPLAY="${DISPLAY:-:0}" nohup xfce4-panel > /dev/null 2>&1 &
    fi
  fi
}

main() {
  local desktop pins arg
  for arg in "$@"; do
    case "${arg}" in
      -y | --yes) export JSH_ASSUME_YES=1 ;;
    esac
  done

  [[ "$(uname -s)" == Linux ]] || return
  desktop=$(jsh_linux_desktop)
  case "${desktop}" in
    xfce) command -v xfconf-query > /dev/null 2>&1 || return ;;
    gnome) command -v gsettings > /dev/null 2>&1 || return ;;
    *)
      jsh::log_note "Skipping application dock: XFCE or GNOME is not active."
      return
      ;;
  esac

  pins=$(dock_pins)
  [[ -n "${pins}" ]] || {
    jsh::log_note "Skipping application dock: no configured applications are installed."
    return
  }
  jsh::log_detail "This will add installed Jsh applications to the ${desktop^^} dock."
  if ! jsh::confirm "Configure the ${desktop^^} application dock?" --default no; then
    jsh::log_note "Skipping application dock."
    return
  fi

  "configure_${desktop}_dock" "${pins}"
  jsh::log_success "${desktop^^} application dock configured."
}

main "$@"
