#!/usr/bin/env bash
# Customize the active desktop, dock, audio, display, wallpaper, and shortcuts.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

python3 "${SCRIPT_DIR}/customize.py" "${1:-all}"
