#!/usr/bin/env bash
# Merge Sublime Text preferences after its first launch.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh" "$@"
jsh::packages sublime
if [[ $(uname -s) == Darwin ]]; then
  directory=${HOME}/Library/Application\ Support/Sublime\ Text
elif [[ -d ${HOME}/.var/app/com.sublimetext.three/config/sublime-text ]]; then
  directory=${HOME}/.var/app/com.sublimetext.three/config/sublime-text
else directory=${XDG_CONFIG_HOME:-${HOME}/.config}/sublime-text; fi
if [[ ! -d ${directory} ]]; then
  if command -v subl >/dev/null 2>&1 || [[ -d /Applications/Sublime\ Text.app || -d /var/lib/flatpak/app/com.sublimetext.three ]]; then
    jsh::notice 'open Sublime Text once, then rerun scripts/sublime.sh'
    exit 0
  fi
  jsh::skip "Sublime Text settings: Sublime Text is not installed"
fi
jsh::step check "Sublime Text settings"
app::json "${SCRIPT_DIR}/sublime/preferences.json" "${directory}/Packages/User/Preferences.sublime-settings"
