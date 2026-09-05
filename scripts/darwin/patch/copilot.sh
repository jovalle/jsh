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
  jsh_warn "Skipping VS Code Copilot patch: macOS only"
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

case "${1:-apply}" in
  apply)
    if grep -Fq 'async function wC(t,e,n,r,o,a,s){return{};' "${EXT_PATH}"; then
      jsh_success "VS Code Copilot is already patched (auto-approving edit requests without hiding)."
      exit 0
    fi

    jsh_warn "This will modify the installed VS Code Copilot extension."
    jsh_prompt "Apply the Copilot patch? [y/N]: "
    read -r CONFIRM || CONFIRM=
    if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
      jsh_warn "Skipping VS Code Copilot patch."
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
      const oldPatched = "async function wC(t,e,n,r,o,a,s){return{presentation:\"hidden\"};";
      const target = "async function wC(t,e,n,r,o,a,s){";
      const patched = "async function wC(t,e,n,r,o,a,s){return{};";
      if (c.includes(oldPatched)) {
        c = c.replace(oldPatched, patched);
        fs.writeFileSync(p, c, "utf8");
      } else if (c.includes(target)) {
        c = c.replace(target, patched);
        fs.writeFileSync(p, c, "utf8");
      } else {
        process.exit(1);
      }
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
    jsh_warn "This will replace the installed extension with its backup."
    jsh_prompt "Restore the original Copilot extension? [y/N]: "
    read -r CONFIRM || CONFIRM=
    if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
      jsh_warn "Skipping VS Code Copilot restore."
      exit 0
    fi
    cp -p "${BAK_PATH}" "${EXT_PATH}"
    jsh_success "Restored original extension.js from backup."
    jsh_detail "Restart VS Code or reload the window for changes to take effect."
    ;;

  status)
    if grep -Fq 'async function wC(t,e,n,r,o,a,s){return{};' "${EXT_PATH}"; then
      jsh_success "Status: PATCHED (Auto-approving edit requests, visible in UI)"
    elif grep -Fq 'async function wC(t,e,n,r,o,a,s){return{presentation:"hidden"};' "${EXT_PATH}"; then
      jsh_warn "Status: PATCHED (Old version: completely hiding edit prompts)"
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
