#!/usr/bin/env bash
# Install the REA CLI and keep the graphify and REA skills in ~/.agents/skills current.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

readonly SKILLS="${HOME}/.agents/skills"

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
  [[ -d ${SKILLS}/reverse-engineer-anything ]] && existed=1
  if command -v rea >/dev/null 2>&1; then
    planned=$(rea setup --dry-run --skill-client shared --format json </dev/null |
      python3 -c 'import json, sys; print(len(json.load(sys.stdin)["plannedActions"]))')
  fi
  if [[ ${planned} == 0 ]]; then
    jsh::current
    return
  fi
  jsh::progress "skill reverse-engineer-anything"
  jsh::run rea setup --yes --skill-client shared
  report reverse-engineer-anything "${existed}"
}

case ${JSH_PHASE:-configure} in
  install) install_rea ;;
  update)
    update_rea
    sync_graphify
    sync_rea
    ;;
  *)
    sync_graphify
    sync_rea
    ;;
esac
