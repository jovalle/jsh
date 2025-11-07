#!/bin/bash
# Generic auto-mount script for SMB shares

CONFIG_FILE="$HOME/.mounts.json"
MOUNT_NAME="$1"

if [[ -z "$MOUNT_NAME" ]]; then
  echo "ERROR: Mount name required"
  exit 1
fi

# Helper function to read from JSON config
read_config() {
  local key="$1"
  local mount_name="$2"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 1
  fi

  if [[ "$key" == "share" ]]; then
    grep -A 10 "\"$mount_name\":" "$CONFIG_FILE" | grep '"share":' | cut -d'"' -f4
  elif [[ "$key" == "mount_point" ]]; then
    grep -A 10 "\"$mount_name\":" "$CONFIG_FILE" | grep '"mount_point":' | cut -d'"' -f4
  elif [[ "$key" == "credential" ]]; then
    grep -A 10 "\"$mount_name\":" "$CONFIG_FILE" | grep '"credential":' | cut -d'"' -f4
  fi
}

# Load configuration
SMB_SHARE=$(read_config "share" "$MOUNT_NAME")
MOUNT_POINT=$(read_config "mount_point" "$MOUNT_NAME")
CREDENTIAL_NAME=$(read_config "credential" "$MOUNT_NAME")

if [[ -z "$SMB_SHARE" ]] || [[ -z "$MOUNT_POINT" ]]; then
  echo "ERROR: Mount configuration not found for: $MOUNT_NAME"
  exit 1
fi

# Check if already mounted
if mount | grep -q " on $MOUNT_POINT "; then
  echo "Already mounted: $MOUNT_POINT"
  exit 0
fi

# Build mount URL with credentials
if [[ -n "$CREDENTIAL_NAME" ]]; then
  SMB_USER=$(grep -A 5 "\"credentials\":" "$CONFIG_FILE" | grep -A 3 "\"$CREDENTIAL_NAME\":" | grep '"username":' | cut -d'"' -f4)
  SMB_PASS=$(grep -A 5 "\"credentials\":" "$CONFIG_FILE" | grep -A 3 "\"$CREDENTIAL_NAME\":" | grep '"password":' | cut -d'"' -f4)
  MOUNT_URL="//${SMB_USER}:${SMB_PASS}@${SMB_SHARE#//}"
else
  MOUNT_URL="${SMB_SHARE}"
fi

# Create mount point if needed
if [ ! -d "$MOUNT_POINT" ]; then
  sudo mkdir -p "$MOUNT_POINT"
  sudo chown "$USER" "$MOUNT_POINT"
fi

# Mount the share
if mount_smbfs "$MOUNT_URL" "$MOUNT_POINT" 2>/dev/null; then
  echo "Successfully mounted $SMB_SHARE to $MOUNT_POINT"
  exit 0
else
  echo "Failed to mount $SMB_SHARE"
  exit 1
fi
