#!/usr/bin/env bash
# Resolve and update the layered package manifest with jq.

jsh_manifest_path() {
  printf '%s\n' "${JSH_PACKAGE_MANIFEST:-${JSH_ROOT}/conf/packages.json}"
}

jsh_manifest_context() {
  local os_name distro desktop host architecture uname_value
  uname_value=${JSH_UNAME:-$(uname -s)}
  case ${JSH_MANIFEST_OS:-${uname_value}} in
    Darwin | darwin) os_name=darwin ;;
    Linux | linux) os_name=linux ;;
    *) os_name=${JSH_MANIFEST_OS:-${uname_value,,}} ;;
  esac

  distro=${JSH_MANIFEST_DISTRO:-}
  if [[ -z ${distro} ]]; then
    if [[ ${os_name} == linux ]] && declare -F jsh_linux_family >/dev/null; then
      distro=$(jsh_linux_family)
    else
      distro=unknown
    fi
  fi

  desktop=${JSH_MANIFEST_DESKTOP:-}
  if [[ -z ${desktop} ]]; then
    if declare -F jsh_linux_desktop >/dev/null; then
      desktop=$(jsh_linux_desktop)
    else
      desktop=unknown
    fi
  fi

  host=${JSH_MANIFEST_HOST:-$(hostname -s)}
  host=${host,,}
  architecture=${JSH_MANIFEST_ARCH:-$(uname -m)}
  case ${architecture,,} in
    amd64 | x86_64) architecture=amd64 ;;
    aarch64 | arm64) architecture=arm64 ;;
    *) architecture=${architecture,,} ;;
  esac

  jq -cn \
    --arg os "${os_name}" \
    --arg distro "${distro}" \
    --arg desktop "${desktop}" \
    --arg host "${host}" \
    --arg arch "${architecture}" \
    '{os: $os, distro: $distro, desktop: $desktop, host: $host, arch: $arch}'
}

