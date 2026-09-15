#!/usr/bin/env bash
# Reconcile the desktop wallpaper from JSH_WALLPAPER or local/wallpaper.*, otherwise black.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

wallpaper=${JSH_WALLPAPER:-}
if [[ -z ${wallpaper} ]]; then
  for candidate in "${JSH_ROOT}"/local/wallpaper.*; do
    [[ -f ${candidate} ]] || continue
    case $(file --brief --mime-type "${candidate}") in
      image/*) wallpaper=${candidate}; break ;;
    esac
  done
fi
if [[ ! -f ${wallpaper} ]] || [[ $(file --brief --mime-type "${wallpaper}" 2>/dev/null) != image/* ]]; then
  wallpaper=
fi
[[ -z ${wallpaper} ]] || wallpaper=$(realpath -- "${wallpaper}")
changed=0

set_xfce() {
  local key=$1 type=$2 value=$3 current
  if current=$(xfconf-query -c xfce4-desktop -p "${key}" 2>/dev/null); then
    [[ ${current} != "${value}" ]] || return 0
    if [[ ${JSH_CONFIGURE_DRY_RUN:-0} != 1 ]]; then
      xfconf-query -c xfce4-desktop -p "${key}" -s "${value}"
    fi
  elif [[ ${JSH_CONFIGURE_DRY_RUN:-0} != 1 ]]; then
    xfconf-query -c xfce4-desktop -p "${key}" -n -t "${type}" -s "${value}"
  fi
  changed=$((changed + 1))
}

case $(jsh_linux_desktop) in
  xfce)
    properties=$(xfconf-query -c xfce4-desktop -l)
    backdrops=$({
      printf '%s\n' "${properties}" | sed -n 's@\(/backdrop/.*\)/[^/]*$@\1@p'
      # RandR logical monitors acquire distinct backdrop keys after a split.
      workspaces=$(xfconf-query -c xfwm4 -p /general/workspace_count 2>/dev/null || printf 1)
      [[ ${workspaces} =~ ^[0-9]+$ ]] || workspaces=1
      while IFS= read -r monitor; do
        for ((workspace=0; workspace<workspaces; workspace++)); do
          printf '/backdrop/screen0/monitor%s/workspace%d\n' "${monitor}" "${workspace}"
        done
      done < <(xrandr --listmonitors | awk 'NR>1 { sub(/^[+*]+/, "", $2); print $2 }';
                xrandr --query | awk '$2 == "connected" {print $1}')
    } | sort -u)
    [[ -n ${backdrops} ]] || { jsh_error 'No active XFCE backdrop settings found.'; exit 1; }
    while IFS= read -r backdrop; do
      set_xfce "${backdrop}/color-style" int 0
      set_xfce "${backdrop}/backdrop-cycle-enable" bool false
      for rgba in rgba1 rgba2; do
        current=$(xfconf-query -c xfce4-desktop -p "${backdrop}/${rgba}" 2>/dev/null || true)
        values=$(printf '%s\n' "${current}" | awk '/^[0-9]/ {printf "%g ", $1}')
        if [[ ${values} != '0 0 0 1 ' ]]; then
          if [[ ${JSH_CONFIGURE_DRY_RUN:-0} != 1 ]]; then
            xfconf-query -c xfce4-desktop -p "${backdrop}/${rgba}" -r 2>/dev/null || true
            xfconf-query -c xfce4-desktop -p "${backdrop}/${rgba}" -n -a -t double -s 0 -t double -s 0 -t double -s 0 -t double -s 1
          fi
          changed=$((changed + 1))
        fi
      done
      if [[ -n ${wallpaper} ]]; then
        set_xfce "${backdrop}/last-image" string "${wallpaper}"
        set_xfce "${backdrop}/image-style" int 5
        set_xfce "${backdrop}/image-show" bool true
      else
        set_xfce "${backdrop}/image-style" int 0
        set_xfce "${backdrop}/image-show" bool false
        set_xfce "${backdrop}/last-image" string ''
      fi
      current=$(xfconf-query -c xfce4-desktop -p "${backdrop}/color1" 2>/dev/null || true)
      values=$(printf '%s\n' "${current}" | sed -n '/^[0-9]/p' | tr '\n' ' ')
      if [[ ${values} != '0 0 0 65535 ' ]]; then
        if [[ ${JSH_CONFIGURE_DRY_RUN:-0} != 1 ]]; then
          if [[ -n ${current} ]]; then
            xfconf-query -c xfce4-desktop -p "${backdrop}/color1" -a -s 0 -s 0 -s 0 -s 65535
          else
            xfconf-query -c xfce4-desktop -p "${backdrop}/color1" -n -a -t uint -s 0 -t uint -s 0 -t uint -s 0 -t uint -s 65535
          fi
        fi
        changed=$((changed + 1))
      fi
    done <<< "${backdrops}"
    ;;
  gnome)
    uri=
    [[ -z ${wallpaper} ]] || uri=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())' "${wallpaper}")
    for key in picture-uri picture-uri-dark primary-color secondary-color picture-options; do
      case ${key} in
        picture-uri*) value="'${uri}'" ;;
        *color) value="'#000000'" ;;
        picture-options) value="'none'"; [[ -z ${wallpaper} ]] || value="'zoom'" ;;
      esac
      current=$(gsettings get org.gnome.desktop.background "${key}")
      [[ ${current} != "${value}" ]] || continue
      [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]] || gsettings set org.gnome.desktop.background "${key}" "${value}"
      changed=$((changed + 1))
    done
    ;;
  *) jsh_error 'Wallpaper requires an XFCE or GNOME session.'; exit 1 ;;
esac
if ((changed)); then
  [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]] || xfdesktop --reload 2>/dev/null || true
  jsh_success "Wallpaper: ${wallpaper:-solid black} (${changed} settings changed)"
else
  jsh_note "Wallpaper is current: ${wallpaper:-solid black}"
fi
