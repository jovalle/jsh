#!/usr/bin/env bash
# Install shell plugins and their matching fzf binary.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
export JSH_ROOT
update=${JSH_UPDATE:-0}
for argument in "$@"; do
  case ${argument} in
    --dry-run) export JSH_DRY_RUN=1 ;;
    --update) update=1 ;;
    -h | --help)
      printf 'Usage: shell.sh [--dry-run] [--update]\n'
      exit 0
      ;;
    *)
      printf 'shell.sh: unknown option: %s\n' "${argument}" >&2
      exit 2
      ;;
  esac
done
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
vendor=${JSH_VENDOR:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/vendor}
while IFS=' ' read -r name url; do
  jsh::activity "Checking shell plugin ${name}"
  destination=${vendor}/${name}
  if [[ -d ${destination}/.git ]]; then
    if ((update)); then
      before=$(git -C "${destination}" rev-parse HEAD)
      jsh::task "updating ${name}" git -C "${destination}" pull --quiet --ff-only
      if [[ ${JSH_DRY_RUN:-0} == 1 || $(git -C "${destination}" rev-parse HEAD) != "${before}" ]]; then
        jsh::changed "${name} updated"
      else
        jsh::detail "shell plugin ${name}: up to date"
      fi
    else
      jsh::current "${name}"
    fi
  elif [[ -e ${destination} || -L ${destination} ]]; then
    jsh::notice "${destination} is not a Git checkout; leaving it alone"
    exit 1
  else
    jsh::run mkdir -p -- "${vendor}"
    jsh::task "installing ${name}" git clone --depth 1 -- "${url}" "${destination}"
    jsh::added "${name}"
  fi
done <<'PLUGINS'
fzf https://github.com/junegunn/fzf.git
fzf-tab https://github.com/Aloxaf/fzf-tab.git
zsh-completions https://github.com/zsh-users/zsh-completions.git
zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
PLUGINS
installer=${vendor}/fzf/install
jsh::activity 'Checking fzf binary'
if [[ -r ${installer} ]]; then
  pinned=$(sed -n 's/^version=//p' "${installer}" | head -n 1)
  current=$([ ! -x "${vendor}/fzf/bin/fzf" ] || "${vendor}/fzf/bin/fzf" --version)
  if [[ -n ${pinned} && ${current%% *} == "${pinned}" ]]; then
    jsh::current 'fzf binary'
  else
    jsh::task "installing fzf binary" "${installer}" --bin
    jsh::changed 'fzf binary'
  fi
elif [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::notice 'would install the fzf binary after cloning its sources'
fi

# Retired completion links make compinit fail when the old checkout is gone.
for name in _j _jsh _jsh_fallback _just _make; do
  jsh::activity "Checking retired completion ${name}"
  completion=${HOME}/.zsh/completions/${name}
  [[ -L ${completion} && ! -e ${completion} ]] || continue
  case $(readlink "${completion}") in
    */dotfiles/.zsh/completions/"${name}")
      jsh::parents "${completion}"
      if [[ ${JSH_DRY_RUN} != 1 ]]; then
        jsh::backup "${completion}"
        rm -- "${completion}"
      fi
      jsh::removed "${completion}"
      ;;
  esac
done

# Atuin 18.24+ creates ~/.atuin/config.toml, which shadows the managed XDG config.
jsh::activity 'Checking Atuin config'
atuin_config=${HOME}/.atuin/config.toml
if [[ -f ${atuin_config} && -L ${XDG_CONFIG_HOME:-${HOME}/.config}/atuin/config.toml ]]; then
  if [[ ${JSH_DRY_RUN:-0} != 1 ]]; then
    jsh::backup "${atuin_config}"
    rm -- "${atuin_config}"
  fi
  jsh::removed "${atuin_config}"
fi
