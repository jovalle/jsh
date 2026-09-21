#!/usr/bin/env bash
# Install, upgrade, and harden Helium on macOS and Linux.

set -euo pipefail
IFS=$'\n\t'
umask 077

if [[ -z ${JSH_ROOT:-} ]]; then
  JSH_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
fi
readonly JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

readonly EXTENSION_HELPER="${JSH_ROOT}/conf/helium/helium-extensions.mjs"
readonly PROFILE_HELPER="${JSH_ROOT}/conf/helium/helium-profile.js"
readonly EXPECTED_BUNDLE_ID="net.imput.helium"
readonly EXPECTED_TEAM_ID="S4Q33XPHB4"
readonly MIN_CHROMIUM_MILESTONE="152"
HELIUM_LATEST_VERSION=
HELIUM_LATEST_URL=
HELIUM_LATEST_SHA256=
PLATFORM="${HELIUM_PLATFORM:-${PLATFORM:-$(uname -s)}}"
readonly PLATFORM
case ${PLATFORM} in
  Darwin)
    readonly APP_PATH="${HELIUM_APP_PATH:-/Applications/Helium.app}"
    readonly PROFILE_ROOT="${HELIUM_PROFILE_ROOT:-${HOME}/Library/Application Support/net.imput.helium}"
    POLICY_USER="$(/usr/bin/id -un)" || {
      printf 'helium: Cannot determine the current login.\n' >&2
      exit 1
    }
    readonly POLICY_USER
    readonly POLICY_PATH="${HELIUM_POLICY_PATH:-/Library/Managed Preferences/${POLICY_USER}/${EXPECTED_BUNDLE_ID}.plist}"
    ;;
  Linux)
    readonly APP_PATH=''
    readonly PROFILE_ROOT="${HELIUM_PROFILE_ROOT:-${XDG_CONFIG_HOME:-${HOME}/.config}/helium}"
    readonly POLICY_PATH="${HELIUM_POLICY_PATH:-/etc/chromium/policies/managed/jsh-helium.json}"
    ;;
  *)
    printf 'helium: Unsupported platform: %s\n' "${PLATFORM}" >&2
    exit 1
    ;;
esac

die() {
  jsh::log_error "Helium: $2"
  exit "$1"
}

usage() {
  cat <<'EOF'
Usage:
  helium [apply [--quit] [-y|--yes]]
  helium status
  helium open [--] [BROWSER_ARGS...]
  helium stop
  helium restart [--] [BROWSER_ARGS...]
  helium launch [--] [BROWSER_ARGS...]
  helium reset [--all] [--force]

apply   Upgrade Helium, install and pin extensions, and apply hardened settings.
        --quit authorizes quitting a running Helium instance without prompting.
status  Check whether Helium is patched.
open    Verify the profile and open Helium in a hardened regular window.
stop    Close Helium.
restart Close and reopen Helium.
launch  Alias for open.
reset   Reset the Helium profile while preserving extension data.
  --all also deletes extension data; --force skips confirmation.
EOF
}

managed_extensions() {
  cat <<EOF
blockjmkbacgjkknlgpkjjiijinjdanf	uBlock Origin
jplgfhpmjnbigmhklmmbgecoobifkmpa	Proton VPN	managed
nngceckbapebfimnlniiiahkandclblb	Bitwarden	managed
pkehgijcmpdhfbdbbnkijodmdjhbjlgp	Privacy Badger	managed
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die 1 "$1 is required."
}

