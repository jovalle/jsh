#!/usr/bin/env bash
#
# configure-systemd.sh - Configure and enable systemd user services
#
# This script enables and starts user-level systemd services for:
# - ssh-agent (SSH key management)
# - gpg-agent (GPG key management)
# - podman.socket (rootless container support)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}[====]${NC} $*"; }

# Check if running on Linux
if [[ "$(uname -s)" != "Linux" ]]; then
  log_error "This script is intended for Linux only."
  exit 1
fi

if ! command -v systemctl &>/dev/null; then
  log_error "systemctl not found. This script requires systemd."
  exit 1
fi

log_info "Configuring systemd user services..."
echo ""

###############################################################################
# SSH AGENT
###############################################################################

log_section "Configuring SSH Agent"

# Create ssh-agent service if it doesn't exist
SSH_AGENT_SERVICE="${HOME}/.config/systemd/user/ssh-agent.service"
mkdir -p "$(dirname "${SSH_AGENT_SERVICE}")"

if [[ ! -f "${SSH_AGENT_SERVICE}" ]]; then
  log_info "Creating ssh-agent.service..."
  cat > "${SSH_AGENT_SERVICE}" << 'EOF'
[Unit]
Description=SSH Agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target
EOF
  log_info "Created ${SSH_AGENT_SERVICE}"
else
  log_info "ssh-agent.service already exists"
fi

# Reload systemd user daemon
systemctl --user daemon-reload

# Enable and start ssh-agent
if systemctl --user is-enabled ssh-agent.service &>/dev/null; then
  log_info "ssh-agent.service already enabled"
else
  systemctl --user enable ssh-agent.service
  log_info "Enabled ssh-agent.service"
fi

if systemctl --user is-active ssh-agent.service &>/dev/null; then
  log_info "ssh-agent.service already running"
else
  systemctl --user start ssh-agent.service
  log_info "Started ssh-agent.service"
fi

# Add SSH_AUTH_SOCK to environment if not already set
SSH_AGENT_ENV_FILE="${HOME}/.config/environment.d/ssh-agent.conf"
SSH_AGENT_ENV_LINE="SSH_AUTH_SOCK=\"\${XDG_RUNTIME_DIR}/ssh-agent.socket\""
if [[ -f "${SSH_AGENT_ENV_FILE}" ]] && grep -qxF "${SSH_AGENT_ENV_LINE}" "${SSH_AGENT_ENV_FILE}" 2>/dev/null; then
  log_info "SSH_AUTH_SOCK environment already configured"
else
  mkdir -p "${HOME}/.config/environment.d"
  echo "${SSH_AGENT_ENV_LINE}" > "${SSH_AGENT_ENV_FILE}"
  log_info "Created environment config for SSH_AUTH_SOCK"
fi

###############################################################################
# GPG AGENT
###############################################################################

log_section "Configuring GPG Agent"

# GPG agent is typically managed by gpg itself, but we ensure the socket is enabled
if command -v gpg-agent &>/dev/null; then
  # Enable gpg-agent socket
  if systemctl --user is-enabled gpg-agent.socket &>/dev/null 2>&1; then
    log_info "gpg-agent.socket already enabled"
  else
    systemctl --user enable gpg-agent.socket 2>/dev/null || log_warn "gpg-agent.socket not available"
    log_info "Enabled gpg-agent.socket"
  fi

  # Start gpg-agent socket
  if systemctl --user is-active gpg-agent.socket &>/dev/null 2>&1; then
    log_info "gpg-agent.socket already running"
  else
    systemctl --user start gpg-agent.socket 2>/dev/null || log_warn "Could not start gpg-agent.socket"
  fi
else
  log_warn "gpg-agent not installed, skipping"
fi

###############################################################################
# PODMAN SOCKET (rootless containers)
###############################################################################

log_section "Configuring Podman Socket"

if command -v podman &>/dev/null; then
  # Enable podman socket for Docker compatibility
  if systemctl --user is-enabled podman.socket &>/dev/null 2>&1; then
    log_info "podman.socket already enabled"
  else
    systemctl --user enable podman.socket 2>/dev/null || log_warn "podman.socket not available"
    log_info "Enabled podman.socket"
  fi

  # Start podman socket
  if systemctl --user is-active podman.socket &>/dev/null 2>&1; then
    log_info "podman.socket already running"
  else
    systemctl --user start podman.socket 2>/dev/null || log_warn "Could not start podman.socket"
  fi

  # Set DOCKER_HOST for Docker CLI compatibility
  PODMAN_ENV_FILE="${HOME}/.config/environment.d/podman.conf"
  PODMAN_ENV_LINE="DOCKER_HOST=\"unix://\${XDG_RUNTIME_DIR}/podman/podman.sock\""
  if [[ -f "${PODMAN_ENV_FILE}" ]] && grep -qxF "${PODMAN_ENV_LINE}" "${PODMAN_ENV_FILE}" 2>/dev/null; then
    log_info "DOCKER_HOST environment already configured"
  else
    mkdir -p "${HOME}/.config/environment.d"
    echo "${PODMAN_ENV_LINE}" > "${PODMAN_ENV_FILE}"
    log_info "Created environment config for DOCKER_HOST (podman compatibility)"
  fi
else
  log_warn "podman not installed, skipping"
fi

###############################################################################
# SUMMARY
###############################################################################

log_section "Service Status Summary"

echo ""
echo "User services status:"
echo ""

for service in ssh-agent.service gpg-agent.socket podman.socket; do
  if systemctl --user is-active "${service}" &>/dev/null 2>&1; then
    echo -e "${GREEN}●${NC} ${service} (running)"
  elif systemctl --user is-enabled "${service}" &>/dev/null 2>&1; then
    echo -e "${YELLOW}○${NC} ${service} (enabled, not running)"
  else
    echo -e "${RED}○${NC} ${service} (not configured)"
  fi
done

echo ""
log_info "Systemd user services configuration complete!"
log_warn "You may need to log out and back in for environment changes to take effect."
echo ""
