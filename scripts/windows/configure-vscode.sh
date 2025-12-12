#!/usr/bin/env bash
# Create symlink for VSCode settings.json (requires elevation)

# Get Windows User Profile path
WIN_USER_PROFILE=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
if [[ -z "$WIN_USER_PROFILE" ]]; then
    echo "Error: Could not determine Windows User Profile."
    exit 1
fi

WSL_USER_PROFILE=$(wslpath "$WIN_USER_PROFILE")
VSCODE_USER_DIR="${WSL_USER_PROFILE}/AppData/Roaming/Code/User"
SETTINGS_SRC="${HOME}/.jsh/configs/vscode/settings.json"

# Check if VSCode is installed
if [[ ! -d "$VSCODE_USER_DIR" ]]; then
  echo "Error: VSCode User directory not found at $VSCODE_USER_DIR"
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
