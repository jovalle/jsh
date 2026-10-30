#!/usr/bin/env bash
# Set up this machine from this checkout, or clone it first when piped from curl.

set -euo pipefail

source_path=${BASH_SOURCE[0]:-}
# Piped from curl: clone the checkout, then run its copy of this script.
if [[ -z ${source_path} || ! -d $(dirname -- "${source_path}")/lib/jsh ]]; then
  target=${JSH_HOME:-${HOME}/.jsh}
  if [[ -e ${target} || -L ${target} ]]; then
    printf 'jsh: %s already exists; run its j.sh to open setup\n' "${target}" >&2
    exit 1
  fi
  command -v git >/dev/null 2>&1 || {
    printf 'jsh: Git is required to clone the checkout; install it first\n' >&2
    exit 1
  }
  [[ -r /dev/tty ]] || {
    printf 'jsh: setup needs an interactive terminal\n' >&2
    exit 1
  }
  git clone https://github.com/jovalle/jsh.git "${target}"
  exec "${target}/j.sh" </dev/tty
fi

JSH_ROOT=$(cd -- "$(dirname -- "${source_path}")" && pwd -P)
export JSH_ROOT
unset source_path

# Find a standard Homebrew installation even before shell startup has added it to PATH.
for brew_prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
  if ! command -v brew >/dev/null 2>&1 && [[ -x ${brew_prefix}/bin/brew ]]; then
    export PATH="${brew_prefix}/bin:${brew_prefix}/sbin:${PATH}"
  fi
done
unset brew_prefix

if [[ ${1:-} == runtime ]]; then
  shift
  exec "${JSH_ROOT}/bin/jsh" "$@"
fi

# Prints the first Python 3.9+ (the oldest the engine supports).
find_python() {
  local candidate
  for candidate in python3 python3.14 python3.13 python3.12 python3.11 \
    /opt/homebrew/bin/python3 /usr/local/bin/python3 /home/linuxbrew/.linuxbrew/bin/python3; do
    candidate=$(command -v "${candidate}" 2>/dev/null) || continue
    "${candidate}" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null || continue
    printf '%s\n' "${candidate}"
    return 0
  done
  return 1
}

# Installs Python 3.9+ with the system package manager, or Homebrew when that is all there is.
install_python() {
  local log=${JSH_ROOT}/local/logs/python.log package
  local -a sudo=()
  [[ ${EUID} == 0 ]] || sudo=(sudo -n --)
  mkdir -p -- "${log%/*}"
  : >"${log}"
  if [[ $(uname -s) != Darwin ]] && { [[ ${EUID} == 0 ]] || sudo -n true 2>/dev/null; }; then
    if command -v apt-get >/dev/null 2>&1; then
      ${sudo[@]+"${sudo[@]}"} apt-get update >>"${log}" 2>&1 || return 1
      for package in python3.13 python3.12 python3.11 python3; do
        ${sudo[@]+"${sudo[@]}"} env DEBIAN_FRONTEND=noninteractive \
          apt-get install -y --no-upgrade "${package}" >>"${log}" 2>&1 && find_python >/dev/null && return 0
      done
    elif command -v dnf >/dev/null 2>&1; then
      for package in python3.13 python3.12 python3.11 python3; do
        ${sudo[@]+"${sudo[@]}"} dnf install -y "${package}" >>"${log}" 2>&1 &&
          find_python >/dev/null && return 0
      done
    fi
  fi
  if command -v brew >/dev/null 2>&1; then
    brew install python >>"${log}" 2>&1 && return 0
  elif [[ $(uname -s) == Darwin ]]; then
    printf 'jsh: install Homebrew first: https://brew.sh\n' >&2
  else
    printf 'jsh: run sudo -v first so jsh can install Python with the package manager\n' >&2
  fi
  return 1
}

if ! python=$(find_python); then
  if [[ " $* " == *' --dry-run '* ]]; then
    printf 'jsh: Python 3.9 or later is required; run without --dry-run to install it\n' >&2
    exit 1
  fi
  if [[ $# == 0 ]]; then
    printf 'jsh: install Python 3.9 or later, then run ./j.sh again\n' >&2
    exit 1
  fi
  printf 'jsh: installing Python 3.9 or later\n' >&2
  if ! install_python || ! python=$(find_python); then
    printf 'jsh: could not install Python 3.9+; see %s\n' "${JSH_ROOT}/local/logs/python.log" >&2
    exit 1
  fi
fi
export PYTHONPATH="${JSH_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" PYTHONDONTWRITEBYTECODE=1
[[ $# != 0 ]] || set -- wizard
exec "${python}" -m jsh "$@"
