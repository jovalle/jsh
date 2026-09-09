#!/usr/bin/env bash
# Install Homebrew, Cargo, and npm packages.

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

declare -A PACKAGE_OWNERS=()

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

confirm() {
  local answer
  [[ ${JSH_ASSUME_YES:-0} == 1 ]] && return 0
  while :; do
    jsh_prompt "$1 [Y/n]: "
    read -r answer || answer=
    case "${answer}" in
      '' | y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) jsh_warn "Please answer yes or no." ;;
    esac
  done
}

claim_package() {
  local manager=$1 package=$2 owner answer
  owner=${PACKAGE_OWNERS[${package}]:-}
  if [[ -z "${owner}" || "${owner}" == "${manager}" ]]; then
    PACKAGE_OWNERS[${package}]=${manager}
    return
  fi

  if [[ ${JSH_ASSUME_YES:-0} == 1 ]]; then
    PACKAGE_OWNERS[${package}]=${manager}
    return
  fi

  jsh_prompt "${package} is already declared for ${owner}. Install it with ${manager} instead? [y/N]: "
  read -r answer || answer=
  case "${answer}" in
    y | Y | yes | YES)
      PACKAGE_OWNERS[${package}]=${manager}
      ;;
    *)
      jsh_note "Keeping ${package} with ${owner}; skipping ${manager}."
      return 1
      ;;
  esac
}

register_native_packages() {
  local installer=${JSH_ROOT}/scripts/linux/install/packages.sh
  local package

  [[ -x "${installer}" ]] || return 0
  while IFS= read -r package; do
    [[ -n "${package}" ]] || continue
    PACKAGE_OWNERS[${package}]=os
  done < <("${installer}" --list-installed-packages)
}

register_brew_packages() {
  local scope brewfile package

  for scope in "$@"; do
    brewfile="${JSH_ROOT}/conf/brew/${scope}/Brewfile"
    [[ -f "${brewfile}" ]] || continue
    while IFS= read -r package; do
      [[ -n "${package}" ]] || continue
      [[ -n "${PACKAGE_OWNERS[${package}]:-}" ]] || PACKAGE_OWNERS[${package}]=brew
    done < <(sed -nE 's/^[[:space:]]*(brew|cask) "([^"]+)".*/\2/p' "${brewfile}")
  done
}

