#!/bin/sh
# Validate the AI agent clients in conf/agents.json; --repair fixes stale links and plugins.
# Prints tab-separated records: `ok`, `issue`, or `fixed`, followed by a message.

set -eu

root=$(CDPATH='' cd -P "${1:?usage: agents.sh JSH_ROOT [--repair]}" && pwd -P)
repair=0
[[ "${2:-}" != --repair ]] || repair=1
config=${JSH_AGENTS_CONFIG:-${root}/conf/agents.json}

case $(uname -s) in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) os=other ;;
esac

record() {
  printf '%s\t%s\n' "$1" "$2"
}

expand_home() {
  case $1 in
    \~/*) printf '%s/%s\n' "${HOME}" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

check_links() {
  [[ -d "$2" ]] || return 0
  for link in "$2"/* "$2"/.[!.]*; do
    [[ -L "${link}" ]] && [[ ! -e "${link}" ]] || continue
    if [[ "${repair}" -eq 1 ]] && rm -f -- "${link}"; then
      record fixed "$1: removed broken link ${link}"
      changed=1
    else
      record issue "$1: broken link ${link}"
      healthy=0
    fi
  done
}

# Only local plugin paths are checked; npm plugins are installed by OpenCode on demand.
check_plugins() {
  [[ -f "$2" ]] || return 0
  if ! specs=$(jq -r '.plugin // [] | .[] | if type == "array" then .[0] else . end | strings' "$2" 2> /dev/null); then
    record issue "$1: cannot parse $2"
    healthy=0
    return 0
  fi
  while IFS= read -r spec; do
    case ${spec} in
      file://*) target=${spec#file://} ;;
      \~/* | /*) target=$(expand_home "${spec}") ;;
      ./* | ../*) target=${2%/*}/${spec} ;;
      *) continue ;;
    esac
    [[ ! -e "${target}" ]] || continue
    # Rewrite in place so a symlinked or permission-restricted config keeps its identity.
    if [[ "${repair}" -eq 1 ]] && updated=$(jq --arg spec "${spec}" \
      '.plugin |= map(select((if type == "array" then .[0] else . end) != $spec))' "$2") &&
      printf '%s\n' "${updated}" > "$2"; then
      record fixed "$1: removed missing plugin ${spec} from $2"
      changed=1
    else
      record issue "$1: missing plugin ${spec} in $2"
      healthy=0
    fi
  done << EOF
${specs}
EOF
}

if ! command -v jq > /dev/null 2>&1; then
  record issue 'AI agents cannot be validated: jq is missing.'
  exit 0
fi
if ! agents=$(jq -c --arg os "${os}" '.agents[] | select((.os // [$os]) | index($os))' "${config}" 2> /dev/null); then
  record issue "AI agents cannot be validated: cannot parse ${config}."
  exit 0
fi

while IFS= read -r agent; do
  [[ -n "${agent}" ]] || continue
  name=$(printf '%s' "${agent}" | jq -r '.name')
  app=$(printf '%s' "${agent}" | jq -r '.app // empty')
  executable=$(printf '%s' "${agent}" | jq -r '.command // empty')
  if [[ -n "${app}" ]] && [[ ! -d "/Applications/${app}" ]] && [[ ! -d "${HOME}/Applications/${app}" ]]; then
    record issue "${name}: ${app} is not installed; run \`jsh install\`."
    continue
  fi
  if [[ -n "${executable}" ]] && ! command -v "${executable}" > /dev/null 2>&1; then
    record issue "${name}: \`${executable}\` is not installed; run \`jsh install\`."
    continue
  fi

  healthy=1
  changed=0
  links=$(printf '%s' "${agent}" | jq -r '.links // [] | .[]')
  while IFS= read -r directory; do
    [[ -z "${directory}" ]] || check_links "${name}" "$(expand_home "${directory}")"
  done << EOF
${links}
EOF
  plugins=$(printf '%s' "${agent}" | jq -r '.plugins // empty')
  [[ -z "${plugins}" ]] || check_plugins "${name}" "$(expand_home "${plugins}")"

  if [[ "${changed}" -eq 1 ]]; then
    reload=$(printf '%s' "${agent}" | jq -r '.reload // [] | @sh')
    if [[ -n "${reload}" ]]; then
      eval "set -- ${reload}"
      "$@" < /dev/null > /dev/null 2>&1 || record issue "${name}: \`$*\` failed after repair."
    fi
  fi

  summary=installed
  check=$(printf '%s' "${agent}" | jq -r '.check // [] | @sh')
  if [[ -n "${check}" ]]; then
    eval "set -- ${check}"
    if output=$("$@" < /dev/null 2>&1); then
      summary=$(printf '%s\n' "${output}" | sed -n '/./{p;q;}')
    else
      record issue "${name}: \`$*\` failed: $(printf '%s\n' "${output}" | sed -n '/./{p;q;}')"
      healthy=0
    fi
  fi
  [[ "${healthy}" -eq 0 ]] || record ok "${name}: ${summary:-installed}"
done << EOF
${agents}
EOF
