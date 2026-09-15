#!/usr/bin/env bash
# Install, upgrade, and harden Helium on macOS and Linux.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
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
PLATFORM="$(uname -s)"
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
  printf 'helium: %s\n' "$2" >&2
  exit "$1"
}

usage() {
  cat <<'EOF'
Usage:
  helium [apply [--quit]]
  helium status
  helium launch [--] [BROWSER_ARGS...]
  helium reset [--all] [--force]

apply   Upgrade Helium, install and pin extensions, and apply hardened settings.
        --quit authorizes quitting a running Helium instance without prompting.
status  Check whether Helium is patched.
launch  Verify the profile and launch Helium in a hardened regular window.
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
  local authorized="${1:-false}" answer attempt
  browser_is_running || return 0

  if [[ "${authorized}" != true ]]; then
    [[ -t 0 ]] || die 1 "Helium is running. Rerun apply with --quit."
    printf 'Helium is running. Quit it now? [y/N] ' >&2
    IFS= read -r answer
    [[ "${answer}" == [yY] || "${answer}" == [yY][eE][sS] ]] || die 1 "Apply cancelled."
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
  local brew_command milestone
  if [[ ${PLATFORM} == Linux ]]; then
    require_command python3
    /usr/bin/env python3 "${JSH_ROOT}/lib/apps.py" apply --only helium --yes ||
      die 1 "The native application installer could not install or update Helium."
    return
  fi
  brew_command="$(command -v brew || true)"
  [[ -n "${brew_command}" ]] || die 1 "Homebrew is required to install or update Helium."

  "${brew_command}" update || die 1 "Homebrew could not update package metadata."
  if "${brew_command}" list --cask helium-browser >/dev/null 2>&1; then
    "${brew_command}" upgrade --cask helium-browser || die 1 "Homebrew could not update Helium."
    milestone="$(chromium_milestone 2>/dev/null || true)"
    if [[ ! "${milestone}" =~ ^[0-9]+$ ]] || (( milestone < MIN_CHROMIUM_MILESTONE )); then
      "${brew_command}" reinstall --cask --force helium-browser || die 1 "Homebrew could not replace the outdated Helium application."
    fi
  else
    "${brew_command}" install --cask --force helium-browser || die 1 "Homebrew could not install Helium."
  fi
}

verify_app() {
  local milestone
  if [[ ${PLATFORM} == Darwin ]]; then
    [[ -d "${APP_PATH}" ]] || die 1 "Helium is not installed. Run apply first."
    local bundle_id team_id
    bundle_id="$(plist_value "${APP_PATH}" CFBundleIdentifier)" || die 1 "Cannot read Helium's bundle identifier."
    [[ "${bundle_id}" == "${EXPECTED_BUNDLE_ID}" ]] || die 1 "The installed app is not the expected Helium bundle."
    /usr/bin/codesign --verify --deep --strict "${APP_PATH}" >/dev/null 2>&1 || die 1 "Helium's code signature is invalid."
    team_id="$(/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    [[ "${team_id}" == "${EXPECTED_TEAM_ID}" ]] || die 1 "Helium is not signed by the expected developer team."
    /usr/sbin/spctl -a -t exec "${APP_PATH}" >/dev/null 2>&1 || die 1 "Gatekeeper rejected Helium."
  else
    app_executable >/dev/null || die 1 "Helium is not installed. Run apply first."
    /usr/bin/env python3 "${JSH_ROOT}/lib/apps.py" check --only helium --json >/dev/null ||
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

install_extension_policy() {
  verify_extension_policy >/dev/null 2>&1 && return 0

  local staged_policy id _name managed attempt
  local -a extension_ids=()
  local -a force_ids=()
  jsh_info "Administrator approval is required to manage Helium extensions."
  /usr/bin/sudo -v || die 1 "Administrator approval is required to manage Helium extensions."
  /bin/mkdir -p "${JSH_ROOT}/tmp"
  staged_policy="$(/usr/bin/mktemp "${JSH_ROOT}/tmp/helium-policy.XXXXXX")"
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
    verify_extension_policy || die 1 "Linux did not activate the Helium extension policy."
    return
  fi
  /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    verify_extension_policy >/dev/null 2>&1 && return 0
    /bin/sleep 0.1
  done
  die 1 "macOS did not activate the Helium extension policy."
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
    jsh_success "Helium is patched."
  else
    jsh_warn "Helium needs patching."
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
  case "${1:-}" in
    '') ;;
    --quit) quit=true ;;
    *) die 64 "apply accepts only --quit." ;;
  esac
  [[ "$#" -le 1 ]] || die 64 "apply accepts only --quit."
  require_command node
  require_command sqlite3
  if [[ ${PLATFORM} == Darwin ]]; then
    require_command osascript
  fi
  stop_for_apply "${quit}"
  upgrade_app
  verify_app
  install_extension_policy
  apply_profile
  configure_extensions
  verify_profile
  jsh_success "Helium is updated, hardened, and ready."
}

