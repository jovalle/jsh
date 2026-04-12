#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s APP[.app] [--check]\n' "${0##*/}"
}

mode=guide
app_argument=
for argument in "$@"; do
  case "${argument}" in
    --check) mode=check ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      [[ -z ${app_argument} ]] || {
        usage >&2
        exit 2
      }
      app_argument=${argument}
      ;;
  esac
done

[[ $(uname -s) == Darwin ]] || {
  printf 'App permissions can only be checked on macOS.\n' >&2
  exit 1
}
[[ -n ${app_argument} ]] || {
  usage >&2
  exit 2
}

if [[ -t 1 && -z ${NO_COLOR+x} ]]; then
  reset=$'\033[0m' bold=$'\033[1m' red=$'\033[31m' green=$'\033[32m'
  yellow=$'\033[33m' cyan=$'\033[36m' dim=$'\033[2m'
else
  reset='' bold='' red='' green='' yellow='' cyan='' dim=''
fi

heading() {
  printf '\n%b%s%b\n' "${bold}${cyan}" "$1" "${reset}"
}

status_row() {
  local label=$1 status=$2 detail=${3:-} color=${yellow}
  case "${status}" in
    granted | registered) color=${green} ;;
    denied | unknown) color=${red} ;;
  esac
  if [[ -n ${detail} ]]; then
    printf '%-22s %b%-15s%b %b%s%b\n' \
      "${label}" "${color}" "${status}" "${reset}" "${dim}" "${detail}" "${reset}"
  else
    printf '%-22s %b%s%b\n' "${label}" "${color}" "${status}" "${reset}"
  fi
}

