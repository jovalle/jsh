#!/usr/bin/env bash
# Write global agent instructions, merge OpenCode and Codex settings, and register Helium's native host.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh" "$@"
jsh::packages ai
jsh::step check "agent instructions"
config=${XDG_CONFIG_HOME:-${HOME}/.config}
# One rules file for every installed agent; each agent's own directory shows it is installed.
instructions=${SCRIPT_DIR}/ai/instructions.md
if [[ -d ${HOME}/.copilot ]]; then
  {
    printf '%s\n' '---' 'description: "Global rules from jsh: commit messages, naming, and secrets."' \
      'applyTo: "**"' '---'
    cat "${instructions}"
  } >"${APP_TMP}/copilot.md"
  jsh::file "${APP_TMP}/copilot.md" "${HOME}/.copilot/instructions/jsh.instructions.md" 644
fi
for target in "${HOME}/.codex/AGENTS.md" "${config}/opencode/AGENTS.md" "${HOME}/.claude/CLAUDE.md" \
  "${HOME}/.gemini/GEMINI.md"; do
  [[ ! -d ${target%/*} ]] || jsh::file "${instructions}" "${target}" 644
done
if command -v opencode >/dev/null 2>&1 || [[ -d ${config}/opencode ]]; then
  jsh::step check "OpenCode settings"
  printf '{"$schema":"https://opencode.ai/config.json","autoupdate":true}\n' >"${APP_TMP}/opencode.json"
  app::json "${APP_TMP}/opencode.json" "${config}/opencode/opencode.json"
fi
path=${HOME}/.codex/config.toml
if command -v codex >/dev/null 2>&1 || [[ -f ${path} ]]; then
  jsh::step check "Codex settings"
  [[ ! -f ${path} ]] || cp "${path}" "${APP_TMP}/codex.toml"
  [[ -f ${APP_TMP}/codex.toml ]] || : >"${APP_TMP}/codex.toml"
  awk '
    function top() { if (!top_done) { if (!update) print "check_for_update_on_startup = true"; top_done=1 } }
    function desktop() {
      if (in_desktop) {
        if (!link) print "open-link-in-target-preference = \"external-browser\""
        if (!local_url) print "open-local-url-in-target-preference = \"external-browser\""
      }
    }
    /^[[:space:]]*\[/ {
      if (!top_done) top()
      desktop(); in_desktop=($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*(#.*)?$/)
      if (in_desktop) { found_desktop=1; link=0; local_url=0 }
    }
    !top_done && /^[[:space:]]*check_for_update_on_startup[[:space:]]*=/ { print "check_for_update_on_startup = true"; update=1; next }
    in_desktop && /^[[:space:]]*open-link-in-target-preference[[:space:]]*=/ { print "open-link-in-target-preference = \"external-browser\""; link=1; next }
    in_desktop && /^[[:space:]]*open-local-url-in-target-preference[[:space:]]*=/ { print "open-local-url-in-target-preference = \"external-browser\""; local_url=1; next }
    { print }
    END {
      top(); desktop()
      if (!found_desktop) {
        print "\n[desktop]"
        print "open-link-in-target-preference = \"external-browser\""
        print "open-local-url-in-target-preference = \"external-browser\""
      }
    }' "${APP_TMP}/codex.toml" >"${APP_TMP}/codex-updated.toml"
  jsh::file "${APP_TMP}/codex-updated.toml" "${path}"
fi
helium=${HOME}/Library/Application\ Support/net.imput.helium
registry=${HOME}/.codex/chrome-native-hosts-v2.json
if [[ $(uname -s) == Darwin && -d ${helium} && -f ${registry} ]]; then
  jsh::step check "Helium native messaging registration"
  jq -c '.entries | max_by(.updatedAt // "") // empty' "${registry}" >"${APP_TMP}/host.json"
  if [[ -s ${APP_TMP}/host.json ]]; then
    while IFS= read -r name; do
      [[ ${name} =~ ^[a-zA-Z0-9_.-]+$ ]] || {
        jsh::notice 'invalid native host name'
        exit 1
      }
      jq --arg name "${name}" '{allowed_origins: [.extensionIds[] | "chrome-extension://" + . + "/"],
        description: "ChatGPT browser native messaging host", name: $name,
        path: .paths.extensionHostPath, type: "stdio"}' "${APP_TMP}/host.json" >"${APP_TMP}/manifest.json"
      jsh::file "${APP_TMP}/manifest.json" "${helium}/NativeMessagingHosts/${name}.json" 644
    done < <(jq -r '.nativeHostNames[]?' "${APP_TMP}/host.json")
  fi
fi
jsh::event stepclose
"${SCRIPT_DIR}/ai/rea.sh" "$@"
