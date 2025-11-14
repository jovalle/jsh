#!/usr/bin/env bash
# Create symlink for VSCode settings.json (requires elevation)

SETTINGS_SRC="${HOME}/.jsh/configs/vscode/settings.json"
VSCODE_USER_DIR="C:\\Users\\jay\\AppData\\Roaming\\Code\\User"

# Check if VSCode is installed
if [[ ! -d "/mnt/c/Users/jay/AppData/Roaming/Code" ]]; then
  echo "Error: VSCode not found (check if installed)"
  exit 1
fi

echo "Configuring VSCode settings..."

# Convert WSL path to Windows path
SETTINGS_SRC_WIN=$(wslpath -w "${SETTINGS_SRC}")
SETTINGS_DEST_WIN="${VSCODE_USER_DIR}\\settings.json"

echo "Creating symlink: ${SETTINGS_DEST_WIN} -> ${SETTINGS_SRC_WIN}"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"New-Item -ItemType SymbolicLink -Path ''${SETTINGS_DEST_WIN}'' -Target ''${SETTINGS_SRC_WIN}'' -Force\"' -Verb RunAs -Wait"

# Validate
echo ""
echo "Validating symlink..."
LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '${SETTINGS_DEST_WIN}' | Select-Object LinkType, Target | Format-List" 2>&1)
if echo "${LINK_INFO}" | grep -q "SymbolicLink"; then
  echo "✓ Symlink created successfully"
  echo "${LINK_INFO}"
else
  echo "✗ Error: Symlink validation failed"
  exit 1
fi
