#!/bin/bash
# Create symlinks for SSH config and key from WSL to Windows (requires elevation)

KEY_SOURCE=$(wslpath -w ~/.jsh/.ssh/id_rsa)
CONFIG_SOURCE=$(wslpath -w ~/.jsh/.ssh/config-windows)
DEST_DIR="C:\\Users\\jay\\.ssh"
KEY_DEST="${DEST_DIR}\\id_rsa"
CONFIG_DEST="${DEST_DIR}\\config"

echo "Creating symlinks for SSH files from WSL to Windows..."
echo "Key source: ${KEY_SOURCE} -> ${KEY_DEST}"
echo "Config source: ${CONFIG_SOURCE} -> ${CONFIG_DEST}"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"if (!(Test-Path ''${DEST_DIR}'')) { New-Item -ItemType Directory -Path ''${DEST_DIR}'' -Force | Out-Null }; if (Test-Path ''${KEY_DEST}'') { Remove-Item ''${KEY_DEST}'' -Force }; if (Test-Path ''${CONFIG_DEST}'') { Remove-Item ''${CONFIG_DEST}'' -Force }; New-Item -ItemType SymbolicLink -Path ''${KEY_DEST}'' -Target ''${KEY_SOURCE}'' -Force | Out-Null; New-Item -ItemType SymbolicLink -Path ''${CONFIG_DEST}'' -Target ''${CONFIG_SOURCE}'' -Force | Out-Null\"' -Verb RunAs -Wait"

echo ""
echo "Validating symlinks..."
KEY_LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '${KEY_DEST}' | Select-Object LinkType, Target | Format-List" 2>&1)
CONFIG_LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '${CONFIG_DEST}' | Select-Object LinkType, Target | Format-List" 2>&1)

if echo "${KEY_LINK_INFO}" | grep -q "SymbolicLink" && echo "${CONFIG_LINK_INFO}" | grep -q "SymbolicLink"; then
  echo "✓ SSH key symlink created successfully"
  echo "${KEY_LINK_INFO}"
  echo "✓ SSH config symlink created successfully"
  echo "${CONFIG_LINK_INFO}"
else
  echo "✗ Error: Symlink validation failed"
  exit 1
fi
