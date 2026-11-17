#!/usr/bin/env bash
# Package-manager handlers for scripts/packages.sh: Homebrew, App Store, apt, dnf, Flatpak, uv, and AppImages.
# shellcheck disable=SC2154 # JSH_PLATFORM and JSH_DRY_RUN come from common.sh, which callers source first.
# shellcheck disable=SC2312 # Substitutions here are checked by the caller's `|| return` or fail closed.

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_NO_ENV_HINTS=1 SUDO_ASKPASS=/usr/bin/false GIT_TERMINAL_PROMPT=0
[[ ${JSH_KEEP_APPS:-0} != 1 ]] || export HOMEBREW_NO_UPGRADE_QUIT_CASKS=1

# An upgraded cask app that is still open keeps running the previous version.
jsh::brew_running() {
  local name=$1 app
  while IFS= read -r app; do
    [[ -n ${app} ]] || continue
    # shellcheck disable=SC2009 # pgrep has no fixed-string match; app names can hold regex characters.
    if ps -axo command= | grep -F -- "/${app}/Contents/MacOS/" >/dev/null; then
      jsh::notice "restart ${app%.app} to use the updated version"
    fi
  done < <(brew info --json=v2 --cask "${name}" 2>/dev/null |
    jq -r '.casks[].artifacts[] | .app? // empty | (map(objects | .target) + map(strings))[0] | split("/") | last')
}

