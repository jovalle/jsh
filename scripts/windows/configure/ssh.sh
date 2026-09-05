#!/usr/bin/env bash
# Link the managed SSH config and key from WSL into Windows.

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
if [[ ! -f "${JSH_ROOT}/dotfiles/.ssh/id_rsa" || ! -f "${JSH_ROOT}/dotfiles/.ssh/config-windows" ]]; then
  jsh_warn "Skipping Windows SSH configuration: source files not found"
  exit 0
fi

KEY_SOURCE=$(wslpath -w "${JSH_ROOT}/dotfiles/.ssh/id_rsa")
CONFIG_SOURCE=$(wslpath -w "${JSH_ROOT}/dotfiles/.ssh/config-windows")
WINDOWS_HOME=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' | tr -d '\r')
DEST_DIR="${WINDOWS_HOME}\\.ssh"
KEY_DEST="${DEST_DIR}\\id_rsa"
CONFIG_DEST="${DEST_DIR}\\config"

windows_link_matches() {
  local destination="$1"
  local target="$2"

  powershell.exe -NoProfile -Command "\$item = Get-Item -LiteralPath '${destination}' -ErrorAction SilentlyContinue; if (\$null -ne \$item -and \$item.LinkType -eq 'SymbolicLink' -and \$item.Target -contains '${target}') { exit 0 }; exit 1"
}

if windows_link_matches "${KEY_DEST}" "${KEY_SOURCE}" &&
  windows_link_matches "${CONFIG_DEST}" "${CONFIG_SOURCE}"; then
  jsh_success "Windows SSH is already configured."
  exit 0
fi

jsh_info "Creating symlinks for SSH files from WSL to Windows..."
jsh_detail "Key source: ${KEY_SOURCE} -> ${KEY_DEST}"
jsh_detail "Config source: ${CONFIG_SOURCE} -> ${CONFIG_DEST}"
jsh_warn "Existing destination files will be replaced."
jsh_prompt "Configure Windows SSH? [y/N]: "
read -r CONFIRM || CONFIRM=
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  jsh_warn "Skipping Windows SSH configuration."
  exit 0
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"if (!(Test-Path ''${DEST_DIR}'')) { New-Item -ItemType Directory -Path ''${DEST_DIR}'' -Force | Out-Null }; if (Test-Path ''${KEY_DEST}'') { Remove-Item ''${KEY_DEST}'' -Force }; if (Test-Path ''${CONFIG_DEST}'') { Remove-Item ''${CONFIG_DEST}'' -Force }; New-Item -ItemType SymbolicLink -Path ''${KEY_DEST}'' -Target ''${KEY_SOURCE}'' -Force | Out-Null; New-Item -ItemType SymbolicLink -Path ''${CONFIG_DEST}'' -Target ''${CONFIG_SOURCE}'' -Force | Out-Null\"' -Verb RunAs -Wait"

jsh_blank
jsh_info "Validating symlinks..."
KEY_LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '${KEY_DEST}' | Select-Object LinkType, Target | Format-List" 2>&1)
CONFIG_LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '${CONFIG_DEST}' | Select-Object LinkType, Target | Format-List" 2>&1)

if echo "${KEY_LINK_INFO}" | grep -q "SymbolicLink" && echo "${CONFIG_LINK_INFO}" | grep -q "SymbolicLink"; then
  jsh_success "SSH key symlink created successfully"
  echo "${KEY_LINK_INFO}"
  jsh_success "SSH config symlink created successfully"
  echo "${CONFIG_LINK_INFO}"
else
  jsh_error "Symlink validation failed"
  exit 1
fi
