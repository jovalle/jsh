#!/usr/bin/env bash
# Keep policy-pinned Waterfox extensions in toolbar order.
set -euo pipefail
selected=${1:?}
shift
# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT:?}/scripts/lib/common.sh" "$@"
APP_TMP=$(jsh::temp)
cat >"${APP_TMP}/desired.json"
jq -c '[.ExtensionSettings // {} | to_entries[] | select(.value.default_area == "navbar")
  | (.key | ascii_downcase | gsub("[^a-z0-9_-]"; "_")) + "-browser-action"]' "${APP_TMP}/desired.json" >"${APP_TMP}/pinned.json"
# default_area only places unseen widgets, so pin navbar entries in policies.json order.
toolbar() {
  local layout
  layout=$(grep -m1 '^user_pref("browser.uiCustomization.state", ' "${selected}/prefs.js" 2>/dev/null) || return 1
  layout=$(jq -Rr --slurpfile pinned "${APP_TMP}/pinned.json" '
    def listed($list): . as $widget | $list | index($widget) != null;
    $pinned[0] as $pinned
    | capture("^user_pref\\(\"browser\\.uiCustomization\\.state\", (?<value>.*)\\);$").value | fromjson | fromjson
    | (.placements["nav-bar"] // []) as $nav
    | [$nav[] | select(listed($pinned) | not)] as $rest
    | (($nav | map(listed($pinned)) | index(true))
      // ($rest | index("unified-extensions-button") | values + 1) // ($rest | length)) as $at
    | .placements |= map_values(map(select(listed($pinned) | not)))
    | .placements["nav-bar"] = $rest[:$at] + $pinned + $rest[$at:]
    | "user_pref(\"browser.uiCustomization.state\", \(tojson | tojson));"' <<<"${layout}") || return 1
  layout=${layout} awk 'index($0, "user_pref(\"browser.uiCustomization.state\", ") == 1 { $0 = ENVIRON["layout"] } { print }' \
    "${selected}/prefs.js" >"${APP_TMP}/prefs.js"
  ! cmp -s "${APP_TMP}/prefs.js" "${selected}/prefs.js"
}

toolbar || exit 0
if [[ ${JSH_TOOLBAR_PROBE:-0} == 1 ]]; then
  printf "pending\n"
elif [[ ${JSH_KEEP_APPS:-0} == 1 ]] && pgrep -u "$(id -u)" -x "waterfox|waterfox-bin|Waterfox" >/dev/null; then
  jsh::notice "quit Waterfox, then run jsh update to pin its toolbar extensions"
else
  jsh::file "${APP_TMP}/prefs.js" "${selected}/prefs.js"
fi
