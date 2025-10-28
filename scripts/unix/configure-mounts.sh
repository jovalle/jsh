#!/bin/bash
# Configure and mount SMB shares (works on both macOS and Linux)

# Detect OS and set defaults
if [[ "$OSTYPE" == "darwin"* ]]; then
  MOUNT_POINT="${MOUNT_POINT:-/Volumes/media}"
  IS_MACOS=true
  CREDS_FILE="$HOME/.smbcredentials_media"
else
  MOUNT_POINT="${MOUNT_POINT:-/mnt/media}"
  IS_MACOS=false
  CREDS_FILE="/root/.smbcredentials_media"
fi

SMB_SHARE="${SMB_SHARE}"

# Check if already configured or mounted
IS_CONFIGURED=false
if [[ "$IS_MACOS" == false ]] && grep -q "$MOUNT_POINT" /etc/fstab 2>/dev/null; then
  IS_CONFIGURED=true
  echo "✓ Mount already configured in /etc/fstab for $MOUNT_POINT"
elif mount | grep -q " on $MOUNT_POINT "; then
  IS_CONFIGURED=true
  echo "✓ Mount already active at $MOUNT_POINT"
fi

if [[ "$IS_CONFIGURED" == true ]]; then
  # Check if already mounted
  if mount | grep -q " on $MOUNT_POINT "; then
    echo "✓ $MOUNT_POINT is currently mounted"
    df -h "$MOUNT_POINT"
  fi

  echo ""
  echo -n "Reconfigure? [y/N]: "
  read RECONFIGURE
  if [[ ! "$RECONFIGURE" =~ ^[Yy]$ ]]; then
    echo "Keeping existing configuration."
    exit 0
  fi

  echo "Reconfiguring..."
fi

# Prompt for SMB share if not provided
if [ -z "$SMB_SHARE" ]; then
  echo -n "Enter SMB share (e.g., //server/share): "
  read SMB_SHARE
  if [ -z "$SMB_SHARE" ]; then
    echo "ERROR: SMB share is required"
    exit 1
  fi
fi

echo "SMB Share: $SMB_SHARE"
echo "Mount Point: $MOUNT_POINT"
echo ""

# Check if credentials file already exists
SMB_USER=""
SMB_PASS=""

if [[ "$IS_MACOS" == true ]] && [[ -f "$CREDS_FILE" ]]; then
  CREDS_EXIST=true
elif [[ "$IS_MACOS" == false ]] && sudo test -f "$CREDS_FILE"; then
  CREDS_EXIST=true
else
  CREDS_EXIST=false
fi

if [[ "$CREDS_EXIST" == true ]]; then
  echo "✓ Found existing credentials file: $CREDS_FILE"
  echo -n "Use existing credentials? [Y/n]: "
  read USE_EXISTING

  if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
    echo "Using existing credentials."
  else
    echo "Enter new credentials:"
    echo -n "Username: "
    read SMB_USER

    echo -n "Password: "
    stty -echo
    read SMB_PASS
    stty echo
    echo ""

    if [ -z "$SMB_USER" ] || [ -z "$SMB_PASS" ]; then
      echo "ERROR: Username and password are required"
      exit 1
    fi
  fi
else
  # Ask if authentication is needed
  echo -n "Does this share require authentication? [y/N]: "
  read AUTH_REQUIRED

  if [[ "$AUTH_REQUIRED" =~ ^[Yy]$ ]]; then
    echo -n "Username: "
    read SMB_USER

    echo -n "Password: "
    stty -echo
    read SMB_PASS
    stty echo
    echo ""

    if [ -z "$SMB_USER" ] || [ -z "$SMB_PASS" ]; then
      echo "ERROR: Username and password are required for authenticated mounts"
      exit 1
    fi
  fi
fi

