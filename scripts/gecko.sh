#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
root_dir=$(cd -- "${script_dir}/.." && pwd -P)
config_dir="${root_dir}/config/gecko"
state_dir="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/gecko"
tmp_dir="${root_dir}/tmp"
betterfox_api_url="${BETTERFOX_API_URL:-https://api.github.com/repos/yokoffing/Betterfox/releases/latest}"
betterfox_raw_base="${BETTERFOX_RAW_BASE:-https://raw.githubusercontent.com/yokoffing/Betterfox}"

mkdir -p "${tmp_dir}"
composed_user_js=$(mktemp "${tmp_dir}/gecko-user.XXXXXX")
downloaded_betterfox=""
downloaded_xpi=""
bootstrap_ini_tmp=""
trap 'rm -f -- "${composed_user_js}" ${downloaded_betterfox:+"${downloaded_betterfox}"} ${downloaded_xpi:+"${downloaded_xpi}"} ${bootstrap_ini_tmp:+"${bootstrap_ini_tmp}"}' EXIT

betterfox_version() {
  sed -n 's/^[[:space:]]*\*[[:space:]]*version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" | head -1
}

version_is_newer() {
  awk -v candidate="${1#v}" -v current="${2#v}" 'BEGIN {
    candidate_count = split(candidate, candidate_parts, ".")
    current_count = split(current, current_parts, ".")
    count = candidate_count > current_count ? candidate_count : current_count
    for (part = 1; part <= count; part++) {
      if (candidate_parts[part] + 0 > current_parts[part] + 0) exit 0
      if (candidate_parts[part] + 0 < current_parts[part] + 0) exit 1
    }
    exit 1
  }'
}

versions_match() {
  awk -v first="${1#v}" -v second="${2#v}" 'BEGIN {
    first_count = split(first, first_parts, ".")
    second_count = split(second, second_parts, ".")
    count = first_count > second_count ? first_count : second_count
    for (part = 1; part <= count; part++) {
      if (first_parts[part] + 0 != second_parts[part] + 0) exit 1
    }
  }'
}

