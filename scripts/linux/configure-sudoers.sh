#!/bin/bash
# Configure sudoers to allow passwordless sudo

USERNAME=$(whoami)
if [ "$USERNAME" = "root" ]; then
  echo "Error: Running as root is not supported/applicable."
  exit 1
fi

SUDOERS_LINE="$USERNAME ALL=(ALL) NOPASSWD:ALL"
SUDOERS_FILE="/etc/sudoers.d/$USERNAME"

if ! sudo grep -Fxq "$SUDOERS_LINE" "$SUDOERS_FILE" 2>/dev/null; then
  echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
  sudo chmod 0440 "$SUDOERS_FILE"
  echo "Sudoers configured for $USERNAME with no password prompt."
else
  echo "Sudoers already configured for $USERNAME."
fi
