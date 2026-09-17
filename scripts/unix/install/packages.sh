#!/usr/bin/env bash
# Install Homebrew, Cargo, uv, and npm packages.

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

manifest() {
  jsh_manifest_main "$@"
}

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
    if [[ ${JSH_ASSUME_YES:-0} == 1 ]]; then answer=y; else read -r answer || answer=; fi
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
    jsh_note "Keeping ${package} with ${owner}; skipping ${manager}."
    return 1
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
    case ${package} in
      fd-find) PACKAGE_OWNERS[fd]=os ;;
      fd) PACKAGE_OWNERS[fd-find]=os ;;
      bats) PACKAGE_OWNERS[bats-core]=os ;;
      golang-go) PACKAGE_OWNERS[go]=os ;;
      python3-poetry) PACKAGE_OWNERS[poetry]=os ;;
      netcat-openbsd) PACKAGE_OWNERS[netcat]=os ;;
    esac
  done < <("${installer}" --list-installed-packages)
}

register_brew_packages() {
  local brewfile=$1 package

  while IFS= read -r package; do
    [[ -n "${package}" ]] || continue
    [[ -n "${PACKAGE_OWNERS[${package}]:-}" ]] || PACKAGE_OWNERS[${package}]=brew
    [[ ${package} != fd ]] || PACKAGE_OWNERS[fd-find]=${PACKAGE_OWNERS[fd]}
  done < <(sed -nE 's/^[[:space:]]*(brew|cask) "([^"]+)".*/\2/p' "${brewfile}")
}

