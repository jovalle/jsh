#!/usr/bin/env bash
# Install a pinned Ansible, with its bundled collections, into the checkout.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"

python_version=3.13
python_preference=only-managed
# Managed Pythons come from GitHub; mirrors-only hosts use an installed one ansible-core supports.
if [[ ${JSH_MIRRORS_ONLY} == 1 ]]; then
  python_version='>=3.12'
  python_preference=only-system
fi
uv_version=0.13.8
home=${JSH_ANSIBLE_HOME:-${JSH_ROOT}/local/ansible}
requirements=${JSH_ROOT}/ansible/requirements.txt

# Linux has no uv package in apt or dnf; install the pinned release binary instead.
install_uv() {
  local arch digest archive
  case $(uname -m) in
    x86_64 | amd64)
      arch=x86_64
      digest=5acfd9177cfecf0bf87578f059728215ccc884388988f55f7a65041b57387d91
      ;;
    aarch64 | arm64)
      arch=aarch64
      digest=74f2f5c6024d397481db228db8fc25eed420db192243f88438c118e7e013e585
      ;;
    *)
      jsh::fail "uv: unsupported architecture $(uname -m)"
      return 1
      ;;
  esac
  archive=$(jsh::temp)/uv.tar.gz
  jsh::download "https://github.com/astral-sh/uv/releases/download/${uv_version}/uv-${arch}-unknown-linux-gnu.tar.gz" \
    "${archive}" || return
  if [[ $(jsh::sha256 "${archive}") != "${digest}" ]]; then
    jsh::fail "uv ${uv_version} checksum does not match"
    return 1
  fi
  mkdir -p "${HOME}/.local/bin"
  tar -xzf "${archive}" -C "${HOME}/.local/bin" --strip-components 1 "uv-${arch}-unknown-linux-gnu/uv"
  jsh::added "uv ${uv_version} installed" "uv is not installed"
}

jsh::step check Ansible
uv=${JSH_UV:-}
if [[ -z ${uv} ]]; then
  if command -v uv >/dev/null 2>&1; then
    uv=$(command -v uv)
  elif [[ -x ${HOME}/.local/bin/uv ]]; then
    uv=${HOME}/.local/bin/uv
  elif [[ ${JSH_PLATFORM} == darwin ]]; then
    jsh::fail "uv is required; run ./install.sh to install the core packages"
    exit 1
  elif [[ ${JSH_MIRRORS_ONLY} == 1 ]]; then
    jsh::notice 'uv is required and its release is not on an internal mirror; install uv from the internal PyPI with `python3 -m pip install --user uv`, then rerun'
    exit 1
  elif [[ ${JSH_DRY_RUN} == 1 ]]; then
    jsh::info "would install uv ${uv_version}"
    uv=uv
  else
    install_uv
    uv=${HOME}/.local/bin/uv
  fi
fi

jsh::status Ansible
scratch=$(jsh::temp)
{
  cat "${requirements}"
  printf 'python %s %s\nhome %s\n' "${python_preference}" "${python_version}" "${home}"
} >"${scratch}/stamp"
wanted=$(jsh::sha256 "${scratch}/stamp")
current=
[[ ! -f ${home}/stamp ]] || current=$(<"${home}/stamp")
if [[ ${current} == "${wanted}" && -x ${home}/venv/bin/ansible-playbook ]] &&
  PYTHONDONTWRITEBYTECODE=1 "${home}/venv/bin/ansible-playbook" --version >/dev/null 2>&1; then
  jsh::ok "Ansible is current"
  exit 0
fi

installed=0
[[ ! -d ${home}/venv ]] || installed=1
if [[ ${JSH_DRY_RUN} == 1 ]]; then
  if ((installed)); then
    jsh::changed "Ansible updated" "Ansible is out of date"
  else
    jsh::added "Ansible installed" "Ansible is not installed"
  fi
  exit 0
fi

# The stamp is written last, so an interrupted or failed install is retried on the next run.
mkdir -p "${home}"
rm -f -- "${home}/stamp"
# Privileged modules from older runs may have left root-owned bytecode directories.
# Preserve an obstructed environment rather than trying to remove it with sudo.
if [[ -d ${home}/venv ]] &&
  [[ -n $(find "${home}/venv" -type d ! -exec test -w {} \; -print -quit) ]]; then
  backup=${home}/venv.backup.$$
  while [[ -e ${backup} || -L ${backup} ]]; do backup+=.1; done
  mv -- "${home}/venv" "${backup}"
  jsh::info "Preserved unwritable Ansible environment at ${backup}"
fi
# Collections installed from Galaxy by older versions would shadow the bundled ones.
rm -rf -- "${home}/collections"
UV_PYTHON_PREFERENCE=${python_preference} jsh::task "Creating the Ansible environment" \
  "${uv}" venv --quiet --clear --python "${python_version}" "${home}/venv"
jsh::task "Installing Ansible" \
  "${uv}" pip install --quiet --python "${home}/venv/bin/python" -r "${requirements}"
printf '%s\n' "${wanted}" >"${home}/stamp"
if ((installed)); then
  jsh::changed "Ansible updated" "Ansible is out of date"
else
  jsh::added "Ansible installed" "Ansible is not installed"
fi
