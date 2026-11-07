#!/usr/bin/env bash
# Install or update the declared packages for the named groups.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALL_UPGRADE=1
export HOMEBREW_NO_ENV_HINTS=1 SUDO_ASKPASS=/usr/bin/false GIT_TERMINAL_PROMPT=0
[[ ${JSH_KEEP_APPS:-0} != 1 ]] || export HOMEBREW_NO_UPGRADE_QUIT_CASKS=1

# An upgraded cask app that is still open keeps running the previous version.
jsh::brew_running() {
  local name=$1 app
  while IFS= read -r app; do
    [[ -n ${app} ]] || continue
    if ps -axo command= | grep -F -- "/${app}/Contents/MacOS/" >/dev/null; then
      jsh::notice "restart ${app%.app} to use the updated version"
    fi
  done < <(brew info --json=v2 --cask "${name}" 2>/dev/null |
    jq -r '.casks[].artifacts[] | .app? // empty | (map(objects | .target) + map(strings))[0] | split("/") | last')
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
    case ${directory} in -*) directory=./${directory} ;; esac
    jsh::run chmod go-w "${directory}" || return
    jsh::changed "${directory} permissions"
  fi
}

jsh::brew_update() {
  local kind=$1 flag=$2 listing metadata name dependents status=0 directory=${JSH_PACKAGE_STATE:-${JSH_TMP}}/brew
  local -a outdated=() retired=()
  [[ ! -f ${directory}/${kind} ]] || return 0
  jsh::refresh brew 'Checking Homebrew updates' brew update --quiet || return
  jsh::need jq || return
  jsh::activity "Inspecting installed Homebrew ${kind}"
  metadata=$(brew info --json=v2 --installed) || return
  if [[ ${kind} == casks ]]; then
    listing=$(brew outdated --cask --greedy-auto-updates --quiet) || return
    metadata=$(jq -r '.casks[] | select(.deprecated or .disabled) | .token' <<<"${metadata}") || return
  else
    listing=$(brew outdated --formula --quiet) || return
    metadata=$(jq -r '.formulae[] | select(.deprecated or .disabled) | .full_name' <<<"${metadata}") || return
  fi
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    retired+=("${name}")
    if [[ ${kind} == formulae ]]; then
      dependents=$(brew uses --installed "${name}") || return
      if [[ -n ${dependents} ]]; then
        jsh::detail "Keeping ${name}; installed packages depend on it: ${dependents//$'\n'/, }"
        continue
      fi
    fi
    if jsh::task "Removing deprecated Homebrew package: ${name}" brew uninstall "${flag}" "${name}"; then
      jsh::emit removed "${name}" package
    else
      status=1
    fi
  done <<<"${metadata}"
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    [[ ${kind}:${name} != casks:sublime-text ]] || continue
    local skip=0 item
    for item in "${retired[@]}"; do
      [[ ${item} != "${name}" && ${item##*/} != "${name}" ]] || skip=1
    done
    ((skip)) || outdated+=("${name}")
  done <<<"${listing}"
  for name in "${outdated[@]}"; do
    if jsh::task "Homebrew upgrade: ${name}" brew upgrade --no-ask "${flag}" "${name}"; then
      jsh::emit changed "${name}" package
      [[ ${kind} != casks || ${JSH_KEEP_APPS:-0} != 1 ]] || jsh::brew_running "${name}"
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
  local kind=$1 name listing flag=--formula status=0
  local -a missing=()
  shift
  [[ ${kind} != casks ]] || {
    [[ ${JSH_PLATFORM} == darwin ]] || return 0
    flag=--cask
  }
  [[ ${JSH_UPDATE:-0} != 1 || ${JSH_BREW_DEFER:-0} != 1 || ${kind} == taps ]] || return 0
  if ! command -v brew >/dev/null 2>&1; then
    [[ ${JSH_PLATFORM} != darwin ]] || {
      jsh::log_error 'Install Homebrew first: https://brew.sh'
      return 1
    }
    jsh::notice 'Homebrew is unavailable; shared Homebrew tools were skipped'
    return 0
  fi
  jsh::brew_trust_directory || return
  if [[ ${kind} == taps ]]; then
    jsh::activity 'Checking Homebrew taps'
    listing=$(brew tap) || return
    for name in "$@"; do
      jsh::activity "Checking Homebrew tap ${name}"
      if ! printf '%s\n' "${listing}" | grep -Fxq -- "${name}"; then
        jsh::task "Tapping ${name}" brew tap "${name}" || return
        jsh::emit added "${name}" package
      fi
    done
    return 0
  fi
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    jsh::brew_update "${kind}" "${flag}"
    return
  fi
  jsh::activity "Checking Homebrew ${kind}"
  listing=$(brew list "${flag}" -1) || return
  for name in "$@"; do
    jsh::activity "Checking Homebrew package ${name}"
    if ! printf '%s\n' "${listing}" | grep -Fxq -- "${name##*/}"; then
      [[ ${kind}:${name} != casks:sublime-text || ! -d '/Applications/Sublime Text.app' ]] || continue
      # Resolve aliases such as python -> python@3.14 before installing.
      if ! brew list "${flag}" --versions "${name}" >/dev/null 2>&1; then missing+=("${name}"); fi
    fi
  done
  ((${#missing[@]})) || return 0
  if ! jsh::task "Homebrew install: ${missing[*]}" brew install "${flag}" "${missing[@]}"; then
    for name in "${missing[@]}"; do
      if jsh::task "Homebrew install: ${name}" brew install "${flag}" "${name}"; then
        jsh::emit added "${name}" package
      else
        status=1
      fi
    done
    return "${status}"
  fi
  for name in "${missing[@]}"; do jsh::emit added "${name}" package; done
}

# App Store apps such as Xcode; mas drops root for the download and needs a signed-in Apple Account.
jsh::mas() {
  local listing id name status=0
  [[ ${JSH_UPDATE:-0} == 1 && ${JSH_PLATFORM} == darwin ]] || return 0
  command -v mas >/dev/null 2>&1 || return 0
  jsh::need jq || return
  jsh::activity 'Checking App Store updates'
  listing=$(mas outdated --json | jq -r '[.adamID, .name] | @tsv') || return
  [[ -n ${listing} ]] || return 0
  if [[ ${JSH_DRY_RUN} != 1 ]] && ! jsh::admin; then
    jsh::notice 'App Store updates need sudo; run sudo -v first, then rerun'
    return 0
  fi
  while IFS=$'\t' read -r id name; do
    [[ ${id} =~ ^[0-9]+$ ]] || continue
    if jsh::task "App Store update: ${name}" jsh::root mas update "${id}"; then
      jsh::emit changed "${name}" package
    else
      status=1
    fi
  done <<<"${listing}"
  return "${status}"
}

jsh::native() {
  local manager=$1 name listing='' status=0 root=1
  local -a missing=()
  shift
  if [[ ${JSH_DRY_RUN} != 1 ]] && ! jsh::admin; then
    if [[ ${JSH_UPDATE:-0} == 1 ]]; then
      jsh::notice "${manager} updates need sudo; run sudo -v first, then rerun"
      return 0
    fi
    root=0
  fi
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    if [[ ${manager} == apt ]]; then
      jsh::refresh apt 'Checking apt updates' jsh::root env DEBIAN_FRONTEND=noninteractive apt-get update || return
      jsh::activity 'Checking apt upgrades'
      listing=$(apt list --upgradable 2>/dev/null) || return
    else
      jsh::refresh dnf 'Refreshing dnf' jsh::root dnf makecache -y || return
      jsh::activity 'Checking dnf upgrades'
      listing=$(dnf --cacheonly check-update -q) || status=$?
      [[ ${status} == 0 || ${status} == 100 ]] || return "${status}"
    fi
  fi
  for name in "$@"; do
    jsh::activity "Checking ${manager} package ${name}"
    if [[ ${JSH_UPDATE:-0} == 1 ]]; then
      if [[ ${manager} == apt ]]; then
        [[ $'\n'${listing} == *$'\n'"${name}/"* ]] && missing+=("${name}")
      elif printf '%s\n' "${listing}" | awk -v name="${name}" '{package=$1; sub(/\.[^.]+$/, "", package); if (package == name) found=1} END {exit !found}'; then
        missing+=("${name}")
      fi
    elif [[ ${manager} == apt ]]; then
      [[ $(dpkg-query -W '-f=${db:Status-Status}' "${name}" 2>/dev/null || true) == installed ]] || missing+=("${name}")
    elif ! rpm -q "${name}" >/dev/null 2>&1; then
      missing+=("${name}")
    fi
  done
  ((${#missing[@]})) || return 0
  if ((root == 0)); then
    jsh::notice "Install with sudo: ${manager} install ${missing[*]}"
    return 1
  fi
  if [[ ${manager} == apt ]]; then
    local option=--no-upgrade
    [[ ${JSH_UPDATE:-0} != 1 ]] || option=--only-upgrade
    if [[ ${JSH_UPDATE:-0} != 1 ]]; then jsh::refresh apt 'Refreshing apt' jsh::root env DEBIAN_FRONTEND=noninteractive apt-get update || return; fi
    local action=Installing
    [[ ${JSH_UPDATE:-0} != 1 ]] || action=Updating
    jsh::task "${action} apt packages: ${missing[*]}" jsh::root env DEBIAN_FRONTEND=noninteractive apt-get install "${option}" -y -- "${missing[@]}" || return
  else
    local operation=install
    [[ ${JSH_UPDATE:-0} != 1 ]] || operation=upgrade
    jsh::task "Running dnf ${operation}: ${missing[*]}" jsh::root dnf "${operation}" -y -- "${missing[@]}" || return
  fi
  for name in "${missing[@]}"; do
    if [[ ${JSH_UPDATE:-0} == 1 ]]; then jsh::emit changed "${name}" package; else jsh::emit added "${name}" package; fi
  done
}

jsh::flatpak() {
  local app
  if ! command -v flatpak >/dev/null 2>&1; then
    jsh::notice 'flatpak is missing; apps were skipped'
    return 0
  fi
  for app in "$@"; do
    jsh::activity "Checking Flatpak ${app}"
    if flatpak info --user "${app}" >/dev/null 2>&1 || flatpak info --system "${app}" >/dev/null 2>&1; then
      [[ ${JSH_UPDATE:-0} == 1 ]] || continue
      jsh::task "Updating ${app}" flatpak update --noninteractive -y "${app}" || return
    else
      [[ ${JSH_UPDATE:-0} != 1 ]] || continue
      jsh::run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || return
      jsh::task "Installing ${app}" flatpak install --user --noninteractive -y flathub "${app}" || return
      jsh::emit added "${app}" package
    fi
  done
}
jsh::uv() {
  local command=$1 package=$2
  jsh::activity "Checking Python tool ${command}"
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    command -v uv >/dev/null 2>&1 || return 0
    uv tool list | grep -Fq "${package} v" || return 0
    jsh::task "Updating ${command}" uv tool upgrade "${package}"
  elif ! command -v "${command}" >/dev/null 2>&1; then
    if command -v uv >/dev/null 2>&1; then
      jsh::task "Installing ${command}" uv tool install "${package}" || return
    else
      jsh::task "Installing ${command}" python3 -m pip install --user "${package}" || return
    fi
    jsh::emit added "${command}" package
  fi
}
jsh::sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
jsh::appimage() {
  local name=$1 release=$2 arm=$3 amd=${4:-x86_64} arch item digest url scratch destination state current
  jsh::activity "Checking ${name} AppImage"
  destination=${HOME}/.local/bin/${name}
  state=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/appimage/${name}.json
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    [[ -f ${state} ]] || return 0
    [[ -f ${destination} && ! -L ${destination} ]] || {
      jsh::log_error "AppImage is no longer managed: ${destination}"
      return 1
    }
    current=$(jq -er .digest "${state}") || return
    [[ $(jsh::sha256 "${destination}") == "${current}" ]] || {
      jsh::log_error "AppImage was modified: ${destination}"
      return 1
    }
  else
    command -v "${name}" >/dev/null 2>&1 && return 0
    [[ ! -e ${destination} && ! -L ${destination} ]] || {
      jsh::log_error "refusing to replace ${destination}"
      return 1
    }
  fi
  if [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::notice "would download verified ${name} AppImage"
    return
  fi
  jsh::need jq || return
  arch=$(uname -m)
  case ${arch} in arm64 | aarch64) arch=${arm} ;; x86_64) arch=${amd} ;; *)
    jsh::log_error "unsupported architecture: ${arch}"
    return 1
    ;;
  esac
  scratch=$(jsh::temp) || return
  jsh::download "${release}" "${scratch}/release.json" || return
  item=$(jq -er --arg suffix "-${arch}.appimage" '[.assets[] | select(.name | ascii_downcase | endswith($suffix))] | if length == 1 then .[0] else error("expected one AppImage asset") end' "${scratch}/release.json") || return
  digest=$(printf '%s' "${item}" | jq -er '.digest | sub("^sha256:"; "")') || return
  [[ ${digest} =~ ^[a-f0-9]{64}$ ]] || {
    jsh::log_error 'release has no SHA-256 digest'
    return 1
  }
  [[ ${JSH_UPDATE:-0} != 1 || ${digest} != "${current}" ]] || return 0
  url=$(printf '%s' "${item}" | jq -er .browser_download_url) || return
  jsh::download "${url}" "${scratch}/appimage" || return
  [[ $(jsh::sha256 "${scratch}/appimage") == "${digest}" ]] || {
    jsh::log_error 'AppImage checksum mismatch'
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

# Package choices are ordinary shell, grouped by purpose and platform.
install_group() {
  case $1 in
    maintenance)
      if command -v brew >/dev/null 2>&1 || [[ ${JSH_PLATFORM} == darwin ]]; then
        jsh::brew formulae || return
        jsh::brew casks || return
        jsh::mas || return
      fi
      ;;
    ai)
      jsh::brew formulae opencode || return
      jsh::brew casks antigravity-cli chatgpt codex copilot-cli || return
      jsh::uv graphify graphifyy || return
      ;;
    apps)
      if [[ (${JSH_PLATFORM} == darwin) ]]; then
        jsh::brew formulae spicetify-cli || return
        jsh::brew casks android-platform-tools citrix-workspace foobar2000 signal spotify tailscale-app todoist-app vorssaint zoom || return
      fi
      if [[ (${JSH_PLATFORM} == darwin) && (${JSH_HOST} == archon) ]]; then
        jsh::brew casks bambu-studio elgato-stream-deck macfuse mounty || return
      fi
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak com.spotify.Client com.todoist.Todoist || return
      fi
      ;;
    audio)
      :
      ;;
    containers)
      jsh::brew formulae colima docker docker-buildx docker-compose lima || return
      if [[ ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt podman || return
      fi
      if [[ ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf podman || return
      fi
      ;;
    core)
      if [[ (${JSH_PLATFORM} == darwin) ]]; then
        jsh::brew formulae bash curl git python zsh jq || return
      fi
      if [[ ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt bash ca-certificates curl git python3 zsh procps jq || return
      fi
      if [[ ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf bash ca-certificates curl git python3 zsh procps-ng jq || return
      fi
      ;;
    desktop)
      if [[ (${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce) && (${JSH_DESKTOP} == xfce) && ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal || return
      fi
      if [[ (${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce) && (${JSH_DESKTOP} == xfce) && ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal || return
      fi
      if [[ (${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce) && (${JSH_PLATFORM} == debian) && (${JSH_DESKTOP} == xfce) && (${JSH_HOST} == colossus) && ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt build-essential pkg-config patch gettext meson libgtk-3-dev libpulse-dev libxfce4panel-2.0-dev libxfce4ui-2-dev libxfconf-0-dev libkeybinder-3.0-dev libnotify-dev libwnck-3-dev libexo-2-dev libxfce4windowing-0-dev || return
      fi
      ;;
    dev)
      jsh::brew formulae actionlint autopep8 bats-core black commitizen commitlint eslint gitleaks hadolint markdownlint-cli pre-commit prettier pylint shellcheck shfmt yamllint || return
      jsh::uv check-yaml pre-commit-hooks || return
      ;;
    display)
      if [[ (${JSH_DESKTOP} == darwin || ${JSH_DESKTOP} == gnome || ${JSH_DESKTOP} == xfce) && (${JSH_PLATFORM} == darwin) ]]; then
        jsh::brew formulae displayplacer || return
      fi
      ;;
    dock)
      :
      ;;
    fonts)
      jsh::brew casks font-jetbrains-mono-nerd-font || return
      ;;
    ghostty)
      jsh::brew casks ghostty || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::appimage ghostty https://api.github.com/repos/pkgforge-dev/ghostty-appimage/releases/latest aarch64 || return
      fi
      ;;
    git)
      :
      ;;
    helium)
      jsh::brew casks helium-browser || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::appimage helium https://api.github.com/repos/imputnet/helium-linux/releases/latest arm64 || return
      fi
      ;;
    keybindings)
      :
      ;;
    kube)
      jsh::brew formulae helm helmfile k9s kubernetes-cli || return
      ;;
    linux)
      :
      ;;
    macos)
      :
      ;;
    password)
      jsh::brew casks bitwarden || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak com.bitwarden.desktop || return
      fi
      ;;
    services)
      :
      ;;
    shell)
      :
      ;;
    skills)
      :
      ;;
    sublime)
      jsh::brew casks sublime-text || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak com.sublimetext.three || return
      fi
      ;;
    tools)
      if [[ (${JSH_PLATFORM} == darwin) ]]; then
        jsh::brew taps gromgit/fuse || return
        jsh::brew formulae bash-completion duti gromgit/fuse/ntfs-3g-mac imagemagick mas || return
      fi
      jsh::brew taps xguot/difi || return
      jsh::brew formulae bash gum jq unzip zip zsh age ansible atuin bat btop bun coreutils curl diffutils direnv eza fd ffmpeg fnm fzf gawk gettext gh git git-lfs gnu-sed gnupg go go-task grc grep hugo just kew lazygit leaf-markdown-viewer libtiff libxcrypt make mpv ncdu neovim netcat nmap node parallel pnpm poetry readline ripgrep rsync rtk sops speedtest-go sshpass stow summarize syncthing tmux tree uv watch xguot/difi/difi xorriso xz zoxide || return
      if [[ ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt jq make ripgrep rsync tmux unzip zip age ansible bat btop direnv fzf gh git-lfs golang-go grc hugo mpv ncdu netcat-openbsd nmap parallel python3-poetry sshpass stow syncthing yamllint zoxide build-essential bzip2 cargo cifs-utils desktop-file-utils dconf-cli dkms earlyoom eza fd-find flatpak gnome-keyring gnupg libarchive-tools libnotify-bin net-tools nfs-common nodejs ntfs-3g nvme-cli openssh-client openssh-server pipewire-pulse python3-yaml sqlite3 tar wireplumber xbindkeys xclip xdg-utils x11-xserver-utils xz-utils yq systemd-zram-generator || return
      fi
      if [[ ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf jq make rsync tmux unzip zip bzip2 cargo cifs-utils desktop-file-utils dconf dkms earlyoom eza fd-find flatpak gcc gcc-c++ gnome-keyring gnupg2 libarchive libnotify mpv net-tools nfs-utils nodejs ntfs-3g nvme-cli openssh-clients openssh-server pipewire-pulseaudio python3-pyyaml readline ripgrep sqlite syncthing tar wireplumber xbindkeys xclip xdg-utils xrandr xz yq zram-generator || return
      fi
      jsh::uv just rust-just || return
      jsh::uv tmail tmail-cli || return
      ;;
    vscode)
      jsh::brew casks visual-studio-code || return
      ;;
    wallpaper)
      :
      ;;
    waterfox)
      jsh::brew casks waterfox || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak net.waterfox.waterfox || return
      fi
      ;;
    wox)
      jsh::brew casks wox || return
      if [[ ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt sqlite3 || return
      fi
      if [[ ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf sqlite || return
      fi
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::appimage wox https://api.github.com/repos/Wox-launcher/Wox/releases/latest arm64 amd64 || return
      fi
      ;;
    *)
      jsh::log_error "unknown package group: $1"
      return 2
      ;;
  esac
}

status=0
for group in "$@"; do
  case ${group} in --dry-run | --update) continue ;; -*)
    jsh::log_error "unknown option: ${group}"
    exit 2
    ;;
  esac
  if install_group "${group}"; then :; else status=1; fi
done
exit "${status}"