trust_declared_formulae() {
  local brewfile=$1 formula existing trusted_json
  local -a formulae=() untrusted=()

  while IFS= read -r formula; do
    for existing in "${formulae[@]}"; do
      [[ "${existing}" != "${formula}" ]] || continue 2
    done
    formulae+=("${formula}")
  done < <(sed -nE 's/^[[:space:]]*brew "([^"/]+\/[^"/]+\/[^"/]+)".*/\1/p' "${brewfile}")

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

filter_native_brew_packages() {
  local brewfile=$1 temporary=$2 line package

  while IFS= read -r line || [[ -n "${line}" ]]; do
    package=$(sed -nE 's/^[[:space:]]*(brew|cask) "([^"]+)".*/\2/p' <<< "${line}")
    if [[ -n "${package}" && "${PACKAGE_OWNERS[${package}]:-}" == os ]]; then
      continue
    fi
    printf '%s\n' "${line}" >> "${temporary}"
  done < "${brewfile}"
}

install_brew_manifest() {
  local brewfile=$1

  if [[ ${JSH_UPDATE:-0} != 1 ]] && HOMEBREW_NO_AUTO_UPDATE=1 brew bundle check --no-upgrade --file="${brewfile}" > /dev/null 2>&1; then
    jsh_note "Homebrew packages are current."
    return
  fi
  jsh_info "Installing Homebrew packages..."
  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    brew bundle --file="${brewfile}"
  else
    HOMEBREW_NO_AUTO_UPDATE=1 brew bundle check --no-upgrade --file="${brewfile}" > /dev/null 2>&1 ||
      HOMEBREW_NO_AUTO_UPDATE=1 brew bundle --no-upgrade --file="${brewfile}"
  fi
  brew bundle check --no-upgrade --file="${brewfile}"
}

install_brew_packages() {
  local declared filtered

  mkdir -p "${JSH_ROOT}/tmp"
  declared=$(mktemp "${JSH_ROOT}/tmp/Brewfile.declared.XXXXXX")
  filtered=$(mktemp "${JSH_ROOT}/tmp/Brewfile.resolved.XXXXXX")
  jsh_interrupt_cleanup_path "${declared}"
  jsh_interrupt_cleanup_path "${filtered}"
  manifest brewfile > "${declared}"
  if [[ ! -s "${declared}" ]]; then
    rm -f "${declared}" "${filtered}"
    return 0
  fi

  # Native packages cover the base system; Homebrew supplies declared CLI gaps.
  load_brew
  confirm "Install Homebrew packages?" || {
    jsh_note "Skipping Homebrew packages."
    rm -f "${declared}" "${filtered}"
    return 0
  }

  load_brew
  command -v brew > /dev/null 2>&1 || install_brew

  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    jsh_info "Updating Homebrew packages..."
    brew update
  fi

  register_brew_packages "${declared}"
  trust_declared_formulae "${declared}"
  migrate_legacy_npm_packages
  filter_native_brew_packages "${declared}" "${filtered}"
  install_brew_manifest "${filtered}"
  rm -f "${declared}" "${filtered}"

  if [[ ${JSH_UPDATE:-0} == 1 ]]; then
    if [[ ${JSH_ASSUME_YES:-0} == 1 ]]; then
      brew upgrade --formula --yes
    else
      brew upgrade --formula
    fi
    jsh_success "Declared Homebrew packages are up to date."
  fi
}

cargo_package_installed() {
  cargo install --list | awk -v package="$1" '$1 == package { found = 1 } END { exit !found }'
}

install_cargo_packages() {
  local package name output
  local -i installing=0
  local -a packages=()

  if ! command -v cargo > /dev/null 2>&1; then
    jsh_note "cargo is not installed; skipping Cargo packages."
    return 0
  fi
  output=$(manifest list cargo) || return
  if [[ -n "${output}" ]]; then mapfile -t packages <<< "${output}"; fi

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
    cargo_package_installed "${name}" || {
      jsh_error "Cargo package verification failed: ${name}"
      return 1
    }
  done
  if ((installing)); then jsh_success "Cargo packages are installed."; else jsh_note "Cargo packages are current."; fi
}

uv_tool_installed() {
  uv tool list | awk -v package="$1" '$1 == package { found = 1 } END { exit !found }'
}

install_uv_tools() {
  local package output
  local -i installing=0
  local -a packages=()

  output=$(manifest list uv) || return
  if [[ -n "${output}" ]]; then mapfile -t packages <<< "${output}"; fi

  ((${#packages[@]} > 0)) || return 0
  confirm "Install uv tools?" || {
    jsh_note "Skipping uv tools."
    return 0
  }
  command -v uv > /dev/null 2>&1 || {
    jsh_error "uv is required by conf/packages.json."
    return 1
  }

  for package in "${packages[@]}"; do
    claim_package uv "${package}" || continue
    if [[ ${JSH_UPDATE:-0} != 1 ]] && uv_tool_installed "${package}"; then
      continue
    fi
    if ((!installing)); then
      jsh_info "Installing uv tools..."
      installing=1
    fi
    uv tool install --upgrade "${package}"
    uv_tool_installed "${package}" || {
      jsh_error "uv tool verification failed: ${package}"
      return 1
    }
  done
  if ((installing)); then jsh_success "uv tools are installed."; else jsh_note "uv tools are current."; fi
}

npm_package_installed() {
  npm list --global --depth=0 "$1@$2" > /dev/null 2>&1
}

install_npm_packages() {
  local package version specification output
  local -i installing=0
  local -a packages=() versions=()

  output=$(manifest list npm) || return
  while IFS=$'\t' read -r package version; do
    [[ -n "${package}" ]] || continue
    packages+=("${package}")
    versions+=("${version}")
  done <<< "${output}"

  ((${#packages[@]} > 0)) || return 0
  confirm "Install npm packages?" || {
    jsh_note "Skipping npm packages."
    return 0
  }
  if ! command -v npm > /dev/null 2>&1; then
    jsh_note "npm is not installed; skipping npm packages."
    return 0
  fi

  for ((index = 0; index < ${#packages[@]}; index++)); do
    package=${packages[index]}
    version=${versions[index]}
    claim_package npm "${package}" || continue
    if [[ ${JSH_UPDATE:-0} != 1 ]] && npm_package_installed "${package}" "${version}"; then
      continue
    fi
    if ((!installing)); then
      jsh_info "Installing npm packages..."
      installing=1
    fi
    specification="${package}@${version}"
    npm install --global "${specification}"
    npm_package_installed "${package}" "${version}" || {
      jsh_error "npm package verification failed: ${specification}"
      return 1
    }
  done
  if ((installing)); then jsh_success "npm packages are installed."; else jsh_note "npm packages are current."; fi
}

main() {
  local platform
  platform=$(uname -s)
  case "${platform}" in
    Darwin | Linux) ;;
    *)
      jsh_error "Unsupported platform: ${platform}"
      exit 1
      ;;
  esac

  register_native_packages
  install_brew_packages
  install_cargo_packages
  install_uv_tools
  install_npm_packages
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
