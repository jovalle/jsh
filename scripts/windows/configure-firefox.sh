#!/bin/bash
# Configure Firefox using Mozilla Autoconfig (applies to all profiles, current and future; requires elevation)

# Firefox installation directory
FF_INSTALL="/mnt/c/Program Files/Mozilla Firefox"
FF_DEFAULTS_PREF="$FF_INSTALL/defaults/pref"

# Source files
AUTOCONFIG_SRC="$HOME/.jsh/configs/firefox/autoconfig.js"
USERJS_SRC="$HOME/.jsh/configs/firefox/user.js"

# Check if Firefox is installed
if [ ! -d "$FF_INSTALL" ]; then
  echo "Error: Firefox not found at $FF_INSTALL"
  exit 1
fi

echo "Configuring Firefox using Mozilla Autoconfig..."
echo "This will apply settings to ALL profiles (current and future)"
echo ""

# Create defaults/pref directory if it doesn't exist
if [ ! -d "$FF_DEFAULTS_PREF" ]; then
  echo "Creating defaults/pref directory..."
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"New-Item -ItemType Directory -Path ''$(wslpath -w "$FF_DEFAULTS_PREF")'' -Force\"' -Verb RunAs -Wait"
fi

# Convert WSL paths to Windows paths
AUTOCONFIG_SRC_WIN=$(wslpath -w "$AUTOCONFIG_SRC")
USERJS_SRC_WIN=$(wslpath -w "$USERJS_SRC")
AUTOCONFIG_DEST_WIN="$(wslpath -w "$FF_DEFAULTS_PREF")\\autoconfig.js"
USERJS_DEST_WIN="$(wslpath -w "$FF_INSTALL")\\user.js"

echo "1. Installing autoconfig.js to defaults/pref..."
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"Copy-Item -Path ''$AUTOCONFIG_SRC_WIN'' -Destination ''$AUTOCONFIG_DEST_WIN'' -Force\"' -Verb RunAs -Wait"

if powershell.exe -NoProfile -Command "Test-Path '$AUTOCONFIG_DEST_WIN'" | grep -q "True"; then
  echo "  ✓ autoconfig.js installed"
else
  echo "  ✗ Failed to install autoconfig.js"
  exit 1
fi

echo ""
echo "2. Installing user.js to Firefox root..."
echo "   Converting user_pref() to pref() for autoconfig compatibility..."

# Create a modified user.js with comment line and converted prefs
TEMP_USERJS="/tmp/firefox-user.js"
echo "// Mozilla Autoconfig" > "$TEMP_USERJS"
sed 's/user_pref(/pref(/g' "$USERJS_SRC" >> "$TEMP_USERJS"

TEMP_USERJS_WIN=$(wslpath -w "$TEMP_USERJS")
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"Copy-Item -Path ''$TEMP_USERJS_WIN'' -Destination ''$USERJS_DEST_WIN'' -Force\"' -Verb RunAs -Wait"

if powershell.exe -NoProfile -Command "Test-Path '$USERJS_DEST_WIN'" | grep -q "True"; then
  echo "  ✓ user.js installed"
else
  echo "  ✗ Failed to install user.js"
  rm -f "$TEMP_USERJS"
  exit 1
fi

rm -f "$TEMP_USERJS"

echo ""
echo "✓ Firefox autoconfig setup complete!"
echo ""
echo "Configuration will apply to:"
echo "  • All existing profiles"
echo "  • All new profiles created in the future"
echo ""
echo "To apply changes, restart Firefox."
