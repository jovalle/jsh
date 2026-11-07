#!/usr/bin/env bash
# Install Wox, start it at login, and give it Command+Space (macOS) or Super+Space (Linux).

set -euo pipefail
# shellcheck disable=SC2034 # APP_LAUNCH and APP_LIVE are consumed by app::with_closed.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
jsh::activity 'Checking launcher support'
[[ -n ${JSH_DESKTOP} ]] || exit 0
jsh::packages wox
jsh::activity 'Checking Wox installation'
temporary=$(jsh::temp)
restart=0
wox::running() { pgrep -u "$(id -u)" -x 'wox|Wox' >/dev/null; }
# Open Wox before taking the native shortcut away, so a launcher is always reachable.
wox::open() {
  ! wox::running || return 0
  jsh::activity 'Opening Wox'
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::run "${APP_LAUNCH[@]}"
  else
    nohup "${APP_LAUNCH[@]}" </dev/null >/dev/null 2>&1 &
  fi
}
wox::database() {
  local data=${HOME}/.wox/wox-user
  [[ ! -f ${HOME}/.wox/.userdata.location ]] || data=$(<"${HOME}/.wox/.userdata.location")
  case ${data} in \~/*) data=${HOME}/${data#\~/} ;; esac
  printf '%s/wox.db\n' "${data}"
}
if [[ ${JSH_DESKTOP} == darwin ]]; then
  [[ -d /Applications/Wox.app ]] || exit 0
  platform=darwin hotkey=cmd+space
  APP_LAUNCH=(open -a Wox)
  wox::open
  cat >"${temporary}/agent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>jsh.wox</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>Wox</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
  jsh::file "${temporary}/agent.plist" "${HOME}/Library/LaunchAgents/jsh.wox.plist" 644
  # Spotlight owns Command+Space through symbolic hotkey 64 until it is disabled.
  jsh::activity 'Checking Spotlight shortcut'
  if [[ $(defaults export com.apple.symbolichotkeys - 2>/dev/null |
    plutil -extract AppleSymbolicHotKeys.64.enabled raw -o - - 2>/dev/null) == false ]]; then
    jsh::current
  else
    jsh::run defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 \
      '<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>'
    jsh::run /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u ||
      jsh::notice 'log out and back in so Command+Space stops opening Spotlight'
    jsh::changed 'Spotlight Command+Space'
    restart=1
  fi
else
  wox=$(command -v wox || printf '%s' "${HOME}/.local/bin/wox")
  [[ -x ${wox} ]] || exit 0
  platform=linux hotkey=super+space
  APP_LAUNCH=("${wox}")
  wox::open
  executable=${wox//\\/\\\\}
  executable=${executable//\"/\\\"}
  executable=${executable//\$/\\\$}
  executable=${executable//\`/\\\`}
  executable=${executable//%/%%}
  printf '[Desktop Entry]\nType=Application\nName=Wox\nExec="%s"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n' \
    "${executable}" >"${temporary}/wox.desktop"
  jsh::file "${temporary}/wox.desktop" "${XDG_CONFIG_HOME:-${HOME}/.config}/autostart/jsh-wox.desktop" 644
  # The desktop grabs Super+Space before Wox can, so release the native bindings.
  jsh::activity 'Checking native Super+Space bindings'
  if [[ ${JSH_DESKTOP} == xfce ]]; then
    property='/commands/custom/<Super>space'
    if xfconf-query -c xfce4-keyboard-shortcuts -p "${property}" >/dev/null 2>&1; then
      jsh::run xfconf-query -c xfce4-keyboard-shortcuts -p "${property}" -r
      jsh::removed "xfce4-keyboard-shortcuts ${property}"
      restart=1
    fi
  else
    for key in switch-input-source switch-input-source-backward; do
      current=$(jsh::gnome_list org.gnome.desktop.wm.keybindings "${key}")
      wanted=$(jq -c 'map(select(test("^(<shift>)?<super>space$"; "i") | not))' <<<"${current}")
      [[ ${wanted} == "${current}" ]] || restart=1
      jsh::gsetting org.gnome.desktop.wm.keybindings "${key}" "${wanted}"
    done
  fi
fi

jsh::activity 'Waiting for Wox settings'
jsh::need sqlite3
key=MainHotkey@${platform}
ready=0
# A first launch creates the database and its tables a few seconds after opening.
for ((index = 0; index < 300; index++)); do
  database=$(wox::database)
  if current=$(sqlite3 -readonly "${database}" \
    "SELECT \"value\" FROM wox_settings WHERE \"key\" = '${key}'" 2>/dev/null); then
    ready=1
    break
  fi
  [[ ${JSH_DRY_RUN} != 1 ]] || break
  sleep 0.1
done
if ((!ready)) && [[ ${JSH_DRY_RUN} != 1 ]]; then
  jsh::notice 'Wox did not create its settings; open Wox, then rerun scripts/wox.sh'
  exit 0
fi
jsh::activity 'Checking Wox hotkey'
[[ ${current} != "${hotkey}" ]] || ((restart)) || exit 0
wox::hotkey() {
  [[ ${current} != "${hotkey}" ]] || return 0
  jsh::run sqlite3 "${database}" \
    "INSERT OR REPLACE INTO wox_settings (\"key\", \"value\") VALUES ('${key}', '${hotkey}')"
  jsh::changed "Wox hotkey ${hotkey}"
}
# Wox registers its hotkey at launch, so a running copy restarts to claim it.
APP_LIVE=1
app::with_closed Wox 'wox|Wox' wox::hotkey
