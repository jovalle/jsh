#!/usr/bin/env bash
# Install Jsh-owned optional tools into platform-qualified data directories.

jsh_gum_release_metadata() {
  local url=$1 expected_archive=$2 archive_suffix=$3 checksums

  command -v curl > /dev/null 2>&1 || return 1
  checksums=$(curl --fail --silent --location --retry 2 --connect-timeout 20 \
    --max-time 60 "${url}") || return 1
  printf '%s\n' "${checksums}" | awk -v expected="${expected_archive}" -v suffix="${archive_suffix}" '
    {
      archive = $NF
      sub(/^\*/, "", archive)
      if ((expected != "" && archive == expected) ||
          (expected == "" && index(archive, "gum_") == 1 &&
           substr(archive, length(archive) - length(suffix) + 1) == suffix)) {
        print archive "\t" $1
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  '
}

jsh_gum_cache_metadata() {
  local cache_file=$1 archive=$2 checksum=$3 temporary
  mkdir -p -- "${cache_file%/*}" || return
  temporary=${cache_file}.partial.$$
  declare -F jsh_interrupt_cleanup_path > /dev/null && jsh_interrupt_cleanup_path "${temporary}"
  printf '%s\t%s\n' "${archive}" "${checksum}" > "${temporary}" &&
    mv -f -- "${temporary}" "${cache_file}"
}

jsh_gum_apply_release_metadata() {
  local version=$1 archive_suffix=$2 expected_archive=$3 metadata=$4 archive checksum

  archive=${metadata%%$'\t'*}
  checksum=${metadata#*$'\t'}
  [[ ${archive} != "${metadata}" && ${#checksum} -eq 64 && ${checksum} != *[!0-9A-Fa-f]* ]] || return 1
  if [[ -n ${expected_archive} ]]; then
    [[ ${archive} == "${expected_archive}" ]] || return 1
  else
    [[ ${archive} == gum_*"${archive_suffix}" && ${archive} != */* ]] || return 1
    version=${archive#gum_}
    version=${version%"${archive_suffix}"}
    [[ ${version} == [0-9]* && ${version} != *[!0-9A-Za-z.+-]* ]] || return 1
  fi

  JSH_GUM_VERSION=${version}
  JSH_GUM_ARCHIVE=${archive}
  JSH_GUM_MEMBER=${archive%.tar.gz}/gum
  JSH_GUM_CHECKSUM=${checksum}
  JSH_GUM_URL="https://github.com/charmbracelet/gum/releases/download/v${version}/${archive}"
}

jsh_gum_release() {
  local platform=${1:-${JSH_PLATFORM:-}} architecture=${2:-${JSH_ARCH:-}}
  local requested=${JSH_GUM_VERSION:-} version release_platform release_arch archive_suffix
  local cache cache_file checksum_url expected_archive metadata fetched=0

  case ${platform} in
    darwin) release_platform=Darwin ;;
    linux) release_platform=Linux ;;
    *) return 1 ;;
  esac
  case ${architecture} in
    amd64) release_arch=x86_64 ;;
    arm64) release_arch=arm64 ;;
    *) return 1 ;;
  esac

  cache=${XDG_CACHE_HOME:-${HOME}/.cache}/jsh/artifacts
  archive_suffix=_${release_platform}_${release_arch}.tar.gz
  if [[ -n ${requested} ]]; then
    version=${requested#v}
    [[ ${version} == [0-9]* && ${version} != *[!0-9A-Za-z.+-]* ]] || return 1
    expected_archive=gum_${version}${archive_suffix}
    checksum_url=https://github.com/charmbracelet/gum/releases/download/v${version}/checksums.txt
    cache_file=${cache}/gum-release-${version}-${platform}-${architecture}.metadata
  else
    checksum_url=https://github.com/charmbracelet/gum/releases/latest/download/checksums.txt
    cache_file=${cache}/gum-release-latest-${platform}-${architecture}.metadata
  fi

  if metadata=$(jsh_gum_release_metadata "${checksum_url}" "${expected_archive:-}" "${archive_suffix}"); then
    fetched=1
  elif [[ -r ${cache_file} ]]; then
    IFS= read -r metadata < "${cache_file}" || return 1
  else
    return 1
  fi
  jsh_gum_apply_release_metadata "${version:-}" "${archive_suffix}" "${expected_archive:-}" "${metadata}" || return
  ((fetched == 0)) || jsh_gum_cache_metadata \
    "${cache_file}" "${JSH_GUM_ARCHIVE}" "${JSH_GUM_CHECKSUM}" || return
}

jsh_gum_archive_safe() {
  local archive=$1 entry
  tar -tzf "${archive}" > /dev/null || return 1
  while IFS= read -r entry; do
    case ${entry} in
      /* | ../* | */../* | */..) return 1 ;;
    esac
  done < <(tar -tzf "${archive}")
}

jsh::bootstrap_gum() {
  local archive staging candidate data_home destination temporary version_output

  [[ ${JSH_INTERACTIVE:-0} == 1 && ${JSH_REMOTE:-0} != 1 ]] || return 0
  [[ -z ${JSH_GUM:-} || ! -x ${JSH_GUM} ]] || return 0
  jsh_gum_release "${JSH_PLATFORM:-}" "${JSH_ARCH:-}" || {
    jsh::log_note "Gum is unavailable for ${JSH_PLATFORM:-unknown}-${JSH_ARCH:-unknown}; keeping the shell UI."
    return 0
  }
  data_home=${JSH_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh}
  destination=${data_home}/tools/gum/${JSH_GUM_VERSION}/${JSH_PLATFORM}-${JSH_ARCH}/gum
  if [[ -x ${destination} ]] &&
    version_output=$("${destination}" --version 2> /dev/null) &&
    [[ ${version_output} == *"${JSH_GUM_VERSION}"* ]]; then
    return 0
  fi

  command -v curl > /dev/null 2>&1 || {
    jsh::log_error 'curl is required to install Gum.'
    return 1
  }
  command -v tar > /dev/null 2>&1 || {
    jsh::log_error 'tar is required to install Gum.'
    return 1
  }
  archive=$(jsh_download_artifact gum "${JSH_GUM_VERSION}-${JSH_PLATFORM}-${JSH_ARCH}" \
    "${JSH_GUM_URL}" .tar.gz "${JSH_GUM_CHECKSUM}") || return
  jsh_gum_archive_safe "${archive}" || {
    jsh::log_error 'The Gum archive contains an unsafe path.'
    return 1
  }

  staging=$(mktemp -d "${TMPDIR:-/tmp}/jsh-gum.XXXXXXXXXX") || return
  declare -F jsh_interrupt_cleanup_path > /dev/null && jsh_interrupt_cleanup_path "${staging}"
  if ! tar -xzf "${archive}" -C "${staging}" "${JSH_GUM_MEMBER}"; then
    rm -rf -- "${staging}"
    return 1
  fi
  candidate=${staging}/${JSH_GUM_MEMBER}
  if [[ ! -f ${candidate} || -L ${candidate} ]]; then
    rm -rf -- "${staging}"
    jsh::log_error 'The Gum archive does not contain a regular executable.'
    return 1
  fi
  chmod 0755 "${candidate}"
  version_output=$("${candidate}" --version 2> /dev/null) || {
    rm -rf -- "${staging}"
    jsh::log_error 'The downloaded Gum executable could not run.'
    return 1
  }
  [[ ${version_output} == *"${JSH_GUM_VERSION}"* ]] || {
    rm -rf -- "${staging}"
    jsh::log_error "Unexpected Gum version: ${version_output}"
    return 1
  }

  mkdir -p -- "${destination%/*}"
  temporary=${destination}.partial.$$
  declare -F jsh_interrupt_cleanup_path > /dev/null && jsh_interrupt_cleanup_path "${temporary}"
  if ! cp -- "${candidate}" "${temporary}" ||
    ! chmod 0755 "${temporary}" ||
    ! mv -f -- "${temporary}" "${destination}"; then
    rm -f -- "${temporary}"
    rm -rf -- "${staging}"
    return 1
  fi
  rm -rf -- "${staging}"
  JSH_GUM=${destination}
  export JSH_GUM
  jsh::log_success "Installed Gum ${JSH_GUM_VERSION} for ${JSH_PLATFORM}-${JSH_ARCH}."
}