jsh_manifest_validate() {
  local manifest=${1:-$(jsh_manifest_path)}
  jq -e '
    def string_list:
      type == "array"
      and all(.[]; type == "string" and length > 0)
      and length == (unique | length);
    def valid_brew:
      type == "object"
      and ((keys - ["taps", "formulae", "casks"]) | length == 0)
      and all(.[]; string_list);
    def valid_npm:
      type == "object"
      and all(to_entries[]; (.key | length > 0) and (.value | type == "string" and length > 0));
    def valid_install:
      type == "object"
      and ((keys - ["apt", "dnf", "pacman", "flatpak", "cargo", "uv", "brew", "npm"]) | length == 0)
      and all(to_entries[];
        if .key == "brew" then .value | valid_brew
        elif .key == "npm" then .value | valid_npm
        else .value | string_list
        end);
    .schema == 1
    and (.layers | type == "array")
    and ([.layers[].id] | length == (unique | length))
    and all(.layers[];
      (.id | type == "string" and length > 0)
      and (.match // {} | type == "object")
      and (((.match // {}) | keys - ["os", "distro", "desktop", "host", "arch"]) | length == 0)
      and all((.match // {})[]; string_list)
      and (.install // {} | valid_install))
  ' "${manifest}" >/dev/null
}

jsh_manifest_resolve() {
  local manifest=${1:-$(jsh_manifest_path)} context selected_layers layer
  jsh_manifest_validate "${manifest}" || return
  context=$(jsh_manifest_context) || return
  selected_layers=${JSH_PACKAGE_LAYERS:-}
  if [[ -n ${selected_layers} ]]; then
    while IFS= read -r layer; do
      jq -e --arg layer "${layer}" 'any(.layers[]; .id == $layer)' "${manifest}" >/dev/null || {
        printf 'Unknown package layer: %s\n' "${layer}" >&2
        return 1
      }
    done < <(tr ',' '\n' <<< "${selected_layers}")
  fi
  jq --argjson context "${context}" --arg selected_layers "${selected_layers}" '
    def matches($context):
      all((.match // {}) | to_entries[];
        .key as $key | (.value | index($context[$key]) != null));
    def selected($selected_layers; $layer_id):
      $selected_layers == "" or ($selected_layers | split(",") | index($layer_id) != null);
    def append_unique($values):
      reduce $values[] as $value (.; if index($value) == null then . + [$value] else . end);
    reduce .layers[] as $layer (
      {
        apt: [], dnf: [], pacman: [], flatpak: [], cargo: [], uv: [],
        brew: {taps: [], formulae: [], casks: []}, npm: {}, layers: []
      };
      if ($layer | matches($context)) and selected($selected_layers; $layer.id) then
        .layers += [$layer.id]
        | reduce ["apt", "dnf", "pacman", "flatpak", "cargo", "uv"][] as $manager
            (.; .[$manager] |= append_unique($layer.install[$manager] // []))
        | reduce ["taps", "formulae", "casks"][] as $kind
            (.; .brew[$kind] |= append_unique($layer.install.brew[$kind] // []))
        | .npm = (.npm * ($layer.install.npm // {}))
      else . end
    )
  ' "${manifest}"
}

jsh_manifest_list() {
  local manager=$1 manifest=${2:-$(jsh_manifest_path)} resolved
  case ${manager} in
    apt | dnf | pacman | flatpak | cargo | uv)
      resolved=$(jsh_manifest_resolve "${manifest}") || return
      jq -r --arg manager "${manager}" '.[$manager][]' <<< "${resolved}"
      ;;
    npm)
      resolved=$(jsh_manifest_resolve "${manifest}") || return
      jq -r '.npm | to_entries[] | [.key, .value] | @tsv' <<< "${resolved}"
      ;;
    *)
      printf 'Unknown package manager: %s\n' "${manager}" >&2
      return 2
      ;;
  esac
}

jsh_manifest_brewfile() {
  local manifest=${1:-$(jsh_manifest_path)} resolved
  resolved=$(jsh_manifest_resolve "${manifest}") || return
  jq -r '
    (.brew.taps[] | "tap \"\(.)\""),
    (.brew.formulae[] | "brew \"\(.)\""),
    (.brew.casks[] | "cask \"\(.)\"")
  ' <<< "${resolved}"
}

jsh_manifest_configured() {
  local kind=$1 name=$2 manifest=${3:-$(jsh_manifest_path)} manifest_kind
  case ${kind} in
    tap) manifest_kind=taps ;;
    brew) manifest_kind=formulae ;;
    cask) manifest_kind=casks ;;
    *) printf 'Unknown Homebrew kind: %s\n' "${kind}" >&2; return 2 ;;
  esac
  jsh_manifest_validate "${manifest}" || return
  jq -r --arg kind "${manifest_kind}" --arg name "${name}" '
    .layers[]
    | select((.install.brew[$kind] // []) | index($name) != null)
    | "conf/packages.json:\(.id)"
  ' "${manifest}"
}

jsh_manifest_adopt() {
  local kind=$1 name=$2 layer_id=$3 manifest=${4:-$(jsh_manifest_path)} manifest_kind
  local directory temporary
  case ${kind} in
    tap) manifest_kind=taps ;;
    brew) manifest_kind=formulae ;;
    cask) manifest_kind=casks ;;
    *) printf 'Unknown Homebrew kind: %s\n' "${kind}" >&2; return 2 ;;
  esac
  jsh_manifest_validate "${manifest}" || return
  jq -e --arg layer "${layer_id}" 'any(.layers[]; .id == $layer)' "${manifest}" >/dev/null || {
    printf 'Unknown package layer: %s\n' "${layer_id}" >&2
    return 1
  }
  jq -e --arg layer "${layer_id}" --arg kind "${manifest_kind}" --arg name "${name}" '
    any(.layers[]; .id == $layer and ((.install.brew[$kind] // []) | index($name) != null))
  ' "${manifest}" >/dev/null && return 0

  directory=${manifest%/*}
  temporary=$(mktemp "${directory}/.packages.XXXXXX") || return
  declare -F jsh_interrupt_cleanup_path >/dev/null && jsh_interrupt_cleanup_path "${temporary}"
  cp -p "${manifest}" "${temporary}"
  if ! jq --arg layer "${layer_id}" --arg kind "${manifest_kind}" --arg name "${name}" '
    .layers |= map(
      if .id == $layer then
        .install = (.install // {})
        | .install.brew = (.install.brew // {})
        | .install.brew[$kind] = (((.install.brew[$kind] // []) + [$name]) | unique)
      else . end
    )
  ' "${manifest}" > "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  if ! jsh_manifest_validate "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  sync "${temporary}" 2>/dev/null || sync
  mv -f "${temporary}" "${manifest}"
}

jsh_manifest_main() {
  local command=${1:-}
  shift || true
  case ${command} in
    validate) jsh_manifest_validate "$@" ;;
    list) jsh_manifest_list "$@" ;;
    brewfile) jsh_manifest_brewfile "$@" ;;
    configured) jsh_manifest_configured "$@" ;;
    adopt) jsh_manifest_adopt "$@" ;;
    *)
      printf 'Usage: manifest.sh {validate|list|brewfile|configured|adopt} ...\n' >&2
      return 2
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]-} == "$0" ]]; then
  set -euo pipefail
  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  JSH_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
  export JSH_ROOT
  jsh_manifest_main "$@"
fi