load_brew() {
  command -v brew >/dev/null 2>&1 && return

  local brew_path
  for brew_path in "${HELIUM_BREW:-}" /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    [[ -n ${brew_path} ]] || continue
    if [[ -x ${brew_path} ]]; then
      eval "$("${brew_path}" shellenv)"
      return
    fi
  done
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

app_executable() {
  if [[ -n ${HELIUM_BINARY:-} ]]; then
    [[ -x ${HELIUM_BINARY} ]] || return 1
    printf '%s\n' "${HELIUM_BINARY}"
  elif [[ ${PLATFORM} == Darwin ]]; then
    local executable
    executable="$(plist_value "${APP_PATH}" CFBundleExecutable)" || return 1
    printf '%s/Contents/MacOS/%s\n' "${APP_PATH}" "${executable}"
  else
    [[ -x /usr/bin/helium ]] || return 1
    printf '%s\n' /usr/bin/helium
  fi
}

chromium_milestone() {
  "$(app_executable)" --version 2>/dev/null |
    /usr/bin/grep -Eo '(Chromium[[:space:]]+)?[0-9]{3}[.][0-9.]+' |
    /usr/bin/grep -Eo '[0-9]{3}' | /usr/bin/head -n 1
}

profile_helper() {
  if [[ ${PLATFORM} == Darwin ]]; then
    /usr/bin/osascript -l JavaScript "${PROFILE_HELPER}" "$@"
  else
    /usr/bin/env node "${PROFILE_HELPER}" "$@"
  fi
}

browser_is_running() {
  if [[ ${PLATFORM} == Darwin ]]; then
    /usr/bin/pgrep -f "^${APP_PATH}/Contents/MacOS/" >/dev/null 2>&1
  else
    /usr/bin/pgrep -x helium >/dev/null 2>&1
  fi
}

require_stopped() {
  browser_is_running && die 1 "Quit Helium first."
  return 0
}

stop_for_apply() {
  local authorized="${1:-false}" attempt
  browser_is_running || return 0

  if [[ ${JSH_ASSUME_YES:-0} == 1 ]]; then
    authorized=true
  fi

  if [[ "${authorized}" != true ]]; then
    [[ -t 0 ]] || die 1 "Helium is running. Rerun apply with --quit."
    jsh::confirm 'Helium is running. Quit it now?' --default no || die 1 "Apply cancelled."
  fi

  if [[ ${PLATFORM} == Darwin ]]; then
    /usr/bin/osascript -e "tell application id \"${EXPECTED_BUNDLE_ID}\" to quit" >/dev/null ||
      die 1 "Cannot ask Helium to quit."
  else
    /usr/bin/pkill -TERM -x helium >/dev/null || die 1 "Cannot ask Helium to quit."
  fi
  for ((attempt = 0; attempt < 100; attempt++)); do
    browser_is_running || return 0
    /bin/sleep 0.1
  done
  die 1 "Helium did not quit."
}

upgrade_app() {
  local brew_command installed
  if [[ ${PLATFORM} == Linux ]]; then
    helium_latest_release
    installed=$(helium_installed_version || true)
    if [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${HELIUM_LATEST_VERSION}"; then
      return
    fi
    if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 || ${JSH_INSTALL_DRY_RUN:-0} == 1 ]]; then
      jsh::log_detail "Would install Helium ${HELIUM_LATEST_VERSION}."
      return
    fi
    jsh_debian_install_package helium helium-bin "${HELIUM_LATEST_VERSION}" \
      "${HELIUM_LATEST_URL}" "${HELIUM_LATEST_SHA256}" helium ||
      die 1 "The native application installer could not install Helium."
    installed=$(helium_installed_version || true)
    [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${HELIUM_LATEST_VERSION}" ||
      die 1 "The installed Helium package did not converge."
    return
  fi
  brew_command="$(command -v brew || true)"
  [[ -n "${brew_command}" ]] || die 1 "Homebrew is required to install or update Helium."

  if [[ ${JSH_UPDATE:-0} != 1 ]] && (verify_app) >/dev/null 2>&1; then
    return 0
  fi

  if [[ ${JSH_UPDATE:-0} != 1 ]]; then
    "${brew_command}" update || die 1 "Homebrew could not update package metadata."
  fi
  export HOMEBREW_NO_AUTO_UPDATE=1
  if "${brew_command}" list --cask helium-browser >/dev/null 2>&1; then
    "${brew_command}" upgrade --cask helium-browser || die 1 "Homebrew could not update Helium."
  else
    "${brew_command}" install --cask --force helium-browser || die 1 "Homebrew could not install Helium."
  fi
  repair_app_metadata
  if ! (verify_app); then
    jsh::log_warn "Helium failed verification; reinstalling the Homebrew cask once."
    "${brew_command}" reinstall --cask --force helium-browser || die 1 "Homebrew could not repair Helium."
    repair_app_metadata
    verify_app
  fi
}

helium_latest_release() {
  local release asset name digest
  require_command curl
  require_command jq
  release=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    'https://api.github.com/repos/imputnet/helium-linux/releases/latest') ||
    die 1 "Cannot resolve the latest Helium release."
  asset=$(jq -cer '.assets[] | select(.name | test("amd64.*[.]deb$"))' <<< "${release}" | head -n 1) ||
    die 1 "The latest Helium release has no AMD64 Debian package."
  name=$(jq -r '.name' <<< "${asset}")
  HELIUM_LATEST_VERSION=$(sed -nE 's/^helium-bin_([^_]+)_amd64.*[.]deb$/\1/p' <<< "${name}")
  HELIUM_LATEST_URL=$(jq -r '.browser_download_url' <<< "${asset}")
  digest=$(jq -r '.digest // empty' <<< "${asset}")
  HELIUM_LATEST_SHA256=${digest#sha256:}
  [[ -n ${HELIUM_LATEST_VERSION} && ${HELIUM_LATEST_URL} == https://* ]] ||
    die 1 "The latest Helium package metadata is invalid."
  [[ -z ${HELIUM_LATEST_SHA256} || ${HELIUM_LATEST_SHA256} =~ ^[0-9a-f]{64}$ ]] ||
    die 1 "The latest Helium package checksum is invalid."
}

helium_installed_version() {
  local installed
  installed=$(dpkg-query -W -f='${db:Status-Status}\t${Version}' helium-bin 2>/dev/null) || return 1
  [[ ${installed%%$'\t'*} == installed ]] || return 1
  printf '%s\n' "${installed#*$'\t'}"
}

install_linux_launcher() {
  local applications=${XDG_DATA_HOME:-${HOME}/.local/share}/applications
  local temporary ensure_status
  [[ ${PLATFORM} == Linux ]] || return 0
  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp "${JSH_ROOT}/tmp/helium.desktop.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  {
    printf '[Desktop Entry]\nType=Application\nName=Helium\n'
    printf 'Exec=%s open -- %%U\n' "$(jsh_desktop_executable "${JSH_ROOT}/bin/helium")"
    printf 'Icon=helium\nCategories=Network;WebBrowser;\n'
    printf 'MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;\n'
    printf 'StartupNotify=true\nStartupWMClass=Helium\n'
  } > "${temporary}"
  jsh_ensure_file "${applications}/helium.desktop" "${temporary}" 0644 || {
    ensure_status=$?
    rm -f -- "${temporary}"
    [[ ${ensure_status} == 1 ]] || return "${ensure_status}"
  }
  rm -f -- "${temporary}"
}

# Finder metadata is not signed content. Preserve quarantine and all other attributes.
repair_app_metadata() {
  [[ ${PLATFORM} == Darwin && -d ${APP_PATH} ]] || return 0
  local diagnostic
  if diagnostic=$(/usr/bin/codesign --verify --deep --strict "${APP_PATH}" 2>&1); then
    return 0
  fi
  [[ ${diagnostic} == *'resource fork, Finder information, or similar detritus not allowed'* ]] || return 0
  jsh::log_warn "Removing Finder metadata that prevents Helium signature verification."
  /usr/bin/xattr -dr com.apple.FinderInfo "${APP_PATH}" || die 1 "Cannot remove Helium Finder metadata."
  /usr/bin/xattr -dr com.apple.ResourceFork "${APP_PATH}" || die 1 "Cannot remove Helium resource forks."
}

verify_app() {
  local milestone installed
  if [[ ${PLATFORM} == Darwin ]]; then
    [[ -d "${APP_PATH}" ]] || die 1 "Helium is not installed. Run apply first."
    local bundle_id team_id
    bundle_id="$(plist_value "${APP_PATH}" CFBundleIdentifier)" || die 1 "Cannot read Helium's bundle identifier."
    [[ "${bundle_id}" == "${EXPECTED_BUNDLE_ID}" ]] || die 1 "The installed app is not the expected Helium bundle."
    /usr/bin/codesign --verify --deep --strict "${APP_PATH}" || die 1 "Helium's code signature is invalid."
    team_id="$(/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    [[ "${team_id}" == "${EXPECTED_TEAM_ID}" ]] || die 1 "Helium is not signed by the expected developer team."
    /usr/sbin/spctl -a -t exec "${APP_PATH}" || die 1 "Gatekeeper rejected Helium."
  else
    app_executable >/dev/null || die 1 "Helium is not installed. Run apply first."
    helium_latest_release
    installed=$(helium_installed_version || true)
    [[ -n ${installed} ]] && dpkg --compare-versions "${installed}" ge "${HELIUM_LATEST_VERSION}" ||
      die 1 "The installed Helium package does not match the managed version."
  fi
  milestone="$(chromium_milestone)"
  [[ "${milestone}" =~ ^[0-9]+$ ]] || die 1 "Cannot determine Helium's Chromium milestone."
  (( milestone >= MIN_CHROMIUM_MILESTONE )) || die 1 "Helium is below Chromium milestone ${MIN_CHROMIUM_MILESTONE}."
}

verify_extension_policy() {
  local id _name managed
  local -a extension_ids=()
  local -a force_ids=()
  [[ -r "${POLICY_PATH}" ]] || return 1
  while IFS=$'\t' read -r id _name managed; do
    extension_ids+=("${id}")
    [[ -z "${managed}" ]] || force_ids+=("${id}")
  done < <(managed_extensions)
  if [[ ${PLATFORM} == Darwin ]]; then
    profile_helper verify-policy \
      "${EXPECTED_BUNDLE_ID}" "${extension_ids[@]}" -- "${force_ids[@]}"
  else
    profile_helper verify-policy-file \
      "${POLICY_PATH}" "${extension_ids[@]}" -- "${force_ids[@]}"
  fi
}

require_policy_privileges() {
  verify_extension_policy >/dev/null 2>&1 && return 0
  /usr/bin/sudo -v || die 1 \
    "Administrator authentication is required for ${POLICY_PATH}. Run sudo -v in your terminal, then rerun jsh --yes update."
}

install_extension_policy() {
  verify_extension_policy >/dev/null 2>&1 && return 0

  local staged_policy id _name managed attempt
  local -a extension_ids=()
  local -a force_ids=()
  jsh::log_warn "Helium's extension policy is missing or inactive."
  jsh::log_note "Administrator approval is required to install the managed policy at ${POLICY_PATH}."
  /usr/bin/sudo -v || die 1 \
    "Could not obtain administrator approval. The Helium extension policy was not changed; rerun setup and approve the password prompt."
  /bin/mkdir -p "${JSH_ROOT}/tmp"
  staged_policy="$(/usr/bin/mktemp "${JSH_ROOT}/tmp/helium-policy.XXXXXX")"
  jsh_interrupt_cleanup_path "${staged_policy}"
  if [[ ${PLATFORM} == Darwin ]]; then
    if [[ -e "${POLICY_PATH}" ]]; then
      /usr/bin/sudo /bin/cp "${POLICY_PATH}" "${staged_policy}" ||
        die 1 "Cannot read the existing Helium policy."
    else
      /usr/bin/plutil -create xml1 "${staged_policy}"
    fi
    /usr/libexec/PlistBuddy -c 'Print :ExtensionSettings' "${staged_policy}" >/dev/null 2>&1 ||
      /usr/libexec/PlistBuddy -c 'Add :ExtensionSettings dict' "${staged_policy}"
    /usr/libexec/PlistBuddy -c 'Delete :ExtensionInstallForcelist' "${staged_policy}" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :ExtensionInstallForcelist array' "${staged_policy}"
    while IFS=$'\t' read -r id _name managed; do
      [[ -z "${managed}" ]] ||
        /usr/libexec/PlistBuddy -c "Add :ExtensionInstallForcelist: string ${id}" "${staged_policy}"
      /usr/libexec/PlistBuddy -c "Delete :ExtensionSettings:${id}" "${staged_policy}" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :ExtensionSettings:${id} dict" "${staged_policy}"
      /usr/libexec/PlistBuddy -c "Add :ExtensionSettings:${id}:toolbar_pin string force_pinned" "${staged_policy}"
    done < <(managed_extensions)
    /usr/bin/plutil -lint "${staged_policy}" >/dev/null || die 1 "Cannot prepare the Helium extension policy."
    /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 755 \
      "/Library/Managed Preferences" \
      "$(/usr/bin/dirname "${POLICY_PATH}")"
    /usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 \
      "${staged_policy}" "${POLICY_PATH}" || die 1 "Cannot install the Helium extension policy."
  else
    while IFS=$'\t' read -r id _name managed; do
      extension_ids+=("${id}")
      [[ -z "${managed}" ]] || force_ids+=("${id}")
    done < <(managed_extensions)
    profile_helper stage-policy \
      "${staged_policy}" "${extension_ids[@]}" -- "${force_ids[@]}" ||
      die 1 "Cannot prepare the Helium extension policy."
    /usr/bin/sudo /usr/bin/install -d -o root -g root -m 755 \
      "$(/usr/bin/dirname "${POLICY_PATH}")"
    /usr/bin/sudo /usr/bin/install -o root -g root -m 644 \
      "${staged_policy}" "${POLICY_PATH}" || die 1 "Cannot install the Helium extension policy."
  fi
  /bin/rm -f "${staged_policy}"
  if [[ ${PLATFORM} == Linux ]]; then
    verify_extension_policy || die 1 \
      "The policy was written to ${POLICY_PATH}, but Helium did not activate it. Quit Helium, rerun setup, and check that the managed policy directory is readable."
    return
  fi
  /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    verify_extension_policy >/dev/null 2>&1 && return 0
    /bin/sleep 0.1
  done
  die 1 \
    "The policy was written to ${POLICY_PATH}, but macOS did not activate it. Quit Helium, rerun setup, and check that the managed preferences path is readable by ${POLICY_USER}."
}

configure_extensions() {
  local browser_pid devtools_file port attempt id _name update_url bootstrap_status=0
  local -a extension_ids=()
  while IFS=$'\t' read -r id _name update_url; do
    extension_ids+=("${id}")
  done < <(managed_extensions)

  devtools_file="${PROFILE_ROOT}/DevToolsActivePort"
  /bin/rm -f "${devtools_file}"
  "$(app_executable)" \
    --headless=new \
    --remote-debugging-port=0 \
    --remote-allow-origins=http://127.0.0.1 \
    --user-data-dir="${PROFILE_ROOT}" \
    --profile-directory=Default \
    --no-first-run \
    --no-default-browser-check \
    --disable-sync \
    'chrome://extensions/' >/dev/null 2>&1 &
  browser_pid=$!

  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -s "${devtools_file}" ]] && break
    /bin/kill -0 "${browser_pid}" >/dev/null 2>&1 || die 1 "Helium stopped during extension setup."
    /bin/sleep 0.1
  done
  [[ -s "${devtools_file}" ]] || {
    /bin/kill "${browser_pid}" >/dev/null 2>&1 || true
    die 1 "Helium did not expose its extension setup endpoint."
  }
  IFS= read -r port < "${devtools_file}"

  /usr/bin/env node "${EXTENSION_HELPER}" configure \
    "${port}" "${extension_ids[@]}" || bootstrap_status=$?
  for ((attempt = 0; attempt < 100; attempt++)); do
    /bin/kill -0 "${browser_pid}" >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
  if /bin/kill -0 "${browser_pid}" >/dev/null 2>&1; then
    /bin/kill "${browser_pid}" >/dev/null 2>&1 || true
  fi
  wait "${browser_pid}" 2>/dev/null || true
  browser_is_running &&
    die 1 "Helium did not stop after extension setup."
  ((bootstrap_status == 0)) || die 1 "Cannot configure Helium extensions."
  profile_helper pin-extensions \
    "${PROFILE_ROOT}/Default/Preferences" "${extension_ids[@]}"
}

