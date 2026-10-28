#!/usr/bin/env bash
# Apply managed macOS preferences and restart the affected system applications.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

restart=()
while IFS=$'\t' read -r domain key type value; do
  [[ -n ${domain} && ${domain} != '#'* ]] || continue
  scope=()
  if [[ ${domain} == '-currentHost '* ]]; then
    scope=(-currentHost)
    domain=${domain#-currentHost }
  fi
  case ${type} in -bool | -int | -float | -string | -array) ;; *) exit 2 ;; esac
  case ${value} in \~/*) value=${HOME}/${value#\~/} ;; esac
  expected=${value}
  expected_type=${type#-}
  case ${type}:${value} in
    -bool:true) expected=1 expected_type=boolean ;;
    -bool:false) expected=0 expected_type=boolean ;;
    -int:*) expected_type=integer ;;
    -array:*) expected='()' ;;
  esac
  current_value=$(defaults ${scope[@]+"${scope[@]}"} read "${domain}" "${key}" 2>/dev/null || true)
  [[ ${type} != -array ]] || current_value=${current_value//[[:space:]]/}
  current_type=$(defaults ${scope[@]+"${scope[@]}"} read-type "${domain}" "${key}" 2>/dev/null || true)
  if [[ ${current_value} == "${expected}" && ${current_type} == "Type is ${expected_type}" ]]; then
    jsh::current
    continue
  fi
  if [[ ${domain}:${key} == com.apple.screencapture:location ]]; then
    jsh::run mkdir -p -- "${value}"
  fi
  jsh::run defaults ${scope[@]+"${scope[@]}"} write "${domain}" "${key}" "${type}" ${value:+"${value}"}
  jsh::changed "${domain} ${key}"
  case ${domain} in
    com.apple.dock) restart+=(Dock) ;;
    com.apple.finder) restart+=(Finder) ;;
    com.apple.Spotlight | com.apple.screencapture) restart+=(SystemUIServer) ;;
  esac
done <"${SCRIPT_DIR}/preferences.tsv"
for app in Dock Finder SystemUIServer; do
  [[ " ${restart[*]-} " == *" ${app} "* ]] || continue
  jsh::run killall "${app}" 2>/dev/null || true
done
