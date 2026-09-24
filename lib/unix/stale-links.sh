#!/bin/sh
# Print HOME symlinks that point at Jsh dotfiles which no longer exist.

set -eu

root=$(CDPATH='' cd -P "${1:?usage: stale-links.sh JSH_ROOT}" && pwd -P)
home=${HOME:?}

candidates() {
  find "${home}" -maxdepth 3 \
    \( -path "${root}" -o -path "${home}/Library" -o -path "${home}/.Trash" \) -prune -o \
    -type l -print 2> /dev/null || :
  # Managed directories hide deeper links; scan two levels below each one.
  git -C "${root}" ls-files --cached --others --exclude-standard -- dotfiles 2> /dev/null |
    sed 's|^dotfiles/||' |
    awk -F/ '{ directory = ""; for (i = 1; i < NF; i++) { directory = directory (i > 1 ? "/" : "") $i; print directory } }' |
    sort -u |
    while IFS= read -r directory; do
      [[ -d "${home}/${directory}" ]] && [[ ! -L "${home}/${directory}" ]] || continue
      find "${home}/${directory}" -mindepth 1 -maxdepth 2 -type l -print 2> /dev/null || :
    done
}

candidates | sort -u | while IFS= read -r link; do
  [[ ! -e "${link}" ]] || continue
  relative=${link#"${home}/"}
  source="${root}/dotfiles/${relative}"
  [[ ! -e "${source}" ]] && [[ ! -L "${source}" ]] || continue
  target=$(readlink "${link}") || continue
  case ${target} in
    */dotfiles/"${relative}") prefix=${target%/dotfiles/"${relative}"} ;;
    *) continue ;;
  esac
  case ${prefix} in
    /*) ;;
    *) prefix=${link%/*}/${prefix} ;;
  esac
  prefix=$(CDPATH='' cd -P "${prefix}" 2> /dev/null && pwd -P) || continue
  if [[ "${prefix}" = "${root}" ]]; then
    printf '%s\n' "${link}"
  fi
done
