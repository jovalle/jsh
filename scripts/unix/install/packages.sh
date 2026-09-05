#!/usr/bin/env bash
# Install Homebrew packages from the repository Brewfiles.

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

load_brew() {
  if command -v brew > /dev/null 2>&1; then
    return
  fi

  local brew_path
  for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [[ -x "${brew_path}" ]]; then
      eval "$("${brew_path}" shellenv)"
      return
    fi
  done
}

install_brew() {
  if ! command -v curl > /dev/null 2>&1; then
    jsh_error "curl is required to install Homebrew."
    exit 1
  fi

  jsh_info "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew

  if ! command -v brew > /dev/null 2>&1; then
    jsh_error "Homebrew installed but could not be added to PATH."
    exit 1
  fi
}

migrate_legacy_npm_package() {
  local package=$1
  shift

  local brew_prefix command link target
  brew_prefix=$(brew --prefix)
  for command in "$@"; do
    link="${brew_prefix}/bin/${command}"
    [[ -L "${link}" ]] || continue
    target=$(readlink "${link}")
    case "${target}" in
      "../lib/node_modules/${package}/"* | "${brew_prefix}/lib/node_modules/${package}/"*)
        jsh_info "Migrating ${package} from npm to Homebrew..."
        npm uninstall --global --prefix "${brew_prefix}" "${package}"
        return
        ;;
      *) ;;
    esac
  done
}

migrate_legacy_npm_packages() {
  command -v npm > /dev/null 2>&1 || return

  migrate_legacy_npm_package commitizen cz git-cz
  migrate_legacy_npm_package @commitlint/cli commitlint
  migrate_legacy_npm_package eslint eslint
  migrate_legacy_npm_package markdownlint-cli markdownlint
}

install_scope() {
  local scope=$1
  local brewfile="${JSH_ROOT}/conf/brew/${scope}/Brewfile"

  [[ -f "${brewfile}" ]] || return
  [[ "${scope}" != contrib ]] || migrate_legacy_npm_packages
  if ((installed_scope)); then
    jsh_blank
  else
    installed_scope=1
  fi
  jsh_info "Installing ${scope} packages..."
  brew bundle --file="${brewfile}"
}

is_arch_family() {
  local os_release=${JSH_OS_RELEASE:-/etc/os-release}
  [[ "$(uname -s)" == Linux && -r "${os_release}" ]] || return 1

  local ID='' ID_LIKE=''
  # shellcheck source=/dev/null
  . "${os_release}"
  [[ " ${ID:-} ${ID_LIKE:-} " == *" endeavouros "* ||
    " ${ID:-} ${ID_LIKE:-} " == *" arch "* ||
    " ${ID:-} ${ID_LIKE:-} " == *" archlinux "* ]]
}

main() {
  local platform
  local -i installed_scope=0
  platform=$(uname -s)
  case "${platform}" in
    Darwin | Linux) ;;
    *)
      jsh_error "Unsupported platform: ${platform}"
      exit 1
      ;;
  esac

  if is_arch_family; then
    jsh_info "Using native Arch package management; skipping Homebrew packages."
    return
  fi

  load_brew
  command -v brew > /dev/null 2>&1 || install_brew

  install_scope core
  install_scope common
  install_scope contrib

  if [[ "${platform}" == Darwin ]]; then
    install_scope macos
  fi

  local machine
  machine=$(hostname -s 2> /dev/null || hostname)
  machine=$(printf '%s' "${machine}" | tr '[:upper:]' '[:lower:]')
  install_scope "${machine}"
}

main "$@"
