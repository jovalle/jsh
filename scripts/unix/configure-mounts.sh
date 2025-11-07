#!/bin/bash
# Configure and mount SMB shares

# Generic config file (stowed from .jsh/.mounts.json to ~/.mounts.json, synced via Syncthing)
CONFIG_FILE="${HOME}/.mounts.json"

# Detect OS
if [[ "${OSTYPE}" == "darwin"* ]]; then
  IS_MACOS=true
else
  IS_MACOS=false
fi

# Get mount name from first argument or default to "media"
MOUNT_NAME="${1:-media}"

# Helper function to read from JSON config
read_config() {
  local key="$1"
  local mount_name="$2"

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return 1
  fi

  # Simple JSON parsing for our schema
  if [[ "${key}" == "share" ]]; then
    grep -A 20 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"share":' | cut -d'"' -f4
  elif [[ "${key}" == "mount_point" ]]; then
    # Check for OS-specific mount point first
    local os_type
    if [[ "${IS_MACOS}" == true ]]; then
      os_type="darwin"
    else
      os_type="linux"
    fi

    # Try OS-specific path first
    local mount_section
    mount_section=$(grep -A 20 "\"${mount_name}\":" "${CONFIG_FILE}")
    local os_mount
    os_mount=$(echo "${mount_section}" | grep -A 5 '"mount_point":' | grep "\"${os_type}\":" | cut -d'"' -f4)

    if [[ -n "${os_mount}" ]]; then
      echo "${os_mount}"
    else
      # Fall back to universal mount_point (string value)
      echo "${mount_section}" | grep '"mount_point":' | grep -v '{' | cut -d'"' -f4
    fi
  elif [[ "${key}" == "credential" ]]; then
    grep -A 20 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"credential":' | cut -d'"' -f4
  elif [[ "${key}" == "username" ]]; then
    grep -A 5 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"username":' | cut -d'"' -f4
  elif [[ "${key}" == "password" ]]; then
    grep -A 5 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"password":' | cut -d'"' -f4
  fi
}

# Helper function to initialize config file if it doesn't exist
init_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}"
    echo ""
    echo -n "Create sample configuration with documentation? [Y/n]: "
    read -r CREATE_SAMPLE

    if [[ "${CREATE_SAMPLE}" =~ ^[Nn]$ ]]; then
      # Create minimal config
      cat > "${CONFIG_FILE}" <<'EOF'
{
  "credentials": {},
  "mounts": {}
}
EOF
      chmod 600 "${CONFIG_FILE}"
      echo "✓ Created minimal config file: ${CONFIG_FILE}"
    else
      # Create sample config with documentation
      cat > "${CONFIG_FILE}" <<'EOF'
{
  "_comment": "SMB/CIFS Mounts Configuration",
  "_documentation": {
    "description": "Configuration file for managing SMB/CIFS mounts across Linux and macOS",
    "usage": {
      "configure_mount": "task mount [mount_name]  # Configure and mount a share",
      "default_mount": "task mount                 # Uses 'media' as default",
      "new_mount": "task mount newshare            # Interactive setup for new mount"
    },
    "schema": {
      "credentials": "Named credential sets that can be reused across multiple mounts",
      "mounts": "Mount configurations with share paths and mount points"
    },
    "mount_point_options": {
      "os_specific": {
        "description": "Different paths for different operating systems (recommended)",
        "example": {
          "darwin": "/Volumes/media",
          "linux": "/mnt/media"
        }
      },
      "universal": {
        "description": "Same path on all operating systems",
        "example": "/shared/media"
      }
    },
    "shared_credentials": {
      "description": "Multiple mounts can reference the same credential set",
      "example": "Both 'media' and 'data' mounts can use 'home' credentials"
    },
    "auto_mount_macos": {
      "description": "LaunchAgents created per-mount for automatic mounting",
      "features": [
        "Mounts at login",
        "Re-mounts every 5 minutes if disconnected",
        "Logs at ~/Library/Logs/com.user.smbmount.<mount_name>.{out,err}"
      ]
    },
    "scripts": {
      "configure": "~/.jsh/scripts/unix/configure-mounts.sh",
      "auto_mount": "~/.jsh/scripts/unix/mount-smb.sh"
    }
  },
  "credentials": {
    "home": {
      "username": "your_username",
      "password": "your_password"
    }
  },
  "mounts": {
    "media": {
      "share": "//nas.local/media",
      "mount_point": {
        "darwin": "/Volumes/media",
        "linux": "/mnt/media"
      },
      "credential": "home"
    },
    "data": {
      "share": "//nas.local/data",
      "mount_point": {
        "darwin": "/Volumes/data",
        "linux": "/mnt/data"
      },
      "credential": "home"
    },
    "public": {
      "share": "//server.local/public",
      "mount_point": "/mnt/public",
      "credential": ""
    }
  }
}
EOF
      chmod 600 "${CONFIG_FILE}"
      echo "✓ Created sample config file: ${CONFIG_FILE}"
      echo ""
      echo "📝 Sample configuration created with example mounts."
      echo "   Edit ${CONFIG_FILE} to add your actual shares and credentials."
      echo ""
      echo "   The file includes comprehensive documentation about:"
      echo "   - Configuration schema and options"
      echo "   - Mount point configurations (OS-specific vs universal)"
      echo "   - Shared credentials across mounts"
      echo "   - Auto-mount features (macOS)"
      echo ""
    fi
  fi
}