resolve_app() {
  local argument=$1 candidate name matches=

  if [[ -f ${argument}/Contents/Info.plist ]]; then
    printf '%s/%s\n' "$(CDPATH='' cd -- "$(dirname -- "${argument}")" && pwd -P)" "$(basename -- "${argument}")"
    return
  fi

  name=$(basename -- "${argument}")
  [[ ${name} == *.app ]] || name=${name}.app
  for candidate in "/Applications/${name}" "${HOME}/Applications/${name}" "/System/Applications/${name}"; do
    if [[ -f ${candidate}/Contents/Info.plist ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  while IFS= read -r candidate; do
    [[ ${candidate##*/} != "${name}" || ! -f ${candidate}/Contents/Info.plist ]] \
      || matches+="${matches:+$'\n'}${candidate}"
  done < <(mdfind -name "${name}" 2>/dev/null)

  [[ -n ${matches} && ${matches} != *$'\n'* ]] || {
    [[ -z ${matches} ]] || printf 'Multiple matches; pass a full path:\n%s\n' "${matches}" >&2
    return 1
  }
  printf '%s\n' "${matches}"
}

app_path=$(resolve_app "${app_argument}") || {
  printf 'Could not find app: %s\n' "${app_argument}" >&2
  exit 1
}
info_plist=${app_path}/Contents/Info.plist
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)
[[ ${bundle_id} =~ ^[A-Za-z0-9.-]+$ ]] || {
  printf 'The app has no valid CFBundleIdentifier: %s\n' "${app_path}" >&2
  exit 1
}
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${info_plist}" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${info_plist}" 2>/dev/null || basename -- "${app_path}" .app)

databases=(
  "${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
  '/Library/Application Support/com.apple.TCC/TCC.db'
)

command -v sqlite3 >/dev/null 2>&1 || {
  printf 'sqlite3 is required to inspect macOS privacy permissions.\n' >&2
  exit 1
}

# Label, TCC service, Settings pane, description.
permissions=()
permission() {
  permissions+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
}
permission 'Full Disk Access' kTCCServiceSystemPolicyAllFiles Privacy_AllFiles 'all protected files'
permission Accessibility kTCCServiceAccessibility Privacy_Accessibility 'control of the interface and input'
permission Accessibility kTCCServicePostEvent Privacy_Accessibility 'synthetic keyboard and pointer events'
permission 'Screen Recording' kTCCServiceScreenCapture Privacy_ScreenCapture 'screen and window contents'
permission 'Input Monitoring' kTCCServiceListenEvent Privacy_ListenEvent 'keyboard and pointing-device events'
permission 'Developer Tools' kTCCServiceDeveloperTool Privacy_DevTools 'developer tool access'
permission 'Remote Desktop' kTCCServiceRemoteDesktop Privacy_RemoteDesktop 'remote desktop control'
permission 'Local Network' kJSHServiceLocalNetwork Privacy_LocalNetwork 'devices on the local network'
permission Camera kTCCServiceCamera Privacy_Camera 'the camera'
permission Microphone kTCCServiceMicrophone Privacy_Microphone 'the microphone'
permission 'App audio capture' kTCCServiceAudioCapture Privacy_AudioCapture 'audio from other apps'
permission Automation kTCCServiceAppleEvents Privacy_Automation 'control of other apps'
permission Bluetooth kTCCServiceBluetoothAlways Privacy_Bluetooth 'Bluetooth devices'
permission Focus kTCCServiceFocusStatus Privacy_Focus 'Focus status'
permission Motion kTCCServiceMotion Privacy_Motion 'motion and fitness data'
permission HomeKit kTCCServiceWillow Privacy_HomeKit 'Home data'
permission Contacts kTCCServiceAddressBook Privacy_Contacts contacts
permission Calendars kTCCServiceCalendar Privacy_Calendars calendars
permission Reminders kTCCServiceReminders Privacy_Reminders reminders
permission Photos kTCCServicePhotos Privacy_Photos 'the photo library'
permission 'Media Library' kTCCServiceMediaLibrary Privacy_Media 'music and media activity'
permission 'Speech Recognition' kTCCServiceSpeechRecognition Privacy_SpeechRecognition 'speech recognition'
permission 'Location Services' kTCCServiceLocation Privacy_LocationServices location
permission 'Desktop folder' kTCCServiceSystemPolicyDesktopFolder Privacy_FilesAndFolders 'the Desktop folder'
permission 'Documents folder' kTCCServiceSystemPolicyDocumentsFolder Privacy_FilesAndFolders 'the Documents folder'
permission 'Downloads folder' kTCCServiceSystemPolicyDownloadsFolder Privacy_FilesAndFolders 'the Downloads folder'
permission 'Network volumes' kTCCServiceSystemPolicyNetworkVolumes Privacy_FilesAndFolders 'network volumes'
permission 'Removable volumes' kTCCServiceSystemPolicyRemovableVolumes Privacy_FilesAndFolders 'removable volumes'
permission 'App data' kTCCServiceSystemPolicyAppData Privacy_FilesAndFolders 'other applications data'
permission 'File providers' kTCCServiceFileProviderDomain Privacy_FilesAndFolders 'file provider domains'
permission 'App Management' kTCCServiceSystemPolicyAppBundles Privacy_AppBundles 'installation, updates, or removal of apps'
permission Passkeys kTCCServiceWebBrowserPublicKeyCredential Privacy_PasskeyAccess 'passkeys from web browsers'
permission Notifications kJSHServiceNotifications Notifications 'notification delivery settings'

permission_records=''
databases_read=0
databases_present=0
refresh_permissions() {
  local database rows

  permission_records=''
  databases_read=0
  databases_present=0
  for database in "${databases[@]}"; do
    [[ -e ${database} ]] || continue
    ((databases_present += 1))
    if rows=$(sqlite3 -readonly "${database}" \
      "SELECT service, auth_value FROM access WHERE client = '${bundle_id}' ORDER BY last_modified;" 2>/dev/null); then
      ((databases_read += 1))
      permission_records+="${permission_records:+$'\n'}${rows}"
    fi
  done
}

local_network_status() {
  local preferences

  preferences=$(defaults read /Library/Preferences/com.apple.networkextension 2>/dev/null) || return 0
  awk -v app="\"${bundle_id}\"," '
    index($0, app) { found = 1; next }
    found && /DenyMulticast =/ { deny = $3; gsub(/;/, "", deny) }
    found && /MulticastPreferenceSet =/ {
      configured = $3
      gsub(/;/, "", configured)
      if (configured == 1) print (deny == 0 ? "granted" : "denied")
      exit
    }
  ' <<<"${preferences}"
}

location_status() {
  local clients

  clients=$(plutil -p /var/db/locationd/clients.plist 2>/dev/null) || return 0
  awk -v bundle="\"BundleId\" => \"${bundle_id}\"" '
    /^  ".*" => \{$/ { record = $0 ORS; next }
    length(record) {
      record = record $0 ORS
      if ($0 == "  }") {
        if (index(record, bundle)) {
          if (index(record, "\"Authorized\" => true")) print "granted"
          else if (index(record, "\"Authorized\" => false")) print "denied"
          else if (index(record, "\"Registered\" => true")) print "registered"
          exit
        }
        record = ""
      }
    }
  ' <<<"${clients}"
}

permission_status() {
  local service=$1 value

  if [[ ${service} == kJSHServiceNotifications ]]; then
    printf 'registered\n'
    return
  fi
  if [[ ${service} == kJSHServiceLocalNetwork ]]; then
    local_network_status
    return
  fi
  if [[ ${service} == kTCCServiceLocation ]]; then
    location_status
    return
  fi
  value=$(awk -F '|' -v service="${service}" '$1 == service { value = $2 } END { print value }' \
    <<<"${permission_records}")
  case "${value}" in
    0) printf 'denied\n' ;;
    2) printf 'granted\n' ;;
    3) printf 'limited\n' ;;
    '')
      ((databases_read == ${#databases[@]})) && printf 'not requested\n' || printf 'unknown\n'
      ;;
    *) printf 'unknown\n' ;;
  esac
}

stably_granted() {
  refresh_permissions
  [[ $(permission_status "$1") == granted ]] || return 1
  sleep 2
  refresh_permissions
  [[ $(permission_status "$1") == granted ]]
}

confirm_grant() {
  local label=$1 service=$2
  printf '%b%s appears enabled.%b Resolve any macOS quit/reopen prompt, then press Return: ' \
    "${yellow}" "${label}" "${reset}"
  IFS= read -r answer </dev/tty || return 1
  sleep 1
  refresh_permissions
  [[ $(permission_status "${service}") == granted ]]
}

refresh_requested_services() {
  local notifications_db

  refresh_permissions
  requested_services=$(awk -F '|' 'NF { print $1 }' <<<"${permission_records}" | sort -u)
  notifications_db="${HOME}/Library/Group Containers/group.com.apple.usernoted/db2/db"
  if sqlite3 -readonly "${notifications_db}" \
    "SELECT 1 FROM app WHERE identifier = '${bundle_id}' LIMIT 1;" 2>/dev/null | grep -qx 1; then
    requested_services+="${requested_services:+$'\n'}kJSHServiceNotifications"
  fi
  if [[ -n $(local_network_status) ]]; then
    requested_services+="${requested_services:+$'\n'}kJSHServiceLocalNetwork"
  fi
  if [[ -n $(location_status) ]]; then
    requested_services+="${requested_services:+$'\n'}kTCCServiceLocation"
  fi
}

service_requested() {
  grep -Fqx "$1" <<<"${requested_services}"
}
catalog_has_service() {
  local wanted=$1 row label service panel reason
  for row in "${permissions[@]}"; do
    IFS=$'\t' read -r label service panel reason <<<"${row}"
    [[ ${service} != "${wanted}" ]] || return 0
  done
  return 1
}

collect_permissions() {
  local row label service panel reason status

  detected=()
  unmapped=
  needs_setup=0
  refresh_requested_services
  for row in "${permissions[@]}"; do
    IFS=$'\t' read -r label service panel reason <<<"${row}"
    service_requested "${service}" || continue
    detected+=("${row}")
    status=$(permission_status "${service}")
    [[ ${status} == granted || ${status} == registered ]] || needs_setup=1
  done
  while IFS= read -r service; do
    if [[ -n ${service} ]] && ! catalog_has_service "${service}"; then
      unmapped+="${unmapped:+$'\n'}${service}"
      needs_setup=1
    fi
  done <<<"${requested_services}"
}

heading "${app_name} permissions"
printf '%b%s%b\n' "${dim}" "${app_path}" "${reset}"
refresh_permissions
if ((databases_present > 0 && databases_read == 0)); then
  printf '\n%bThe terminal running this check cannot read macOS privacy records.%b\n' "${red}" "${reset}"
  printf 'If macOS asks whether the terminal may access data from other apps, choose Allow. '
  printf "If you chose Don't Allow, rerun this command and allow it.\n"
  printf 'If the check remains blocked, add the terminal to Privacy & Security > Full Disk Access, then rerun.\n'
  exit 1
fi
collect_permissions
for row in "${detected[@]}"; do
  IFS=$'\t' read -r label service panel reason <<<"${row}"
  status_row "${label}" "$(permission_status "${service}")"
done

if ((${#detected[@]} == 0)) && [[ -z ${unmapped} ]]; then
  printf '%bNo registered permissions found.%b\n' "${dim}" "${reset}"
  exit 0
fi
[[ -z ${unmapped} ]] || printf '\n%bUnmapped requested services%b\n%s\n' "${red}" "${reset}" "${unmapped}"

if [[ ${mode} == check ]]; then
  failed=0
  for row in "${detected[@]}"; do
    IFS=$'\t' read -r label service panel reason <<<"${row}"
    status=$(permission_status "${service}")
    service_requested "${service}" && [[ ${status} != granted && ${status} != registered ]] && failed=1
  done
  [[ -z ${unmapped} ]] || failed=1
  ((failed == 0))
  exit
fi
[[ -r /dev/tty && -w /dev/tty ]] || {
  printf '\nGuided setup requires an interactive terminal. Use --check for status only.\n' >&2
  exit 1
}
if ((needs_setup == 0)); then
  printf '\n%bAll detected permissions are granted.%b\n' "${green}" "${reset}"
  exit 0
fi
printf '\nBegin guided setup? [y/N] '
IFS= read -r -s -n 1 answer </dev/tty || answer=
printf '\n'
[[ ${answer} == [yY] ]] || {
  printf '\nNo changes made.\n'
  exit 0
}

open_with_retry() {
  local target=$1 label=$2 answer
  while ! open "${target}"; do
    printf '%bCould not open %s.%b [r] retry, [s] skip, [q] finish: ' "${red}" "${label}" "${reset}"
    IFS= read -r answer </dev/tty || answer=q
    case "${answer}" in
      r | R | retry | RETRY) ;;
      s | S | skip | SKIP) return 2 ;;
      *) return 3 ;;
    esac
  done
  sleep 1
}

guide_panel() {
  local label=$1 service=$2 panel=$3 reason=$4 answer result target key
  refresh_permissions
  status_row "${label}" "$(permission_status "${service}")" "allows ${reason}"
  printf '[Enter] open settings, [s] skip, [q] finish: '
  IFS= read -r answer </dev/tty || answer=q
  case "${answer}" in
    s | S | skip | SKIP) return 2 ;;
    q | Q | quit | QUIT) return 3 ;;
  esac

  target="x-apple.systempreferences:com.apple.preference.security?${panel}"
  result=0
  open_with_retry "${target}" "${label} panel" || result=$?
  ((result == 0)) || return "${result}"

  printf 'Waiting. [r] reopen panel, [s] skip, [q] finish\n'
  while :; do
    if stably_granted "${service}" && confirm_grant "${label}" "${service}"; then
      return 0
    fi
    key=
    if IFS= read -r -s -n 1 -t 1 key </dev/tty; then
      case "${key}" in
        r | R)
          if open "${target}"; then
            sleep 1
            printf '%s panel reopened.\n' "${label}"
          else
            printf '%bCould not reopen %s panel.%b\n' "${red}" "${label}" "${reset}"
          fi
          ;;
        s | S) return 2 ;;
        q | Q) return 3 ;;
      esac
    fi
  done
}

