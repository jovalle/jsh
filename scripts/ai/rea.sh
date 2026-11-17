#!/usr/bin/env bash
# Install the REA CLI, keep the graphify and REA skills current, and register the REA MCP server.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh" "$@"

readonly SKILLS="${HOME}/.agents/skills"

select_node() {
  local node directory
  jsh::step check "Node.js support for REA"
  for node in "$(command -v node || :)" "${HOMEBREW_PREFIX:-/nonexistent}/opt/node/bin/node" \
    /opt/homebrew/opt/node/bin/node \
    /home/linuxbrew/.linuxbrew/opt/node/bin/node /usr/local/opt/node/bin/node; do
    [[ -n ${node} && -x ${node} ]] || continue
    if "${node}" -e 'process.exit(typeof require("node:zlib").zstdDecompress === "function" ? 0 : 1)' \
      >/dev/null 2>&1; then
      directory=${node%/*}
      if command -v rea >/dev/null 2>&1 &&
        ! PATH="${directory}:${PATH}" rea --version >/dev/null 2>&1; then
        continue
      fi
      export PATH="${directory}:${PATH}"
      jsh::ok "Node.js supports REA"
      return 0
    fi
  done
  jsh::notice 'REA needs a newer Node.js with zstd support; install or select a compatible Node.js, then rerun scripts/ai.sh'
  return 1
}

install_rea() {
  jsh::step check "REA installation"
  if command -v rea >/dev/null 2>&1; then
    jsh::ok "rea-agents is installed"
    return
  fi
  jsh::task 'Installing rea-agents' npm install --global rea-agents
  jsh::added "rea-agents installed" "rea-agents is missing"
}

update_rea() {
  local before after
  if ! command -v rea >/dev/null 2>&1; then
    install_rea
    return
  fi
  jsh::step update "rea-agents"
  before=$(rea --version)
  jsh::task 'Updating rea-agents' npm update --global rea-agents
  after=$(rea --version)
  if [[ ${before} == "${after}" ]]; then
    jsh::ok "rea-agents is ${after}"
  else
    jsh::changed "rea-agents set ${after}" "rea-agents is ${before}"
  fi
}

sync_graphify() {
  local existed=0 installed='' version=''
  jsh::step check "graphify skill"
  [[ -d ${SKILLS}/graphify ]] && existed=1
  if command -v graphify >/dev/null 2>&1; then
    version=$(graphify --version)
    version=${version##* }
    if [[ -f ${SKILLS}/graphify/.graphify_version ]]; then
      installed=$(<"${SKILLS}/graphify/.graphify_version")
    fi
    if [[ ${installed} == "${version}" ]]; then
      jsh::ok "graphify skill is ${version}"
      return
    fi
  fi
  jsh::task 'Installing skill graphify' graphify install --platform agents
  if [[ -z ${version} ]]; then
    if [[ ${existed} == 1 ]]; then
      jsh::changed "graphify skill installed" "graphify CLI is missing"
    else
      jsh::added "graphify skill installed" "graphify skill is missing"
    fi
  elif [[ -n ${installed} ]]; then
    jsh::changed "graphify skill set ${version}" "graphify skill is ${installed}"
  elif [[ ${existed} == 1 ]]; then
    jsh::changed "graphify skill set ${version}" "graphify skill version is unknown"
  else
    jsh::added "graphify skill ${version} installed" "graphify skill is missing"
  fi
}

sync_rea() {
  local plan planned reason
  jsh::step check "REA skill registration"
  local -a args=(--skill-client shared)
  command -v opencode >/dev/null 2>&1 && args+=(--client opencode)
  command -v codex >/dev/null 2>&1 && args+=(--client codex)
  command -v agy >/dev/null 2>&1 && args+=(--client antigravity)
  if ! command -v rea >/dev/null 2>&1; then
    if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
      jsh::info "REA registration unchecked in preview"
      return
    fi
    jsh::fail "REA registration is unchecked: rea is not installed"
    return 1
  fi
  plan=$(rea setup --dry-run "${args[@]}" --format json </dev/null 2>/dev/null || :)
  if [[ $(jq -r '.status' <<<"${plan}") == needs_human ]]; then
    jsh::notice "REA setup: $(jq -r '.remediation' <<<"${plan}")"
    return 1
  fi
  planned=$(jq '.plannedActions | length' <<<"${plan}")
  if [[ ${planned} == 0 ]]; then
    jsh::ok "REA skill registration is current"
    return
  fi
  reason="REA has ${planned} planned registration change"
  [[ ${planned} == 1 ]] || reason+=s
  jsh::task 'Installing skill reverse-engineer-anything' rea setup --yes "${args[@]}"
  jsh::changed "REA registrations updated" "${reason}"
}

if [[ ${JSH_UPDATE:-0} == 1 ]]; then JSH_PHASE=update; fi
case ${JSH_PHASE:-configure} in
  install) if select_node; then install_rea; fi ;;
  update)
    node_ready=0
    if select_node; then
      node_ready=1
      update_rea
    fi
    sync_graphify
    if [[ ${node_ready} == 1 ]]; then sync_rea; fi
    ;;
  *)
    sync_graphify
    if select_node; then
      install_rea
      sync_rea
    fi
    ;;
esac
