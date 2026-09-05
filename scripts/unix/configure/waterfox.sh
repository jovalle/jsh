#!/usr/bin/env bash
# Configure Waterfox preferences, Citrix policy, and file associations.

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
# shellcheck source=../../../lib/unix/waterfox.sh
. "${JSH_ROOT}/lib/unix/waterfox.sh"

readonly ACTION=${1:-apply}
readonly CONFIG_DIR="${JSH_ROOT}/conf/gecko"
readonly BETTERFOX_MANIFEST=${JSH_BETTERFOX_MANIFEST:-${CONFIG_DIR}/betterfox.json}
readonly WATERFOX_OVERRIDES=${JSH_WATERFOX_OVERRIDES:-${CONFIG_DIR}/waterfox.js}
# shellcheck disable=SC2034 # Consumed by sourced lib/unix/waterfox.sh.
readonly WATERFOX_CONFIG=${JSH_WATERFOX_CONFIG:-${JSH_ROOT}/conf/waterfox.yaml}
readonly BETTERFOX_RAW_BASE=${BETTERFOX_RAW_BASE:-https://raw.githubusercontent.com/yokoffing/Betterfox}
readonly BETTERFOX_API_URL=${BETTERFOX_API_URL:-https://api.github.com/repos/yokoffing/Betterfox/releases/latest}
readonly STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/waterfox"
readonly CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/jsh/betterfox"

TEMP_DIR=
BETTERFOX_SOURCE=
POLICY_SOURCE=
POLICY_TARGET=
POLICY_CHANGED=0
# shellcheck disable=SC2034 # Consumed by sourced lib/unix/waterfox.sh.
ACTIVE_WATERFOX_CONFIG=
# shellcheck disable=SC2034 # Consumed by sourced lib/unix/waterfox.sh.
ACTIVE_WATERFOX_PREFERENCES=
# shellcheck disable=SC2034 # Consumed by sourced lib/unix/waterfox.sh.
ACTIVE_WATERFOX_PROFILE=
WATERFOX_SETTINGS_DIFFER=0

cleanup() {
  [[ -z ${TEMP_DIR} ]] || rm -rf -- "${TEMP_DIR}"
}

trap cleanup EXIT

require_command() {
  command -v "$1" > /dev/null 2>&1 || {
    jsh_error "$1 is required to configure Waterfox."
    return 1
  }
}

sha256_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum -- "$1" | awk '{ print $1 }'
  else
    shasum -a 256 -- "$1" | awk '{ print $1 }'
  fi
}

manifest_value() {
  jq -er ".$1" "${BETTERFOX_MANIFEST}"
}

validate_manifest() {
  jq -e '
    (keys == ["revision", "sha256", "version"])
    and (.version | type == "string" and test("^[0-9]+([.][0-9]+)*$"))
    and (.revision | type == "string" and test("^[0-9a-f]{40}$"))
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "${BETTERFOX_MANIFEST}" > /dev/null || {
    jsh_error "Invalid Betterfox manifest: ${BETTERFOX_MANIFEST}"
    return 1
  }
  [[ -r ${WATERFOX_OVERRIDES} ]] || {
    jsh_error "Missing Waterfox preferences: ${WATERFOX_OVERRIDES}"
    return 1
  }
}

stage_betterfox() {
  local revision expected cached downloaded actual
  revision=$(manifest_value revision)
  expected=$(manifest_value sha256)
  cached="${CACHE_DIR}/${revision}/user.js"

  if [[ -r ${cached} && $(sha256_file "${cached}") == "${expected}" ]]; then
    BETTERFOX_SOURCE=${cached}
    return
  fi

  downloaded="${TEMP_DIR}/betterfox.js"
  if ! curl -fsSL --retry 2 --output "${downloaded}" \
    "${BETTERFOX_RAW_BASE}/${revision}/user.js"; then
    jsh_error "Could not download pinned Betterfox revision ${revision}."
    return 1
  fi
  actual=$(sha256_file "${downloaded}")
  [[ ${actual} == "${expected}" ]] || {
    jsh_error "Betterfox checksum mismatch: expected ${expected}, got ${actual}."
    return 1
  }
  grep -q 'user_pref' "${downloaded}" || {
    jsh_error "Downloaded Betterfox file contains no preferences."
    return 1
  }

  install -d -m 0700 -- "${cached%/*}"
  install -m 0644 -- "${downloaded}" "${cached}.new"
  mv -f -- "${cached}.new" "${cached}"
  BETTERFOX_SOURCE=${cached}
}

waterfox_binary() {
  local candidate
  if [[ -n ${JSH_WATERFOX_BIN:-} ]]; then
    [[ -x ${JSH_WATERFOX_BIN} ]] || return 1
    printf '%s\n' "${JSH_WATERFOX_BIN}"
    return
  fi
  if [[ $(uname -s) == Darwin ]]; then
    for candidate in \
      "/Applications/Waterfox.app/Contents/MacOS/waterfox" \
      "${HOME}/Applications/Waterfox.app/Contents/MacOS/waterfox"; do
      [[ -x ${candidate} ]] || continue
      printf '%s\n' "${candidate}"
      return
    done
    return 1
  fi
  command -v waterfox 2> /dev/null
}

waterfox_root() {
  if [[ -n ${JSH_WATERFOX_ROOT:-} ]]; then
    printf '%s\n' "${JSH_WATERFOX_ROOT}"
  elif [[ $(uname -s) == Darwin ]]; then
    printf '%s\n' "${HOME}/Library/Application Support/Waterfox"
  else
    printf '%s\n' "${HOME}/.waterfox"
  fi
}

validate_profile_path() {
  local root=$1 profile=$2 canonical_root canonical_profile
  [[ ${profile} == /* && -d ${profile} ]] || return 1
  canonical_root=$(cd -P -- "${root}" && pwd)
  canonical_profile=$(cd -P -- "${profile}" && pwd)
  case ${canonical_profile} in
    "${canonical_root%/}"/*) printf '%s\n' "${canonical_profile}" ;;
    *)
      jsh_error "Selected Waterfox profile escapes its profile root: ${profile}"
      return 2
      ;;
  esac
}

install_default_path() {
  local root=$1 ini=$2 install_path=
  if [[ -r ${root}/installs.ini ]]; then
    install_path=$(awk -F= '$1 == "Default" { print substr($0, index($0, "=") + 1); exit }' \
      "${root}/installs.ini")
  fi
  if [[ -z ${install_path} ]]; then
    install_path=$(awk -F= '
      /^\[Install[^]]+\]$/ { install_section=1; next }
      /^\[/ { install_section=0 }
      install_section && $1 == "Default" {
        print substr($0, index($0, "=") + 1); exit
      }
    ' "${ini}")
  fi
  [[ -n ${install_path} ]] || return 1
  printf '%s\n' "${install_path}"
}

registered_profile_path() {
  awk -F= '
    function emit_profile() {
      if (!in_profile || profile_path == "") return
      if (first_path == "") {
        first_relative=is_relative
        first_path=profile_path
      }
      if (is_default == 1) {
        print is_relative "|" profile_path
        selected=1
        exit
      }
    }
    /^\[/ {
      emit_profile()
      in_profile=($0 ~ /^\[Profile[0-9]+\]$/)
      profile_path=""
      is_relative=1
      is_default=0
      next
    }
    in_profile && $1 == "Path" { profile_path=substr($0, index($0, "=") + 1) }
    in_profile && $1 == "IsRelative" { is_relative=$2 }
    in_profile && $1 == "Default" { is_default=$2 }
    END {
      emit_profile()
      if (!selected && first_path != "") print first_relative "|" first_path
    }
  ' "$1"
}

selected_profile() {
  local root=$1 ini="${1}/profiles.ini" install_path relative path profile
  [[ -r ${ini} ]] || return 1

  if install_path=$(install_default_path "${root}" "${ini}"); then
    [[ ${install_path} == /* ]] || install_path="${root}/${install_path}"
    if [[ -d ${install_path} ]]; then
      validate_profile_path "${root}" "${install_path}"
      return
    fi
  fi

  IFS='|' read -r relative path < <(registered_profile_path "${ini}")
  [[ -n ${path} ]] || return 1
  if [[ ${relative} == 0 ]]; then
    profile=${path}
  else
    profile="${root}/${path}"
  fi
  validate_profile_path "${root}" "${profile}"
}

bootstrap_profile() {
  local root=$1 binary=$2
  [[ ! -e ${root}/profiles.ini && ! -e ${root}/installs.ini ]] || {
    jsh_error "Waterfox has a profile registry but no usable default profile."
    return 1
  }
  install -d -m 0700 -- "${root}"
  "${binary}" -CreateProfile "jsh-default ${root}/Profiles/jsh-default" > /dev/null
  selected_profile "${root}" > /dev/null || {
    jsh_error "Waterfox did not create a usable default profile."
    return 1
  }
  jsh_success "Created the jsh-default Waterfox profile."
}

profile_is_locked() {
  local profile=$1 lock lock_file
  for lock in .parentlock parent.lock lock; do
    lock_file="${profile}/${lock}"
    [[ -e ${lock_file} || -L ${lock_file} ]] || continue
    if command -v lsof > /dev/null 2>&1; then
      lsof -t -- "${lock_file}" > /dev/null 2>&1 && return 0
      continue
    fi
    if command -v fuser > /dev/null 2>&1; then
      fuser "${lock_file}" > /dev/null 2>&1 && return 0
      continue
    fi
    return 0
  done
  return 1
}

compose_preferences() {
  local profile=$1 output=$2 version revision toolbar quoted_toolbar
  version=$(manifest_value version)
  revision=$(manifest_value revision)
  {
    printf '/* Managed by jsh. Betterfox %s (%s). */\n\n' "${version}" "${revision}"
    cat -- "${BETTERFOX_SOURCE}"
    printf '\n\n/* jsh Waterfox overrides */\n'
    cat -- "${WATERFOX_OVERRIDES}"
  } > "${output}"
  if toolbar=$(managed_toolbar_state "${profile}"); then
    quoted_toolbar=$(jq -Rn --arg toolbar "${toolbar}" '$toolbar')
    printf '\nuser_pref("browser.uiCustomization.state", %s);\n' "${quoted_toolbar}" \
      >> "${output}"
  fi
}

backup_file() {
  local source=$1 label=$2 stamp backup
  [[ -e ${source} && ! -L ${source} ]] || return 0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="${STATE_DIR}/${stamp}-${label}-$$"
  install -d -m 0700 -- "${STATE_DIR}"
  install -m 0600 -- "${source}" "${backup}"
  jsh_detail "Backup: ${backup}"
}

install_preferences() {
  local profile=$1 source=$2 target="${1}/user.js" temporary
  [[ ! -L ${target} ]] || {
    jsh_error "Refusing to replace symlinked Waterfox preferences: ${target}"
    return 1
  }
  if cmp -s -- "${source}" "${target}"; then
    jsh_success "Waterfox preferences current."
    return
  fi
  backup_file "${target}" user.js
  temporary=$(mktemp "${profile}/user.js.jsh.XXXXXX")
  install -m 0600 -- "${source}" "${temporary}"
  mv -f -- "${temporary}" "${target}"
  jsh_success "Waterfox preferences updated."
}

policy_target() {
  local binary resolved
  if [[ -n ${JSH_WATERFOX_POLICY_FILE:-} ]]; then
    printf '%s\n' "${JSH_WATERFOX_POLICY_FILE}"
  elif [[ $(uname -s) == Darwin ]]; then
    printf '/Library/Preferences/net.waterfox.waterfox.plist\n'
  else
    binary=$(waterfox_binary) || return 1
    resolved=$(realpath "${binary}" 2> /dev/null || printf '%s' "${binary}")
    printf '%s/distribution/policies.json\n' "${resolved%/*}"
  fi
}

prepare_policy() {
  local existing managed merged current
  POLICY_CHANGED=0
  POLICY_TARGET=$(policy_target) || {
    jsh_warn "Skipping Waterfox Citrix policy: browser executable not found."
    return
  }
  existing='{}'
  if [[ -e ${POLICY_TARGET} ]]; then
    [[ -r ${POLICY_TARGET} ]] || {
      jsh_error "Waterfox policy is not readable: ${POLICY_TARGET}"
      return 1
    }
    if [[ $(uname -s) == Darwin ]]; then
      existing=$(plutil -convert json -o - -- "${POLICY_TARGET}")
    else
      existing=$(jq -c . "${POLICY_TARGET}")
    fi
  fi
  managed=$(waterfox_config_json | jq -c '{
    AutoLaunchProtocolsFromOrigins: [{
      protocol: .citrix.protocol,
      allowed_origins: .citrix.allowedOrigins
    }],
    SearchEngines: {
      Default: .search.default,
      DefaultPrivate: .search.privateDefault
    }
  }')
  if [[ $(uname -s) == Darwin ]]; then
    merged=$(jq -c --argjson managed "${managed}" \
      '.EnterprisePoliciesEnabled = true | . * $managed' <<< "${existing}")
  else
    merged=$(jq -c --argjson managed "${managed}" '
      .policies = ((.policies // {}) * $managed)
    ' <<< "${existing}")
  fi
  current=$(jq -Sc . <<< "${existing}")
  [[ ${current} != "$(jq -Sc . <<< "${merged}")" ]] || return 0

  POLICY_SOURCE="${TEMP_DIR}/waterfox-policy"
  if [[ $(uname -s) == Darwin ]]; then
    plutil -convert xml1 -o "${POLICY_SOURCE}" -- - <<< "${merged}"
  else
    jq -S . <<< "${merged}" > "${POLICY_SOURCE}"
  fi
  POLICY_CHANGED=1
}

run_root() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    sudo -- "$@"
  fi
}

install_policy() {
  local target_dir
  ((POLICY_CHANGED)) || {
    [[ -z ${POLICY_TARGET} ]] || jsh_success "Waterfox Citrix policy current."
    return
  }
  backup_file "${POLICY_TARGET}" policy
  target_dir=${POLICY_TARGET%/*}
  if [[ $(uname -s) == Darwin && ${POLICY_TARGET} == /Library/Preferences/*.plist ]]; then
    run_root defaults import "${POLICY_TARGET%.plist}" "${POLICY_SOURCE}" > /dev/null
  elif install -d -- "${target_dir}" 2> /dev/null \
    && install -m 0644 -- "${POLICY_SOURCE}" "${POLICY_TARGET}" 2> /dev/null; then
    :
  else
    run_root install -d -- "${target_dir}"
    run_root install -m 0644 -- "${POLICY_SOURCE}" "${POLICY_TARGET}"
  fi
  jsh_success "Waterfox Citrix policy updated."
}

check_update() {
  local current latest
  require_command curl
  require_command jq
  validate_manifest
  current=$(manifest_value version)
  latest=$(curl -fsSL --retry 2 "${BETTERFOX_API_URL}" | jq -er '.tag_name') || {
    jsh_error "Could not determine the latest Betterfox release."
    return 1
  }
  if [[ ${latest} == "${current}" ]]; then
    jsh_success "Betterfox ${current} is the latest release."
  else
    jsh_warn "Betterfox ${latest} is available; reviewed pin is ${current}."
  fi
}

apply_configuration() {
  local binary root profile profile_status composed
  require_command curl
  require_command jq
  require_command unzip
  require_command yq
  validate_manifest
  validate_waterfox_config
  binary=$(waterfox_binary 2> /dev/null || true)
  root=$(waterfox_root)
  if [[ -z ${binary} && ! -d ${root} ]]; then
    jsh_info "Skipping Waterfox configuration: Waterfox is not installed."
    return
  fi
  mkdir -p "${JSH_ROOT}/tmp"
  TEMP_DIR=$(mktemp -d "${JSH_ROOT}/tmp/waterfox.XXXXXX")

  if profile=$(selected_profile "${root}"); then
    :
  else
    profile_status=$?
    ((profile_status == 1)) || return "${profile_status}"
    [[ -n ${binary} ]] || {
      jsh_error "No Waterfox default profile or executable is available."
      return 1
    }
    bootstrap_profile "${root}" "${binary}"
    profile=$(selected_profile "${root}")
  fi
  if profile_is_locked "${profile}"; then
    jsh_error "Close Waterfox before configuring profile ${profile##*/}."
    return 1
  fi

  validate_configured_addons "${profile}"
  prepare_waterfox_review "${profile}"
  show_waterfox_review apply
  if ((WATERFOX_SETTINGS_DIFFER)) && ! confirm_waterfox_review apply; then
    jsh_warn "Keeping the active Waterfox configuration."
    return
  fi

  stage_betterfox
  prepare_policy
  composed="${TEMP_DIR}/user.js"
  compose_preferences "${profile}" "${composed}"
  reconcile_addon_state "${profile}"
  reconcile_addon_permissions "${profile}"
  install_preferences "${profile}" "${composed}"
  install_policy
  configure_associations
  jsh_success "Waterfox configuration complete; changes apply on next launch."
}

main() {
  case ${ACTION} in
    apply) apply_configuration ;;
    backup) backup_waterfox_configuration ;;
    check-update) check_update ;;
    *)
      jsh_error "Usage: ${0##*/} [apply|backup|check-update]"
      return 2
      ;;
  esac
}

main "$@"
