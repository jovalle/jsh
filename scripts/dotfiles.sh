#!/usr/bin/env bash
# Link files from dotfiles and back up conflicting destinations.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
JSH_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
readonly SCRIPT_DIR JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

backup_root=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d-%H%M%S)-$$
current=()
linked=()
while IFS= read -r -d '' source; do
  relative=${source#"${JSH_ROOT}/dotfiles/"}
  target=${HOME}/${relative}
  # VS Code on macOS reads user files from Application Support, not ~/.config.
  if [[ ${OSTYPE} == darwin* && ${relative} == .config/Code/User/* ]]; then
    target="${HOME}/Library/Application Support/Code/User/${relative#.config/Code/User/}"
  fi
  # -ef also matches files reached through a linked parent directory that points here.
  if [[ -L ${target} && $(readlink "${target}") == "${source}" || ${target} -ef ${source} ]]; then
    current+=("${relative}")
    continue
  fi
  # Do not deploy through a symlinked parent (which may point into this checkout).
  parent=${target%/*}
  while [[ ${parent} != "${HOME}" && ${parent} != / ]]; do
    if [[ -L ${parent} ]]; then
      jsh::log_error "Symlinked parent requires manual review: ${parent}"
      exit 1
    fi
    parent=${parent%/*}
  done
  if [[ -e ${target} || -L ${target} ]]; then
    backup=${backup_root}/${relative}
    jsh::run mkdir -p -- "${backup%/*}"
    jsh::run mv -- "${target}" "${backup}"
    jsh::log_note "  › backup ${backup}"
  fi
  jsh::run mkdir -p -- "${target%/*}"
  jsh::run ln -s -- "${source}" "${target}"
  linked+=("${relative}")
done < <(find "${JSH_ROOT}/dotfiles" \( -type f -o -type l \) \
  ! -name .DS_Store ! -name '.zcompdump*' -print0 | sort -z)
summary=
[[ ${#linked[@]} == 0 ]] || summary="${#linked[@]} $([[ ${JSH_DRY_RUN:-0} == 1 ]] && echo 'to link' || echo linked)"
jsh::log_summary dotfiles "${summary}"
for item in ${current[@]+"${current[@]}"}; do jsh::log_current "${item}"; done
for item in ${linked[@]+"${linked[@]}"}; do jsh::log_item "${item}"; done