# Helper function to save mount configuration
save_config() {
  local mount_name="$1"
  local share="$2"
  local mount_point="$3"
  local cred_name="$4"
  local username="$5"
  local password="$6"

  python3 <<PYTHON_EOF
import json
import sys

config_file = "${CONFIG_FILE}"
is_macos = "${IS_MACOS}" == "true"

try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except:
    config = {"credentials": {}, "mounts": {}}

# Save credentials if provided
if "${cred_name}" and "${username}":
    config["credentials"]["${cred_name}"] = {
        "username": "${username}",
        "password": "${password}"
    }

# Get existing mount config or create new
if "${mount_name}" not in config["mounts"]:
    config["mounts"]["${mount_name}"] = {}

mount_config = config["mounts"]["${mount_name}"]

# Update share
mount_config["share"] = "${share}"

# Handle mount_point - check if it's already an object (OS-specific)
if isinstance(mount_config.get("mount_point"), dict):
    # Already OS-specific, update the appropriate key
    if is_macos:
        mount_config["mount_point"]["darwin"] = "${mount_point}"
    else:
        mount_config["mount_point"]["linux"] = "${mount_point}"
else:
    # Check if this is a default path pattern
    if (is_macos and "${mount_point}".startswith("/Volumes/")) or \
       (not is_macos and "${mount_point}".startswith("/mnt/")):
        # Create OS-specific structure
        mount_config["mount_point"] = {
            "darwin": "/Volumes/${mount_name}" if is_macos else "/Volumes/${mount_name}",
            "linux": "/mnt/${mount_name}" if not is_macos else "/mnt/${mount_name}"
        }
        # Override with actual value for current OS
        if is_macos:
            mount_config["mount_point"]["darwin"] = "${mount_point}"
        else:
            mount_config["mount_point"]["linux"] = "${mount_point}"
    else:
        # Universal mount point
        mount_config["mount_point"] = "${mount_point}"

# Update credential reference
if "${cred_name}":
    mount_config["credential"] = "${cred_name}"

# Write back to file
with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print("✓ Configuration saved")
PYTHON_EOF

  chmod 600 "${CONFIG_FILE}"
}

# Try to load configuration for this mount
SMB_SHARE=$(read_config "share" "${MOUNT_NAME}")
MOUNT_POINT=$(read_config "mount_point" "${MOUNT_NAME}")
CREDENTIAL_NAME=$(read_config "credential" "${MOUNT_NAME}")

# Set default mount point if not configured
if [[ -z "${MOUNT_POINT}" ]]; then
  if [[ "${IS_MACOS}" == true ]]; then
    MOUNT_POINT="/Volumes/${MOUNT_NAME}"
  else
    MOUNT_POINT="/mnt/${MOUNT_NAME}"
  fi
fi

# Check if already configured or mounted
IS_CONFIGURED=false
if [[ "${IS_MACOS}" == false ]] && grep -q "${MOUNT_POINT}" /etc/fstab 2>/dev/null; then
  IS_CONFIGURED=true
  echo "✓ Mount already configured in /etc/fstab for ${MOUNT_POINT}"
elif mount | grep -q " on ${MOUNT_POINT} "; then
  IS_CONFIGURED=true
  echo "✓ Mount already active at ${MOUNT_POINT}"
fi

if [[ "${IS_CONFIGURED}" == true ]]; then
  # Check if already mounted
  if mount | grep -q " on ${MOUNT_POINT} "; then
    echo "✓ ${MOUNT_POINT} is currently mounted"
    df -h "${MOUNT_POINT}"
  fi

  echo ""
  echo -n "Reconfigure? [y/N]: "
  read -r RECONFIGURE
  if [[ ! "${RECONFIGURE}" =~ ^[Yy]$ ]]; then
    echo "Keeping existing configuration."
    exit 0
  fi

  echo "Reconfiguring..."
