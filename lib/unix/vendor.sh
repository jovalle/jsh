#!/bin/sh
# Clone missing repositories from conf/vendor.list; with --update, fast-forward them to upstream HEAD.

set -eu

usage='usage: vendor.sh [--update] [--dry-run] JSH_ROOT'
update=0
dry_run=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --update) update=1 ;;
    --dry-run) dry_run=1 ;;
    -*)
      printf '%s\n' "${usage}" >&2
      exit 2
      ;;
    *) break ;;
  esac
  shift
done
root=$(CDPATH='' cd -P "${1:?${usage}}" && pwd -P)
# shellcheck source=lib/output.sh
. "${root}/lib/output.sh"

# Former submodule checkouts keep their Git directory in the superproject; move it into the checkout.
adopt() {
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir) &&
    mv -- "${gitdir}" "$1/.git.jsh-adopt" &&
    rm -f -- "$1/.git" &&
    mv -- "$1/.git.jsh-adopt" "$1/.git" &&
    git config --file "$1/.git/config" --unset core.worktree
}

# An old submodule may have lost its Git metadata during removal. Clone into a
# staging directory first, then keep the original checkout as a backup.
restore_broken_checkout() {
  mkdir -p "${root}/tmp" || return 1
  stage=$(mktemp -d "${root}/tmp/vendor-stage.XXXXXX") || return 1
  if ! git clone --quiet --depth 1 -- "${url}" "${stage}/repo" < /dev/null; then
    rm -rf -- "${stage}"
    return 1
  fi
  if [ -z "${backup_root}" ]; then
    backup_root=$(mktemp -d "${root}/tmp/vendor-backup.XXXXXX") || return 1
  fi
  backup_target=${backup_root}/${dir}
  mkdir -p "$(dirname "${backup_target}")" || return 1
  mv -- "${target}" "${backup_target}" || return 1
  if ! mv -- "${stage}/repo" "${target}"; then
    mv -- "${backup_target}" "${target}" || jsh_error "Restore ${dir} from ${backup_target} manually."
    return 1
  fi
  rmdir -- "${stage}"
  jsh_warn "Saved previous ${dir} at ${backup_target}."
  jsh_success "Restored ${dir}"
}

failed=0
backup_root=
while read -r dir url <&3; do
  case ${dir} in '' | '#'*) continue ;; esac
  target=${root}/${dir}

  if [ ! -e "${target}/.git" ]; then
    if [ "${dry_run}" -eq 1 ]; then
      jsh_detail "Would clone ${dir}"
    else
      jsh_info "Cloning ${dir}..."
      git clone --quiet --depth 1 -- "${url}" "${target}" < /dev/null || failed=1
    fi
    continue
  fi

  if ! checkout_root=$(git -C "${target}" rev-parse --show-toplevel 2> /dev/null) ||
    [ "${checkout_root}" != "$(CDPATH='' cd -P "${target}" && pwd -P)" ]; then
    if [ "${dry_run}" -eq 1 ]; then
      jsh_detail "Would back up and reclone ${dir} (broken Git metadata)"
    elif ! restore_broken_checkout; then
      jsh_error "Could not restore ${dir}; its checkout was preserved."
      failed=1
    fi
    continue
  fi

  if [ -f "${target}/.git" ]; then
    if [ "${dry_run}" -eq 1 ]; then
      jsh_detail "Would convert ${dir} from a submodule"
    elif ! adopt "${target}"; then
      jsh_error "Could not convert ${dir} from a submodule."
      failed=1
      continue
    fi
  fi

  [ "${update}" -eq 1 ] || continue
  head=$(git -C "${target}" rev-parse HEAD) || {
    failed=1
    continue
  }
  if [ "${dry_run}" -eq 1 ]; then
    remote=$(git ls-remote -- "${url}" HEAD < /dev/null) || {
      failed=1
      continue
    }
    [ "${remote%%[[:space:]]*}" = "${head}" ] || jsh_detail "Would update ${dir}"
    continue
  fi
  # reset --keep refuses to overwrite local edits, so dirty checkouts stay put.
  if git -C "${target}" remote set-url origin "${url}" &&
    git -C "${target}" fetch --quiet --depth 1 origin HEAD < /dev/null &&
    git -C "${target}" reset --quiet --keep FETCH_HEAD; then
    [ "$(git -C "${target}" rev-parse HEAD)" = "${head}" ] || jsh_success "Updated ${dir}"
  else
    jsh_warn "Could not update ${dir}; it stays at ${head}."
    failed=1
  fi
done 3< "${root}/conf/vendor.list"

exit "${failed}"