# Usage: jsh::brew_caveats NAME... Report caveats from the last task's Homebrew output, one
# notice per package, skipping the shell-completion and Emacs paths most packages print.
jsh::brew_caveats() {
  local caveat
  while IFS= read -r caveat; do
    [[ -z ${caveat} ]] || jsh::notice "${caveat}"
  done < <(jsh::task_text <"${JSH_TASK_LOG:?}" | awk -v names="$*" '
    BEGIN {
      count = split(names, list, " ")
      for (i = 1; i <= count; i++) { sub(/.*\//, "", list[i]); known[list[i]] = 1 }
      single = (count == 1) ? list[1] : ""
    }
    $0 == "==> Caveats" { section = 1; pkg = single; paths = 0; next }
    section && /^(==> |Warning: |Error: )/ {
      title = substr($0, 5)
      if ($0 ~ /^==> / && (title in known)) { pkg = title; text[pkg] = ""; paths = 0 }
      else section = 0
      next
    }
    !section || pkg == "" { next }
    / ha(s|ve) been installed to:$/ { paths = 1; next }
    paths && /^[ \t]/ { next }
    {
      paths = 0
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "") text[pkg] = (text[pkg] == "" ? "" : text[pkg] " ") $0
    }
    END { for (pkg in text) if (text[pkg] != "") print pkg ": " text[pkg] }')
}

jsh::package_listed() {
  local listing=$1 expected=$2 mode=${3:-} item
  while IFS= read -r item; do
    [[ -n ${item} ]] || continue
    if [[ ${item} == "${expected}" ]]; then return 0; fi
    if [[ ${mode} == native && ${item%%:*} == "${expected}" ]]; then return 0; fi
    if [[ ${mode} == uv && ${item%% *} == "${expected}" ]]; then return 0; fi
  done <<<"${listing}"
  return 1
}

jsh::refresh() {
  local manager=$1 directory=${JSH_PACKAGE_STATE:-${JSH_TMP}}/refresh
  shift
  [[ ! -f ${directory}/${manager} ]] || return 0
  jsh::task "$@" || return
  mkdir -p -- "${directory}"
  : >"${directory}/${manager}"
}

# Homebrew refuses to lock or write its trust store in a group-writable directory.
jsh::brew_trust_directory() {
  local directory mode
  if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
    directory=${XDG_CONFIG_HOME}/homebrew
  else
    directory=${HOME}/.homebrew
  fi
  [[ -d ${directory} && ! -L ${directory} && -O ${directory} ]] || return 0
  if [[ ${JSH_PLATFORM} == darwin ]]; then
    mode=$(stat -f '%Lp' "${directory}") || return
  else
    mode=$(stat -c '%a' "${directory}") || return
  fi
  if (( (8#${mode} & 8#022) != 0 )); then
    case ${directory} in -*) directory=./${directory} ;; *) ;; esac
    jsh::run chmod go-w "${directory}" || return
    jsh::changed "${directory} is not group-writable" "${directory} is group-writable"
  fi
}

jsh::brew_update() {
  local kind=$1 flag=$2 listing metadata name dependents item keep count status=0
  local directory=${JSH_PACKAGE_STATE:-${JSH_TMP}}/brew
  local -a outdated=() retired=() needed=()
  [[ ! -f ${directory}/${kind} ]] || return 0
  jsh::refresh brew "Checking Homebrew updates" brew update --quiet || return
  jsh::need jq || return
  jsh::status "Inspecting installed Homebrew ${kind}"
  metadata=$(brew info --json=v2 --installed) || return
  if [[ ${kind} == casks ]]; then
    listing=$(brew outdated --cask --greedy-auto-updates --quiet) || return
    metadata=$(jq -r ".casks[] | select(.deprecated or .disabled) | .token" <<<"${metadata}") || return
  else
    listing=$(brew outdated --formula --quiet) || return
    metadata=$(jq -r ".formulae[] | select(.deprecated or .disabled) | .full_name" <<<"${metadata}") || return
  fi
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    retired+=("${name}")
    if [[ ${kind} == formulae ]]; then
      dependents=$(brew uses --installed "${name}") || return
      if [[ -n ${dependents} ]]; then
        needed=()
        while IFS= read -r item; do
          [[ -z ${item} ]] || needed+=("${item##*/}")
        done <<<"${dependents}"
        keep=
        count=0
        for item in "${needed[@]}"; do
          ((count < 3)) || break
          if [[ -n ${keep} ]]; then keep+=", "; fi
          keep+=${item}
          ((count += 1))
        done
        if ((${#needed[@]} > 3)); then keep+=", +$((${#needed[@]} - 3))"; fi
        jsh::info "Keeping ${name}: needed by ${keep}"
        continue
      fi
    fi
    if jsh::task "Removing deprecated Homebrew package: ${name}" brew uninstall "${flag}" "${name}"; then
      jsh::removed "${name} removed" "${name} is deprecated"
    else
      status=1
    fi
  done <<<"${metadata}"
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    [[ ${kind}:${name} != casks:sublime-text ]] || continue
    local skip=0 retired_name
    for retired_name in "${retired[@]}"; do
      [[ ${retired_name} != "${name}" && ${retired_name##*/} != "${name}" ]] || skip=1
    done
    ((skip)) || outdated+=("${name}")
  done <<<"${listing}"
  for name in "${outdated[@]}"; do
    if jsh::task "Homebrew upgrade: ${name}" brew upgrade --no-ask "${flag}" "${name}"; then
      jsh::changed "${name} upgraded" "${name} is outdated"
      if [[ ${JSH_DRY_RUN} != 1 ]]; then
        jsh::brew_caveats "${name}"
        [[ ${kind} != casks || ${JSH_KEEP_APPS:-0} != 1 ]] || jsh::brew_running "${name}"
      fi
    else
      status=1
    fi
  done
  if ((status == 0)); then
    mkdir -p -- "${directory}"
    : >"${directory}/${kind}"
  fi
  return "${status}"
}

jsh::brew() {
  local kind=$1 name listing flag=--formula status=0 object directory
  local -a missing=()
  shift
  [[ ${JSH_UPDATE:-0} != 1 || ${JSH_BREW_DEFER:-0} != 1 || ${kind} == taps ]] || return 0
  if [[ ${JSH_UPDATE:-0} == 1 && ${kind} != taps ]]; then
    directory=${JSH_PACKAGE_STATE:-${JSH_TMP}}/brew
    [[ ! -f ${directory}/${kind} ]] || return 0
  fi
  case ${kind} in
    formulae) object="Homebrew formulae" ;;
    casks) object="Homebrew casks" ;;
    taps) object="Homebrew taps" ;;
    *) object="Homebrew ${kind}" ;;
  esac
  if [[ ${kind} == casks && ${JSH_PLATFORM} != darwin ]]; then
    jsh::skipped "Homebrew casks: macOS only"
    return 0
  fi
  jsh::step check "${object}"
  [[ ${kind} != casks ]] || flag=--cask
  if ! command -v brew >/dev/null 2>&1; then
    [[ ${JSH_PLATFORM} != darwin ]] || {
      jsh::fail "Install Homebrew first: https://brew.sh"
      return 1
    }
    jsh::notice "Homebrew is unavailable; shared Homebrew tools were skipped"
    return 0
  fi
  jsh::brew_trust_directory || return
  if [[ ${kind} == taps ]]; then
    listing=$(brew tap) || return
    for name in "$@"; do
      if jsh::package_listed "${listing}" "${name}"; then
        jsh::ok "${name} is tapped"
      else
        jsh::task "Tapping ${name}" brew tap "${name}" || return
        jsh::added "${name} tapped" "${name} is not tapped"
      fi
    done
    return 0
  fi
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    jsh::brew_update "${kind}" "${flag}"
    return
  fi
  listing=$(brew list "${flag}" -1) || return
  for name in "$@"; do
    if jsh::package_listed "${listing}" "${name##*/}" ||
      [[ ${kind}:${name} == casks:sublime-text && -d "/Applications/Sublime Text.app" ]]; then
      jsh::ok "${name} is installed"
    elif [[ ${kind} == casks ]] && brew list --cask --versions "${name}" >/dev/null 2>&1; then
      jsh::ok "${name} is installed"
    elif [[ ${kind} != casks ]] && brew list --versions "${name}" >/dev/null 2>&1; then
      jsh::ok "${name} is installed"
    else
      missing+=("${name}")
    fi
  done
  ((${#missing[@]})) || return 0
  if ! jsh::task --retryable "Homebrew install: ${missing[*]}" brew install "${flag}" "${missing[@]}"; then
    for name in "${missing[@]}"; do
      if jsh::task "Homebrew install: ${name}" brew install "${flag}" "${name}"; then
        jsh::added "${name} installed" "${name} is not installed"
        [[ ${JSH_DRY_RUN} == 1 ]] || jsh::brew_caveats "${name}"
      else
        status=1
      fi
    done
    return "${status}"
  fi
  for name in "${missing[@]}"; do
    jsh::added "${name} installed" "${name} is not installed"
  done
  [[ ${JSH_DRY_RUN} == 1 ]] || jsh::brew_caveats "${missing[@]}"
}

# App Store apps such as Xcode; mas drops root for the download and needs a signed-in Apple Account.
jsh::mas() {
  local listing id name status=0
  [[ ${JSH_UPDATE:-0} == 1 && ${JSH_PLATFORM} == darwin ]] || return 0
  jsh::step check "App Store apps"
  if ! command -v mas >/dev/null 2>&1; then
    jsh::skipped "App Store apps: mas is unavailable"
    return 0
  fi
  jsh::need jq || return
  listing=$(mas outdated --json | jq -r "[.adamID, .name] | @tsv") || return
  [[ -n ${listing} ]] || return 0
  if [[ ${JSH_DRY_RUN} != 1 ]] && ! jsh::admin; then
    jsh::notice "App Store updates need sudo; run sudo -v first, then rerun"
    return 0
  fi
  while IFS=$'\t' read -r id name; do
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    if jsh::task "App Store update: ${name}" jsh::root mas update "${id}"; then
      jsh::changed "${name} upgraded" "${name} is outdated"
    else
      status=1
    fi
  done <<<"${listing}"
  return "${status}"
}

jsh::native() {
  local manager=$1 name listing="" installed="" installed_rows="" item state root=1 status=0 is_outdated
  local -a missing=() upgrades=()
  shift
  jsh::step check "${manager} packages"
  if [[ ${manager} == apt ]]; then
    installed_rows=$(dpkg-query -W '-f=${binary:Package}\t${db:Status-Status}\n' 2>/dev/null || true)
    while IFS=$'\t' read -r item state; do
      [[ ${state} != installed ]] || installed+=${installed:+$'\n'}${item}
    done <<<"${installed_rows}"
  else
    installed=$(rpm -qa --qf "%{NAME}\n") || return
  fi
  if [[ ${JSH_DRY_RUN} != 1 ]] && ! jsh::admin; then
    if [[ ${JSH_UPDATE:-0} == 1 ]]; then
      for name in "$@"; do
        if jsh::package_listed "${installed}" "${name}" native; then
          jsh::ok "${name} is installed"
        else
          jsh::drift "${name} is not installed"
        fi
      done
      jsh::notice "${manager} updates need sudo; run sudo -v first, then rerun"
      return 0
    fi
    root=0
  fi
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    if [[ ${manager} == apt ]]; then
      jsh::refresh apt "Checking apt updates" jsh::root env DEBIAN_FRONTEND=noninteractive apt-get update || return
      listing=$(apt list --upgradable 2>/dev/null) || return
    else
      jsh::refresh dnf "Refreshing dnf" jsh::root dnf makecache -y || return
      listing=$(dnf --cacheonly check-update -q) || status=$?
      [[ ${status} == 0 || ${status} == 100 ]] || return "${status}"
      status=0
    fi
  fi
  for name in "$@"; do
    if ! jsh::package_listed "${installed}" "${name}" native; then
      if [[ ${JSH_UPDATE:-0} == 1 ]]; then
        jsh::drift "${name} is not installed"
      else
        missing+=("${name}")
      fi
      continue
    fi
    if [[ ${JSH_UPDATE:-0} != 1 ]]; then
      jsh::ok "${name} is installed"
      continue
    fi
    is_outdated=0
    while IFS= read -r item; do
      if [[ ${manager} == apt ]]; then
        item=${item%%/*}
      else
        item=${item%%[[:space:]]*}
        item=${item%.*}
      fi
      [[ ${item} != "${name}" ]] || is_outdated=1
    done <<<"${listing}"
    if ((is_outdated)); then upgrades+=("${name}"); else jsh::ok "${name} is installed"; fi
  done
  if ((${#missing[@]})); then
    if ((root == 0)); then
      for name in "${missing[@]}"; do jsh::drift "${name} is not installed"; done
      jsh::notice "Install with sudo: ${manager} install ${missing[*]}"
      return 1
    fi
    if [[ ${manager} == apt ]]; then
      jsh::refresh apt "Refreshing apt" jsh::root env DEBIAN_FRONTEND=noninteractive apt-get update || return
      jsh::task "Installing apt packages: ${missing[*]}" jsh::root env DEBIAN_FRONTEND=noninteractive apt-get install --no-upgrade -y -- "${missing[@]}" || return
    else
      jsh::task "Running dnf install: ${missing[*]}" jsh::root dnf install -y -- "${missing[@]}" || return
    fi
    for name in "${missing[@]}"; do
      jsh::added "${name} installed" "${name} is not installed"
    done
  fi
  ((${#upgrades[@]})) || return 0
  if [[ ${manager} == apt ]]; then
    jsh::task "Updating apt packages: ${upgrades[*]}" jsh::root env DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y -- "${upgrades[@]}" || return
  else
    jsh::task "Running dnf upgrade: ${upgrades[*]}" jsh::root dnf upgrade -y -- "${upgrades[@]}" || return
  fi
  for name in "${upgrades[@]}"; do
    jsh::changed "${name} upgraded" "${name} is outdated"
  done
}

jsh::flatpak() {
  local app listing updates
  jsh::step check "Flatpak apps"
  if ! command -v flatpak >/dev/null 2>&1; then
    jsh::notice "flatpak is missing; apps were skipped"
    return 0
  fi
  listing=$(flatpak list --app --columns=application) || return
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    updates=$(flatpak remote-ls --updates --columns=application) || return
  fi
  for app in "$@"; do
    if jsh::package_listed "${listing}" "${app}"; then
      if [[ ${JSH_UPDATE:-0} == 1 ]] && jsh::package_listed "${updates}" "${app}"; then
        jsh::task "Updating ${app}" flatpak update --noninteractive -y "${app}" || return
        jsh::changed "${app} upgraded" "${app} is outdated"
      else
        jsh::ok "${app} is installed"
      fi
    elif [[ ${JSH_UPDATE:-0} == 1 ]]; then
      jsh::drift "${app} is not installed"
    else
      jsh::run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || return
      jsh::task "Installing ${app}" flatpak install --user --noninteractive -y flathub "${app}" || return
      jsh::added "${app} installed" "${app} is not installed"
    fi
  done
}

jsh::uv() {
  local command=$1 package=$2 listing after help outdated
  jsh::step check "uv tools"
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    if ! command -v "${command}" >/dev/null 2>&1; then
      jsh::drift "${command} is not installed"
      return 0
    fi
    if ! command -v uv >/dev/null 2>&1; then
      jsh::ok "${command} is installed"
      return 0
    fi
    listing=$(uv tool list) || return
    if ! jsh::package_listed "${listing}" "${package}" uv; then
      jsh::ok "${command} is installed"
      return 0
    fi
    if [[ ${JSH_DRY_RUN} == 1 ]]; then
      help=$(uv tool list --help 2>/dev/null || true)
      if [[ ${help} == *--outdated* ]]; then
        outdated=$(uv tool list --outdated 2>/dev/null || true)
        if jsh::package_listed "${outdated}" "${package}" uv; then
          jsh::changed "${command} upgraded" "${command} is outdated"
        else
          jsh::ok "${command} is installed"
        fi
      else
        jsh::ok "${command} is installed"
      fi
      return 0
    fi
    jsh::task "Updating ${command}" uv tool upgrade "${package}" || return
    after=$(uv tool list) || return
    if [[ ${after} != "${listing}" ]]; then
      jsh::changed "${command} upgraded" "${command} is outdated"
    else
      jsh::ok "${command} is installed"
    fi
  elif command -v "${command}" >/dev/null 2>&1; then
    jsh::ok "${command} is installed"
  else
    if command -v uv >/dev/null 2>&1; then
      jsh::task "Installing ${command}" uv tool install "${package}" || return
    else
      jsh::task "Installing ${command}" python3 -m pip install --user "${package}" || return
    fi
    jsh::added "${command} installed" "${command} is not installed"
  fi
}

jsh::appimage() {
  local name=$1 release=$2 arm=$3 amd=${4:-x86_64} arch item digest url scratch destination state current
  jsh::status "Checking ${name} AppImage"
  destination=${HOME}/.local/bin/${name}
  state=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/appimage/${name}.json
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    [[ -f ${state} ]] || return 0
    [[ -f ${destination} && ! -L ${destination} ]] || {
      jsh::fail "AppImage is no longer managed: ${destination}"
      return 1
    }
    current=$(jq -er .digest "${state}") || return
    [[ $(jsh::sha256 "${destination}") == "${current}" ]] || {
      jsh::fail "AppImage was modified: ${destination}"
      return 1
    }
  else
    command -v "${name}" >/dev/null 2>&1 && return 0
    [[ ! -e ${destination} && ! -L ${destination} ]] || {
      jsh::fail "refusing to replace ${destination}"
      return 1
    }
  fi
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::info "would download verified ${name} AppImage"
    return
  fi
  jsh::need jq || return
  arch=$(uname -m)
  case ${arch} in arm64 | aarch64) arch=${arm} ;; x86_64) arch=${amd} ;; *)
    jsh::fail "unsupported architecture: ${arch}"
    return 1
    ;;
  esac
  scratch=$(jsh::temp) || return
  jsh::download "${release}" "${scratch}/release.json" || return
  item=$(jq -er --arg suffix "-${arch}.appimage" '[.assets[] | select(.name | ascii_downcase | endswith($suffix))] | if length == 1 then .[0] else error("expected one AppImage asset") end' "${scratch}/release.json") || return
  digest=$(printf '%s' "${item}" | jq -er '.digest | sub("^sha256:"; "")') || return
  [[ ${digest} =~ ^[a-f0-9]{64}$ ]] || {
    jsh::fail 'release has no SHA-256 digest'
    return 1
  }
  [[ ${JSH_UPDATE:-0} != 1 || ${digest} != "${current}" ]] || return 0
  url=$(printf '%s' "${item}" | jq -er .browser_download_url) || return
  jsh::download "${url}" "${scratch}/appimage" || return
  [[ $(jsh::sha256 "${scratch}/appimage") == "${digest}" ]] || {
    jsh::fail 'AppImage checksum mismatch'
    return 1
  }
  jsh::file "${scratch}/appimage" "${destination}" 755 || return
  printf '%s' "${item}" | jq '{asset: .name, digest: (.digest | sub("^sha256:"; ""))}' >"${scratch}/state.json" || return
  jsh::file "${scratch}/state.json" "${state}" || return
  local executable=${destination//\\/\\\\}
  executable=${executable//\"/\\\"}
  executable=${executable//\$/\\\$}
  executable=${executable//\`/\\\`}
  executable=${executable//%/%%}
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec="%s" %%U\nTerminal=false\n' "${name}" "${executable}" >"${scratch}/app.desktop"
  jsh::file "${scratch}/app.desktop" "${XDG_DATA_HOME:-${HOME}/.local/share}/applications/jsh-${name}.desktop" 644
}
