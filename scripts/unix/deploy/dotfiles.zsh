#!/usr/bin/env zsh
# Deploy managed dotfiles and command links.

set -eu

readonly repo_root=${0:A:h:h:h:h}
readonly dotfiles_dir="${repo_root}/dotfiles"
readonly commands_dir="${repo_root}/bin"
readonly commands_link="${HOME}/.bin"
for library_file in "${repo_root}"/lib/*; do
  [[ -f ${library_file} && -x ${library_file} ]] || continue
  # shellcheck source=/dev/null
  . "${library_file}"
done
unset library_file
recovery_dir=
backup_root=
typeset -a stashed_paths stashed_backups

stash_path() {
  local target=$1 relative backup
  if [[ -z "${recovery_dir}" ]]; then
    mkdir -p -- "${repo_root}/tmp"
    recovery_dir=$(mktemp -d "${repo_root}/tmp/jstow-deploy.XXXXXX")
  fi
  relative=${target#"${HOME}/"}
  backup="${recovery_dir}/${relative}"
  mkdir -p -- "${backup:h}"
  mv -- "${target}" "${backup}"
  stashed_paths+=("${target}")
  stashed_backups+=("${backup}")
}

backup_path() {
  local target=$1 relative backup
  if [[ -z "${backup_root}" ]]; then
    backup_root="${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p -- "${backup_root}"
  fi
  relative=${target#"${HOME}/"}
  backup="${backup_root}/${relative}"
  mkdir -p -- "${backup:h}"
  mv -- "${target}" "${backup}"
  stashed_paths+=("${target}")
  stashed_backups+=("${backup}")
}

restore_stashed() {
  local exit_status=$? index target backup failed=0
  (( exit_status == 0 )) && return
  for (( index = ${#stashed_paths}; index >= 1; index-- )); do
    target=${stashed_paths[index]}
    backup=${stashed_backups[index]}
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
      mkdir -p -- "${target:h}"
      mv -- "${backup}" "${target}" || failed=1
    else
      failed=1
    fi
  done
  if (( failed )); then
    jsh_error "Deployment recovery is incomplete; moved files remain in Jsh backup storage"
  else
    [[ -z "${recovery_dir}" ]] || rm -rf -- "${recovery_dir}"
    [[ -z "${backup_root}" ]] || rm -rf -- "${backup_root}"
  fi
}
trap restore_stashed EXIT

if [[ ! -d "${dotfiles_dir}" ]]; then
  jsh_error "Dotfiles directory not found: ${dotfiles_dir}"
  exit 1
fi
if [[ ! -d "${commands_dir}" ]]; then
  jsh_error "Commands directory not found: ${commands_dir}"
  exit 1
fi

jsh_detail "This will back up conflicting paths and deploy managed dotfiles into ${HOME}."
if [[ ${JSH_ASSUME_YES:-0} != 1 ]]; then
  jsh_prompt "Continue? [Y/n]: "
  if ! read -r confirm; then
    confirm=
  fi
  if [[ -n "${confirm}" && "${confirm}" != [Yy] ]]; then
    jsh_note "Skipping dotfile deployment."
    exit 0
  fi
fi

jsh_info "Checking for legacy Jsh symlinks..."
while IFS= read -r -d $'\0' link; do
  target=$(readlink "${link}")
  [[ "${target}" == /* ]] || target="${link:h}/${target}"
  target=${target:a}
  home_relative=${link#"${HOME}/"}
  repo_relative=${target#"${repo_root}/"}

  if [[ "${target}" == "${dotfiles_dir}/${home_relative}" ]] || \
    { [[ "${target}" == "${repo_root}"/* ]] && [[ "${home_relative}" == "${repo_relative}" ]]; }; then
    jsh_info "Removing managed symlink: ${link}"
    stash_path "${link}"
  fi
done < <(
  find "${HOME}" -maxdepth 3 \
    \( -path "${repo_root}" -o -path "${HOME}/Library" -o -path "${HOME}/.Trash" \) -prune -o \
    -type l -print0 2> /dev/null
)

typeset -a jstow_args
jstow_args=(--restow --dir "${repo_root}" --target "${HOME}")

while IFS= read -r -d $'\0' source; do
  relative=${source#"${dotfiles_dir}/"}
  target="${HOME}/${relative}"

  if [[ -L "${target}" ]]; then
    destination=$(readlink "${target}")
    [[ "${destination}" == /* ]] || destination="${target:h}/${destination}"
    [[ "${destination:a}" == "${source:a}" ]] && continue
  fi
  if [[ -e "${target}" || -L "${target}" ]]; then
    jsh_warn "Backing up unmanaged path: ${target}"
    backup_path "${target}"
  fi
done < <(find "${dotfiles_dir}" \( -type f -o -type l \) -print0)

"${commands_dir}/jstow" "${jstow_args[@]}" dotfiles

if [[ -e "${commands_link}" || -L "${commands_link}" ]]; then
  if [[ -L "${commands_link}" ]]; then
    target=$(readlink "${commands_link}")
    [[ "${target}" == /* ]] || target="${commands_link:h}/${target}"
    target=${target:a}
  else
    target=
  fi
  if [[ "${target}" != "${commands_dir}" ]]; then
    jsh_warn "Preserving unmanaged path: ${commands_link}"
  fi
else
  jsh_info "Linking command directory: ${commands_link}"
  ln -s -- "${commands_dir}" "${commands_link}"
fi
if [[ -n "${recovery_dir}" ]]; then
  rm -rf -- "${recovery_dir}"
fi
if [[ -n "${backup_root}" ]]; then
  jsh_detail "Backups: ${backup_root}"
fi
jsh_success "Dotfiles deployed successfully"
