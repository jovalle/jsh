#!/usr/bin/env bash
# Install and verify the managed JetBrains Mono Nerd Font files.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
for library_file in "${JSH_ROOT}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file

install_fonts() {
  local manifest=${JSH_FONT_MANIFEST:-${JSH_ROOT}/conf/fonts.json}
  local destination=${JSH_FONT_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/fonts/jsh}
  local id repository asset metadata version url expected archive name temporary
  local -i changed=0 ensure_status
  local -a files=()

  jq -e '
    (.id | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and (.repository | type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))
    and (.asset | type == "string" and test("^[^/]+[.]tar[.]xz$"))
    and (.files | type == "array" and length > 0)
    and all(.files[]; type == "string" and test("^[^/]+[.]ttf$"))
  ' "${manifest}" >/dev/null || {
    jsh::log_error "Invalid font manifest: ${manifest}"
    return 1
  }
  id=$(jq -r '.id' "${manifest}")
  repository=$(jq -r '.repository' "${manifest}")
  asset=$(jq -r '.asset' "${manifest}")
  mapfile -t files < <(jq -r '.files[]' "${manifest}")

  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]]; then
    jsh::log_detail "Would install the latest ${asset} from ${repository}: ${files[*]}"
    return
  fi

  if ! metadata=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repository}/releases/latest"); then
    for name in "${files[@]}"; do
      [[ -f ${destination}/${name} ]] || {
        jsh::log_error "Could not resolve the latest ${repository} release."
        return 1
      }
    done
    jsh::log_warn "Could not check ${repository} for updates; keeping installed fonts."
    return
  fi
  version=$(jq -r '.tag_name // empty' <<< "${metadata}")
  url=$(jq -r --arg asset "${asset}" '.assets[] | select(.name == $asset) | .browser_download_url' <<< "${metadata}")
  expected=$(jq -r --arg asset "${asset}" '.assets[] | select(.name == $asset) | .digest // empty' <<< "${metadata}")
  expected=${expected#sha256:}
  if [[ -z ${expected} ]]; then
    expected=$(curl -fsSL "https://github.com/${repository}/releases/download/${version}/SHA-256.txt" |
      awk -v asset="${asset}" '$2 == asset { print $1 }' || true)
  fi
  [[ -n ${version} && ${url} == https://* && ${expected} =~ ^[0-9a-f]{64}$ ]] || {
    jsh::log_error "Could not resolve a verifiable ${asset} in the latest ${repository} release."
    return 1
  }
  archive=$(jsh_download_artifact "${id}" "${version#v}" "${url}" .tar.xz "${expected}")

  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp -d "${JSH_ROOT}/tmp/fonts.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  for name in "${files[@]}"; do
    if ! tar -xOf "${archive}" "${name}" > "${temporary}/${name}"; then
      jsh::log_error "${asset} ${version} does not contain ${name}."
      rm -rf -- "${temporary}"
      return 1
    fi
    ensure_status=0
    jsh_ensure_file "${destination}/${name}" "${temporary}/${name}" 0644 || ensure_status=$?
    case ${ensure_status} in
      0) changed=1 ;;
      1) ;;
      *)
        rm -rf -- "${temporary}"
        return "${ensure_status}"
        ;;
    esac
  done
  rm -rf -- "${temporary}"
  if ((changed == 0)); then
    jsh::log_note "JetBrains Mono Nerd Font ${version} is current."
    return
  fi
  fc-cache "${destination}"
  jsh::log_success "JetBrains Mono Nerd Font ${version} installed."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_fonts
fi
