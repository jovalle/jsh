#!/usr/bin/env bash
# Configure an opt-in EndeavourOS XFCE application dock and pins.

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

is_endeavouros() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1
  local ID=
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ "${ID:-}" == endeavouros ]]
}

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
  desktop_file=$(find_desktop_file visual-studio-code.desktop code.desktop code-oss.desktop) && pins+="${desktop_file};"
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

write_pins() {
  local target=$1 pins=$2 temporary
  temporary=$(mktemp "${target}.XXXXXX")
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

main() {
  local pins panel_dir target plugin_id panel_id id autostart temporary
  local -a plugin_ids=() array_args=()
  [[ "$(uname -s)" == Linux ]] || return
  is_endeavouros || {
    jsh_info "Skipping application dock: EndeavourOS not detected."
    return
  }
  command -v xfconf-query > /dev/null 2>&1 || {
    jsh_warn "Skipping application dock: xfconf-query is unavailable."
    return
  }

  pins=$(dock_pins)
  [[ -n "${pins}" ]] || {
    jsh_warn "Skipping application dock: no configured applications are installed."
    return
  }
  jsh_info "This will add or update the jsh-managed XFCE Docklike plugin."
  jsh_prompt "Configure the EndeavourOS application dock? [y/N]: "
  read -r answer || answer=
  [[ "${answer}" =~ ^[Yy]$ ]] || {
    jsh_warn "Skipping EndeavourOS application dock."
    return
  }

  panel_dir="${HOME}/.config/xfce4/panel"
  mkdir -p "${panel_dir}"
  target=$(managed_dock_target "${panel_dir}" || true)
  if [[ -z "${target}" ]]; then
    plugin_id=$(xfconf-query -c xfce4-panel -lv 2> /dev/null |
      sed -n 's|^/plugins/plugin-\([0-9][0-9]*\).*|\1|p' | sort -n | tail -1)
    plugin_id=$((${plugin_id:-0} + 1))
    panel_id=$(xfconf-query -c xfce4-panel -p /panels 2> /dev/null | sed -n '1p')
    [[ "${panel_id}" =~ ^[0-9]+$ ]] || {
      jsh_error "No XFCE panel is available for the application dock."
      return 1
    }
    target="${panel_dir}/docklike-${plugin_id}.rc"
    xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}" -n -t string -s docklike > /dev/null
    xfconf-query -c xfce4-panel -p "/plugins/plugin-${plugin_id}/jsh-managed" -n -t bool -s true > /dev/null
    while IFS= read -r id; do
      [[ "${id}" =~ ^[0-9]+$ ]] && plugin_ids+=("${id}")
    done < <(xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" 2> /dev/null)
    plugin_ids+=("${plugin_id}")
    for id in "${plugin_ids[@]}"; do
      array_args+=(-t int -s "${id}")
    done
    xfconf-query -c xfce4-panel -p "/panels/panel-${panel_id}/plugin-ids" -a "${array_args[@]}" > /dev/null
  fi

  [[ -e "${target}" ]] || printf '[user]\n' > "${target}"
  write_pins "${target}" "${pins}"
  autostart="${HOME}/.config/autostart/jsh-dock.desktop"
  mkdir -p "$(dirname -- "${autostart}")"
  temporary=$(mktemp "${autostart}.XXXXXX")
  printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=jsh application dock' \
    "Exec=${SCRIPT_DIR}/dock.sh" 'OnlyShowIn=XFCE;' 'X-GNOME-Autostart-enabled=true' > "${temporary}"
  install -m 0644 "${temporary}" "${autostart}"
  rm -f "${temporary}"
  xfce4-panel -r > /dev/null 2>&1 || true
  jsh_success "EndeavourOS application dock configured."
}

main "$@"
