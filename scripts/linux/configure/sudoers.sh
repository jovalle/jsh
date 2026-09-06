#!/usr/bin/env bash
# Configure passwordless sudo for the current user.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

USERNAME=$(whoami)
if [[ "${USERNAME}" = "root" ]]; then
  jsh_error "Running as root is not supported/applicable."
  exit 1
fi

SUDOERS_LINE="${USERNAME} ALL=(ALL) NOPASSWD:ALL"
SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"

if sudo -n grep -Fxq "${SUDOERS_LINE}" "${SUDOERS_FILE}" 2>/dev/null; then
  jsh_success "Sudoers already configured for ${USERNAME}."
  exit 0
fi

jsh_info "This will grant ${USERNAME} passwordless sudo access."
jsh_prompt "Configure sudoers? [y/N]: "
read -r CONFIRM || CONFIRM=
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  jsh_warn "Skipping sudoers configuration."
  exit 0
fi

echo "${SUDOERS_LINE}" | sudo tee "${SUDOERS_FILE}" > /dev/null
sudo chmod 0440 "${SUDOERS_FILE}"
jsh_success "Sudoers configured for ${USERNAME} with no password prompt."
