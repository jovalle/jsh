#!/usr/bin/env bash
# Apply JSH_WALLPAPER to the active desktop without choosing an image implicitly.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
jsh::activity 'Checking wallpaper selection'
[[ -n ${JSH_WALLPAPER:-} ]] || exit 0
image=${JSH_WALLPAPER}
case ${image} in \~/*) image=${HOME}/${image#\~/} ;; /*) ;; *) image=${PWD}/${image} ;; esac
[[ -f ${image} ]] || {
  jsh::notice "JSH_WALLPAPER is not a file: ${image}"
  exit 1
}
image=$(cd -- "${image%/*}" && printf '%s/%s' "$(pwd -P)" "${image##*/}")
jsh::activity 'Checking desktop wallpaper'
case ${JSH_DESKTOP} in
  darwin)
    check='on run argv
      tell application "System Events"
        repeat with itemDesktop in desktops
          if picture of itemDesktop is not item 1 of argv then return false
        end repeat
      end tell
      return true
    end run'
    if [[ $(osascript -e "${check}" "${image}") == true ]]; then
      jsh::current
    else
      script='on run argv
        tell application "System Events"
          repeat with itemDesktop in desktops
            if picture of itemDesktop is not item 1 of argv then set picture of itemDesktop to item 1 of argv
          end repeat
        end tell
      end run'
      jsh::run osascript -e "${script}" "${image}"
      jsh::changed "wallpaper ${image}"
    fi
    ;;
  gnome)
    uri=file://$(jq -rn --arg path "${image}" '$path | split("/") | map(@uri) | join("/")')
    keys=$(gsettings list-keys org.gnome.desktop.background)
    for key in picture-uri picture-uri-dark; do
      if printf '%s\n' "${keys}" | grep -Fxq "${key}"; then
        jsh::gsetting org.gnome.desktop.background "${key}" "$(jq -Rn --arg uri "${uri}" '$uri')"
      fi
    done
    jsh::gsetting org.gnome.desktop.background picture-options "'zoom'"
    ;;
  xfce)
    found=0
    while IFS= read -r property; do
      [[ ${property} == */last-image ]] || continue
      found=1
      jsh::xfsetting xfce4-desktop "${property}" "${image}"
    done < <(xfconf-query -c xfce4-desktop -l)
    ((found)) || jsh::notice 'XFCE has no backdrop properties yet; log in to XFCE once, then rerun'
    ;;
esac