processed_services=
while :; do
  collect_permissions
  current_row=
  for row in "${detected[@]}"; do
    IFS=$'\t' read -r label service panel reason <<<"${row}"
    status=$(permission_status "${service}")
    [[ ${status} != granted && ${status} != registered ]] || continue
    grep -Fqx "${service}" <<<"${processed_services}" && continue
    current_row=${row}
    break
  done
  [[ -n ${current_row} ]] || break

  IFS=$'\t' read -r label service panel reason <<<"${current_row}"
  processed_services+="${processed_services:+$'\n'}${service}"
  heading "${label}"

  if [[ $(permission_status "${service}") == unknown ]]; then
    printf '%bCannot monitor TCC. Grant Full Disk Access to this terminal and retry.%b\n' "${red}" "${reset}"
    continue
  fi

  result=0
  guide_panel "${label}" "${service}" "${panel}" "${reason}" || result=$?
  case "${result}" in
    0)
      printf '%b%s granted.%b\n' "${green}" "${label}" "${reset}"
      ;;
    2) printf '%b%s skipped.%b\n' "${yellow}" "${label}" "${reset}" ;;
    3)
      break
      ;;
  esac
done

remaining=0
collect_permissions
for row in "${detected[@]}"; do
  IFS=$'\t' read -r label service panel reason <<<"${row}"
  status=$(permission_status "${service}")
  if [[ ${status} != granted && ${status} != registered ]]; then
    ((remaining += 1))
  fi
done
if [[ -n ${unmapped} ]]; then
  while IFS= read -r service; do
    ((remaining += 1))
  done <<<"${unmapped}"
fi
((remaining == 0))