check_betterfox_update() {
  local source="${config_dir}/user.js" current release latest answer downloaded_version
  [[ -r ${source} ]] || return

  current=$(betterfox_version "${source}")
  if [[ ! ${current} =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
    printf 'Could not determine the installed Betterfox version.\n' >&2
    return
  fi
  if ! release=$(curl -fsSL --retry 2 "${betterfox_api_url}"); then
    printf 'Could not check for Betterfox updates.\n' >&2
    return
  fi
  latest=$(printf '%s' "${release}" | jq -r '.tag_name // empty')
  if [[ ! ${latest} =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
    printf 'Could not determine the latest Betterfox version.\n' >&2
    return
  fi
  if ! version_is_newer "${latest}" "${current}"; then
    printf 'Betterfox %s is current.\n' "${current}"
    return
  fi

  if [[ ! -t 0 || ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'Betterfox %s is available (current %s); rerun interactively to update.\n' "${latest}" "${current}"
    return
  fi

  printf 'Betterfox %s is available (current %s). Download it? [y/N] ' "${latest}" "${current}" >/dev/tty
  IFS= read -r answer </dev/tty || answer=""
  case ${answer} in
    y | Y | yes | YES) ;;
    *)
      printf 'Betterfox update skipped.\n'
      return
      ;;
  esac

  downloaded_betterfox=$(mktemp "${tmp_dir}/betterfox-user.XXXXXX")
  if ! curl -fsSL --retry 2 --output "${downloaded_betterfox}" \
    "${betterfox_raw_base}/${latest}/user.js"; then
    printf 'Could not download Betterfox %s.\n' "${latest}" >&2
    return 1
  fi
  downloaded_version=$(betterfox_version "${downloaded_betterfox}")
  if ! grep -q 'user_pref' "${downloaded_betterfox}" \
    || [[ ! ${downloaded_version} =~ ^v?[0-9]+(\.[0-9]+)*$ ]] \
    || ! versions_match "${latest}" "${downloaded_version}"; then
    printf 'Downloaded Betterfox %s failed validation.\n' "${latest}" >&2
    return 1
  fi

  install -m 0644 -- "${downloaded_betterfox}" "${source}"
  rm -f -- "${downloaded_betterfox}"
  downloaded_betterfox=""
  printf 'Downloaded Betterfox %s.\n' "${latest}"
}

check_betterfox_update

for source in "${config_dir}/user.js" "${config_dir}/overrides.js"; do
  [[ -r ${source} ]] || {
    printf 'Missing Gecko configuration: %s\n' "${source}" >&2
    exit 1
  }
  cat "${source}" >>"${composed_user_js}"
  printf '\n' >>"${composed_user_js}"
done

profile_roots() {
  case "$(uname -s)" in
    Darwin)
      printf 'waterfox\t%s\n' "${HOME}/Library/Application Support/Waterfox"
      printf 'firefox\t%s\n' "${HOME}/Library/Application Support/Firefox"
      ;;
    *)
      printf 'waterfox\t%s\n' "${HOME}/.waterfox"
      printf 'firefox\t%s\n' "${HOME}/.mozilla/firefox"
      ;;
  esac
}

browser_binary() {
  local browser=$1 candidate override
  case ${browser} in
    waterfox) override=${GECKO_WATERFOX_BIN:-} ;;
    firefox) override=${GECKO_FIREFOX_BIN:-} ;;
    *) return 1 ;;
  esac

  if [[ -n ${override} ]]; then
    [[ -x ${override} ]] || return 1
    printf '%s\n' "${override}"
    return
  fi

  if [[ $(uname -s) == Darwin ]]; then
    case ${browser} in
      waterfox)
        for candidate in \
          "/Applications/Waterfox.app/Contents/MacOS/waterfox" \
          "${HOME}/Applications/Waterfox.app/Contents/MacOS/waterfox"; do
          [[ -x ${candidate} ]] || continue
          printf '%s\n' "${candidate}"
          return
        done
        ;;
      firefox)
        for candidate in \
          "/Applications/Firefox.app/Contents/MacOS/firefox" \
          "/Applications/Firefox.app/Contents/MacOS/firefox-bin" \
          "${HOME}/Applications/Firefox.app/Contents/MacOS/firefox" \
          "${HOME}/Applications/Firefox.app/Contents/MacOS/firefox-bin"; do
          [[ -x ${candidate} ]] || continue
          printf '%s\n' "${candidate}"
          return
        done
        ;;
    esac
    return 1
  fi

  candidate=$(command -v "${browser}" 2>/dev/null || true)
  [[ -x ${candidate} ]] || return 1
  printf '%s\n' "${candidate}"
}

bootstrap_profile() {
  local browser=$1 root=$2 ini profile_dir
  ini="${root}/profiles.ini"

  # An existing profiles.ini is authoritative. Do not replace or reinterpret it.
  [[ -e ${ini} || -L ${ini} ]] && return
  # Do not silently hide an existing profile if the registry file was removed.
  [[ -e ${root}/installs.ini || -L ${root}/installs.ini ]] && return
  if [[ -d ${root}/Profiles && ! -d ${root}/Profiles/jsh-default ]]; then
    return
  fi
  browser_binary "${browser}" >/dev/null || return 0
  profile_dir="${root}/Profiles/jsh-default"

  install -d -m 0700 -- "${root}" "${root}/Profiles" "${profile_dir}"
  [[ -e ${ini} || -L ${ini} ]] && return

  bootstrap_ini_tmp=$(mktemp "${root}/profiles.ini.XXXXXX")
  printf '[General]\nStartWithLastProfile=1\nVersion=2\n\n[Profile0]\nName=jsh-default\nIsRelative=1\nPath=Profiles/jsh-default\nDefault=1\n' >"${bootstrap_ini_tmp}"
  install -m 0600 -- "${bootstrap_ini_tmp}" "${ini}"
  rm -f -- "${bootstrap_ini_tmp}"
  bootstrap_ini_tmp=""
  printf 'Bootstrapped %s profile for %s.\n' "jsh-default" "${browser}"
}

bootstrap_profiles() {
  local browser root
  while IFS=$'\t' read -r browser root; do
    bootstrap_profile "${browser}" "${root}"
  done < <(profile_roots)
}