verify_extensions() {
  local secure_preferences="${PROFILE_ROOT}/Default/Secure Preferences"
  local preferences="${PROFILE_ROOT}/Default/Preferences"
  local id _name update_url
  local -a extension_ids=()
  local -a incognito_ids=()
  while IFS=$'\t' read -r id _name update_url; do
    extension_ids+=("${id}")
    [[ -z "${update_url}" ]] || incognito_ids+=("${id}")
  done < <(managed_extensions)
  [[ -r "${secure_preferences}" && -r "${preferences}" ]] ||
    die 1 "Helium extension state is missing. Run apply again."
  /usr/bin/env node "${EXTENSION_HELPER}" verify-state \
    "${secure_preferences}" "${preferences}" \
    "${extension_ids[@]}" -- "${incognito_ids[@]}"
}

stage_json() {
  local preferences_file="$1"
  local local_state_file="$2"
  local staged_preferences="$3"
  local staged_local_state="$4"

  profile_helper stage \
    "${preferences_file}" "${local_state_file}" "${staged_preferences}" "${staged_local_state}"
}

stage_history() {
  local staged_history="$1"
  /bin/rm -f "${staged_history}"
  sqlite3 "${staged_history}" <<'SQL'
CREATE TABLE urls(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url LONGVARCHAR,
  title LONGVARCHAR,
  visit_count INTEGER DEFAULT 0 NOT NULL,
  typed_count INTEGER DEFAULT 0 NOT NULL,
  last_visit_time INTEGER NOT NULL,
  hidden INTEGER DEFAULT 0 NOT NULL
);
CREATE INDEX urls_url_index ON urls (url);
INSERT INTO urls(url, title, visit_count, typed_count, last_visit_time, hidden)
VALUES('http://go/', '', 0, 1, 0, 0);
SQL
}

