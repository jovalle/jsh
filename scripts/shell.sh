#!/usr/bin/env bash
# Install shell plugins and their matching fzf binary.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
update=${JSH_UPDATE:-0}
vendor=${JSH_VENDOR:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/vendor}
if ((update)) && [[ ${JSH_DRY_RUN:-0} != 1 ]]; then
  jsh::step update "shell plugins"
else
  jsh::step check "shell plugins"
fi
while IFS=' ' read -r name url; do
  jsh::status "${name}"
  destination=${vendor}/${name}
  if [[ -d ${destination}/.git ]]; then
    if ((update)); then
      before=$(git -C "${destination}" rev-parse HEAD)
      if [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
        if remote=$(GIT_TERMINAL_PROMPT=0 git -C "${destination}" ls-remote origin HEAD) &&
          [[ -n ${remote} ]]; then
          remote=${remote%%[[:space:]]*}
          if [[ ${remote} == "${before}" ]]; then
            jsh::ok "${name} is up to date"
          else
            jsh::changed "${name} updated" "${name} is behind"
          fi
        else
          jsh::info "${name}: could not check for updates"
        fi
      else
        jsh::task "updating ${name}" git -C "${destination}" pull --quiet --ff-only
        if [[ $(git -C "${destination}" rev-parse HEAD) != "${before}" ]]; then
          jsh::changed "${name} updated" "${name} is behind"
        else
          jsh::ok "${name} is up to date"
        fi
      fi
    else
      jsh::ok "${name} is cloned"
    fi
  elif [[ -e ${destination} || -L ${destination} ]]; then
    jsh::notice "${destination} is not a Git checkout; leaving it alone"
    exit 1
  else
    jsh::run mkdir -p -- "${vendor}"
    jsh::task "installing ${name}" git clone --depth 1 -- "${url}" "${destination}"
    jsh::added "${name} cloned" "${name} is missing"
  fi
done <<'PLUGINS'
fzf https://github.com/junegunn/fzf.git
fzf-tab https://github.com/Aloxaf/fzf-tab.git
zsh-completions https://github.com/zsh-users/zsh-completions.git
zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
PLUGINS
installer=${vendor}/fzf/install
jsh::step check "fzf binary"
if [[ -r ${installer} ]]; then
  pinned=$(sed -n 's/^version=//p' "${installer}" | head -n 1)
  if [[ ! -x ${vendor}/fzf/bin/fzf ]]; then
    jsh::task "installing fzf binary" "${installer}" --bin
    jsh::added "fzf installed" "fzf is not installed"
  else
    current=$("${vendor}/fzf/bin/fzf" --version)
    current=${current%% *}
    if [[ -n ${pinned} && ${current} == "${pinned}" ]]; then
      jsh::ok "fzf is ${pinned}"
    else
      jsh::task "installing fzf binary" "${installer}" --bin
      jsh::changed "fzf set ${pinned}" "fzf is ${current}"
    fi
  fi
elif [[ ${JSH_DRY_RUN:-0} == 1 ]]; then
  jsh::info 'would install the fzf binary after cloning its sources'
fi

# Retired completion links make compinit fail when the old checkout is gone.
jsh::step check "retired completion links"
for name in _j _jsh _jsh_fallback _just _make; do
  jsh::status "${name}"
  completion=${HOME}/.zsh/completions/${name}
  [[ -L ${completion} && ! -e ${completion} ]] || continue
  case $(readlink "${completion}") in
    */dotfiles/.zsh/completions/"${name}")
      jsh::parents "${completion}"
      if [[ ${JSH_DRY_RUN} != 1 ]]; then
        jsh::backup "${completion}"
        rm -- "${completion}"
      fi
      jsh::removed "${completion} removed" "${completion} is stale"
      ;;
  esac
done

# Atuin 18.24+ creates ~/.atuin/config.toml, which shadows the managed XDG config.
jsh::step check "Atuin config"
atuin_config=${HOME}/.atuin/config.toml
if [[ -f ${atuin_config} && -L ${XDG_CONFIG_HOME:-${HOME}/.config}/atuin/config.toml ]]; then
  if [[ ${JSH_DRY_RUN:-0} != 1 ]]; then
    jsh::backup "${atuin_config}"
    rm -- "${atuin_config}"
  fi
  jsh::removed "${atuin_config} removed" "${atuin_config} shadows managed config"
else
  jsh::ok "Atuin config does not shadow managed config"
fi
