#!/usr/bin/env bash
# Install the REA CLI, keep the graphify and REA skills in ~/.agents/skills current, and
# register the REA MCP server with OpenCode, Codex, and Antigravity.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

readonly SKILLS="${HOME}/.agents/skills"

select_node() {
  local node directory
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
      return 0
    fi
  done
  jsh::notice 'REA needs a newer Node.js with zstd support; install or select a compatible Node.js, then rerun jsh update ai'
  return 1
}

install_rea() {
  if command -v rea >/dev/null 2>&1; then
    jsh::current
    return
  fi
  jsh::progress rea-agents
  jsh::run npm install --global rea-agents
  jsh::added rea-agents
}

update_rea() {
  local before after
  if ! command -v rea >/dev/null 2>&1; then
    install_rea
    return
  fi
  before=$(rea --version)
  jsh::progress rea-agents
  jsh::run npm update --global rea-agents
  after=$(rea --version)
  if [[ ${before} == "${after}" ]]; then
    jsh::current
  else
    jsh::changed "rea-agents ${before} → ${after}"
  fi
}

report() {
  local name=$1 existed=$2
  if [[ ${existed} == 1 ]]; then
    jsh::changed "skill ${name}"
  else
    jsh::added "skill ${name}"
  fi
}

sync_graphify() {
  local existed=0 installed='' version
  [[ -d ${SKILLS}/graphify ]] && existed=1
  if command -v graphify >/dev/null 2>&1; then
    version=$(graphify --version)
    version=${version##* }
    if [[ -f ${SKILLS}/graphify/.graphify_version ]]; then
      installed=$(<"${SKILLS}/graphify/.graphify_version")
    fi
    if [[ ${installed} == "${version}" ]]; then
      jsh::current
      return
    fi
  fi
  jsh::progress "skill graphify"
  jsh::run graphify install --platform agents
  report graphify "${existed}"
}

sync_rea() {
  local existed=0 planned=1
  local -a args=(--skill-client shared)
  [[ -d ${SKILLS}/reverse-engineer-anything ]] && existed=1
  command -v opencode >/dev/null 2>&1 && args+=(--client opencode)
  command -v codex >/dev/null 2>&1 && args+=(--client codex)
  command -v agy >/dev/null 2>&1 && args+=(--client antigravity)
  if command -v rea >/dev/null 2>&1; then
    planned=$(rea setup --dry-run "${args[@]}" --format json </dev/null |
      python3 -c 'import json, sys; print(len(json.load(sys.stdin)["plannedActions"]))')
  fi
  if [[ ${planned} == 0 ]]; then
    jsh::current
    return
  fi
  jsh::progress "skill reverse-engineer-anything"
  jsh::run rea setup --yes "${args[@]}"
  report reverse-engineer-anything "${existed}"
}

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
    if select_node; then sync_rea; fi
    ;;
esac
