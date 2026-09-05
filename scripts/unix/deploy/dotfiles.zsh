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
    jsh_error "Deployment recovery is incomplete; backups remain in ${recovery_dir}"
  elif [[ -n "${recovery_dir}" ]]; then
    rm -rf -- "${recovery_dir}"
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

jsh_info "This will deploy managed dotfiles into ${HOME}."
jsh_prompt "Continue? [y/N]: "
if ! read -r confirm; then
  confirm=
fi
if [[ "${confirm}" != [Yy] ]]; then
  jsh_warn "Skipping dotfile deployment."
  exit 0
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
    \( -path "${repo_root}" -o -path "${HOME}/Library" \) -prune -o \
    -type l -print0
)

typeset -a jstow_args
jstow_args=(--restow --dir "${repo_root}" --target "${HOME}")

while IFS= read -r -d $'\0' source; do
  relative=${source#"${dotfiles_dir}/"}
  target="${HOME}/${relative}"

  if [[ -e "${target}" && ! -L "${target}" ]]; then
    if [[ -f "${source}" && -f "${target}" ]] && cmp -s "${source}" "${target}"; then
      jsh_info "Removing identical copy: ${target}"
      stash_path "${target}"
    else
      pattern=$(print -r -- "${relative}" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
      jsh_warn "Preserving unmanaged file: ${target}"
      jstow_args+=("--ignore=^${pattern}$")
    fi
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
jsh_success "Dotfiles deployed successfully"