clear_sensitive_data() {
  local profile_dir
  while IFS= read -r -d '' profile_dir; do
    /usr/bin/find "${profile_dir}" -depth \
      \( -type d \( \
        -name blob_storage -o -name Cache -o -name 'Code Cache' -o -name Crashpad -o \
        -name DawnCache -o -name GPUCache -o -name GrShaderCache -o -name 'Media Cache' -o \
        -name Sessions -o -name 'Trust Tokens' \
      \) -o -type f \( \
        -name Cookies -o -name 'Cookies-*' -o -name Favicons -o -name 'Favicons-*' -o \
        -name History -o -name 'History-*' -o -name 'Login Data' -o -name 'Login Data-*' -o \
        -name 'Network Action Predictor' -o -name 'Network Action Predictor-*' -o \
        -name Shortcuts -o -name 'Shortcuts-*' -o -name 'Top Sites' -o -name 'Top Sites-*' -o \
        -name TransportSecurity -o -name 'Visited Links' -o -name 'Web Data' -o -name 'Web Data-*' -o \
        -name '*.dmp' \
      \) \) -exec /bin/rm -rf {} +
    if [[ -d "${profile_dir}/IndexedDB" ]]; then
      /usr/bin/find "${profile_dir}/IndexedDB" -mindepth 1 -maxdepth 1 \
        ! -name 'chrome-extension_*' -exec /bin/rm -rf {} +
    fi
  done < <(/usr/bin/find "${PROFILE_ROOT}" -maxdepth 1 -type d \( -name Default -o -name 'Profile [0-9]*' \) -print0)
}

