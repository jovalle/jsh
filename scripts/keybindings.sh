#!/usr/bin/env bash
# Apply native keyboard settings and managed launcher shortcuts.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/desktop.sh
. "${SCRIPT_DIR}/lib/desktop.sh"
jsh::activity 'Checking keyboard shortcut support'
[[ -n ${JSH_DESKTOP} ]] || exit 0
jsh::need jq
spec=${SCRIPT_DIR}/keybindings/keybindings.json
if [[ ${JSH_DESKTOP} == darwin ]]; then
  while IFS=$'\t' read -r key value; do
    jsh::activity "Checking keyboard setting ${key}"
    if [[ $(defaults read NSGlobalDomain "${key}" 2>/dev/null || true) == "${value}" ]]; then
      jsh::current
    else
      jsh::run defaults write NSGlobalDomain "${key}" -int "${value}"
      jsh::changed "${key}"
    fi
  done < <(jq -r '.darwin.keyboard | to_entries[] | [.key,.value] | @tsv' "${spec}")
  while IFS=$'\t' read -r menu binding; do
    jsh::activity "Checking menu shortcut ${menu}"
    current=$(defaults export NSGlobalDomain - | plutil -extract NSUserKeyEquivalents json -o - -)
    if [[ $(jq -r --arg menu "${menu}" '.[$menu] // ""' <<<"${current}") == "${binding}" ]]; then
      jsh::current
    else
      jsh::run defaults write NSGlobalDomain NSUserKeyEquivalents -dict-add "${menu}" "${binding}"
      jsh::changed "${menu}"
    fi
  done < <(jq -r '.darwin.shortcuts | to_entries[] | [.key,.value] | @tsv' "${spec}")
else
  while IFS=$'\t' read -r name binding command; do
    jsh::activity "Checking shortcut ${name}"
    command -v "${command%% *}" >/dev/null 2>&1 || continue
    if [[ ${JSH_DESKTOP} == xfce ]]; then
      jsh::xfsetting xfce4-keyboard-shortcuts "/commands/custom/${binding}" "${command}"
    else
      path=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/jsh-$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')/
      schema=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}
      for key in name binding command; do
        case ${key} in name) value=${name} ;; binding) value=${binding} ;; command) value=${command} ;; esac
        jsh::gsetting "${schema}" "${key}" "$(jq -Rn --arg text "${value}" '$text')"
      done
      paths=$(jsh::gnome_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings)
      if ! jq -e --arg path "${path}" 'index($path)' <<<"${paths}" >/dev/null; then
        jsh::gsetting org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
          "$(jq -c --arg path "${path}" '. + [$path]' <<<"${paths}")"
      fi
    fi
  done < <(jq -r --arg desktop "${JSH_DESKTOP}" '.[$desktop][] | [.name,.binding,.command] | @tsv' "${spec}")
fi
