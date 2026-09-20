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
  local id version url expected archive name digest temporary
  local -a missing=()

  jq -e '
    .id | type == "string" and length > 0
  ' "${manifest}" >/dev/null
  jq -e '
    (.kind == "tar")
    and (.url | type == "string" and startswith("https://"))
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.files | type == "object" and length > 0)
    and all(.files | to_entries[];
      (.key | test("^[^/]+[.]ttf$"))
      and (.value | test("^[0-9a-f]{64}$")))
  ' "${manifest}" >/dev/null || {
    jsh::log_error "Invalid font manifest: ${manifest}"
    return 1
  }

  while IFS=$'\t' read -r name digest; do
    if [[ ! -f ${destination}/${name} ]] ||
      [[ $(jsh_sha256_file "${destination}/${name}") != "${digest}" ]]; then
      missing+=("${name}")
    fi
  done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' "${manifest}")
  if ((${#missing[@]} == 0)); then
    jsh::log_note 'JetBrains Mono Nerd Font is current.'
    return
  fi
  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 ]]; then
    jsh::log_detail "Would install font files: ${missing[*]}"
    return
  fi

  id=$(jq -r '.id' "${manifest}")
  url=$(jq -r '.url' "${manifest}")
  expected=$(jq -r '.sha256' "${manifest}")
  version=$(sed -nE 's#.+/download/v?([^/]+)/.+#\1#p' <<< "${url}")
  [[ -n ${version} ]] || version=${expected:0:12}
  archive=$(jsh_download_artifact "${id}" "${version}" "${url}" .tar.xz "${expected}")

  mkdir -p "${JSH_ROOT}/tmp"
  temporary=$(mktemp -d "${JSH_ROOT}/tmp/fonts.XXXXXXXXXX")
  jsh_interrupt_cleanup_path "${temporary}"
  for name in "${missing[@]}"; do
    if ! tar -xOf "${archive}" "${name}" > "${temporary}/${name}"; then
      rm -rf -- "${temporary}"
      return 1
    fi
    digest=$(jq -r --arg name "${name}" '.files[$name]' "${manifest}")
    [[ $(jsh_sha256_file "${temporary}/${name}") == "${digest}" ]] || {
      jsh::log_error "Font checksum mismatch: ${name}"
      rm -rf -- "${temporary}"
      return 1
    }
    jsh_ensure_file "${destination}/${name}" "${temporary}/${name}" 0644 || {
      local ensure_status=$?
      if [[ ${ensure_status} != 1 ]]; then
        rm -rf -- "${temporary}"
        return "${ensure_status}"
      fi
    }
  done
  rm -rf -- "${temporary}"
  fc-cache "${destination}"
  jsh::log_success 'JetBrains Mono Nerd Font installed.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_fonts
fi