profiles() {
  local browser root ini path relative
  while IFS=$'\t' read -r browser root; do
    ini="${root}/profiles.ini"
    [[ -r ${ini} ]] || continue
    while IFS='|' read -r relative path; do
      [[ -n ${path} ]] || continue
      if [[ ${relative} == 0 ]]; then
        printf '%s\t%s\n' "${browser}" "${path}"
      else
        printf '%s\t%s\n' "${browser}" "${root}/${path}"
      fi
    done < <(awk -F= '
      /^\[/ { if (path != "") print relative "|" path; path=""; relative=1; next }
      $1 == "Path" { path=substr($0, index($0, "=") + 1) }
      $1 == "IsRelative" { relative=$2 }
      END { if (path != "") print relative "|" path }
    ' "${ini}")
  done < <(profile_roots)
}

bootstrap_profiles

install_preferences() {
  local browser=$1 profile=$2 target backup
  target="${profile}/user.js"
  if cmp -s -- "${composed_user_js}" "${target}" 2>/dev/null; then
    preferences_status=current
    return
  fi

  if [[ -e ${target} && ! -L ${target} ]]; then
    backup="${state_dir}/${browser}-${profile##*/}/user.js"
    if [[ ! -e ${backup} ]]; then
      install -d -m 0700 -- "${backup%/*}"
      install -m 0600 -- "${target}" "${backup}"
    fi
  fi

  install -m 0644 -- "${composed_user_js}" "${target}"
  preferences_status=updated
}

install_addons() {
  local browser=$1 profile=$2 id name slug path source target
  local manifest="${config_dir}/addons.json"
  addons_total=0
  addons_present=0
  addons_installed=0
  addons_skipped=0
  [[ -r ${manifest} ]] || return

  mkdir -p "${profile}/extensions"
  while IFS=$'\x1f' read -r id name slug path; do
    ((addons_total += 1))
    target="${profile}/extensions/${id}.xpi"
    if [[ -e ${target} ]]; then
      ((addons_present += 1))
      continue
    fi

    if [[ -n ${path} ]]; then
      source=${path/#\~/${HOME}}
      if [[ ! -r ${source} ]]; then
        printf 'Skipping unavailable add-on %s: %s\n' "${name}" "${source}" >&2
        ((addons_skipped += 1))
        continue
      fi
      install -m 0644 -- "${source}" "${target}"
    else
      downloaded_xpi=$(mktemp "${tmp_dir}/gecko-addon.XXXXXX")
      if ! curl -fsSL --retry 2 --output "${downloaded_xpi}" \
        "https://addons.mozilla.org/firefox/downloads/latest/${slug}/latest.xpi"; then
        printf 'Skipping unavailable add-on %s: %s\n' "${name}" "${slug}" >&2
        ((addons_skipped += 1))
        rm -f -- "${downloaded_xpi}"
        downloaded_xpi=""
        continue
      fi
      install -m 0644 -- "${downloaded_xpi}" "${target}"
      rm -f -- "${downloaded_xpi}"
      downloaded_xpi=""
    fi
    ((addons_present += 1))
    ((addons_installed += 1))
  done < <(jq -r --arg browser "${browser}" '
    .addons[]
    | select(((.exclude // []) | index($browser)) | not)
    | [.id, .name, (.slug // ""), (.path // "")]
    | join("\u001f")
  ' "${manifest}")
}

found=0
changed=0
while IFS=$'\t' read -r browser profile; do
  [[ -d ${profile} ]] || continue
  ((found += 1))
  case ${browser} in
    firefox) browser_name=Firefox ;;
    waterfox) browser_name=Waterfox ;;
  esac
  install_preferences "${browser}" "${profile}"
  install_addons "${browser}" "${profile}"
  if [[ ${preferences_status} == updated ]] || ((addons_installed > 0)); then
    ((changed += 1))
  fi
  printf '%s %s: preferences %s, add-on files %d/%d' "${browser_name}" "${profile##*/}" \
    "${preferences_status}" "${addons_present}" "${addons_total}"
  ((addons_installed == 0)) || printf ' (%d installed)' "${addons_installed}"
  ((addons_skipped == 0)) || printf ' (%d unavailable)' "${addons_skipped}"
  printf '\n'
done < <(profiles)

if ((found == 0)); then
  printf 'No Firefox or Waterfox profiles found.\n'
elif ((changed == 0)); then
  printf 'Gecko configuration current: %d profiles checked.\n' "${found}"
else
  printf 'Gecko configuration updated: %d profiles checked.\n' "${found}"
fi
