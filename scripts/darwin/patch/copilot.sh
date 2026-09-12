#!/usr/bin/env bash
# Patch VS Code Copilot edit confirmations on macOS.

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

if [[ "$(uname -s)" != "Darwin" ]]; then
  jsh_note "Skipping VS Code Copilot patch: macOS only"
  exit 0
fi

# Find VS Code app path
VSCODE_APP="/Applications/Visual Studio Code.app"
EXT_PATH="${VSCODE_APP}/Contents/Resources/app/extensions/copilot/dist/extension.js"
BAK_PATH="${EXT_PATH}.bak"

if [[ ! -f "${EXT_PATH}" ]]; then
  jsh_error "Copilot extension.js not found at ${EXT_PATH}"
  exit 1
fi

copilot_patch_state() {
  node -e '
    const fs = require("fs");
    const c = fs.readFileSync(process.argv[1], "utf8");
    const handler = /async function [$A-Z_a-z][$\w]*\([^)]*\)\{(?=.{0,1000}\(\"Allow edits\?\"\))/gs;
    const matches = [...c.matchAll(handler)];
    if (matches.length !== 1) process.stdout.write("unknown");
    else {
      const body = c.slice(matches[0].index + matches[0][0].length);
      if (body.startsWith("return{};")) process.stdout.write("patched");
      else if (body.startsWith("return{presentation:\"hidden\"};")) process.stdout.write("hidden");
      else process.stdout.write("unpatched");
    }
  ' "${EXT_PATH}"
}

PATCH_STATE=$(copilot_patch_state)

case "${1:-apply}" in
  apply)
    if [[ "${PATCH_STATE}" == patched ]]; then
      jsh_success "VS Code Copilot is already patched (auto-approving edit requests without hiding)."
      exit 0
    fi
    if [[ "${PATCH_STATE}" == unknown ]]; then
      jsh_error "Edit confirmation handler not found uniquely in extension.js"
      exit 1
    fi

    jsh_detail "This will modify the installed VS Code Copilot extension."
    jsh_prompt "Apply the Copilot patch? [y/N]: "
    read -r CONFIRM || CONFIRM=
    if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
      jsh_note "Skipping VS Code Copilot patch."
      exit 0
    fi

    if [[ ! -f "${BAK_PATH}" ]]; then
      jsh_info "Creating backup at ${BAK_PATH}..."
      cp -p "${EXT_PATH}" "${BAK_PATH}"
    fi

    if node -e '
      const fs = require("fs");
      const p = process.argv[1];
      let c = fs.readFileSync(p, "utf8");
      const handler = /async function [$A-Z_a-z][$\w]*\([^)]*\)\{(?=.{0,1000}\(\"Allow edits\?\"\))/gs;
      const matches = [...c.matchAll(handler)];
      if (matches.length !== 1) process.exit(1);
      const offset = matches[0].index + matches[0][0].length;
      const hidden = "return{presentation:\"hidden\"};";
      const replacementLength = c.startsWith(hidden, offset) ? hidden.length : 0;
      c = c.slice(0, offset) + "return{};" + c.slice(offset + replacementLength);
      fs.writeFileSync(p, c, "utf8");
    ' "${EXT_PATH}"; then
      jsh_success "Patched extension.js to auto-approve edit requests."
    else
      jsh_error "Target pattern not found in extension.js"
      exit 1
    fi
    jsh_detail "Restart VS Code or reload the window for changes to take effect."
    ;;

  restore|revert)
    if [[ ! -f "${BAK_PATH}" ]]; then
      jsh_error "No backup found at ${BAK_PATH}"
      exit 1
    fi
    jsh_detail "This will replace the installed extension with its backup."
    jsh_prompt "Restore the original Copilot extension? [y/N]: "
    read -r CONFIRM || CONFIRM=
    if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
      jsh_note "Skipping VS Code Copilot restore."
      exit 0
    fi
    cp -p "${BAK_PATH}" "${EXT_PATH}"
    jsh_success "Restored original extension.js from backup."
    jsh_detail "Restart VS Code or reload the window for changes to take effect."
    ;;

  status)
    if [[ "${PATCH_STATE}" == patched ]]; then
      jsh_success "Status: PATCHED (Auto-approving edit requests, visible in UI)"
    elif [[ "${PATCH_STATE}" == hidden ]]; then
      jsh_warn "Status: PATCHED (Old version: completely hiding edit prompts)"
    elif [[ "${PATCH_STATE}" == unknown ]]; then
      jsh_error "Status: UNKNOWN (Edit confirmation handler not found uniquely)"
    else
      jsh_warn "Status: UNPATCHED (Original confirmation prompts active)"
    fi
    if [[ -f "${BAK_PATH}" ]]; then
      printf -v quoted_backup '%q' "${BAK_PATH}"
      jsh_success "Backup: Available (${quoted_backup})"
    else
      jsh_warn "Backup: None"
    fi
    ;;

  *)
    jsh_error "Usage: $0 [apply|restore|status]"
    exit 1
    ;;
esac
