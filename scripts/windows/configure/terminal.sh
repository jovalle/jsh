#!/usr/bin/env bash
# Link the managed Windows Terminal settings from WSL into Windows.

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
SETTINGS_SRC="${JSH_ROOT}/dotfiles/.config/windows-terminal/settings.json"
if [[ ! -f "${SETTINGS_SRC}" ]]; then
  jsh_warn "Skipping Windows Terminal configuration: source file not found"
  exit 0
fi

LOCAL_APP_DATA=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("LocalApplicationData")' | tr -d '\r')
TERMINAL_SETTINGS_DIR="${LOCAL_APP_DATA}\\Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState"

# Check if Windows Terminal is installed
TERMINAL_DIR_WSL=$(wslpath -u "${TERMINAL_SETTINGS_DIR}")
if [[ ! -d "${TERMINAL_DIR_WSL}" ]]; then
  jsh_warn "Skipping Windows Terminal configuration: application not found"
  exit 0
fi

jsh_info "Configuring Windows Terminal settings..."

# Convert WSL path to Windows path
SETTINGS_SRC_WIN=$(wslpath -w "${SETTINGS_SRC}")
SETTINGS_DEST_WIN="${TERMINAL_SETTINGS_DIR}\\settings.json"

if powershell.exe -NoProfile -Command "\$item = Get-Item -LiteralPath '${SETTINGS_DEST_WIN}' -ErrorAction SilentlyContinue; if (\$null -ne \$item -and \$item.LinkType -eq 'SymbolicLink' -and \$item.Target -contains '${SETTINGS_SRC_WIN}') { exit 0 }; exit 1"; then
  jsh_success "Windows Terminal is already configured."
  exit 0
fi

jsh_info "Creating symlink: ${SETTINGS_DEST_WIN} -> ${SETTINGS_SRC_WIN}"
jsh_warn "The existing settings file may be replaced."
jsh_prompt "Configure Windows Terminal? [y/N]: "
read -r CONFIRM || CONFIRM=
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  jsh_warn "Skipping Windows Terminal configuration."
  exit 0
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"New-Item -ItemType SymbolicLink -Path ''${SETTINGS_DEST_WIN}'' -Target ''${SETTINGS_SRC_WIN}'' -Force\"' -Verb RunAs -Wait"

# Validate
jsh_blank
jsh_info "Validating symlink..."
LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '${SETTINGS_DEST_WIN}' | Select-Object LinkType, Target | Format-List" 2>&1)
if echo "${LINK_INFO}" | grep -q "SymbolicLink"; then
  jsh_success "Symlink created successfully"
  echo "${LINK_INFO}"
else
  jsh_error "Symlink validation failed"
  exit 1
fi
