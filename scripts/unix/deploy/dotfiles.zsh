#!/usr/bin/env zsh
# Deploy managed dotfiles and command links.

set -eu
unsetopt monitor

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
commands_link_created=0
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
  if (( commands_link_created )); then
    if [[ -L "${commands_link}" && "${commands_link:A}" == "${commands_dir:A}" ]]; then
      rm -- "${commands_link}" || failed=1
    else
      failed=1
    fi
  fi
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
    jsh::log_error "Deployment recovery is incomplete; moved files remain in Jsh backup storage"
  else
    [[ -z "${recovery_dir}" ]] || rm -rf -- "${recovery_dir}"
    [[ -z "${backup_root}" ]] || rm -rf -- "${backup_root}"
  fi
}
trap restore_stashed EXIT

if [[ ! -d "${dotfiles_dir}" ]]; then
  jsh::log_error "Dotfiles directory not found: ${dotfiles_dir}"
  exit 1
fi
if [[ ! -d "${commands_dir}" ]]; then
  jsh::log_error "Commands directory not found: ${commands_dir}"
  exit 1
fi

for arg in "$@"; do
  case "${arg}" in
    -y | --yes) JSH_ASSUME_YES=1 ;;
  esac
done

jsh::log_detail "This will back up conflicting paths and deploy managed dotfiles into ${HOME}."
if ! jsh::confirm "Continue?" --default yes; then
  jsh::log_note "Skipping dotfile deployment."
  exit 0
fi

jsh::log_info "Checking for legacy Jsh symlinks..."
typeset -a dotfile_sources
while IFS= read -r -d $'\0' link; do
  [[ -n "${link}" ]] || continue
  target=$(readlink "${link}")
  [[ "${target}" == /* ]] || target="${link:h}/${target}"
  target=${target:a}
  home_relative=${link#"${HOME}/"}
  repo_relative=${target#"${repo_root}/"}

  [[ "${target}" != "${dotfiles_dir}/${home_relative}" ]] || continue
  if [[ "${target}" == "${repo_root}"/* && "${home_relative}" == "${repo_relative}" ]]; then
    jsh::log_info "Removing managed symlink: ${link}"
    stash_path "${link}"
  fi
done < <(
  find "${HOME}" -maxdepth 3 \
    \( -path "${repo_root}" -o -path "${HOME}/Library" -o -path "${HOME}/.Trash" \) -prune -o \
    -type l -print0 2> /dev/null
)

typeset -a jstow_args
jstow_args=(
  --restow
  --dir "${repo_root}"
  --target "${HOME}"
  '--ignore=(^|/)[.]zcompdump([.-].*)?$'
)

if git -C "${repo_root}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  while IFS= read -r -d $'\0' source; do
    dotfile_sources+=("${repo_root}/${source}")
  done < <(git -C "${repo_root}" ls-files --cached --others --exclude-standard -z -- dotfiles)

  while IFS= read -r -d $'\0' ignored; do
    ignored=${ignored#dotfiles/}
    ignored=${ignored%/}
    ignored=$(printf '%s' "${ignored}" | sed 's/[][\.^$*+?(){}|]/\\&/g')
    jstow_args+=("--ignore=^${ignored}(/.*)?$")
  done < <(git -C "${repo_root}" ls-files --others --ignored --exclude-standard --directory -z -- dotfiles)
else
  dotfile_sources=(${(0)"$(find "${dotfiles_dir}" \( -type f -o -type l \) -print0)"})
fi

for source in "${dotfile_sources[@]}"; do
  [[ -n "${source}" ]] || continue
  relative=${source#"${dotfiles_dir}/"}
  [[ ${relative} != .zcompdump && ${relative} != .zcompdump[.-]* ]] || continue
  target="${HOME}/${relative}"

  # Stow may link a parent directory; its children already are the source files.
  [[ ! -e "${target}" || ! "${target}" -ef "${source}" ]] || continue

  if [[ -L "${target}" ]]; then
    destination=$(readlink "${target}")
    [[ "${destination}" == /* ]] || destination="${target:h}/${destination}"
    [[ "${destination:a}" == "${source:a}" ]] && continue
  fi
  if [[ -e "${target}" || -L "${target}" ]]; then
    jsh::log_warn "Backing up unmanaged path: ${target}"
    backup_path "${target}"
  fi
done

if [[ -e "${commands_link}" || -L "${commands_link}" ]]; then
  if [[ -L "${commands_link}" ]]; then
    target=$(readlink "${commands_link}")
    [[ "${target}" == /* ]] || target="${commands_link:h}/${target}"
    target=${target:a}
  else
    target=
  fi
  if [[ "${target}" != "${commands_dir}" ]]; then
    jsh::log_warn "Preserving unmanaged path: ${commands_link}"
  fi
else
  jsh::log_info "Linking command directory: ${commands_link}"
  ln -s -- "${commands_dir}" "${commands_link}"
  commands_link_created=1
fi

"${commands_dir}/jstow" "${jstow_args[@]}" dotfiles

if [[ -n "${recovery_dir}" ]]; then
  rm -rf -- "${recovery_dir}"
fi
if [[ -n "${backup_root}" ]]; then
  jsh::log_detail "Backups: ${backup_root}"
fi
jsh::log_success "Dotfiles deployed successfully"
