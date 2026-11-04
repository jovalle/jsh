#!/usr/bin/env bash
# Apply Waterfox policy and managed preferences to its selected default profile.
set -euo pipefail
# shellcheck disable=SC2034 # APP_LAUNCH is consumed by app::with_closed.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
jsh::packages waterfox
jsh::activity 'Checking Waterfox installation'
APP_TMP=${APP_TMP:?}
if [[ $(uname -s) == Darwin ]]; then
  roots=("${HOME}/Library/Application Support/Waterfox")
else roots=("${HOME}/.waterfox" "${HOME}/.var/app/net.waterfox.waterfox/.waterfox"); fi
present=0
for directory in "${roots[@]}"; do [[ ! -d ${directory} ]] || present=1; done
if command -v waterfox >/dev/null 2>&1 || [[ -d /Applications/Waterfox.app || -d /var/lib/flatpak/app/net.waterfox.waterfox ]]; then present=1; fi
[[ ${present} == 1 ]] || exit 0
if [[ $(uname -s) == Darwin ]]; then
  app::desired waterfox policies.json | jq '.EnterprisePoliciesEnabled = true' >"${APP_TMP}/policy.json"
  app::policy "${APP_TMP}/policy.json" /Library/Preferences/net.waterfox.waterfox.plist 1
