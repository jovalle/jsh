#!/usr/bin/env bash
# Install or update the declared packages for the named groups.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
# shellcheck source=scripts/lib/packages.sh
. "${SCRIPT_DIR}/lib/packages.sh"

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
      if [[ ${JSH_PLATFORM} == darwin ]]; then
        jsh::brew formulae spicetify-cli || return
        jsh::brew casks android-platform-tools citrix-workspace foobar2000 macdown-3000 signal spotify tailscale-app todoist-app vorssaint zoom || return
      fi
      if [[ ${JSH_PLATFORM} == darwin && ${JSH_HOST} == archon ]]; then
        jsh::brew casks bambu-studio elgato-stream-deck macfuse mounty || return
      fi
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak com.spotify.Client com.todoist.Todoist || return
      fi
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
      if [[ ${JSH_PLATFORM} == darwin ]]; then
        jsh::brew formulae bash curl git python zsh jq uv || return
      fi
      if [[ ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt bash ca-certificates curl git python3 zsh procps jq || return
      fi
      if [[ ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf bash ca-certificates curl git python3 zsh procps-ng jq || return
      fi
      ;;
    desktop)
      if [[ ${JSH_DESKTOP} == xfce && ${JSH_PLATFORM} == debian ]]; then
        jsh::native apt fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal || return
      fi
      if [[ ${JSH_DESKTOP} == xfce && ${JSH_PLATFORM} == rhel ]]; then
        jsh::native dnf fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal || return
      fi
      if [[ ${JSH_DESKTOP} == xfce && ${JSH_PLATFORM} == debian && ${JSH_HOST} == colossus ]]; then
        jsh::native apt build-essential pkg-config patch gettext meson libgtk-3-dev libpulse-dev libxfce4panel-2.0-dev libxfce4ui-2-dev libxfconf-0-dev libkeybinder-3.0-dev libnotify-dev libwnck-3-dev libexo-2-dev libxfce4windowing-0-dev || return
      fi
      ;;
    dev)
      jsh::brew formulae actionlint autopep8 bats-core black commitizen commitlint eslint gitleaks hadolint markdownlint-cli pre-commit prettier pylint shellcheck shfmt yamllint || return
      jsh::uv check-yaml pre-commit-hooks || return
      ;;
    display)
      if [[ ${JSH_PLATFORM} == darwin && -n ${JSH_DESKTOP} ]]; then
        jsh::brew formulae displayplacer || return
      fi
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
    helium)
      jsh::brew casks helium-browser || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::appimage helium https://api.github.com/repos/imputnet/helium-linux/releases/latest arm64 || return
      fi
      ;;
    kube)
      jsh::brew formulae helm helmfile k9s kubernetes-cli || return
      ;;
    password)
      jsh::brew casks bitwarden || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak com.bitwarden.desktop || return
      fi
      ;;
    sublime)
      jsh::brew casks sublime-text || return
      if [[ ${JSH_PLATFORM} != darwin ]]; then
        jsh::flatpak com.sublimetext.three || return
      fi
      ;;
    tools)
      if [[ ${JSH_PLATFORM} == darwin ]]; then
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
      # Groups configured entirely by their own scripts declare no packages here.
      jsh::is_group "$1" && return 0
      jsh::fail "unknown package group: $1"
      return 2
      ;;
  esac
}

# Any failed group exits 1; an unknown group exits 2.
status=0
for group in "$@"; do
  case ${group} in --dry-run | --update) continue ;; -*)
    jsh::fail "unknown option: ${group}"
    exit 2
    ;;
  esac
  install_group "${group}" || case $? in
    2) status=2 ;;
    *) ((status)) || status=1 ;;
  esac
done
exit "${status}"
