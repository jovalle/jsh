#!/usr/bin/env bash
#
# configure-ghostty-aliases.sh - Create launcher apps for Ghostty
#
# This script creates an AppleScript wrapper application as a lazy shortcut to Ghostty
# and replacement for the OG Terminal.app.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if Ghostty is installed
if [[ ! -d "/Applications/Ghostty.app" ]]; then
    log_error "Ghostty.app not found in /Applications"
    log_error "Please install Ghostty first"
    exit 1
fi

log_info "Creating Ghostty launcher applications..."

# Create temporary AppleScript file
SCRIPT_FILE="/tmp/launch_ghostty.scpt"
cat > "$SCRIPT_FILE" << 'EOF'
do shell script "open -a Ghostty"
EOF

# Determine icon source (prefer custom, fallback to system Terminal.app)
ICON_SOURCE=""
CUSTOM_ICON="$HOME/.jsh/configs/macos/icons/terminal.icns"
SYSTEM_ICON="/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns"

if [[ -f "$CUSTOM_ICON" ]]; then
    ICON_SOURCE="$CUSTOM_ICON"
    log_info "Using custom Terminal icon from repository"
elif [[ -f "$SYSTEM_ICON" ]]; then
    ICON_SOURCE="$SYSTEM_ICON"
    log_info "Using system Terminal.app icon"
else
    log_warn "No Terminal icon found, apps will use default AppleScript icon"
fi

# Create launcher apps
app_path="/Applications/Terminal.app"

log_info "Creating Terminal.app..."
osacompile -o "$app_path" "$SCRIPT_FILE"

# Copy Terminal icon if we found one
if [[ -n "$ICON_SOURCE" ]]; then
    log_info "Copying Terminal icon to Terminal.app..."
    mkdir -p "${app_path}/Contents/Resources"
    cp "$ICON_SOURCE" "${app_path}/Contents/Resources/applet.icns"

    # Update icon cache
    touch "$app_path"
fi

# Force Spotlight to index the new app
log_info "Indexing Terminal.app in Spotlight..."
mdimport "$app_path" 2>/dev/null || true

log_info "✓ Terminal.app created successfully"

# Cleanup
rm -f "$SCRIPT_FILE"

log_info "Done! You can now use Spotlight to search for 'term' or 'terminal' to launch Ghostty"
log_info "Note: It may take a minute for Spotlight to fully index the new apps"
