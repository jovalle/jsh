#!/usr/bin/env bash
# Install EndeavourOS packages with pacman, an AUR helper, and Flatpak.

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

DRY_RUN=${JSH_INSTALL_DRY_RUN:-${JSH_CONFIGURE_DRY_RUN:-0}}

is_arch_family() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ -r "${os_release}" ]] || return 1

  local ID='' ID_LIKE=''
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ " ${ID:-} ${ID_LIKE:-} " == *" endeavouros "* ||
    " ${ID:-} ${ID_LIKE:-} " == *" arch "* ||
    " ${ID:-} ${ID_LIKE:-} " == *" archlinux "* ]]
}

run_root() {
  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would run as root: $*"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo > /dev/null 2>&1; then
    sudo -- "$@"
  else
    jsh_error "sudo is required to install system packages."
    return 1
  fi
}

install_native_packages() {
  local package
  local -a missing=()
  local -a packages=(
    actionlint age ansible arc-gtk-theme-eos atuin base-devel bash bat btop
    bun bzip2 ca-certificates cifs-utils coreutils curl desktop-file-utils dconf
    diffutils direnv dkms docker docker-buildx docker-compose earlyoom
    eos-qogir-icons eslint eza fd flatpak fnm fzf gawk github-cli git git-lfs
    gitleaks gnome-keyring gnupg go grep grc helm helmfile hugo jq k9s kubectl
    libarchive libnotify make markdownlint-cli2 mpv ncdu net-tools nfs-utils
    nmap ntfs-3g nvme-cli openssh parallel pipewire-pulse pnpm podman pre-commit
    prettier procps-ng python python-autopep8 python-black python-poetry
    python-pylint readline reflector ripgrep rsync s-tui shellcheck shfmt sops
    speedtest-cli sqlite sshpass stow syncthing tar tmux
    ttf-jetbrains-mono-nerd unzip uv wireplumber xbindkeys xclip xdg-utils
    xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin
    xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal xorg-xrandr xz
    yamllint yq zoxide zram-generator zsh
  )

  for package in "${packages[@]}"; do
    pacman -Q "${package}" > /dev/null 2>&1 || missing+=("${package}")
  done
  if ((${#missing[@]} > 0)); then
    if [[ "${DRY_RUN}" == 1 ]]; then
      jsh_detail "Would install native packages: ${missing[*]}"
    else
      run_root pacman -S --needed --noconfirm -- "${missing[@]}"
    fi
  fi
  jsh_success "Native Arch packages are installed."
}

find_aur_helper() {
  command -v yay 2> /dev/null || command -v paru 2> /dev/null
}

install_aur_helper() {
  local build_dir package_file
  find_aur_helper > /dev/null && return

  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would install the yay AUR helper."
    return
  fi

  if pacman -Si yay > /dev/null 2>&1; then
    run_root pacman -S --needed --noconfirm -- yay
    return
  fi

  build_dir=$(mktemp -d "${TMPDIR:-${JSH_ROOT}/tmp}/jsh-yay-bin.XXXXXX")
  trap 'rm -rf -- "${build_dir}"' RETURN
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git "${build_dir}"
  (cd "${build_dir}" && makepkg --force --noconfirm)
  package_file=$(find "${build_dir}" -maxdepth 1 -type f -name 'yay-bin-*.pkg.tar.*' -print -quit)
  [[ -n "${package_file}" ]] || {
    jsh_error "The yay build did not produce an installable package."
    return 1
  }
  run_root pacman -U --noconfirm -- "${package_file}"
}

install_aur_packages() {
  local helper package
  local -a missing=()
  local -a packages=(
    commitlint commitlint-config-conventional gemini-cli-git hadolint-bin
    nodejs-commitizen nodejs-cz-conventional-changelog opencode-bin
    visual-studio-code-bin waterfox-bin
  )

  for package in "${packages[@]}"; do
    pacman -Q "${package}" > /dev/null 2>&1 || missing+=("${package}")
  done
  ((${#missing[@]} == 0)) && return

  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would install AUR packages: ${missing[*]}"
    return
  fi

  install_aur_helper
  helper=$(find_aur_helper)
  "${helper}" -S --needed --noconfirm -- "${missing[@]}"
  jsh_success "AUR packages are installed."
}

install_flatpaks() {
  local application
  local -a applications=(com.spotify.Client com.todoist.Todoist)

  if [[ "${DRY_RUN}" == 1 ]]; then
    jsh_detail "Would configure Flathub and install: ${applications[*]}"
    return
  fi
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  for application in "${applications[@]}"; do
    flatpak info --user "${application}" > /dev/null 2>&1 ||
      flatpak install --user --noninteractive flathub "${application}"
  done
  jsh_success "Flatpak applications are installed."
}

main() {
  [[ "$(uname -s)" == Linux ]] || return
  is_arch_family || {
    jsh_info "Skipping native packages: Arch Linux or EndeavourOS not detected."
    return
  }

  command -v pacman > /dev/null 2>&1 || {
    jsh_error "pacman is required on Arch-family systems."
    return 1
  }
  install_native_packages
  install_aur_packages
  install_flatpaks
}

main "$@"