if [[ "$IS_MACOS" == false ]]; then
  # LINUX SETUP
  # Ensure cifs-utils is installed
  if ! command -v mount.cifs &> /dev/null; then
    echo "Installing cifs-utils..."
    sudo apt update && sudo apt install -y cifs-utils
  fi

  # Create mount point if it doesn't exist
  if [ ! -d "$MOUNT_POINT" ]; then
    echo "Creating mount point: $MOUNT_POINT"
    sudo mkdir -p "$MOUNT_POINT"
  fi

  # Update credentials file if new credentials were provided
  if [ -n "$SMB_USER" ] && [ -n "$SMB_PASS" ]; then
    echo "Updating credentials file: $CREDS_FILE"
    echo "username=$SMB_USER" | sudo tee "$CREDS_FILE" > /dev/null
    echo "password=$SMB_PASS" | sudo tee -a "$CREDS_FILE" > /dev/null
    sudo chmod 600 "$CREDS_FILE"
  fi

  # Build fstab entry
  if sudo test -f "$CREDS_FILE"; then
    FSTAB_ENTRY="$SMB_SHARE $MOUNT_POINT cifs credentials=$CREDS_FILE,uid=1000,gid=1000,file_mode=0755,dir_mode=0755,nofail 0 0"
  else
    FSTAB_ENTRY="$SMB_SHARE $MOUNT_POINT cifs guest,uid=1000,gid=1000,file_mode=0755,dir_mode=0755,nofail 0 0"
  fi

  # Update fstab entry
  if grep -q "$MOUNT_POINT" /etc/fstab 2>/dev/null; then
    echo "Updating /etc/fstab entry..."
    # Unmount if currently mounted
    if mount | grep -q " on $MOUNT_POINT "; then
      sudo umount "$MOUNT_POINT"
    fi
    # Remove old entry and add new one
    sudo sed -i "\|$MOUNT_POINT|d" /etc/fstab
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
    echo "✓ Updated /etc/fstab"
  else
    echo "Adding entry to /etc/fstab..."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
    echo "✓ Added to /etc/fstab"
  fi

  # Mount the share
  echo "Mounting $SMB_SHARE to $MOUNT_POINT..."
  if sudo mount "$MOUNT_POINT" 2>/dev/null; then
    echo "✓ Successfully mounted"
    df -h "$MOUNT_POINT"
  else
    echo "✗ Failed to mount. Check your credentials and network connection."
    echo "Try: sudo mount -a"
    exit 1
  fi
else
  # MACOS SETUP
  # Create mount point if it doesn't exist
  if [ ! -d "$MOUNT_POINT" ]; then
    echo "Creating mount point: $MOUNT_POINT"
    sudo mkdir -p "$MOUNT_POINT"
  fi

  # Update credentials file if new credentials were provided
  if [ -n "$SMB_USER" ] && [ -n "$SMB_PASS" ]; then
    echo "Updating credentials file: $CREDS_FILE"
    echo "username=$SMB_USER" > "$CREDS_FILE"
    echo "password=$SMB_PASS" >> "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
  fi

  # Build mount command
  if [[ -f "$CREDS_FILE" ]]; then
    # Read credentials
    STORED_USER=$(grep "^username=" "$CREDS_FILE" | cut -d'=' -f2)
    STORED_PASS=$(grep "^password=" "$CREDS_FILE" | cut -d'=' -f2)
    MOUNT_URL="//${STORED_USER}:${STORED_PASS}@${SMB_SHARE#//}"
  else
    MOUNT_URL="${SMB_SHARE}"
  fi

  # Unmount if currently mounted
  if mount | grep -q " on $MOUNT_POINT "; then
    echo "Unmounting existing mount..."
    sudo umount "$MOUNT_POINT"
  fi

  # Mount the share
  echo "Mounting $SMB_SHARE to $MOUNT_POINT..."
  if mount -t smbfs "$MOUNT_URL" "$MOUNT_POINT" 2>/dev/null; then
    echo "✓ Successfully mounted"
    df -h "$MOUNT_POINT"
  else
    echo "✗ Failed to mount. Check your credentials and network connection."
    echo "Try manually: mount -t smbfs $MOUNT_URL $MOUNT_POINT"
    exit 1
  fi

  echo ""
  echo "Note: On macOS, this mount is temporary. To make it persistent:"
  echo "Add to /etc/auto_master or create a login item."
fi
