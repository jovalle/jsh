#!/usr/bin/env bash
# Provide Node.js and the REA CLI, keep the graphify and REA skills current, and register REA.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "${JSH_ROOT:?}/scripts/lib/common.sh" "$@"

readonly SKILLS="${HOME}/.agents/skills"
readonly DEFAULT_PATH=${PATH}
readonly LAUNCHER="${HOME}/.local/bin/rea"
readonly LAUNCHER_MARK='# jsh: REA launcher'
readonly NODE_HOME="${JSH_VENDOR:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/vendor}/node"
# rea-agents needs ^22.23.4, ^24.22.1, or >=26.12.1; the newest 24 release satisfies it.
readonly NODE_MAJOR=24
readonly NODE_DIST=https://nodejs.org/dist

select_node() {
  local node directory bundle
  local -a nodes=("$(command -v node || :)")
  jsh::step check "Node.js support for REA"
  # nvm versions, newest first, cover hosts whose default Node is too old.
  while IFS= read -r node; do
    nodes+=("${node}")
  done < <(printf '%s\n' "${NVM_DIR:-${HOME}/.nvm}"/versions/node/v*/bin/node "${NODE_HOME}"/v*/bin/node | sort -rV)
  nodes+=("${HOMEBREW_PREFIX:-/nonexistent}/opt/node/bin/node" /opt/homebrew/opt/node/bin/node \
    /home/linuxbrew/.linuxbrew/opt/node/bin/node /usr/local/opt/node/bin/node)
  # npm trusts only its bundled CAs; add the system store for TLS-inspecting proxies and mirrors.
  if [[ -z ${NODE_EXTRA_CA_CERTS:-} ]]; then
    for bundle in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
      if [[ -r ${bundle} ]]; then
        export NODE_EXTRA_CA_CERTS=${bundle}
        break
      fi
    done
  fi
  for node in "${nodes[@]}"; do
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
  return 1
}

# Fetch from nodejs.org; no internal mirror carries Node.js builds, so mirrors-only hosts use the proxy.
fetch_node() {
  local proxy=${https_proxy:-${HTTPS_PROXY:-}}
  local -a args=(--fail --location --silent --show-error --proto "=https" --proto-redir "=https"
    --connect-timeout 15 --max-time 600 --retry 2)
  # A proxy without credentials in its URL (Kerberos) needs curl to negotiate.
  [[ -z ${proxy} || ${proxy} == *@* ]] || args+=(--proxy-negotiate --proxy-user :)
  curl -q "${args[@]}" "$@"
}

provision_node() {
  local os arch version archive sums expected staging
  jsh::step install "Node.js for REA"
  if [[ ${JSH_MIRRORS_ONLY:-0} == 1 && -z ${https_proxy:-${HTTPS_PROXY:-}} ]]; then
    jsh::internet "Node.js ${NODE_MAJOR} for REA" || return 1
  fi
  jsh::need curl || return
  case $(uname -s) in Linux) os=linux ;; Darwin) os=darwin ;; *) os='' ;; esac
  case $(uname -m) in x86_64 | amd64) arch=x64 ;; aarch64 | arm64) arch=arm64 ;; *) arch='' ;; esac
  if [[ -z ${os} || -z ${arch} ]]; then
    jsh::notice "REA needs Node.js ${NODE_MAJOR}; no nodejs.org build for $(uname -sm)"
    return 1
  fi
  if ! version=$(fetch_node "${NODE_DIST}/index.json" |
    jq -er --arg major "v${NODE_MAJOR}." '[.[] | select(.version | startswith($major))][0].version'); then
    jsh::fail "Node.js ${NODE_MAJOR} release list is unavailable from nodejs.org"
    return 1
  fi
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::added "Node.js ${version} installed" "Node.js for REA is missing"
    return 1
  fi
  archive=node-${version}-${os}-${arch}.tar.gz
  staging=$(mktemp -d "${JSH_TMP:-${TMPDIR:-/tmp}}/node.XXXXXXXX")
  if ! jsh::task "Downloading ${archive}" fetch_node --output "${staging}/${archive}" \
    "${NODE_DIST}/${version}/${archive}" ||
    ! sums=$(fetch_node "${NODE_DIST}/${version}/SHASUMS256.txt"); then
    rm -rf -- "${staging}"
    jsh::fail "Node.js ${version} download failed"
    return 1
  fi
  expected=$(awk -v name="${archive}" '$2 == name { print $1 }' <<<"${sums}")
  if [[ -z ${expected} || $(jsh::sha256 "${staging}/${archive}") != "${expected}" ]]; then
    rm -rf -- "${staging}"
    jsh::fail "Node.js ${version} checksum does not match SHASUMS256.txt"
    return 1
  fi
  mkdir -p -- "${NODE_HOME}"
  rm -rf -- "${NODE_HOME}/.${version}"
  mkdir -- "${NODE_HOME}/.${version}"
  if ! tar -xzf "${staging}/${archive}" -C "${NODE_HOME}/.${version}" --strip-components 1 ||
    ! mv -- "${NODE_HOME}/.${version}" "${NODE_HOME}/${version}"; then
    rm -rf -- "${staging}" "${NODE_HOME}/.${version}"
    jsh::fail "Node.js ${version} could not be unpacked into ${NODE_HOME}"
    return 1
  fi
  rm -rf -- "${staging}"
  export PATH="${NODE_HOME}/${version}/bin:${PATH}"
  jsh::added "Node.js ${version} installed" "Node.js for REA is missing"
}

node_for_rea() {
  select_node && return
  provision_node && return
  [[ ${JSH_DRY_RUN} == 1 ]] ||
    jsh::notice 'REA needs a newer Node.js with zstd support; install or select a compatible Node.js, then rerun `jsh update`'
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

# Agents run `rea` with the login PATH; when its Node.js is too old, a launcher pins REA's Node.js.
link_rea() {
  local rea source status=0
  jsh::step check "REA command"
  if ! rea=$(command -v rea); then
    jsh::info "REA command unchecked: rea is not installed"
    return
  fi
  if [[ -e ${LAUNCHER} || -L ${LAUNCHER} ]] && ! grep -qxF "${LAUNCHER_MARK}" "${LAUNCHER}" 2>/dev/null; then
    jsh::ok "${LAUNCHER} is not managed by jsh"
    return
  fi
  if [[ ! -e ${LAUNCHER} ]] && PATH=${DEFAULT_PATH} rea --version >/dev/null 2>&1; then
    jsh::ok "rea runs with the default Node.js"
    return
  fi
  source=$(mktemp "${JSH_TMP:-${TMPDIR:-/tmp}}/rea.XXXXXXXX")
  printf '#!/usr/bin/env bash\n%s\nexec %q %q "$@"\n' "${LAUNCHER_MARK}" "$(command -v node)" "${rea}" >"${source}"
  jsh::file "${source}" "${LAUNCHER}" 755 || status=$?
  rm -f -- "${source}"
  return "${status}"
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
  install) if node_for_rea; then install_rea && link_rea; fi ;;
  update)
    node_ready=0
    if node_for_rea; then
      node_ready=1
      update_rea
      link_rea
    fi
    sync_graphify
    if [[ ${node_ready} == 1 ]]; then sync_rea; fi
    ;;
  *)
    sync_graphify
    if node_for_rea; then
      install_rea
      link_rea
      sync_rea
    fi
    ;;
esac
