#!/usr/bin/env bash
# Merge VS Code settings and install its Linux package when needed.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
jsh::packages vscode
jsh::activity 'Checking VS Code installation'

if [[ $(uname -s) == Darwin ]]; then
  directory=${HOME}/Library/Application\ Support/Code/User
else
  directory=${XDG_CONFIG_HOME:-${HOME}/.config}/Code/User
  installed=''
  if command -v apt-get >/dev/null 2>&1; then
    channel=deb
    if [[ $(dpkg-query -W '-f=${db:Status-Status}' code 2>/dev/null || true) == installed ]]; then
      installed=$(dpkg-query -W '-f=${Version}' code)
      installed=${installed%%-*}
    fi
  else
    channel=rpm
    if rpm -q code >/dev/null 2>&1; then installed=$(rpm -q --qf '%{VERSION}' code); fi
  fi
  code_package() {
    local arch version url digest
    if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
      if [[ -n ${installed} ]]; then jsh::notice 'would check for a VS Code update'; else jsh::emit added vscode package; fi
      return
    fi
    case $(uname -m) in x86_64) arch=x64 ;; aarch64 | arm64) arch=arm64 ;;
    *)
      jsh::notice 'VS Code requires x86_64 or aarch64'
      return 1
      ;;
    esac
    jsh::download "https://update.code.visualstudio.com/api/update/linux-${channel}-${arch}/stable/latest" "${APP_TMP}/release.json"
    version=$(jq -er .productVersion "${APP_TMP}/release.json")
    if [[ ${installed} == "${version}" ]]; then
      jsh::current vscode
      return
    fi
    if ! jsh::admin; then
      jsh::notice "needs sudo to install VS Code ${version}; run sudo -v first, then rerun"
      return
    fi
    url=$(jq -er .url "${APP_TMP}/release.json")
    digest=$(jq -er .sha256hash "${APP_TMP}/release.json")
    app::download "${url}" "${APP_TMP}/vscode.${channel}" "${digest}"
    if [[ ${channel} == deb ]]; then
      jsh::task "Installing VS Code ${version}" jsh::root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APP_TMP}/vscode.deb"
    else
      jsh::task "Installing VS Code ${version}" jsh::root dnf install -y "${APP_TMP}/vscode.rpm"
    fi
    if [[ -n ${installed} ]]; then jsh::emit changed "vscode ${installed} → ${version}" package; else jsh::emit added vscode package; fi
  }
  if [[ -n ${installed} ]]; then
    [[ ${JSH_UPDATE:-0} != 1 ]] || code_package
  elif [[ ${JSH_UPDATE:-0} != 1 ]] && ! command -v code >/dev/null 2>&1; then
    code_package
  fi
fi
if ! command -v code >/dev/null 2>&1 && [[ ! -d ${directory} ]]; then exit 0; fi
cp "${SCRIPT_DIR}/vscode/settings.json" "${APP_TMP}/settings.json"
jsh::activity 'Preparing VS Code settings'
if command -v zsh >/dev/null 2>&1; then
  key=linux
  [[ $(uname -s) != Darwin ]] || key=osx
  jq --arg key "${key}" --arg shell "$(command -v zsh)" \
    '.["terminal.integrated.profiles." + $key] = {zsh: {path: $shell}} |
      .["terminal.integrated.defaultProfile." + $key] = "zsh"' \
    "${APP_TMP}/settings.json" >"${APP_TMP}/settings-shell.json"
  mv "${APP_TMP}/settings-shell.json" "${APP_TMP}/settings.json"
fi
app::json "${APP_TMP}/settings.json" "${directory}/settings.json"
jsh::link "${SCRIPT_DIR}/vscode/keybindings.json" "${directory}/keybindings.json"
