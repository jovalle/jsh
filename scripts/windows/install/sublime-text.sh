#!/usr/bin/env bash
# Install Windows Sublime Text Build 4200 through its official installer from WSL.
# shellcheck disable=SC2016

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

install_sublime_text() {
  local app_path build installer installer_path
  if [[ -n ${SUBLIME_BINARY:-} ]]; then
    app_path=$(wslpath -w "${SUBLIME_BINARY%/*}")
  elif [[ -n ${SUBLIME_APP_PATH:-} ]]; then
    app_path=$(wslpath -w "${SUBLIME_APP_PATH}")
  else
    app_path=$(powershell.exe -NoProfile -NonInteractive -Command '
      foreach ($path in @("$env:LOCALAPPDATA\Programs\Sublime Text", "$env:ProgramFiles\Sublime Text")) {
        if (Test-Path -LiteralPath "$path\sublime_text.exe") { Write-Output $path; exit 0 }
      }; Write-Output "$env:ProgramFiles\Sublime Text"' | tr -d '\r')
  fi
  app_path=${app_path//\'/\'\'}
  build=$(powershell.exe -NoProfile -NonInteractive -Command \
    "if (Test-Path -LiteralPath '${app_path}\sublime_text.exe') { (Get-Item -LiteralPath '${app_path}\sublime_text.exe').VersionInfo.FileVersion }" | tr -d '\r')
  if [[ ${build} == 4200 ]]; then
    jsh::log_note 'Windows Sublime Text Build 4200 is already installed.'
    return 0
  fi
  if [[ -n ${build} ]]; then
    jsh::confirm "Replace Windows Sublime Text Build ${build} with Build 4200?" --default yes || {
      local confirmation_status=$?
      [[ ${confirmation_status} -eq 1 ]] || return "${confirmation_status}"
      jsh::log_note "Keeping Windows Sublime Text Build ${build}."
      return 0
    }
  fi
  if powershell.exe -NoProfile -NonInteractive -Command \
    "if (Get-Process sublime_text -ErrorAction SilentlyContinue | Where-Object Path -eq '${app_path}\sublime_text.exe') { exit 0 }; exit 1"; then
    jsh::confirm_app_close 'Windows Sublime Text is running. Quit it now?' --default yes || {
      local confirmation_status=$?
      [[ ${confirmation_status} -eq 1 ]] || return "${confirmation_status}"
      jsh_update_defer 'Windows Sublime Text installation' 'Sublime Text remains open' 'jsh update --close-apps sublime-text'
      return 0
    }
    powershell.exe -NoProfile -NonInteractive -Command \
      "\$ErrorActionPreference = 'Stop'; Get-Process sublime_text -ErrorAction SilentlyContinue | Where-Object Path -eq '${app_path}\sublime_text.exe' | ForEach-Object { [void]\$_.CloseMainWindow(); \$_.WaitForExit(15000) | Out-Null; if (!\$_.HasExited) { throw 'Sublime Text remains open; finish saving and retry.' } }" || return
  fi
  installer=$(jsh_download_artifact sublime-text-windows 4200 \
    https://download.sublimetext.com/sublime_text_build_4200_x64_setup.exe .exe \
    3d3c70e51aef08f85d7160bcc70793bed9acec250973090ab67d98987bce7c7e) || return
  installer_path=$(wslpath -w "${installer}")
  installer_path=${installer_path//\'/\'\'}
  powershell.exe -NoProfile -NonInteractive -Command \
    "\$ErrorActionPreference = 'Stop'; \$installerArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', '/DIR=\"${app_path}\"'); \$p = Start-Process -FilePath '${installer_path}' -ArgumentList \$installerArguments -Verb RunAs -Wait -PassThru; exit \$p.ExitCode" || return
  build=$(powershell.exe -NoProfile -NonInteractive -Command \
    "(Get-Item -LiteralPath '${app_path}\sublime_text.exe').VersionInfo.FileVersion" | tr -d '\r') || return
  [[ ${build} == 4200 ]] || {
    jsh::log_error "Windows Sublime Text installation did not produce Build 4200 (got ${build})."
    return 1
  }
  jsh::log_success 'Windows Sublime Text Build 4200 installed.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_sublime_text
fi
