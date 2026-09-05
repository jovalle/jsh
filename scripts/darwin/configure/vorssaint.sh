#!/usr/bin/env bash
# Configure Vorssaint onboarding, login startup, and managed settings.

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

readonly APP_PATH="/Applications/Vorssaint.app"
readonly BACKUP_PATH="${JSH_ROOT}/conf/vorssaint/Vorssaint Settings.plist"
readonly BUNDLE_ID="com.vorssaint.utils"
TEMP_DIR=
IMPORT_CONFIRMED=0
BACKUP_CONFIRMED=0
SETTINGS_DIFFER=0
SETTING_EXCLUDED=0
VORSSAINT_WAS_RUNNING=0
EXCLUDED_BACKUP_COUNT=0
MANAGED_SETTING_COUNT=0

cleanup() {
  [[ -z "${TEMP_DIR}" ]] || rm -rf -- "${TEMP_DIR}"
}

confirm_import() {
  jsh_prompt "Apply this backup to Vorssaint? [y/N]: "
  read -r answer || answer=
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    IMPORT_CONFIRMED=1
  fi
}

confirm_backup() {
  jsh_prompt "Replace the managed backup with these active settings? [y/N]: "
  read -r answer || answer=
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    BACKUP_CONFIRMED=1
  fi
}

review_line() {
  local color=$1
  shift

  if jsh_color_enabled 1; then
    printf '\033[%sm%s\033[0m\n' "${color}" "$*"
  else
    printf '%s\n' "$*"
  fi
}

summarize_keys() {
  awk '
    {
      if (NR <= 12) summary = summary (summary ? ", " : "") $0
    }
    END {
      if (NR > 12) summary = summary ", ... (" NR - 12 " more)"
      print summary
    }
  ' "$1"
}

write_top_level_records() {
  awk '
    function flush_record() {
      if (key != "") print key "\t" record
    }
    /^  "[^"]+" =>/ {
      flush_record()
      key = $0
      sub(/^  "/, "", key)
      sub(/" =>.*/, "", key)
      record = $0
      next
    }
    key != "" {
      record = record "\\n" $0
    }
    END {
      flush_record()
    }
  ' "$1" | LC_ALL=C sort > "$2"
}

classify_setting() {
  SETTING_EXCLUDED=0
  case $1 in
    featureAvailable.*)
      SETTING_EXCLUDED=1
      ;;
    lastUpdateIntroVersion | panelCollapsedResetVersion | supportUpdateIntroVersion | updateHighlightsSeenVersion)
      SETTING_EXCLUDED=1
      ;;
    mediaLastTool | screenshotFileNumberNext | screenshotLastColor | screenshotLastSticker | screenshotLastStroke | screenshotLastTool)
      SETTING_EXCLUDED=1
      ;;
    *) ;;
  esac
}

delete_plist_keys() {
  local plist=$1 keys=$2 setting commands_file

  [[ -s "${keys}" ]] || return
  commands_file=$(mktemp "${TEMP_DIR}/plistbuddy-delete.XXXXXX")
  while IFS= read -r setting || [[ -n "${setting}" ]]; do
    printf 'Delete :"%s"\n' "${setting}" >> "${commands_file}"
  done < "${keys}"
  printf '%s\n' Save Exit >> "${commands_file}"
  /usr/libexec/PlistBuddy "${plist}" < "${commands_file}" > /dev/null
}

overlay_plist() {
  local destination_plist=$1 overlay_plist=$2 shared_keys=$3 setting commands_file

  commands_file=$(mktemp "${TEMP_DIR}/plistbuddy-overlay.XXXXXX")
  while IFS= read -r setting || [[ -n "${setting}" ]]; do
    printf 'Delete :"%s"\n' "${setting}" >> "${commands_file}"
  done < "${shared_keys}"
  printf 'Merge "%s"\nSave\nExit\n' "${overlay_plist}" >> "${commands_file}"
  /usr/libexec/PlistBuddy "${destination_plist}" < "${commands_file}" > /dev/null
}

render_diff() {
  local line color

  while IFS= read -r line || [[ -n "${line}" ]]; do
    case ${line} in
      '--- '*|'+++ '*) color='1;36' ;;
      '@@'*) color=36 ;;
      -*) color=31 ;;
      +*) color=32 ;;
      *) color=2 ;;
    esac
    review_line "${color}" "${line}"
  done < "$1"
}

