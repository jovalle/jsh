#!/bin/bash
# Create symlink for Windows Terminal settings (requires elevation)

SETTINGS_SRC="$HOME/.config/windows-terminal/settings.json"
TERMINAL_SETTINGS_DIR="\$([Environment]::GetEnvironmentVariable('LOCALAPPDATA'))\\Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState"

# Check if Windows Terminal is installed
TERMINAL_DIR_WSL=$(echo "$TERMINAL_SETTINGS_DIR" | sed 's|\\|/|g' | sed 's|$([Environment]::GetEnvironmentVariable('\''LOCALAPPDATA'\''))|/mnt/c/Users/jay/AppData/Local|')
if [ ! -d "$TERMINAL_DIR_WSL" ]; then
  echo "Error: Windows Terminal not found (check if installed)"
  exit 1
fi

echo "Configuring Windows Terminal settings..."

# Convert WSL path to Windows path
SETTINGS_SRC_WIN=$(wslpath -w "$SETTINGS_SRC")
SETTINGS_DEST_WIN="$TERMINAL_SETTINGS_DIR\\settings.json"

echo "Creating symlink: $SETTINGS_DEST_WIN -> $SETTINGS_SRC_WIN"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"New-Item -ItemType SymbolicLink -Path ''$SETTINGS_DEST_WIN'' -Target ''$SETTINGS_SRC_WIN'' -Force\"' -Verb RunAs -Wait"

# Validate
echo ""
echo "Validating symlink..."
LINK_INFO=$(powershell.exe -NoProfile -Command "Get-Item '$SETTINGS_DEST_WIN' | Select-Object LinkType, Target | Format-List" 2>&1)
if echo "$LINK_INFO" | grep -q "SymbolicLink"; then
  echo "✓ Symlink created successfully"
  echo "$LINK_INFO"
else
  echo "✗ Error: Symlink validation failed"
  exit 1
fi