fi

# Initialize config file if needed
init_config

# Prompt for SMB share if not configured
if [[ -z "${SMB_SHARE}" ]]; then
  echo -n "Enter SMB share (e.g., //server/share): "
  read -r SMB_SHARE
  if [[ -z "${SMB_SHARE}" ]]; then
    echo "ERROR: SMB share is required"
    exit 1
  fi
fi

echo "Mount Name: ${MOUNT_NAME}"
echo "SMB Share: ${SMB_SHARE}"
echo "Mount Point: ${MOUNT_POINT}"
echo ""

# Handle credentials
SMB_USER=""
SMB_PASS=""

# Check if mount already has a credential reference
if [[ -n "${CREDENTIAL_NAME}" ]]; then
  # Try to read credential from config
  CRED_USER=$(grep -A 5 "\"credentials\":" "${CONFIG_FILE}" | grep -A 3 "\"${CREDENTIAL_NAME}\":" | grep '"username":' | cut -d'"' -f4)
  CRED_PASS=$(grep -A 5 "\"credentials\":" "${CONFIG_FILE}" | grep -A 3 "\"${CREDENTIAL_NAME}\":" | grep '"password":' | cut -d'"' -f4)

  if [[ -n "${CRED_USER}" ]]; then
    echo "✓ Using existing credential set: ${CREDENTIAL_NAME}"
    echo -n "Update credentials? [y/N]: "
    read -r UPDATE_CREDS

    if [[ "${UPDATE_CREDS}" =~ ^[Yy]$ ]]; then
      echo -n "Username [${CRED_USER}]: "
      read -r SMB_USER
      SMB_USER="${SMB_USER:-${CRED_USER}}"

      echo -n "Password: "
      stty -echo
      read -r SMB_PASS
      stty echo
      echo ""
    else
      SMB_USER="${CRED_USER}"
      SMB_PASS="${CRED_PASS}"
    fi
  fi
else
  # Ask if authentication is needed
  echo -n "Does this share require authentication? [Y/n]: "
  read -r AUTH_REQUIRED

  if [[ ! "${AUTH_REQUIRED}" =~ ^[Nn]$ ]]; then
    # Check if there are existing credentials we can reuse
    EXISTING_CREDS=$(grep -A 1000 '"credentials":' "${CONFIG_FILE}" | grep -B 1 '"username":' | grep -v username | grep '"' | cut -d'"' -f2 | head -5)

    if [[ -n "${EXISTING_CREDS}" ]]; then
      echo ""
      echo "Existing credential sets:"
      echo "${EXISTING_CREDS}" | nl
      echo ""
      echo -n "Use existing credentials? Enter number or 'n' for new: "
      read -r CRED_CHOICE

      if [[ "${CRED_CHOICE}" =~ ^[0-9]+$ ]]; then
        CREDENTIAL_NAME=$(echo "${EXISTING_CREDS}" | sed -n "${CRED_CHOICE}p")
        SMB_USER=$(grep -A 5 "\"credentials\":" "${CONFIG_FILE}" | grep -A 3 "\"${CREDENTIAL_NAME}\":" | grep '"username":' | cut -d'"' -f4)
        SMB_PASS=$(grep -A 5 "\"credentials\":" "${CONFIG_FILE}" | grep -A 3 "\"${CREDENTIAL_NAME}\":" | grep '"password":' | cut -d'"' -f4)
        echo "✓ Using credential set: ${CREDENTIAL_NAME}"
      fi
    fi

    # If no existing creds selected, prompt for new
    if [[ -z "${SMB_USER}" ]]; then
      echo -n "Credential set name [default]: "
      read -r CREDENTIAL_NAME
      CREDENTIAL_NAME="${CREDENTIAL_NAME:-default}"

      echo -n "Username: "
      read -r SMB_USER

      echo -n "Password: "
      stty -echo
      read -r SMB_PASS
      stty echo
      echo ""

      if [[ -z "${SMB_USER}" ]] || [[ -z "${SMB_PASS}" ]]; then
        echo "ERROR: Username and password are required for authenticated mounts"
        exit 1
      fi
    fi
  fi
fi

  # Save configuration
save_config "${MOUNT_NAME}" "${SMB_SHARE}" "${MOUNT_POINT}" "${CREDENTIAL_NAME}" "${SMB_USER}" "${SMB_PASS}"