extension_data_paths() {
  cat <<'EOF'
Default/CacheStorage
Default/DNR Extension Rules
Default/Extension Cookies
Default/Extension Cookies-journal
Default/Extension Rules
Default/Extension Scripts
Default/Extension State
Default/Extensions
Default/File System
Default/Local Extension Settings
Default/Local Storage
Default/Managed Extension Settings
Default/Service Worker
Default/Session Storage
Default/Storage
Default/Sync Extension Settings
EOF
}

backup_extension_data() {
  local backup_root="$1" relative source destination
  while IFS= read -r relative; do
    source="${PROFILE_ROOT}/${relative}"
    [[ -e "${source}" ]] || continue
    destination="${backup_root}/${relative}"
    /bin/mkdir -p "$(/usr/bin/dirname "${destination}")"
    /bin/cp -R -p "${source}" "${destination}" || return 1
  done < <(extension_data_paths)

  [[ -d "${PROFILE_ROOT}/Default/IndexedDB" ]] || return 0
  while IFS= read -r -d '' source; do
    relative="${source#"${PROFILE_ROOT}/"}"
    destination="${backup_root}/${relative}"
    /bin/mkdir -p "$(/usr/bin/dirname "${destination}")"
    /bin/cp -R -p "${source}" "${destination}" || return 1
  done < <(/usr/bin/find "${PROFILE_ROOT}/Default/IndexedDB" -mindepth 1 -maxdepth 1 \
    -name 'chrome-extension_*' -print0)
}

