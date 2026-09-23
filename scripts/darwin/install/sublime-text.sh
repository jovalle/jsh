#!/usr/bin/env bash
# Install Sublime Text Build 4200, the build bin/sublime patches.

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

readonly SUBLIME_BUILD=4200
readonly SUBLIME_URL=https://download.sublimetext.com/sublime_text_build_${SUBLIME_BUILD}_mac.zip
readonly SUBLIME_SHA256=4835eb2a5d3f2b223ce93a27149f360ef158af9f8dd708b6f501d708c081d319
readonly SUBLIME_TEAM_ID=Z6D26JE4Y4
readonly APP_PATH=${SUBLIME_APP_PATH:-/Applications/Sublime Text.app}
TEMP_DIR=

quit_sublime() {
  local attempt
  pgrep -x sublime_text > /dev/null 2>&1 || return 0
  jsh::confirm "Sublime Text is running. Quit it now?" --default yes || return 1
  osascript -e 'tell application "Sublime Text" to quit' > /dev/null 2>&1 || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    pgrep -x sublime_text > /dev/null 2>&1 || return 0
    sleep 0.1
  done
  jsh::log_error "Sublime Text could not be closed."
  return 1
}

install_sublime_text() {
  local build signature
  build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${APP_PATH}/Contents/Info.plist" 2> /dev/null || true)
  if [[ ${build} == "${SUBLIME_BUILD}" ]]; then
    jsh::log_note "Sublime Text Build ${SUBLIME_BUILD} is already installed."
    return 0
  fi
  if [[ -n ${build} ]] && ! jsh::confirm "Replace Sublime Text Build ${build} with Build ${SUBLIME_BUILD}?" --default yes; then
    jsh::log_note "Keeping Sublime Text Build ${build}."
    return 0
  fi

  mkdir -p "${JSH_ROOT}/tmp"
  TEMP_DIR=$(mktemp -d "${JSH_ROOT}/tmp/sublime-text.XXXXXX")
  jsh_interrupt_cleanup_path "${TEMP_DIR}"
  trap 'rm -rf -- "${TEMP_DIR}"' EXIT

  jsh::log_info "Downloading Sublime Text Build ${SUBLIME_BUILD}..."
  curl -fsSL -o "${TEMP_DIR}/sublime.zip" "${SUBLIME_URL}"
  printf '%s  %s\n' "${SUBLIME_SHA256}" "${TEMP_DIR}/sublime.zip" | shasum -a 256 -c --status || {
    jsh::log_error "Sublime Text download checksum did not match."
    return 1
  }
  ditto -x -k "${TEMP_DIR}/sublime.zip" "${TEMP_DIR}"
  codesign --verify --deep --strict "${TEMP_DIR}/Sublime Text.app" &&
    signature=$(codesign -dv "${TEMP_DIR}/Sublime Text.app" 2>&1) &&
    [[ $'\n'${signature}$'\n' == *$'\n'"TeamIdentifier=${SUBLIME_TEAM_ID}"$'\n'* ]] || {
    jsh::log_error "Sublime Text download is not signed by Sublime HQ."
    return 1
  }

  quit_sublime
  # Homebrew would otherwise track and upgrade the floating cask build.
  if command -v brew > /dev/null 2>&1 && brew list --cask sublime-text > /dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew uninstall --cask sublime-text
  fi
  rm -rf -- "${APP_PATH}"
  mv -- "${TEMP_DIR}/Sublime Text.app" "${APP_PATH}"
  jsh::log_success "Sublime Text Build ${SUBLIME_BUILD} is installed."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_sublime_text
fi
