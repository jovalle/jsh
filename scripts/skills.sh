#!/usr/bin/env bash
# Install agent skill repositories and link their published skills.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh" "$@"
jsh::need git
vendor=${JSH_VENDOR:-${XDG_DATA_HOME:-${HOME}/.local/share}/jsh/vendor}/skills
while IFS=$'\t' read -r name url; do
  jsh::activity "Checking skill repository ${name}"
  destination=${vendor}/${name}
  if [[ -d ${destination}/.git ]]; then
    if [[ ${JSH_UPDATE:-0} == 1 ]]; then
      before=$(git -C "${destination}" rev-parse HEAD)
      jsh::task "Updating ${name}" git -C "${destination}" pull --quiet --ff-only
      if [[ ${JSH_DRY_RUN:-0} == 1 || $(git -C "${destination}" rev-parse HEAD) != "${before}" ]]; then
        jsh::changed "${name}"
      else
        jsh::detail "skill repository ${name}: up to date"
      fi
    else
      jsh::current
    fi
  elif [[ -e ${destination} || -L ${destination} ]]; then
    jsh::notice "${destination} is not a Git checkout; leaving it alone"
    exit 1
  else
    jsh::run mkdir -p -- "${vendor}"
    jsh::task "Cloning ${name}" git clone --depth 1 -- "${url}" "${destination}"
    jsh::added "${name}"
  fi
done <"${SCRIPT_DIR}/skills/repos.tsv"
while IFS=$'\t' read -r source name; do
  jsh::activity "Checking skill link ${name}"
  if [[ ${JSH_DRY_RUN:-0} != 1 && ! -d ${vendor}/${source} ]]; then
    jsh::notice "Skill source is missing: ${vendor}/${source}"
    continue
  fi
  jsh::link "${vendor}/${source}" "${HOME}/.agents/skills/${name}"
done <"${SCRIPT_DIR}/skills/links.tsv"
# Machine-local skills live outside the repository: SOURCE (relative to $HOME) TAB NAME.
for list in "${XDG_CONFIG_HOME:-${HOME}/.config}/jsh/skills.tsv" "${JSH_ROOT}/local/skills.tsv"; do
  [[ -f ${list} ]] || continue
  while IFS=$'\t' read -r source name; do
    jsh::activity "Checking local skill ${name}"
    if [[ ! -d ${HOME}/${source} ]]; then
      jsh::detail "local skill ${name}: ${HOME}/${source} is missing"
      continue
    fi
    jsh::link "${HOME}/${source}" "${HOME}/.agents/skills/${name}"
  done <"${list}"
  break
done
# scripts/ai/rea.sh installs graphify and reverse-engineer-anything as real directories.
for name in github-actions-hardening show-me-your-work; do
  jsh::activity "Checking bundled skill ${name}"
  jsh::link "${JSH_ROOT}/dotfiles/.agents/skills/${name}" "${HOME}/.agents/skills/${name}"
done