verify_json() {
  local preferences_file="$1"
  local local_state_file="$2"
  profile_helper verify \
    "${preferences_file}" "${local_state_file}"
}

verify_history() {
  local history_file="$1" result
  [[ -f "${history_file}" ]] || die 1 "The go host classifier is missing. Run apply first."
  result="$(sqlite3 -batch -readonly "file:${history_file}?immutable=1" \
    "PRAGMA integrity_check; SELECT url, visit_count, typed_count, hidden FROM urls WHERE url = 'http://go/';")" ||
    die 1 "Cannot verify the History database."
  [[ "${result}" == $'ok\nhttp://go/|0|1|0' ]] || die 1 "The go host classifier is missing. Run apply again."
}

verify_profile_settings() {
  verify_json "${PROFILE_ROOT}/Default/Preferences" "${PROFILE_ROOT}/Local State" ||
    die 1 "The Helium profile is not fully hardened. Run apply again."
  verify_history "${PROFILE_ROOT}/Default/History"
}

verify_profile() {
  verify_extension_policy || die 1 "Helium's extension policy is missing or inactive. Run apply again."
  verify_extensions
  verify_profile_settings
}

is_patched() {
  (
    verify_app || exit 1
    verify_extension_policy || exit 1
    verify_extensions || exit 1
    verify_profile_settings || exit 1
  ) >/dev/null 2>&1
}