trust_declared_formulae() {
  local scope brewfile formula existing trusted_json
  local -a formulae=() untrusted=()

  for scope in "$@"; do
    brewfile="${JSH_ROOT}/conf/brew/${scope}/Brewfile"
    [[ -f "${brewfile}" ]] || continue
    while IFS= read -r formula; do
      for existing in "${formulae[@]}"; do
        [[ "${existing}" != "${formula}" ]] || continue 2
      done
      formulae+=("${formula}")
    done < <(sed -nE 's/^[[:space:]]*brew "([^"/]+\/[^"/]+\/[^"/]+)".*/\1/p' "${brewfile}")
  done

  trusted_json=$(brew trust --json=v1)
  for formula in "${formulae[@]}"; do
    jq -e --arg formula "${formula}" '.formulae | index($formula) != null' \
      <<< "${trusted_json}" > /dev/null || untrusted+=("${formula}")
  done
  ((${#untrusted[@]} > 0)) || return 0

  jsh_warn "Homebrew requires trust for these third-party formulas:"
  printf '  %s\n' "${untrusted[@]}"
  if ! confirm "Trust these formulas?"; then
    jsh_error "Cannot install untrusted third-party formulas."
    return 1
  fi
  brew trust --formula "${untrusted[@]}"
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

  [[ -f "${brewfile}" ]] || return 0
  [[ "${scope}" != contrib ]] || migrate_legacy_npm_packages
  if ((installed_scope)); then
    jsh_blank
  else
    installed_scope=1
  fi
  jsh_info "Installing ${scope} packages..."
  brew bundle --file="${brewfile}"
}

install_brew_packages() {
  local scope
  local -i installed_scope=0 has_brewfile=0

  for scope in "$@"; do
    if [[ -f "${JSH_ROOT}/conf/brew/${scope}/Brewfile" ]]; then
      has_brewfile=1
      break
    fi
  done
  ((has_brewfile)) || return 0

  if is_arch_family; then
    jsh_note "Using native Arch package management; skipping Homebrew packages."
    return
  fi
  confirm "Install Homebrew packages?" || {
    jsh_note "Skipping Homebrew packages."
    return 0
  }

  load_brew
  command -v brew > /dev/null 2>&1 || install_brew

  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    jsh_info "Updating Homebrew packages..."
    brew update
  fi

  register_brew_packages "$@"
  trust_declared_formulae "$@"
  for scope in "$@"; do
    install_scope "${scope}"
  done

  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    brew upgrade
    jsh_success "Homebrew packages are up to date."
  fi
}

cargo_package_installed() {
  cargo install --list | awk -v package="$1" '$1 == package { found = 1 } END { exit !found }'
}

install_cargo_packages() {
  local manifest=${JSH_ROOT}/conf/Cargo.toml
  local metadata package name
  local -i installing=0
  local -a packages=()

  [[ -f "${manifest}" ]] || return 0
  command -v cargo > /dev/null 2>&1 || {
    jsh_error "cargo is required by ${manifest}."
    return 1
  }
  command -v jq > /dev/null 2>&1 || {
    jsh_error "jq is required to read ${manifest}."
    return 1
  }
  metadata=$(cargo metadata --no-deps --format-version 1 --manifest-path "${manifest}")
  while IFS= read -r package; do
    [[ -n "${package}" ]] && packages+=("${package}")
  done < <(jq -r '.metadata.jsh.packages[]?' <<< "${metadata}")

  ((${#packages[@]} > 0)) || return 0
  confirm "Install Cargo packages?" || {
    jsh_note "Skipping Cargo packages."
    return 0
  }
  for package in "${packages[@]}"; do
    name=${package%%@*}
    claim_package cargo "${name}" || continue
    if [[ ${JSH_UPDATE:-0} != 1 ]] && cargo_package_installed "${name}"; then
      continue
    fi
    if ((!installing)); then
      jsh_info "Installing Cargo packages..."
      installing=1
    fi
    cargo install --locked "${package}"
  done
  jsh_success "Cargo packages are installed."
}

npm_package_installed() {
  npm list --global --depth=0 "$1" > /dev/null 2>&1
}

install_npm_packages() {
  local manifest=${JSH_ROOT}/conf/package.json
  local package version specification
  local -i installing=0
  local -a packages=() versions=()

  [[ -f "${manifest}" ]] || return 0
  command -v jq > /dev/null 2>&1 || return 0
  while IFS=$'\t' read -r package version; do
    [[ -n "${package}" ]] || continue
    packages+=("${package}")
    versions+=("${version}")
  done < <(jq -r '(.dependencies // {}) | to_entries[] | [.key, .value] | @tsv' "${manifest}")

  ((${#packages[@]} > 0)) || return 0
  confirm "Install npm packages?" || {
    jsh_note "Skipping npm packages."
    return 0
  }
  command -v npm > /dev/null 2>&1 || {
    jsh_error "npm is required by the active package suite."
    return 1
  }

  for ((index = 0; index < ${#packages[@]}; index++)); do
    package=${packages[index]}
    version=${versions[index]}
    claim_package npm "${package}" || continue
    if [[ ${JSH_UPDATE:-0} != 1 ]] && npm_package_installed "${package}"; then
      continue
    fi
    if ((!installing)); then
      jsh_info "Installing npm packages..."
      installing=1
    fi
    specification="${package}@${version}"
    npm install --global "${specification}"
  done
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
  local platform machine
  local -a package_scopes=(core common contrib)
  platform=$(uname -s)
  case "${platform}" in
    Darwin | Linux) ;;
    *)
      jsh_error "Unsupported platform: ${platform}"
      exit 1
      ;;
  esac

  if [[ "${platform}" == Darwin ]]; then
    package_scopes+=(macos)
  fi
  machine=$(hostname -s 2> /dev/null || hostname)
  machine=$(printf '%s' "${machine}" | tr '[:upper:]' '[:lower:]')
  package_scopes+=("${machine}")

  register_native_packages
  install_brew_packages "${package_scopes[@]}"
  install_cargo_packages
  install_npm_packages
}

main "$@"
