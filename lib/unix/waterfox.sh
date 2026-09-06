#!/usr/bin/env bash
# Reconcile Waterfox toolbar state and operating-system associations.
# shellcheck disable=SC2154 # WATERFOX_CONFIG and TEMP_DIR are set by the caller.

current_toolbar_state() {
  local profile=$1 encoded
  [[ -r ${profile}/prefs.js ]] || return 1
  encoded=$(sed -n 's/^user_pref("browser.uiCustomization.state", \(.*\));$/\1/p' \
    "${profile}/prefs.js" | tail -1)
  [[ -n ${encoded} ]] || return 1
  jq -er 'fromjson' <<< "${encoded}"
}

waterfox_config_json() {
  yq -o=json '.' "${WATERFOX_CONFIG}"
}

validate_waterfox_config() {
  [[ -r ${WATERFOX_CONFIG} ]] || {
    jsh_error "Missing Waterfox configuration: ${WATERFOX_CONFIG}"
    return 1
  }
  waterfox_config_json | jq -e '
    def string_array:
      type == "array" and all(.[]; type == "string") and length == (unique | length);
    type == "object"
      and (keys == ["addons", "associations", "citrix", "search", "toolbar", "version"])
      and .version == 1
      and (.search | keys == ["default", "privateDefault"])
      and (.search.default | type == "string" and length > 0)
      and (.search.privateDefault | type == "string" and length > 0)
      and (.citrix | keys == ["allowedOrigins", "protocol"])
      and (.citrix.protocol | type == "string" and length > 0)
      and (.citrix.allowedOrigins | string_array)
      and (.associations | keys == ["linux", "macos"])
      and (.associations.macos
        | keys == ["citrixBundleId", "htmlBundleId", "htmlType", "httpBundleId",
          "httpsBundleId", "icaType"])
      and (.associations.linux
        | keys == ["browserDesktopAlternative", "citrixIcaDesktop",
          "citrixReceiverDesktop", "htmlDesktop", "httpDesktop", "httpsDesktop"])
      and (all(.associations[][]; type == "string" and length > 0))
      and (.toolbar | keys == ["remove"])
      and (.toolbar.remove | string_array)
      and (.addons | type == "array")
      and ([.addons[].id] | length == (unique | length))
      and all(.addons[];
        ((keys - ["autoUpdate", "dataCollection", "enabled", "fileAccess", "id",
          "name", "origins", "permissions", "pinned", "privateBrowsing"]) | length == 0)
        and (.id | type == "string" and length > 0 and contains("/") == false)
        and (.name | type == "string" and length > 0)
        and ((has("enabled") | not) or (.enabled | type == "boolean"))
        and ((has("pinned") | not) or (.pinned | type == "boolean"))
        and ((has("privateBrowsing") | not) or (.privateBrowsing | type == "boolean"))
        and ((has("fileAccess") | not) or (.fileAccess | type == "boolean"))
        and ((has("autoUpdate") | not)
          or (.autoUpdate == "default" or .autoUpdate == "on" or .autoUpdate == "off"))
        and ((has("permissions") | not) or (.permissions | string_array))
        and ((has("origins") | not) or (.origins | string_array))
        and ((has("dataCollection") | not) or (.dataCollection | string_array))
        and ((.enabled // true) or ((.pinned // false) | not)))
  ' > /dev/null || {
    jsh_error "Invalid Waterfox configuration: ${WATERFOX_CONFIG}"
    return 1
  }
}

configured_action_widgets() {
  local profile=$1 pin_state=$2 id extension_path widget
  while IFS=$'\t' read -r id extension_path; do
    [[ -r ${extension_path} && ! -L ${extension_path} ]] || continue
    unzip -p "${extension_path}" manifest.json 2> /dev/null \
      | jq -e 'has("action") or has("browser_action")' > /dev/null || continue
    widget=$(printf '%s' "${id}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')
    printf '%s-browser-action\n' "${widget}"
  done < <(waterfox_config_json | jq -r --arg profile "${profile}" \
    --argjson pinned "${pin_state}" '
    .addons[] | select((.enabled // true) and (.pinned // false) == $pinned)
    | .id as $id
    | [$id, ($profile + "/extensions/" + $id + ".xpi")]
    | @tsv
  ')
}

managed_toolbar_state() {
  local profile=$1 state pinned unpinned removed
  state=$(current_toolbar_state "${profile}") || return 1
  pinned=$(configured_action_widgets "${profile}" true \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  unpinned=$(configured_action_widgets "${profile}" false \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  removed=$(waterfox_config_json | jq -c '.toolbar.remove')
  jq -c --argjson pinned "${pinned}" --argjson unpinned "${unpinned}" \
    --argjson removed "${removed}" '
    ([.placements[][] | select(endswith("-browser-action"))] + $removed | unique) as $remove
    | reduce $remove[] as $widget (.;
        .placements |= with_entries(.value |= map(select(. != $widget)))
        | .seen = ((.seen // []) | map(select(. != $widget)))
      )
    | .placements |= with_entries(
      .value |= map(select(startswith("customizableui-special-spring") | not))
    )
    | .placements["nav-bar"] = ((.placements["nav-bar"] // []) + $pinned)
    | .placements["unified-extensions-area"] = $unpinned
    | .seen = ((.seen // []) + $pinned + $unpinned | unique)
    | .dirtyAreaCache = ((.dirtyAreaCache // []) + ["nav-bar", "unified-extensions-area"] | unique)
  ' <<< "${state}"
}

validate_configured_addons() {
  local profile=$1 id name private_browsing pinned extension_path failed=0
  [[ -r ${profile}/extensions.json ]] || return 0
  while IFS=$'\t' read -r id name private_browsing pinned; do
    extension_path="${profile}/extensions/${id}.xpi"
    if [[ ! -r ${extension_path} || -L ${extension_path} ]]; then
      jsh_warn "Configured Waterfox add-on is not installed: ${name}"
      continue
    fi
    if [[ ${private_browsing} == true ]] \
      && unzip -p "${extension_path}" manifest.json 2> /dev/null \
        | jq -e '.incognito == "not_allowed"' > /dev/null; then
      jsh_error "${name} does not support private browsing."
      failed=1
    fi
    if [[ ${pinned} == true ]] \
      && ! unzip -p "${extension_path}" manifest.json 2> /dev/null \
        | jq -e 'has("action") or has("browser_action")' > /dev/null; then
      jsh_error "${name} cannot be pinned because it has no toolbar action."
      failed=1
    fi
  done < <(waterfox_config_json | jq -r \
    '.addons[] | [.id, .name, ((.privateBrowsing // false) | tostring),
      ((.pinned // false) | tostring)] | @tsv')
  ((failed == 0))
}

reconcile_addon_state() {
  local profile=$1 target="${1}/extensions.json" candidate config
  [[ -r ${target} ]] || return 0
  config=$(waterfox_config_json)
  candidate=$(mktemp "${TEMP_DIR}/extensions.XXXXXX")
  jq --argjson config "${config}" '
    ($config.addons | map({key: .id, value: .}) | from_entries) as $configured
    | .addons |= map(
        .id as $id
        | if ($configured | has($id)) then
          ($configured[$id].enabled // true) as $enabled
            | .userDisabled = ($enabled | not)
            | .active = ($enabled and (.appDisabled != true)
                and (.embedderDisabled != true) and (.softDisabled != true))
            | .applyBackgroundUpdates = (
              if ($configured[$id].autoUpdate // "default") == "off" then 0
              elif ($configured[$id].autoUpdate // "default") == "on" then 2
                else 1 end)
          else . end
      )
  ' "${target}" > "${candidate}"
  if cmp -s -- "${candidate}" "${target}"; then
    return 0
  fi
  backup_file "${target}" extensions.json
  install -m 0600 -- "${candidate}" "${target}"
  rm -f -- "${profile}/addonStartup.json.lz4" "${profile}/compatibility.ini"
  jsh_success "Waterfox add-on enablement and updates reconciled."
}

reconcile_addon_permissions() {
  local profile=$1 target="${1}/extension-preferences.json" candidate config
  [[ -r ${profile}/extensions.json ]] || return 0
  config=$(waterfox_config_json)
  candidate=$(mktemp "${TEMP_DIR}/extension-preferences.XXXXXX")
  {
    [[ ! -r ${target} ]] || cat "${target}"
    [[ -r ${target} ]] || printf '{}\n'
  } | jq --argjson config "${config}" --slurpfile extensions "${profile}/extensions.json" '
    ($extensions[0].addons | map(.id)) as $installed
    | reduce ($config.addons[] | select(.id as $id | $installed | index($id))) as $addon (.;
        ($addon.id) as $id
        | ([
            ($addon.permissions // [])[],
            if ($addon.privateBrowsing // false) then "internal:privateBrowsingAllowed" else empty end,
            if ($addon.fileAccess // false) then "internal:fileSchemeAllowed" else empty end
          ]) as $permissions
        | if has($id) or ($permissions | length) > 0
            or (($addon.origins // []) | length) > 0
            or (($addon.dataCollection // []) | length) > 0 then
            .[$id] = ((.[$id] // {})
              | .permissions = $permissions
              | .origins = ($addon.origins // [])
              | .data_collection = ($addon.dataCollection // []))
          else . end
      )
  ' > "${candidate}"
  if cmp -s -- "${candidate}" "${target}" 2> /dev/null; then
    return 0
  fi
  backup_file "${target}" extension-preferences.json
  install -m 0600 -- "${candidate}" "${target}"
  rm -f -- "${profile}/addonStartup.json.lz4" "${profile}/compatibility.ini"
  jsh_success "Waterfox add-on permissions reconciled."
}

macos_url_handler() {
  local scheme=$1
  local launch_services=${JSH_LAUNCH_SERVICES_PLIST:-${HOME}/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist}
  [[ -r ${launch_services} ]] || return 1
  plutil -convert json -o - -- "${launch_services}" 2> /dev/null \
    | jq -er --arg scheme "${scheme}" '
      [.LSHandlers[]?
        | select(.LSHandlerURLScheme == $scheme)
        | (.LSHandlerRoleAll // .LSHandlerRoleViewer // empty)]
      | last // empty
    '
}

set_macos_url_handler() {
  local bundle_id=$1 scheme=$2 current
  current=$(macos_url_handler "${scheme}" || true)
  [[ ${current} == "${bundle_id}" ]] || duti -s "${bundle_id}" "${scheme}"
}

configure_associations() {
  local config desktop alternative application_dir citrix_bundle html_type ica_type
  local html_bundle http_bundle https_bundle citrix_ica citrix_receiver
  config=$(waterfox_config_json)
  if [[ $(uname -s) == Darwin ]]; then
    if ! command -v duti > /dev/null 2>&1; then
      jsh_warn "Skipping macOS file associations: duti is unavailable."
      return
    fi
    citrix_bundle=$(jq -r '.associations.macos.citrixBundleId' <<< "${config}")
    html_bundle=$(jq -r '.associations.macos.htmlBundleId' <<< "${config}")
    http_bundle=$(jq -r '.associations.macos.httpBundleId' <<< "${config}")
    https_bundle=$(jq -r '.associations.macos.httpsBundleId' <<< "${config}")
    html_type=$(jq -r '.associations.macos.htmlType' <<< "${config}")
    ica_type=$(jq -r '.associations.macos.icaType' <<< "${config}")
    duti -s "${html_bundle}" "${html_type}" all
    set_macos_url_handler "${http_bundle}" http
    set_macos_url_handler "${https_bundle}" https
    if [[ -d ${JSH_CITRIX_APP:-/Applications/Citrix Workspace.app} ]]; then
      duti -s "${citrix_bundle}" "${ica_type}" all
    fi
    jsh_success "macOS Waterfox and Citrix associations configured."
    return
  fi

  if ! command -v xdg-mime > /dev/null 2>&1; then
    jsh_warn "Skipping Linux file associations: xdg-mime is unavailable."
    return
  fi
  application_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
  alternative=$(jq -r '.associations.linux.browserDesktopAlternative' <<< "${config}")
  for association in html http https; do
    desktop=$(jq -r ".associations.linux.${association}Desktop" <<< "${config}")
    if [[ ${desktop} == waterfox.desktop \
      && (-r ${application_dir}/${alternative} || -r /usr/share/applications/${alternative}) ]]; then
      desktop=${alternative}
    fi
    case ${association} in
      html) xdg-mime default "${desktop}" text/html ;;
      *) xdg-mime default "${desktop}" "x-scheme-handler/${association}" ;;
    esac
  done
  citrix_ica=$(jq -r '.associations.linux.citrixIcaDesktop' <<< "${config}")
  citrix_receiver=$(jq -r '.associations.linux.citrixReceiverDesktop' <<< "${config}")
  if [[ -r ${application_dir}/${citrix_ica} ]]; then
    xdg-mime default "${citrix_ica}" application/x-ica
  fi
  if [[ -r ${application_dir}/${citrix_receiver} ]]; then
    xdg-mime default "${citrix_receiver}" x-scheme-handler/receiver
  fi
  jsh_success "Linux Waterfox and Citrix associations configured."
}

# Compare active Waterfox state with repository-managed configuration.
# shellcheck disable=SC2034,SC2154 # Paths and review state cross the caller boundary.

waterfox_review_line() {
  local color=$1
  shift
  if jsh_color_enabled 1; then
    printf '\033[%sm%s\033[0m\n' "${color}" "$*"
  else
    printf '%s\n' "$*"
  fi
}

render_waterfox_diff() {
  local line color
  while IFS= read -r line || [[ -n ${line} ]]; do
    case ${line} in
      '--- '*|'+++ '*) color='1;36' ;;
      '@@'*) color=36 ;;
      -*) color=31 ;;
      +*) color=32 ;;
      *) color=2 ;;
    esac
    waterfox_review_line "${color}" "${line}"
  done < "$1"
}

macos_content_handler() {
  local content_type=$1
  local launch_services=${JSH_LAUNCH_SERVICES_PLIST:-${HOME}/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist}
  [[ -r ${launch_services} ]] || return 1
  plutil -convert json -o - -- "${launch_services}" 2> /dev/null \
    | jq -er --arg content_type "${content_type}" '
      [.LSHandlers[]?
        | select(.LSHandlerContentType == $content_type)
        | (.LSHandlerRoleAll // .LSHandlerRoleViewer // .LSHandlerRoleEditor // empty)]
      | last // empty
    '
}

active_managed_policy() {
  local config=$1 target existing policies
  target=$(policy_target 2> /dev/null || true)
  existing='{}'
  if [[ -n ${target} && -r ${target} ]]; then
    if [[ $(uname -s) == Darwin ]]; then
      existing=$(plutil -convert json -o - -- "${target}")
      policies=${existing}
    else
      existing=$(jq -c . "${target}")
      policies=$(jq -c '.policies // {}' <<< "${existing}")
    fi
  else
    policies='{}'
  fi
  jq -cn --argjson config "${config}" --argjson policies "${policies}" '{
    search: {
      default: ($policies.SearchEngines.Default // $config.search.default),
      privateDefault: ($policies.SearchEngines.DefaultPrivate // $config.search.privateDefault)
    },
    citrix: {
      protocol: ($policies.AutoLaunchProtocolsFromOrigins[0].protocol
        // $config.citrix.protocol),
      allowedOrigins: ($policies.AutoLaunchProtocolsFromOrigins[0].allowed_origins
        // $config.citrix.allowedOrigins)
    }
  }'
}

active_associations() {
  local config=$1 association current desired type
  local active=${config}
  if [[ $(uname -s) == Darwin ]]; then
    for association in html http https; do
      desired=$(jq -r ".macos.${association}BundleId" <<< "${config}")
      case ${association} in
        html)
          type=$(jq -r '.macos.htmlType' <<< "${config}")
          current=$(macos_content_handler "${type}" || true)
          ;;
        *) current=$(macos_url_handler "${association}" || true) ;;
      esac
      [[ -z ${current} ]] || active=$(jq -c --arg key "${association}BundleId" \
        --arg value "${current}" '.macos[$key] = $value' <<< "${active}")
      [[ -n ${current} ]] || current=${desired}
    done
    desired=$(jq -r '.macos.citrixBundleId' <<< "${config}")
    type=$(jq -r '.macos.icaType' <<< "${config}")
    current=$(macos_content_handler "${type}" || true)
    [[ -z ${current} ]] || active=$(jq -c --arg value "${current}" \
      '.macos.citrixBundleId = $value' <<< "${active}")
  elif command -v xdg-mime > /dev/null 2>&1; then
    for association in html http https; do
      case ${association} in
        html) current=$(xdg-mime query default text/html 2> /dev/null || true) ;;
        *) current=$(xdg-mime query default "x-scheme-handler/${association}" 2> /dev/null || true) ;;
      esac
      [[ -z ${current} ]] || active=$(jq -c --arg key "${association}Desktop" \
        --arg value "${current}" '.linux[$key] = $value' <<< "${active}")
    done
    for association in citrixIca citrixReceiver; do
      case ${association} in
        citrixIca) current=$(xdg-mime query default application/x-ica 2> /dev/null || true) ;;
        citrixReceiver) current=$(xdg-mime query default x-scheme-handler/receiver 2> /dev/null || true) ;;
      esac
      [[ -z ${current} ]] || active=$(jq -c --arg key "${association}Desktop" \
        --arg value "${current}" '.linux[$key] = $value' <<< "${active}")
    done
  fi
  printf '%s\n' "${active}"
}

write_active_waterfox_config() {
  local profile=$1 output=$2 config extensions grants toolbar policy associations
  config=$(waterfox_config_json)
  if [[ -r ${profile}/extensions.json ]]; then
    extensions=$(cat "${profile}/extensions.json")
  else
    extensions='{"addons":[]}'
  fi
  if [[ -r ${profile}/extension-preferences.json ]]; then
    grants=$(cat "${profile}/extension-preferences.json")
  else
    grants='{}'
  fi
  toolbar=$(current_toolbar_state "${profile}" || printf '{"placements":{}}')
  policy=$(active_managed_policy "${config}")
  associations=$(active_associations "$(jq -c '.associations' <<< "${config}")")
  jq -n --argjson config "${config}" --argjson extensions "${extensions}" \
    --argjson grants "${grants}" --argjson toolbar "${toolbar}" \
    --argjson policy "${policy}" --argjson associations "${associations}" '
    def widget($id):
      ($id | ascii_downcase | gsub("[^a-z0-9_-]"; "_")) + "-browser-action";
    ($extensions.addons | map(select(.type == "extension")
      | {key: .id, value: .}) | from_entries) as $active
    | ([($toolbar.placements // {})[][]]) as $placements
    | ($toolbar.placements["nav-bar"] // []) as $navbar
    | $config
    | .addons |= map(
        .id as $id
        | if $active[$id] then
            ($grants[$id] // {}) as $grant
            | .enabled = ($active[$id].userDisabled != true)
            | .autoUpdate = (if $active[$id].applyBackgroundUpdates == 0 then "off"
                elif $active[$id].applyBackgroundUpdates == 2 then "on" else "default" end)
            | .pinned = (.enabled and (($navbar | index(widget($id))) != null))
            | .privateBrowsing = (($grant.permissions // [])
                | index("internal:privateBrowsingAllowed") != null)
            | .fileAccess = (($grant.permissions // [])
                | index("internal:fileSchemeAllowed") != null)
            | .permissions = [($grant.permissions // [])[] | select(startswith("internal:") | not)]
            | .origins = ($grant.origins // [])
            | .dataCollection = ($grant.data_collection // [])
          else . end
        | if .enabled == true then del(.enabled) else . end
        | if .autoUpdate == "default" then del(.autoUpdate) else . end
        | if .pinned == false then del(.pinned) else . end
        | if .privateBrowsing == false then del(.privateBrowsing) else . end
        | if .fileAccess == false then del(.fileAccess) else . end
        | if .permissions == [] then del(.permissions) else . end
        | if .origins == [] then del(.origins) else . end
        | if .dataCollection == [] then del(.dataCollection) else . end
      )
    | .toolbar.remove |= map(. as $button | select(($placements | index($button)) == null))
    | .search = $policy.search
    | .citrix = $policy.citrix
    | .associations = $associations
  ' | yq -P '.' > "${output}"
}

write_active_preferences() {
  local profile=$1 output=$2 active_preferences="${1}/prefs.js"
  [[ -r ${active_preferences} ]] || active_preferences=/dev/null
  awk '
    function normalize(value, first, last) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      first=substr(value, 1, 1); last=substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") ||
          (first == sprintf("%c", 39) && last == sprintf("%c", 39)))
        return "string:" substr(value, 2, length(value) - 2)
      return value
    }
    NR == FNR && /^user_pref\("[^"]+", / {
      key=$0; sub(/^user_pref\("/, "", key); sub(/".*/, "", key)
      value=$0; sub(/^user_pref\("[^"]+",[[:space:]]*/, "", value); sub(/\);$/, "", value)
      active[key]=value; next
    }
    /^user_pref\('\''[^'\'']+'\'', / {
      key=$0; sub(/^user_pref\('\''/, "", key); sub(/'\''.*/, "", key)
      value=$0; sub(/^user_pref\('\''[^'\'']+'\'',[[:space:]]*/, "", value); sub(/\);$/, "", value)
      if ((key in active) && normalize(value) != normalize(active[key]))
        print "user_pref('\''" key "'\'', " active[key] ");"
      else print
      next
    }
    { print }
  ' "${active_preferences}" "${WATERFOX_OVERRIDES}" > "${output}"
}

write_preference_records() {
  awk '
    function normalize(value, first, last) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      first=substr(value, 1, 1); last=substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") ||
          (first == sprintf("%c", 39) && last == sprintf("%c", 39)))
        return "string:" substr(value, 2, length(value) - 2)
      return value
    }
    /^user_pref\(["'\''][^"'\'']+["'\''], / {
      key=$0; sub(/^user_pref\(["'\'']/, "", key); sub(/["'\''].*/, "", key)
      value=$0; sub(/^user_pref\(["'\''][^"'\'']+["'\''],[[:space:]]*/, "", value); sub(/\);$/, "", value)
      print key "\t" normalize(value)
    }
  ' "$1" | LC_ALL=C sort
}

prepare_waterfox_review() {
  local profile=$1
  ACTIVE_WATERFOX_PROFILE=${profile}
  ACTIVE_WATERFOX_CONFIG="${TEMP_DIR}/active-waterfox.yaml"
  ACTIVE_WATERFOX_PREFERENCES="${TEMP_DIR}/active-waterfox.js"
  write_active_waterfox_config "${profile}" "${ACTIVE_WATERFOX_CONFIG}"
  write_active_preferences "${profile}" "${ACTIVE_WATERFOX_PREFERENCES}"
}

show_waterfox_review() {
  local direction=$1 config_from config_to prefs_from prefs_to diff_file diff_status
  local config_from_label config_to_label prefs_from_label prefs_to_label action
  local config_diff="${TEMP_DIR}/waterfox-config.diff"
  local prefs_diff="${TEMP_DIR}/waterfox-preferences.diff"
  local current_config="${TEMP_DIR}/current-config.json"
  local active_config="${TEMP_DIR}/active-config.json"
  local current_prefs="${TEMP_DIR}/current-prefs.txt"
  local active_prefs="${TEMP_DIR}/active-prefs.txt"
  WATERFOX_SETTINGS_DIFFER=0

  waterfox_config_json | jq -S . > "${current_config}"
  yq -o=json '.' "${ACTIVE_WATERFOX_CONFIG}" | jq -S . > "${active_config}"
  write_preference_records "${WATERFOX_OVERRIDES}" > "${current_prefs}"
  write_preference_records "${ACTIVE_WATERFOX_PREFERENCES}" > "${active_prefs}"
  if [[ ${direction} == apply ]]; then
    config_from=${active_config}; config_to=${current_config}
    prefs_from=${active_prefs}; prefs_to=${current_prefs}
    config_from_label='active Waterfox state'; config_to_label='managed Waterfox configuration'
    prefs_from_label='active Waterfox preferences'; prefs_to_label='managed Waterfox preferences'
    action='Apply repository-managed values to the active profile'
  else
    config_from=${current_config}; config_to=${active_config}
    prefs_from=${current_prefs}; prefs_to=${active_prefs}
    config_from_label='managed Waterfox configuration'; config_to_label='active Waterfox state'
    prefs_from_label='managed Waterfox preferences'; prefs_to_label='active Waterfox preferences'
    action='Update repository-managed values from the active profile'
  fi
  diff -u -L "${config_from_label}" -L "${config_to_label}" \
    "${config_from}" "${config_to}" > "${config_diff}" || diff_status=$?
  [[ ${diff_status:-0} -le 1 ]] || return "${diff_status}"
  diff_status=0
  diff -u -L "${prefs_from_label}" -L "${prefs_to_label}" \
    "${prefs_from}" "${prefs_to}" > "${prefs_diff}" || diff_status=$?
  [[ ${diff_status} -le 1 ]] || return "${diff_status}"
  if [[ ! -s ${config_diff} && ! -s ${prefs_diff} ]]; then
    jsh_success "Waterfox managed state already matches."
    return
  fi
  WATERFOX_SETTINGS_DIFFER=1
  waterfox_review_line '1;36' 'Waterfox configuration review'
  waterfox_review_line 2 "  Active   ${ACTIVE_WATERFOX_PROFILE}"
  waterfox_review_line 2 "  Managed  ${WATERFOX_CONFIG} and ${WATERFOX_OVERRIDES}"
  waterfox_review_line 2 "  Action   ${action}"
  jsh_blank
  for diff_file in "${config_diff}" "${prefs_diff}"; do
    [[ ! -s ${diff_file} ]] || render_waterfox_diff "${diff_file}"
  done
  jsh_blank
  waterfox_review_line 36 'Unlisted and missing add-ons remain outside backup membership.'
}

confirm_waterfox_review() {
  local action=$1 prompt
  [[ ${JSH_CONFIGURE_ASSUME_YES:-0} != 1 ]] || return 0
  case ${action} in
    apply) prompt='Apply this configuration to Waterfox?' ;;
    backup) prompt='Replace the managed Waterfox configuration with active values?' ;;
  esac
  jsh_prompt "${prompt} [y/N]: "
  read -r answer || answer=
  [[ ${answer} =~ ^[Yy]$ ]]
}

backup_waterfox_configuration() {
  local binary root profile profile_status config_candidate preferences_candidate
  require_command jq
  require_command unzip
  require_command yq
  validate_manifest
  validate_waterfox_config
  binary=$(waterfox_binary 2> /dev/null || true)
  root=$(waterfox_root)
  if [[ -z ${binary} && ! -d ${root} ]]; then
    jsh_info "Skipping Waterfox backup: Waterfox is not installed."
    return
  fi

  mkdir -p "${JSH_ROOT}/tmp"
  TEMP_DIR=$(mktemp -d "${JSH_ROOT}/tmp/waterfox.XXXXXX")
  if profile=$(selected_profile "${root}"); then
    :
  else
    profile_status=$?
    ((profile_status == 1)) || return "${profile_status}"
    jsh_error "No initialized Waterfox profile is available to back up."
    return 1
  fi
  if profile_is_locked "${profile}"; then
    jsh_error "Close Waterfox before backing up profile ${profile##*/}."
    return 1
  fi

  validate_configured_addons "${profile}"
  prepare_waterfox_review "${profile}"
  show_waterfox_review backup
  ((WATERFOX_SETTINGS_DIFFER)) || return 0
  confirm_waterfox_review backup || {
    jsh_warn "Keeping the managed Waterfox configuration."
    return
  }

  config_candidate=$(mktemp "${WATERFOX_CONFIG}.XXXXXX")
  preferences_candidate=$(mktemp "${WATERFOX_OVERRIDES}.XXXXXX")
  install -m 0644 -- "${ACTIVE_WATERFOX_CONFIG}" "${config_candidate}"
  install -m 0644 -- "${ACTIVE_WATERFOX_PREFERENCES}" "${preferences_candidate}"
  yq -e '.' "${config_candidate}" > /dev/null
  grep -q '^user_pref' "${preferences_candidate}"
  mv -f -- "${config_candidate}" "${WATERFOX_CONFIG}"
  mv -f -- "${preferences_candidate}" "${WATERFOX_OVERRIDES}"
  jsh_success "Backed up active Waterfox managed state."
}