prepare_settings() {
  local active_plist=$1 managed_active_plist=$2 managed_backup_plist=$3 merged_plist=$4
  local exported_backup_plist="${TEMP_DIR}/exported-backup.plist"
  local backup_keys="${TEMP_DIR}/exported-backup-keys.txt"
  local managed_keys="${TEMP_DIR}/managed-keys.txt"
  local excluded_keys="${TEMP_DIR}/excluded-keys.txt"
  local active_records="${TEMP_DIR}/prepared-active-records.txt"
  local active_keys="${TEMP_DIR}/prepared-active-keys.txt"
  local unmanaged_active_keys="${TEMP_DIR}/unmanaged-active-keys.txt"
  local shared_managed_keys="${TEMP_DIR}/shared-managed-keys.txt"
  local setting

  plutil -extract settings xml1 -o "${exported_backup_plist}" "${BACKUP_PATH}"
  if ! defaults export "${BUNDLE_ID}" "${active_plist}" > /dev/null 2>&1; then
    plutil -create xml1 "${active_plist}"
  fi
  plutil -extract settings raw -o "${backup_keys}" "${BACKUP_PATH}"
  : > "${managed_keys}"
  : > "${excluded_keys}"

  while IFS= read -r setting || [[ -n "${setting}" ]]; do
    classify_setting "${setting}"
    if [[ "${SETTING_EXCLUDED}" -eq 1 ]]; then
      printf '%s\n' "${setting}" >> "${excluded_keys}"
    else
      printf '%s\n' "${setting}" >> "${managed_keys}"
    fi
  done < "${backup_keys}"

  LC_ALL=C sort -u -o "${managed_keys}" "${managed_keys}"
  LC_ALL=C sort -u -o "${excluded_keys}" "${excluded_keys}"
  MANAGED_SETTING_COUNT=$(awk 'END { print NR + 0 }' "${managed_keys}")
  EXCLUDED_BACKUP_COUNT=$(awk 'END { print NR + 0 }' "${excluded_keys}")

  cp -p "${exported_backup_plist}" "${managed_backup_plist}"
  delete_plist_keys "${managed_backup_plist}" "${excluded_keys}"

  plutil -p "${active_plist}" > "${TEMP_DIR}/active-all.txt"
  plutil -p "${exported_backup_plist}" > "${TEMP_DIR}/backup-all.txt"
  write_top_level_records "${TEMP_DIR}/active-all.txt" "${active_records}"
  cut -f 1 "${active_records}" > "${active_keys}"

  cp -p "${active_plist}" "${managed_active_plist}"
  LC_ALL=C comm -23 "${active_keys}" "${managed_keys}" > "${unmanaged_active_keys}"
  delete_plist_keys "${managed_active_plist}" "${unmanaged_active_keys}"

  cp -p "${active_plist}" "${merged_plist}"
  LC_ALL=C comm -12 "${active_keys}" "${managed_keys}" > "${shared_managed_keys}"
  overlay_plist "${merged_plist}" "${managed_backup_plist}" "${shared_managed_keys}"

  plutil -lint "${managed_active_plist}" "${managed_backup_plist}" "${merged_plist}" > /dev/null
  plutil -p "${managed_active_plist}" > "${TEMP_DIR}/active.txt"
  plutil -p "${managed_backup_plist}" > "${TEMP_DIR}/backup.txt"
}

create_backup_candidate() {
  local managed_active_plist=$1 candidate_settings=$2 candidate_backup=$3
  local commands_file="${TEMP_DIR}/plistbuddy-backup.commands"
  local app_version backup_version

  cp -p "${TEMP_DIR}/exported-backup.plist" "${candidate_settings}"
  overlay_plist "${candidate_settings}" "${managed_active_plist}" "${TEMP_DIR}/managed-keys.txt"

  app_version=$(plutil -extract CFBundleShortVersionString raw -o - "${APP_PATH}/Contents/Info.plist")
  backup_version=$(plutil -extract vorssaintBackupVersion raw -o - "${BACKUP_PATH}")
  cp -p "${BACKUP_PATH}" "${candidate_backup}"
  printf '%s\n' \
    'Delete :settings' \
    'Add :settings dict' \
    "Merge \"${candidate_settings}\" :settings" \
    "Set :vorssaintBackupAppVersion ${app_version}" \
    "Set :vorssaintBackupVersion ${backup_version}" \
    Save Exit > "${commands_file}"
  /usr/libexec/PlistBuddy "${candidate_backup}" < "${commands_file}" > /dev/null
  plutil -lint "${candidate_settings}" "${candidate_backup}" > /dev/null
}