patch_status() {
  [[ "$#" -eq 0 ]] || die 64 "status accepts no arguments."
  if is_patched; then
    jsh::log_success "Helium is patched."
  else
    jsh::log_warn "Helium needs patching."
    return 1
  fi
}

apply_profile() {
  local default_dir="${PROFILE_ROOT}/Default"
  local preferences_file="${default_dir}/Preferences"
  local local_state_file="${PROFILE_ROOT}/Local State"
  local staged_preferences="${default_dir}/Preferences.new"
  local staged_local_state="${PROFILE_ROOT}/Local State.new"
  local staged_history="${default_dir}/History.new"

  /bin/mkdir -p "${default_dir}"
  stage_json "${preferences_file}" "${local_state_file}" "${staged_preferences}" "${staged_local_state}" ||
    die 1 "Cannot prepare hardened preferences."
  stage_history "${staged_history}" || die 1 "Cannot prepare the go host classifier."
  /bin/chmod 600 "${staged_preferences}" "${staged_local_state}" "${staged_history}"

  verify_json "${staged_preferences}" "${staged_local_state}" || die 1 "Prepared preferences failed validation."
  verify_history "${staged_history}"

  clear_sensitive_data
  /bin/mv -f "${staged_preferences}" "${preferences_file}"
  /bin/mv -f "${staged_local_state}" "${local_state_file}"
  /bin/mv -f "${staged_history}" "${default_dir}/History"
  verify_profile_settings
}

apply() {
  local quit=false
  local argument
  for argument in "$@"; do
    case ${argument} in
      --quit) quit=true ;;
      -y | --yes) export JSH_ASSUME_YES=1 ;;
      *) die 64 "apply accepts only --quit and -y/--yes." ;;
    esac
  done
  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]]; then
    jsh::log_detail 'Would inspect, update, and harden Helium.'
    return
  fi
  load_brew
  require_command node
  require_command sqlite3
  if [[ ${PLATFORM} == Darwin ]]; then
    require_command osascript
  fi

  if [[ ${JSH_UPDATE:-0} != 1 ]] && is_patched; then
    jsh::log_note "Helium is already configured and hardened."
    return 0
  fi

  require_policy_privileges
  stop_for_apply "${quit}"
  upgrade_app
  verify_app
  install_linux_launcher
  install_extension_policy
  apply_profile
  configure_extensions
  verify_profile
  jsh::log_success "Helium is updated, hardened, and ready."
}

