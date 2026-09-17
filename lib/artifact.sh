#!/usr/bin/env bash
# Download artifacts to the shared cache and activate only verified content.

jsh_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

jsh_sha512_file() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum -- "$1" | awk '{print $1}'
  else
    shasum -a 512 -- "$1" | awk '{print $1}'
  fi
}

jsh_checksum_file() {
  case $1 in
    sha256) jsh_sha256_file "$2" ;;
    sha512) jsh_sha512_file "$2" ;;
    *) jsh_error "Unsupported checksum algorithm: $1"; return 2 ;;
  esac
}

jsh_download_artifact() {
  local id=$1 version=$2 url=$3 suffix=$4 expected=${5:-}
  local algorithm=${6:-sha256} cache target temporary actual safe_version
  cache=${XDG_CACHE_HOME:-${HOME}/.cache}/jsh/artifacts
  safe_version=${version//[^A-Za-z0-9.+~-]/_}
  target=${cache}/${id}-${safe_version}${suffix}

  if [[ -s ${target} ]]; then
    if [[ -z ${expected} || $(jsh_checksum_file "${algorithm}" "${target}") == "${expected}" ]]; then
      printf '%s\n' "${target}"
      return
    fi
  fi
  mkdir -p -- "${cache}"
  temporary=${target}.partial
  declare -F jsh_interrupt_cleanup_path >/dev/null && jsh_interrupt_cleanup_path "${temporary}"
  rm -f -- "${temporary}"
  if ! curl --fail --location --retry 2 --connect-timeout 20 --max-time 600 \
    --output "${temporary}" "${url}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  if [[ -n ${expected} ]]; then
    actual=$(jsh_checksum_file "${algorithm}" "${temporary}")
    if [[ ${actual} != "${expected}" ]]; then
      rm -f -- "${temporary}"
      jsh_error "Checksum mismatch for ${id}: expected ${expected}, got ${actual}."
      return 1
    fi
  fi
  mv -f -- "${temporary}" "${target}"
  printf '%s\n' "${target}"
}