fi
: >"${APP_TMP}/profiles"
: >"${APP_TMP}/defaults"
jsh::activity 'Finding Waterfox profiles'
for directory in "${roots[@]}"; do
  [[ -f ${directory}/profiles.ini ]] || continue
  : >"${APP_TMP}/directory-profiles"
  : >"${APP_TMP}/install-defaults"
  awk -f "${SCRIPT_DIR}/waterfox/profiles.awk" "${directory}/profiles.ini" >"${APP_TMP}/registrations"
  while IFS=$'\t' read -r type name profile relative default; do
    if [[ ${relative} == 1 && ${profile} != /* ]]; then profile=${directory}/${profile}; fi
    [[ -d ${profile} ]] || continue
    profile=$(cd -- "${profile}" && pwd -P)
    if [[ ${type} == install ]]; then
      printf '%s\n' "${profile}" >>"${APP_TMP}/install-defaults"
    else printf '%s\t%s\t%s\t%s\n' "${directory}" "${name}" "${profile}" "${default:-0}" >>"${APP_TMP}/directory-profiles"; fi
  done <"${APP_TMP}/registrations"
  cat "${APP_TMP}/directory-profiles" >>"${APP_TMP}/profiles"
  sort -u "${APP_TMP}/install-defaults" >"${APP_TMP}/install-selected"
  awk -F '\t' '$4 == "1" { print $3 }' "${APP_TMP}/directory-profiles" >"${APP_TMP}/profile-selected"
  if [[ ! -s ${APP_TMP}/profile-selected && $(wc -l <"${APP_TMP}/directory-profiles" | tr -d ' ') == 1 ]]; then
    cut -f3 "${APP_TMP}/directory-profiles" >"${APP_TMP}/profile-selected"
  fi
  if [[ -s ${APP_TMP}/install-selected ]]; then
    if [[ $(wc -l <"${APP_TMP}/install-selected" | tr -d ' ') -gt 1 && $(wc -l <"${APP_TMP}/profile-selected" | tr -d ' ') == 1 ]] &&
      grep -Fx -f "${APP_TMP}/profile-selected" "${APP_TMP}/install-selected" >/dev/null; then
      cp "${APP_TMP}/profile-selected" "${APP_TMP}/directory-defaults"
    else cp "${APP_TMP}/install-selected" "${APP_TMP}/directory-defaults"; fi
  else cp "${APP_TMP}/profile-selected" "${APP_TMP}/directory-defaults"; fi
  # The existing behavior uses the first registered installation when no profile is selected.
  if [[ ! -s ${APP_TMP}/defaults ]]; then cat "${APP_TMP}/directory-defaults" >"${APP_TMP}/defaults"; fi
done
if [[ ! -s ${APP_TMP}/profiles ]]; then
  jsh::notice 'open Waterfox once to create a profile, then rerun scripts/waterfox.sh'
  exit 0
fi
state=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/waterfox-profile
jsh::activity 'Selecting Waterfox profile'
requested=${JSH_WATERFOX_PROFILE:-}
explicit=0
if [[ -n ${requested} ]]; then
  explicit=1
elif [[ -f ${state} ]]; then
  saved=$(cat "${state}")
  if awk -F '\t' -v saved="${saved}" '$3 == saved { found++ } END { exit(found != 1) }' "${APP_TMP}/profiles"; then requested=${saved}; fi
fi
if [[ -n ${requested} ]]; then
  case ${requested} in \~/*) requested=${HOME}/${requested#\~/} ;; esac
  awk -F '\t' -v requested="${requested}" '$2 == requested || $3 == requested' "${APP_TMP}/profiles" >"${APP_TMP}/matches"
  if [[ $(wc -l <"${APP_TMP}/matches" | tr -d ' ') != 1 ]]; then
    jsh::notice 'profile name or path must match exactly one existing Waterfox profile'
    exit 1
  fi
  selected=$(cut -f3 "${APP_TMP}/matches")
else
  if [[ $(wc -l <"${APP_TMP}/defaults" | tr -d ' ') == 1 ]]; then
    selected=$(cat "${APP_TMP}/defaults")
  elif [[ -t 0 && -t 2 && ${JSH_DRY_RUN:-0} != 1 ]]; then
    choices=()
    while IFS= read -r choice; do choices+=("${choice}"); done < <(cut -f2,3 "${APP_TMP}/profiles")
    selection=$(jsh::choose 'Waterfox profile' "${choices[@]}") || exit 0
    selected=${selection#*$'\t'}
    explicit=1
  else
    jsh::notice "choose a Waterfox profile with JSH_WATERFOX_PROFILE='name or path' scripts/waterfox.sh"
    exit 0
  fi
fi
jsh::activity 'Preparing Waterfox preferences'
cat "${SCRIPT_DIR}/waterfox/user.js" >"${APP_TMP}/managed.js"
extra=$(app::local waterfox user.js)
if [[ -n ${extra} ]]; then
  printf '\n' >>"${APP_TMP}/managed.js"
  cat "${extra}" >>"${APP_TMP}/managed.js"
fi
[[ ! -f ${selected}/user.js ]] || cp "${selected}/user.js" "${APP_TMP}/current.js"
[[ -f ${APP_TMP}/current.js ]] || : >"${APP_TMP}/current.js"
awk '
  FNR == NR {
    if ($0 ~ /^user_pref\(["\047]/) { key=$0; sub(/^user_pref\(["\047]/, "", key); sub(/["\047].*$/, "", key); keys[key]=1 }
    managed=managed $0 "\n"; next
  }
  $0 == "// BEGIN jsh preferences" { block=1; next }
  $0 == "// END jsh preferences" { block=0; next }
  block { next }
  /^user_pref\(["\047]/ { key=$0; sub(/^user_pref\(["\047]/, "", key); sub(/["\047].*$/, "", key); if (key in keys) next }
  { kept=kept $0 "\n" }
  END {
    sub(/[[:space:]]+$/, "", kept); sub(/[[:space:]]+$/, "", managed)
    if (kept != "") printf "%s\n\n", kept
    printf "// BEGIN jsh preferences\n%s\n// END jsh preferences\n", managed
  }' "${APP_TMP}/managed.js" "${APP_TMP}/current.js" >"${APP_TMP}/user.js"
write_preferences() { jsh::file "${APP_TMP}/user.js" "${selected}/user.js"; }
if cmp -s "${APP_TMP}/user.js" "${selected}/user.js"; then
  jsh::current
else
  if [[ $(uname -s) == Darwin ]]; then
    APP_LAUNCH=(open -a Waterfox)
  elif [[ ${selected} == "${HOME}/.var/app/net.waterfox.waterfox/"* ]]; then
    APP_LAUNCH=(flatpak run net.waterfox.waterfox)
  else APP_LAUNCH=(waterfox); fi
  app::with_closed Waterfox 'waterfox|waterfox-bin|Waterfox' write_preferences
fi
if [[ ${explicit} == 1 ]]; then
  printf '%s\n' "${selected}" >"${APP_TMP}/selected"
  jsh::file "${APP_TMP}/selected" "${state}"
fi