reset_profile() {
  local force=false delete_all=false answer argument backup_root
  for argument in "$@"; do
    case "${argument}" in
      --all) delete_all=true ;;
      --force) force=true ;;
      *) die 64 "reset accepts only --all and --force." ;;
    esac
  done
  require_stopped
  [[ -n "${PROFILE_ROOT}" && "${PROFILE_ROOT}" != / ]] || die 1 "Refusing to reset an unsafe profile path."

  if [[ "${force}" != true ]]; then
    [[ -t 0 ]] || die 1 "reset requires --force when input is not interactive."
    if [[ "${delete_all}" == true ]]; then
      printf 'Delete the Helium profile and all extension data at %s? [y/N] ' "${PROFILE_ROOT}" >&2
    else
      printf 'Reset the Helium profile at %s while preserving extension data? [y/N] ' "${PROFILE_ROOT}" >&2
    fi
    IFS= read -r answer
    [[ "${answer}" == [yY] || "${answer}" == [yY][eE][sS] ]] || die 1 "Reset cancelled."
  fi

  if [[ "${delete_all}" != true ]]; then
    /bin/mkdir -p "${JSH_ROOT}/tmp"
    backup_root="$(/usr/bin/mktemp -d "${JSH_ROOT}/tmp/helium-extension-data.XXXXXX")"
    backup_extension_data "${backup_root}" ||
      die 1 "Cannot back up extension data. Backup retained at ${backup_root}."
  fi
  /bin/rm -rf -- "${PROFILE_ROOT:?}"
  if [[ "${delete_all}" == true ]]; then
    jsh_success "Helium profile and extension data reset."
    return 0
  fi

  /bin/mkdir -p "${PROFILE_ROOT}"
  /bin/cp -R -p "${backup_root}/." "${PROFILE_ROOT}/" ||
    die 1 "Cannot restore extension data. Backup retained at ${backup_root}."
  /bin/rm -rf -- "${backup_root}"
  jsh_success "Helium profile reset; extension data preserved."
}

launch() {
  local -a browser_arguments=("$@")
  if [[ "${1:-}" == "--" ]]; then
    browser_arguments=("${@:2}")
  fi
  require_command node
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
    nohup "$(app_executable)" \
      --user-data-dir="${PROFILE_ROOT}" \
      --profile-directory=Default \
      --no-first-run \
      --no-default-browser-check \
      --disable-sync \
      --disable-notifications \
      --disable-breakpad \
      --new-window \
      "${browser_arguments[@]}" >/dev/null 2>&1 &
  fi
}

main() {
  local command="${1:-apply}"
  case "${command}" in
    apply) [[ "$#" -eq 0 ]] || shift; apply "$@" ;;
    status) shift; patch_status "$@" ;;
    launch) shift; launch "$@" ;;
    reset) shift; reset_profile "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 64 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
