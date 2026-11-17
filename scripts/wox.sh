#!/usr/bin/env bash
# Install Wox, start it at login, and give it Command+Space (macOS) or Super+Space (Linux).
set -euo pipefail
# shellcheck disable=SC2034 # APP_LAUNCH and APP_LIVE are consumed by app::with_closed.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
[[ -n ${JSH_DESKTOP} ]] || jsh::skip "Wox: no desktop session"
jsh::packages wox
jsh::step check "Wox startup"
temporary=$(jsh::temp)
restart=0
wox::running() { pgrep -u "$(id -u)" -x 'wox|Wox' >/dev/null; }
# Open Wox before taking the native shortcut away, so a launcher is always reachable.
wox::open() {
  if wox::running; then
    jsh::ok "Wox is running"
    return 0
  fi
  jsh::status "Wox"
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::run "${APP_LAUNCH[@]}"
    jsh::changed "Wox started" "Wox needs to start"
    return 0
  fi
  jsh::detach "${APP_LAUNCH[@]}"
  for _ in {1..50}; do
    wox::running && break
    sleep 0.1
  done
  if wox::running; then
    jsh::changed "Wox started" "Wox needs to start"
  else
    jsh::info "Wox did not start"
  fi
}
wox::database() {
  local data=${HOME}/.wox/wox-user
  [[ ! -f ${HOME}/.wox/.userdata.location ]] || data=$(<"${HOME}/.wox/.userdata.location")
  case ${data} in \~/*) data=${HOME}/${data#\~/} ;; esac
  printf '%s/wox.db\n' "${data}"
}
# Set a macOS symbolic hotkey on Space; an absent entry means the system default.
wox::symbolic() {
  local id=$1 enabled=$2 modifiers=$3 label=$4 settings state
  settings=$(defaults export com.apple.symbolichotkeys - 2>/dev/null) || settings=
  if [[ $(plutil -extract "AppleSymbolicHotKeys.${id}.enabled" raw -o - - <<<"${settings}" 2>/dev/null) == "${enabled}" ]] &&
    { [[ ${enabled} == false ]] ||
      [[ $(plutil -extract "AppleSymbolicHotKeys.${id}.value.parameters.2" raw -o - - <<<"${settings}" 2>/dev/null) == "${modifiers}" ]]; }; then
    if [[ ${enabled} == true ]]; then
      jsh::ok "${label} is enabled"
    else
      jsh::ok "${label} is disabled"
    fi
    return
  fi
  jsh::run defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "${id}" \
    "<dict><key>enabled</key><${enabled}/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>${modifiers}</integer></array><key>type</key><string>standard</string></dict></dict>"
  if [[ ${enabled} == true ]]; then state=enabled; else state=disabled; fi
  jsh::changed "${label} set ${state}" "${label} is not ${state}"
  restart=1
}
if [[ ${JSH_DESKTOP} == darwin ]]; then
  [[ -d /Applications/Wox.app ]] || jsh::skip "Wox: /Applications/Wox.app is not installed"
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
  jsh::step check "macOS launcher shortcuts"
  # Spotlight (symbolic hotkey 64) moves from Command+Space to Control+Space, which the
  # previous-input-source hotkey (60) gives up.
  wox::symbolic 60 false 262144 "previous input source Control+Space"
  wox::symbolic 64 true 262144 "Spotlight Control+Space"
  if ((restart)); then
    if jsh::run /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u; then
      jsh::changed "macOS launcher shortcuts reloaded" \
        "macOS launcher shortcuts need a reload"
    else
      jsh::notice 'log out and back in so Control+Space opens Spotlight'
    fi
  fi
else
  wox=$(command -v wox || printf '%s' "${HOME}/.local/bin/wox")
  [[ -x ${wox} ]] || jsh::skip "Wox: executable is not installed"
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
  # The desktop grabs Super+Space before Wox can, so release the native bindings and
  # keep the desktop's app launcher on Control+Space.
  jsh::step check "native launcher shortcuts"
  if [[ ${JSH_DESKTOP} == xfce ]]; then
    property='/commands/custom/<Super>space'
    if xfconf-query -c xfce4-keyboard-shortcuts -p "${property}" >/dev/null 2>&1; then
      jsh::run xfconf-query -c xfce4-keyboard-shortcuts -p "${property}" -r
      jsh::removed "xfce4-keyboard-shortcuts ${property} removed" \
        "xfce4-keyboard-shortcuts ${property} exists"
      restart=1
    fi
    jsh::xfsetting xfce4-keyboard-shortcuts '/commands/custom/<Primary>space' xfce4-appfinder
  else
    for key in switch-input-source switch-input-source-backward; do
      current=$(jsh::gnome_list org.gnome.desktop.wm.keybindings "${key}")
      wanted=$(jq -c 'map(select(test("^(<shift>)?<super>space$"; "i") | not))' <<<"${current}")
      [[ ${wanted} == "${current}" ]] || restart=1
      jsh::gsetting org.gnome.desktop.wm.keybindings "${key}" "${wanted}"
    done
    current=$(jsh::gnome_list org.gnome.shell.keybindings toggle-application-view)
    wanted=$(jq -c 'if any(.[]; test("^<(control|primary|ctrl)>space$"; "i")) then . else . + ["<Control>space"] end' \
      <<<"${current}")
    jsh::gsetting org.gnome.shell.keybindings toggle-application-view "${wanted}"
  fi
fi

jsh::step check "Wox hotkey"
jsh::status "settings database"
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
jsh::status "${hotkey}"
clipboard_hotkeys=0
if [[ ${platform} == darwin ]] && ((ready)); then
  clipboard_hotkeys=$(sqlite3 -readonly "${database}" \
    "SELECT count(*) FROM wox_settings, json_each(wox_settings.value)
     WHERE wox_settings.key = 'QueryHotkeys@darwin'
       AND lower(json_extract(json_each.value, '$.Hotkey')) = 'cmd+shift+v'
       AND coalesce(json_extract(json_each.value, '$.Disabled'), 0) != 1")
fi
if [[ ${current} == "${hotkey}" ]] && ((!restart && !clipboard_hotkeys)); then
  jsh::ok "Wox hotkey is ${hotkey}"
  if [[ ${platform} == darwin ]] && ((ready)); then
    jsh::ok 'Wox Command+Shift+V is disabled'
  fi
  exit 0
fi
wox::hotkey() {
  if [[ ${current} == "${hotkey}" ]]; then
    jsh::ok "Wox hotkey is ${hotkey}"
  else
    jsh::run sqlite3 "${database}" \
      "INSERT OR REPLACE INTO wox_settings (\"key\", \"value\") VALUES ('${key}', '${hotkey}')"
    jsh::changed "Wox hotkey set ${hotkey}" "Wox hotkey is not ${hotkey}"
  fi
  if [[ ${platform} == darwin ]] && ((ready)); then
    if ((clipboard_hotkeys)); then
      jsh::run sqlite3 "${database}" \
        "UPDATE wox_settings SET value = (
           SELECT json_group_array(json(CASE
             WHEN lower(json_extract(value, '$.Hotkey')) = 'cmd+shift+v'
             THEN json_set(value, '$.Disabled', json('true')) ELSE value END))
           FROM json_each(wox_settings.value))
         WHERE key = 'QueryHotkeys@darwin'"
      jsh::changed 'Wox Command+Shift+V disabled' 'Wox Command+Shift+V is enabled'
    else
      jsh::ok 'Wox Command+Shift+V is disabled'
    fi
  fi
}
# Wox registers its hotkey at launch, so a running copy restarts to claim it.
APP_LIVE=1
app::with_closed Wox 'wox|Wox' wox::hotkey
