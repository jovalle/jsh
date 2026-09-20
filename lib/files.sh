#!/usr/bin/env bash
# Safely converge managed files without overwriting user-owned links.

jsh_file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

jsh_approve_broken_symlink() {
  local path=$1
  printf 'Broken symlink detected: %s\n' "${path}" >&2
  if [[ ${JSH_CONFIGURE_DRY_RUN:-0} == 1 || ${JSH_INSTALL_DRY_RUN:-0} == 1 ||
    ${JSH_CONFIGURE_ASSUME_YES:-${JSH_ASSUME_YES:-0}} == 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    printf 'Non-interactive setup cannot replace it without --yes.\n' >&2
    return 1
  fi
  JSH_NON_INTERACTIVE=0 JSH_INTERACTIVE=1 \
    jsh::confirm 'Replace it with the managed file?' --default yes
}

jsh_backup_managed_file() {
  local path=$1 backup_root backup_dir relative relative_parent
  backup_root=${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/backups
  mkdir -p -- "${backup_root}"
  chmod 0700 "${backup_root}"
  backup_dir=$(mktemp -d "${backup_root}/managed.XXXXXXXXXX") || return
  relative=${path#/}
  relative_parent=$(dirname -- "${relative}")
  mkdir -p -- "${backup_dir}/${relative_parent}"
  cp -p -- "${path}" "${backup_dir}/${relative}"
  chmod 0600 "${backup_dir}/${relative}"
  jsh::log_detail "Backup: ${backup_dir}/${relative}"
}

jsh_ensure_file() {
  local target=$1 source=$2 mode=${3:-0644} temporary
  local dry_run=${JSH_CONFIGURE_DRY_RUN:-${JSH_INSTALL_DRY_RUN:-0}}

  [[ -r ${source} ]] || {
    jsh::log_error "Managed file source is unreadable: ${source}"
    return 1
  }
  if [[ -L ${target} ]]; then
    if [[ -e ${target} ]]; then
      if cmp -s -- "${source}" "${target}"; then
        return 1
      fi
      jsh::log_error "Refusing to replace an unmanaged symlink: ${target}"
      return 2
    fi
    jsh_approve_broken_symlink "${target}" || return 1
    if [[ ${dry_run} == 1 ]]; then
      jsh::log_detail "Would replace broken symlink: ${target}"
      return 0
    fi
    jsh::log_detail "Replacing broken symlink: ${target}"
    rm -- "${target}"
  fi
  if [[ -f ${target} ]] && cmp -s -- "${source}" "${target}" &&
    [[ $(jsh_file_mode "${target}") == "${mode#0}" ]]; then
    return 1
  fi
  if [[ ${dry_run} == 1 ]]; then
    jsh::log_detail "Would write ${target}"
    return 0
  fi

  mkdir -p -- "${target%/*}"
  [[ ! -e ${target} ]] || jsh_backup_managed_file "${target}"
  temporary=$(mktemp "${target%/*}/.jsh.XXXXXXXXXX") || return
  declare -F jsh_interrupt_cleanup_path >/dev/null && jsh_interrupt_cleanup_path "${temporary}"
  if ! install -m "${mode}" -- "${source}" "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  mv -f -- "${temporary}" "${target}"
  jsh::log_detail "Writing ${target}"
}

jsh_desktop_executable() {
  local value=$1
  if [[ ${value} =~ ^[/A-Za-z0-9_.+-]+$ ]]; then
    printf '%s\n' "${value}"
    return
  fi
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\`/\\\`}
  value=${value//\$/\\\$}
  printf '"%s"\n' "${value}"
}