if [[ "${IS_MACOS}" == false ]]; then
  # LINUX SETUP
  # Ensure cifs-utils is installed
  if ! command -v mount.cifs &> /dev/null; then
    echo "Installing cifs-utils..."
    sudo apt update && sudo apt install -y cifs-utils
  fi

  # Create mount point if it doesn't exist
  if [[ ! -d "${MOUNT_POINT}" ]]; then
    echo "Creating mount point: ${MOUNT_POINT}"
    sudo mkdir -p "${MOUNT_POINT}"
  fi

  # Build fstab entry
  if [[ -n "${SMB_USER}" ]]; then
    # Create a temporary credentials file for this mount (fstab requires a file)
    TEMP_CREDS_FILE="${HOME}/.smbcredentials_${MOUNT_NAME}"
    echo "username=${SMB_USER}" > "${TEMP_CREDS_FILE}"
    echo "password=${SMB_PASS}" >> "${TEMP_CREDS_FILE}"
    chmod 600 "${TEMP_CREDS_FILE}"
    FSTAB_ENTRY="${SMB_SHARE} ${MOUNT_POINT} cifs credentials=${TEMP_CREDS_FILE},uid=$(id -u),gid=$(id -g),file_mode=0755,dir_mode=0755,nofail 0 0"
  else
    FSTAB_ENTRY="${SMB_SHARE} ${MOUNT_POINT} cifs guest,uid=$(id -u),gid=$(id -g),file_mode=0755,dir_mode=0755,nofail 0 0"
  fi

  # Update fstab entry
  if grep -q "${MOUNT_POINT}" /etc/fstab 2>/dev/null; then
    echo "Updating /etc/fstab entry..."
    # Unmount if currently mounted
    if mount | grep -q " on ${MOUNT_POINT} "; then
      sudo umount "${MOUNT_POINT}"
    fi
    # Remove old entry and add new one
    sudo sed -i "\|${MOUNT_POINT}|d" /etc/fstab
    echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null
    echo "✓ Updated /etc/fstab"
  else
    echo "Adding entry to /etc/fstab..."
    echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null
    echo "✓ Added to /etc/fstab"
  fi

  # Mount the share
  echo "Mounting ${SMB_SHARE} to ${MOUNT_POINT}..."
  if sudo mount "${MOUNT_POINT}" 2>/dev/null; then
    echo "✓ Successfully mounted"
    df -h "${MOUNT_POINT}"
  else
    echo "✗ Failed to mount. Check your credentials and network connection."
    echo "Try: sudo mount -a"
    exit 1
  fi
else
  # MACOS SETUP
  # Build mount command
  if [[ -n "${SMB_USER}" ]]; then
    MOUNT_URL="//${SMB_USER}:${SMB_PASS}@${SMB_SHARE#//}"
  else
    MOUNT_URL="${SMB_SHARE}"
  fi

  # Unmount if currently mounted
  if mount | grep -q " on ${MOUNT_POINT} "; then
    echo "Unmounting existing mount..."
    umount "${MOUNT_POINT}" 2>/dev/null || sudo umount "${MOUNT_POINT}"
  fi

  # Create mount point if it doesn't exist (do this right before mounting)
  # On macOS, /Volumes mount points are auto-removed on unmount, so recreate as needed
  if [[ ! -d "${MOUNT_POINT}" ]]; then
    echo "Creating mount point: ${MOUNT_POINT}"
    sudo mkdir -p "${MOUNT_POINT}"
    # Set ownership to current user to avoid permission issues
    sudo chown "${USER}" "${MOUNT_POINT}"
  fi

  # Mount the share using mount_smbfs
  echo "Mounting ${SMB_SHARE} to ${MOUNT_POINT}..."
  if mount_smbfs "${MOUNT_URL}" "${MOUNT_POINT}" 2>/dev/null; then
    echo "✓ Successfully mounted"
    df -h "${MOUNT_POINT}"
  else
    echo "✗ Failed to mount. Check your credentials and network connection."
    echo "Try manually: mount_smbfs ${MOUNT_URL} ${MOUNT_POINT}"
    exit 1
  fi

  # Create LaunchAgent for persistent mounting
  echo ""
  echo -n "Create LaunchAgent for automatic mounting at login? [Y/n]: "
  read -r CREATE_AGENT

  if [[ ! "${CREATE_AGENT}" =~ ^[Nn]$ ]]; then
    AGENT_NAME="com.user.smbmount.${MOUNT_NAME}"
    AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_NAME}.plist"
    MOUNT_SCRIPT="${HOME}/.jsh/scripts/unix/mount-smb.sh"

    # Create generic mount script if it doesn't exist
    if [[ ! -f "${MOUNT_SCRIPT}" ]]; then
      echo "Creating mount script: ${MOUNT_SCRIPT}"
      cat > "${MOUNT_SCRIPT}" <<'SCRIPT_EOF'
