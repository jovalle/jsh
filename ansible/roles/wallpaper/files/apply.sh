#!/usr/bin/env bash
# Reapply the current Linux wallpaper after display geometry changes.
set -euo pipefail
[[ ${JSH_DRY_RUN:-0} != 1 ]] || exit 0
session=${JSH_DESKTOP:-${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}}
case $(printf '%s' "${session}" | tr '[:upper:]' '[:lower:]') in
  *gnome*)
    keys=$(gsettings list-keys org.gnome.desktop.background)
    for key in picture-uri picture-uri-dark picture-options; do
      grep -Fxq "${key}" <<<"${keys}" || continue
      value=$(gsettings get org.gnome.desktop.background "${key}")
      gsettings set org.gnome.desktop.background "${key}" "${value}"
    done
    ;;
  *xfce*)
    while IFS= read -r property; do
      [[ ${property} == */last-image ]] || continue
      value=$(xfconf-query -c xfce4-desktop -p "${property}")
      xfconf-query -c xfce4-desktop -p "${property}" -s "${value}"
    done < <(xfconf-query -c xfce4-desktop -l)
    command -v xfdesktop >/dev/null 2>&1 && xfdesktop --reload
    ;;
esac