show_backup_diff() {
  local candidate_backup=$1
  local current_text="${TEMP_DIR}/current-backup.txt"
  local candidate_text="${TEMP_DIR}/candidate-backup.txt"
  local diff_file="${TEMP_DIR}/backup.diff"
  local current_records="${TEMP_DIR}/current-backup-records.txt"
  local candidate_records="${TEMP_DIR}/candidate-backup-records.txt"
  local current_keys="${TEMP_DIR}/current-backup-keys.txt"
  local candidate_keys="${TEMP_DIR}/candidate-backup-keys.txt"
  local added_keys="${TEMP_DIR}/backup-added-keys.txt"
  local removed_keys="${TEMP_DIR}/backup-removed-keys.txt"
  local changed_keys="${TEMP_DIR}/backup-changed-keys.txt"
  local diff_status added_count removed_count changed_count unchanged_count summary backup_display

  plutil -p "${BACKUP_PATH}" > "${current_text}"
  plutil -p "${candidate_backup}" > "${candidate_text}"
  if diff -u -L "managed Vorssaint backup" -L "active Vorssaint export" \
    "${current_text}" "${candidate_text}" > "${diff_file}"; then
    return
  else
    diff_status=$?
  fi
  if [[ "${diff_status}" -ne 1 ]]; then
    jsh_error "Unable to compare active settings with the managed Vorssaint backup."
    return "${diff_status}"
  fi

  SETTINGS_DIFFER=1
  write_top_level_records "${TEMP_DIR}/backup.txt" "${current_records}"
  write_top_level_records "${TEMP_DIR}/active.txt" "${candidate_records}"
  cut -f 1 "${current_records}" > "${current_keys}"
  cut -f 1 "${candidate_records}" > "${candidate_keys}"
  LC_ALL=C comm -13 "${current_keys}" "${candidate_keys}" > "${added_keys}"
  LC_ALL=C comm -23 "${current_keys}" "${candidate_keys}" > "${removed_keys}"
  LC_ALL=C join -t $'\t' "${current_records}" "${candidate_records}" |
    awk -F '\t' '$2 != $3 { print $1 }' > "${changed_keys}"

  added_count=$(awk 'END { print NR + 0 }' "${added_keys}")
  removed_count=$(awk 'END { print NR + 0 }' "${removed_keys}")
  changed_count=$(awk 'END { print NR + 0 }' "${changed_keys}")
  unchanged_count=$((MANAGED_SETTING_COUNT - added_count - removed_count - changed_count))
  backup_display=${BACKUP_PATH#"${JSH_ROOT}/"}

  review_line '1;36' '◆ Vorssaint backup review'
  review_line 2 "  Active   ${BUNDLE_ID}"
  review_line 2 "  Backup   ${backup_display}"
  review_line 2 '  Action   Update the native settings backup from active managed values'
  jsh_blank

  review_line '1;36' '▸ Backup changes'
  review_line 32 "  + ${added_count} setting(s) will be added"
  if [[ "${added_count}" -gt 0 ]]; then
    summary=$(summarize_keys "${added_keys}")
    review_line 2 "    ${summary}"
  fi
  review_line 31 "  − ${removed_count} setting(s) will be removed"
  if [[ "${removed_count}" -gt 0 ]]; then
    summary=$(summarize_keys "${removed_keys}")
    review_line 2 "    ${summary}"
  fi
  review_line 33 "  ~ ${changed_count} setting value(s) will change"
  if [[ "${changed_count}" -gt 0 ]]; then
    summary=$(summarize_keys "${changed_keys}")
    review_line 2 "    ${summary}"
  fi
  review_line 2 "  = ${unchanged_count} managed setting(s) already match"

  jsh_blank
  review_line '1;36' '▸ Preserved state'
  review_line 36 "  ○ ${EXCLUDED_BACKUP_COUNT} excluded setting(s) retain their stored backup values"
  review_line 2 '    featureAvailable.*, update UI markers, migration markers, and recent-use values'
  review_line 36 '  ○ Active-only runtime fields and clipboard history are not exported'

  jsh_blank
  review_line '1;36' '▸ Full diff'
  review_line 2 '  − current backup   + active managed value   unchanged context'
  render_diff "${diff_file}"
  jsh_blank
  review_line '1;36' "ℹ The output uses Vorssaint's native settings backup schema and XML plist format."
}

backup_settings() {
  local managed_active_plist=$1 candidate_settings=$2 candidate_backup=$3

  create_backup_candidate "${managed_active_plist}" "${candidate_settings}" "${candidate_backup}"
  show_backup_diff "${candidate_backup}"
  if [[ "${SETTINGS_DIFFER}" -eq 0 ]]; then
    jsh_success "The managed Vorssaint backup already matches active settings."
    return
  fi

  confirm_backup
  if [[ "${BACKUP_CONFIRMED}" -eq 1 ]]; then
    mv -f "${candidate_backup}" "${BACKUP_PATH}"
    jsh_success "Backed up active Vorssaint settings to ${BACKUP_PATH#"${JSH_ROOT}/"}."
  else
    jsh_warn "Keeping the managed Vorssaint backup."
  fi
}

show_settings_diff() {
  local diff_file="${TEMP_DIR}/settings.diff"
  local active_records="${TEMP_DIR}/active-records.txt"
  local backup_records="${TEMP_DIR}/backup-records.txt"
  local active_keys="${TEMP_DIR}/active-keys.txt"
  local backup_keys="${TEMP_DIR}/backup-keys.txt"
  local added_keys="${TEMP_DIR}/added-keys.txt"
  local changed_keys="${TEMP_DIR}/changed-keys.txt"
  local full_active_records="${TEMP_DIR}/full-active-records.txt"
  local full_backup_records="${TEMP_DIR}/full-backup-records.txt"
  local full_active_keys="${TEMP_DIR}/full-active-keys.txt"
  local full_backup_keys="${TEMP_DIR}/full-backup-keys.txt"
  local active_only_keys="${TEMP_DIR}/active-only-keys.txt"
  local diff_status added_count changed_count active_only_count unchanged_count summary backup_display

  if diff -u -L "active Vorssaint settings" -L "managed Vorssaint backup" \
    "${TEMP_DIR}/active.txt" "${TEMP_DIR}/backup.txt" > "${diff_file}"; then
    return
  else
    diff_status=$?
  fi
  if [[ "${diff_status}" -ne 1 ]]; then
    jsh_error "Unable to compare active and managed Vorssaint settings."
    return "${diff_status}"
  fi

  SETTINGS_DIFFER=1
  write_top_level_records "${TEMP_DIR}/active.txt" "${active_records}"
  write_top_level_records "${TEMP_DIR}/backup.txt" "${backup_records}"
  cut -f 1 "${active_records}" > "${active_keys}"
  cut -f 1 "${backup_records}" > "${backup_keys}"
  LC_ALL=C comm -13 "${active_keys}" "${backup_keys}" > "${added_keys}"
  LC_ALL=C join -t $'\t' "${active_records}" "${backup_records}" |
    awk -F '\t' '$2 != $3 { print $1 }' > "${changed_keys}"
  write_top_level_records "${TEMP_DIR}/active-all.txt" "${full_active_records}"
  write_top_level_records "${TEMP_DIR}/backup-all.txt" "${full_backup_records}"
  cut -f 1 "${full_active_records}" > "${full_active_keys}"
  cut -f 1 "${full_backup_records}" > "${full_backup_keys}"
  LC_ALL=C comm -23 "${full_active_keys}" "${full_backup_keys}" > "${active_only_keys}"

  added_count=$(awk 'END { print NR + 0 }' "${added_keys}")
  changed_count=$(awk 'END { print NR + 0 }' "${changed_keys}")
  active_only_count=$(awk 'END { print NR + 0 }' "${active_only_keys}")
  unchanged_count=$((MANAGED_SETTING_COUNT - added_count - changed_count))
  backup_display=${BACKUP_PATH#"${JSH_ROOT}/"}

  review_line '1;36' '◆ Vorssaint settings review'
  review_line 2 "  Active   ${BUNDLE_ID}"
  review_line 2 "  Backup   ${backup_display}"
  review_line 2 '  Action   Overlay managed settings from the backup'
  jsh_blank

  review_line '1;36' '▸ Managed changes'
  review_line 32 "  + ${added_count} missing setting(s) will be added"
  if [[ "${added_count}" -gt 0 ]]; then
    summary=$(summarize_keys "${added_keys}")
    review_line 2 "    ${summary}"
  fi
  review_line 33 "  ~ ${changed_count} shared setting value(s) will change"
  if [[ "${changed_count}" -gt 0 ]]; then
    summary=$(summarize_keys "${changed_keys}")
    review_line 2 "    ${summary}"
  fi
  review_line 2 "  = ${unchanged_count} managed setting(s) already match"

  jsh_blank
  review_line '1;36' '▸ Preserved state'
  review_line 36 "  ○ ${active_only_count} active-only setting(s) are preserved"
  if [[ "${active_only_count}" -gt 0 ]]; then
    summary=$(summarize_keys "${active_only_keys}")
    review_line 2 "    ${summary}"
  fi
  review_line 36 "  ○ ${EXCLUDED_BACKUP_COUNT} computed, update, migration, or recent-use setting(s) are excluded"
  review_line 2 '    featureAvailable.*, update UI markers, migration markers, and recent-use values'

  jsh_blank
  review_line '1;36' '▸ Full diff'
  review_line 2 '  − current value   + backup value   unchanged context'
  render_diff "${diff_file}"
  jsh_blank
  review_line '1;36' 'ℹ Importing updates only managed settings; preserved state will not be changed.'
  return 0
}

import_settings() {
  local backup_plist=$1

  if pgrep -x Vorssaint > /dev/null 2>&1; then
    VORSSAINT_WAS_RUNNING=1
    killall Vorssaint > /dev/null 2>&1 || true
  fi
  defaults import "${BUNDLE_ID}" "${backup_plist}"
  jsh_success "Imported managed Vorssaint settings."
}

configure_onboarding() {
  local backup_plist=$1 onboarding_version
  onboarding_version=$(plutil -extract featuresOnboardingVersion raw -o - "${backup_plist}")

  defaults write "${BUNDLE_ID}" hasOnboarded -bool true
  defaults write "${BUNDLE_ID}" onboardingStep -int 0
  defaults write "${BUNDLE_ID}" featuresOnboardingVersion -int "${onboarding_version}"
  jsh_success "Vorssaint onboarding is marked complete."
}

configure_login_item() {
  local login_item_exists

  defaults write "${BUNDLE_ID}" launchAtLoginWanted -bool true
  login_item_exists=$(osascript -e 'tell application "System Events" to exists login item "Vorssaint"')
  if [[ "${login_item_exists}" != true ]]; then
    osascript - "${APP_PATH}" << 'APPLESCRIPT'
on run arguments
  tell application "System Events"
    make login item at end with properties {name:"Vorssaint", path:item 1 of arguments, hidden:true}
  end tell
end run
APPLESCRIPT
  fi
  jsh_success "Vorssaint will start at login."
}

main() {
  local action=${1:-apply}
  local active_plist managed_active_plist managed_backup_plist merged_plist
  local candidate_settings candidate_backup operating_system

  if [[ "$#" -gt 1 ]]; then
    jsh_error "Usage: $0 [apply|backup]"
    return 1
  fi
  case ${action} in
    apply | backup) ;;
    *)
      jsh_error "Usage: $0 [apply|backup]"
      return 1
      ;;
  esac

  operating_system=$(uname -s)
  [[ "${operating_system}" == Darwin ]] || {
    jsh_info "Skipping Vorssaint configuration: macOS not detected."
    return
  }
  [[ -d "${APP_PATH}" ]] || {
    jsh_warn "Skipping Vorssaint configuration: ${APP_PATH} is not installed."
    return
  }
  [[ -r "${BACKUP_PATH}" ]] || {
    jsh_error "Vorssaint backup is unavailable: ${BACKUP_PATH}"
    return 1
  }
  command -v defaults > /dev/null 2>&1 || {
    jsh_error "defaults is required to configure Vorssaint."
    return 1
  }
  [[ "${action}" != apply ]] || command -v osascript > /dev/null 2>&1 || {
    jsh_error "osascript is required to configure Vorssaint login startup."
    return 1
  }
  plutil -lint "${BACKUP_PATH}" > /dev/null

  mkdir -p "${JSH_ROOT}/tmp"
  TEMP_DIR=$(mktemp -d "${JSH_ROOT}/tmp/vorssaint.XXXXXX")
  active_plist="${TEMP_DIR}/active.plist"
  managed_active_plist="${TEMP_DIR}/managed-active.plist"
  managed_backup_plist="${TEMP_DIR}/managed-backup.plist"
  merged_plist="${TEMP_DIR}/merged.plist"
  prepare_settings "${active_plist}" "${managed_active_plist}" "${managed_backup_plist}" "${merged_plist}"

  if [[ "${action}" == backup ]]; then
    candidate_settings="${TEMP_DIR}/candidate-settings.plist"
    candidate_backup="${TEMP_DIR}/candidate-backup.plist"
    backup_settings "${managed_active_plist}" "${candidate_settings}" "${candidate_backup}"
    return
  fi

  show_settings_diff
  if [[ "${SETTINGS_DIFFER}" -eq 1 ]]; then
    confirm_import
    if [[ "${IMPORT_CONFIRMED}" -eq 1 ]]; then
      import_settings "${merged_plist}"
    else
      jsh_warn "Keeping the active Vorssaint settings."
    fi
  else
    jsh_success "Vorssaint settings already match the managed backup."
  fi

  configure_onboarding "${managed_backup_plist}"
  configure_login_item
  if [[ "${VORSSAINT_WAS_RUNNING}" -eq 1 ]]; then
    open -gj -a Vorssaint
  fi
}

trap cleanup EXIT
main "$@"
