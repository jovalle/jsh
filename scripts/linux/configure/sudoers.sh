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
  jsh::log_error "Running as root is not supported/applicable."
  exit 1
fi

SUDOERS_LINE="${USERNAME} ALL=(ALL) NOPASSWD:ALL"
SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"

if sudo -n grep -Fxq "${SUDOERS_LINE}" "${SUDOERS_FILE}" 2>/dev/null; then
  jsh::log_note "Sudoers already configured for ${USERNAME}."
  exit 0
fi

local_arg=
for local_arg in "$@"; do
  case "${local_arg}" in
    -y | --yes) export JSH_ASSUME_YES=1 ;;
  esac
done

jsh::log_detail "This will grant ${USERNAME} passwordless sudo access."
if ! jsh::confirm "Configure sudoers?" --default no; then
  jsh::log_note "Skipping sudoers configuration."
  exit 0
fi

if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]]; then
  jsh::log_detail "Would validate and install ${SUDOERS_FILE}"
  exit 0
fi
temporary=$(mktemp)
jsh_interrupt_cleanup_path "${temporary}"
trap 'rm -f -- "${temporary}"' EXIT
printf '%s\n' "${SUDOERS_LINE}" > "${temporary}"
sudo visudo -cf "${temporary}"
if [[ -e ${SUDOERS_FILE} ]]; then
  backup="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%s)-$$/sudoers"
  mkdir -p "$(dirname -- "${backup}")"
  # shellcheck disable=SC2024 # Deliberately keep the private backup owned by the invoking user.
  (umask 077; sudo cat "${SUDOERS_FILE}" > "${backup}")
fi
staging=$(sudo mktemp /etc/sudoers.d/.jsh-XXXXXX)
jsh_interrupt_cleanup_root_path "${staging}"
trap 'rm -f -- "${temporary}"; sudo -n rm -f -- "${staging}" 2>/dev/null || true' EXIT
sudo install -o root -g root -m 0440 "${temporary}" "${staging}"
sudo mv -f -- "${staging}" "${SUDOERS_FILE}"
jsh::log_success "Sudoers configured for ${USERNAME} with no password prompt."