profile_root_is_safe() {
  local canonical_home canonical_profile parent expected_leaf
  canonical_home=$(cd -- "${HOME}" && pwd -P) || return 1
  if [[ -d ${PROFILE_ROOT} ]]; then
    canonical_profile=$(cd -- "${PROFILE_ROOT}" && pwd -P) || return 1
  else
    parent=$(cd -- "$(/usr/bin/dirname "${PROFILE_ROOT}")" && pwd -P) || return 1
    canonical_profile="${parent}/${PROFILE_ROOT##*/}"
  fi
  case ${PLATFORM} in
    Darwin) expected_leaf=${EXPECTED_BUNDLE_ID} ;;
    Linux) expected_leaf=helium ;;
    *) return 1 ;;
  esac
  [[ ${canonical_profile} == "${canonical_home}"/* && ${canonical_profile##*/} == "${expected_leaf}" ]]
}

reset_profile() {
  local force=false delete_all=false argument backup_root prompt
  for argument in "$@"; do
    case "${argument}" in
      --all) delete_all=true ;;
      --force) force=true ;;
      *) die 64 "reset accepts only --all and --force." ;;
    esac
  done
  require_stopped
  profile_root_is_safe || die 1 "Refusing to reset an unsafe profile path: ${PROFILE_ROOT}"

  if [[ "${force}" != true ]]; then
    [[ -t 0 ]] || die 1 "reset requires --force when input is not interactive."
    if [[ "${delete_all}" == true ]]; then
      prompt="Delete the Helium profile and all extension data at ${PROFILE_ROOT}?"
    else
      prompt="Reset the Helium profile at ${PROFILE_ROOT} while preserving extension data?"
    fi
    jsh::confirm "${prompt}" --default no || die 1 "Reset cancelled."
  fi

  if [[ "${delete_all}" != true ]]; then
    /bin/mkdir -p "${JSH_ROOT}/tmp"
    backup_root="$(/usr/bin/mktemp -d "${JSH_ROOT}/tmp/helium-extension-data.XXXXXX")"
    backup_extension_data "${backup_root}" ||
      die 1 "Cannot back up extension data. Backup retained at ${backup_root}."
  fi
  /bin/rm -rf -- "${PROFILE_ROOT:?}"
  if [[ "${delete_all}" == true ]]; then
    jsh::log_success "Helium profile and extension data reset."
    return 0
  fi

  /bin/mkdir -p "${PROFILE_ROOT}"
  /bin/cp -R -p "${backup_root}/." "${PROFILE_ROOT}/" ||
    die 1 "Cannot restore extension data. Backup retained at ${backup_root}."
  /bin/rm -rf -- "${backup_root}"
  jsh::log_success "Helium profile reset; extension data preserved."
}

launch() {
  local executable
  local -a browser_arguments=("$@")
  if [[ "${1:-}" == "--" ]]; then
    browser_arguments=("${@:2}")
  fi
  load_brew
  require_command node
  require_command sqlite3
  verify_app
  verify_profile
  if [[ ${PLATFORM} == Darwin ]]; then
    /usr/bin/open -a "${APP_PATH}" --args \
      --user-data-dir="${PROFILE_ROOT}" \
      --profile-directory=Default \
      --no-first-run \
      --no-default-browser-check \
      --disable-sync \
      --disable-notifications \
      --disable-breakpad \
      "${browser_arguments[@]}"
  else
    if ((${#browser_arguments[@]} == 0)); then
      browser_arguments=(about:blank)
    fi
    executable=$(app_executable)
    exec "${executable}" \
      --user-data-dir="${PROFILE_ROOT}" \
      --profile-directory=Default \
      --no-first-run \
      --no-default-browser-check \
      --disable-sync \
      --disable-notifications \
      --disable-breakpad \
      --new-window \
      "${browser_arguments[@]}" >/dev/null 2>&1
  fi
}

stop() {
  [[ "$#" -eq 0 ]] || die 64 "stop accepts no arguments."
  stop_for_apply true
}

restart() {
  stop
  launch "$@"
}

main() {
  local command="${1:-apply}"
  case "${command}" in
    apply) [[ "$#" -eq 0 ]] || shift; apply "$@" ;;
    status) shift; patch_status "$@" ;;
    open | launch) shift; launch "$@" ;;
    stop) shift; stop "$@" ;;
    restart) shift; restart "$@" ;;
    reset) shift; reset_profile "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 64 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