#!/bin/bash
# Generic auto-mount script for SMB shares

CONFIG_FILE="${HOME}/.mounts"
MOUNT_NAME="$1"

if [[ -z "${MOUNT_NAME}" ]]; then
  echo "ERROR: Mount name required"
  exit 1
fi

# Helper function to read from JSON config
read_config() {
  local key="$1"
  local mount_name="$2"

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return 1
  fi

  if [[ "${key}" == "share" ]]; then
    grep -A 10 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"share":' | cut -d'"' -f4
  elif [[ "${key}" == "mount_point" ]]; then
    grep -A 10 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"mount_point":' | cut -d'"' -f4
  elif [[ "${key}" == "credential" ]]; then
    grep -A 10 "\"${mount_name}\":" "${CONFIG_FILE}" | grep '"credential":' | cut -d'"' -f4
  fi
}

# Load configuration
SMB_SHARE=$(read_config "share" "${MOUNT_NAME}")
MOUNT_POINT=$(read_config "mount_point" "${MOUNT_NAME}")
CREDENTIAL_NAME=$(read_config "credential" "${MOUNT_NAME}")

if [[ -z "${SMB_SHARE}" ]] || [[ -z "${MOUNT_POINT}" ]]; then
  echo "ERROR: Mount configuration not found for: ${MOUNT_NAME}"
  exit 1
fi

# Check if already mounted
if mount | grep -q " on ${MOUNT_POINT} "; then
  echo "Already mounted: ${MOUNT_POINT}"
  exit 0
fi

# Build mount URL with credentials
if [[ -n "${CREDENTIAL_NAME}" ]]; then
  SMB_USER=$(grep -A 5 "\"credentials\":" "${CONFIG_FILE}" | grep -A 3 "\"${CREDENTIAL_NAME}\":" | grep '"username":' | cut -d'"' -f4)
  SMB_PASS=$(grep -A 5 "\"credentials\":" "${CONFIG_FILE}" | grep -A 3 "\"${CREDENTIAL_NAME}\":" | grep '"password":' | cut -d'"' -f4)
  MOUNT_URL="//${SMB_USER}:${SMB_PASS}@${SMB_SHARE#//}"
else
  MOUNT_URL="${SMB_SHARE}"
fi

# Create mount point if needed
if [[ ! -d "${MOUNT_POINT}" ]]; then
  sudo mkdir -p "${MOUNT_POINT}"
  sudo chown "${USER}" "${MOUNT_POINT}"
fi

# Mount the share
if mount_smbfs "${MOUNT_URL}" "${MOUNT_POINT}" 2>/dev/null; then
  echo "Successfully mounted ${SMB_SHARE} to ${MOUNT_POINT}"
  exit 0
else
  echo "Failed to mount ${SMB_SHARE}"
  exit 1
fi
SCRIPT_EOF

      chmod +x "${MOUNT_SCRIPT}"
      echo "✓ Created generic mount script"
    fi

    # Create LaunchAgent plist
    echo "Creating LaunchAgent: ${AGENT_PLIST}"
    cat > "${AGENT_PLIST}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${MOUNT_SCRIPT}</string>
        <string>${MOUNT_NAME}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/${AGENT_NAME}.err</string>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/${AGENT_NAME}.out</string>
</dict>
</plist>
PLIST_EOF

    echo "✓ Created LaunchAgent plist"

    # Load the LaunchAgent
    launchctl unload "${AGENT_PLIST}" 2>/dev/null
    if launchctl load "${AGENT_PLIST}" 2>/dev/null; then
      echo "✓ LaunchAgent loaded and will run at login"
      echo ""
      echo "The mount will automatically reconnect:"
      echo "  - At login"
      echo "  - Every 5 minutes if disconnected"
      echo ""
      echo "To disable: launchctl unload ${AGENT_PLIST}"
      echo "Logs: ${HOME}/Library/Logs/${AGENT_NAME}.{out,err}"
    else
      echo "✗ Failed to load LaunchAgent"
      echo "Try manually: launchctl load ${AGENT_PLIST}"
    fi
  else
    echo "Skipping LaunchAgent creation."
    echo ""
    echo "Note: Mount is temporary and will not persist after reboot."
  fi
fi
