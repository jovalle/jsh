#!/usr/bin/env bash

_jgit_backup_require() {
  command -v "$1" > /dev/null 2>&1 || _jgit_die "required command not found: $1"
}

_jgit_backup_confirm() {
  JSH_ASSUME_YES=0 JSH_NON_INTERACTIVE=0 JSH_INTERACTIVE=1 \
    jsh::confirm "$1" --default "${2:-no}"
}

_jgit_backup_authenticate() {
  local auth_status
  _jgit_backup_require gh
  auth_status=$(LC_ALL=C gh auth status 2>&1) || {
    printf '%s\n' "${auth_status}" >&2
    _jgit_backup_confirm 'Authenticate GitHub CLI for secret gist backups?' yes ||
      _jgit_die 'GitHub CLI authentication is required'
    gh auth login --scopes gist || _jgit_die 'GitHub CLI authentication failed'
    auth_status=$(LC_ALL=C gh auth status 2>&1) || _jgit_die 'GitHub CLI authentication failed'
  }

  if grep -q 'Token scopes:' <<< "${auth_status}" &&
    ! grep -Eq "Token scopes:.*['\", ]gist['\", ]" <<< "${auth_status}"; then
    _jgit_backup_confirm 'Grant GitHub CLI gist access?' yes ||
      _jgit_die 'the active GitHub CLI token requires gist access'
    gh auth refresh --scopes gist || _jgit_die 'could not grant GitHub CLI gist access'
  fi
}

_jgit_backup_normalize_origin() {
  local origin=$1 authority host repository
  [[ ${origin} != *$'\n'* ]] || return 1
  case ${origin} in
    *://*)
      repository=${origin#*://}
      authority=${repository%%/*}
      repository=${repository#*/}
      host=${authority##*@}
      ;;
    *@*:* | [[:alnum:]._-]*:*)
      authority=${origin%%:*}
      repository=${origin#*:}
      host=${authority##*@}
      ;;
    *)
      printf '%s\n' "${origin%/}"
      return
      ;;
  esac
  host=$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')
  repository=${repository#/}
  repository=${repository%/}
  repository=${repository%.git}
  [[ -n ${host} && -n ${repository} ]] || return 1
  case ${host} in
    github.com | github.com:22 | github.com:443)
      host=github.com
      repository=$(printf '%s' "${repository}" | tr '[:upper:]' '[:lower:]')
      ;;
  esac
  printf '%s/%s\n' "${host}" "${repository}"
}

_jgit_backup_repository_context() {
  JGIT_BACKUP_ROOT=$(git rev-parse --show-toplevel 2> /dev/null) ||
    _jgit_die 'not in a Git repository'
  git rev-parse --verify HEAD > /dev/null 2>&1 || _jgit_die 'backup requires at least one commit'
  JGIT_BACKUP_ORIGIN=$(git remote get-url origin 2> /dev/null) ||
    _jgit_die 'backup requires an origin remote'
  JGIT_BACKUP_IDENTITY=$(_jgit_backup_normalize_origin "${JGIT_BACKUP_ORIGIN}") ||
    _jgit_die 'could not normalize the origin URL'
  JGIT_BACKUP_REPOSITORY_ID=$(printf 'jgit-backup-v1\0%s' "${JGIT_BACKUP_IDENTITY}" |
    git hash-object --stdin)
  JGIT_BACKUP_LABEL=${JGIT_BACKUP_IDENTITY##*/}
  JGIT_BACKUP_DESCRIPTION="jgit-backup:v1:${JGIT_BACKUP_REPOSITORY_ID}:${JGIT_BACKUP_LABEL}"
}

_jgit_backup_parse_excludes() {
  local argument exclude existing
  JGIT_BACKUP_EXCLUDES=()
  while (($#)); do
    argument=$1
    case ${argument} in
      --exclude)
        (($# >= 2)) || _jgit_die '--exclude requires a path'
        exclude=$2
        shift 2
        ;;
      --exclude=*)
        exclude=${argument#*=}
        shift
        ;;
      -h | --help)
        printf 'Usage: jgit %s [--exclude PATH]...\n' "${JGIT_BACKUP_ACTION}"
        return 2
        ;;
      *) _jgit_die "unknown ${JGIT_BACKUP_ACTION} option: ${argument}" ;;
    esac

    case ${exclude} in
      "${JGIT_BACKUP_ROOT}"/*) exclude=${exclude#"${JGIT_BACKUP_ROOT}"/} ;;
      /*) _jgit_die "excluded path is outside the repository: ${exclude}" ;;
    esac
    while [[ ${exclude} == ./* ]]; do exclude=${exclude#./}; done
    while [[ ${exclude} == */ ]]; do exclude=${exclude%/}; done
    [[ -n ${exclude} && ${exclude} != . && ${exclude} != .. &&
      ${exclude} != ../* && ${exclude} != */../* && ${exclude} != */.. ]] ||
      _jgit_die "invalid excluded path: ${exclude:-<empty>}"
    [[ ${exclude} != *$'\n'* ]] || _jgit_die 'excluded paths cannot contain newlines'

    for existing in "${JGIT_BACKUP_EXCLUDES[@]}"; do
      [[ ${existing} == "${exclude}" ]] && continue 2
    done
    JGIT_BACKUP_EXCLUDES+=("${exclude}")
  done
}

_jgit_backup_map_excludes() {
  local repository_path=$1 exclude local_exclude existing
  JGIT_BACKUP_LOCAL_EXCLUDES=()
  JGIT_BACKUP_SKIP_REPOSITORY=0
  for exclude in "${JGIT_BACKUP_EXCLUDES[@]}"; do
    if [[ -z ${repository_path} ]]; then
      local_exclude=${exclude}
    elif [[ ${exclude} == "${repository_path}" || ${repository_path} == "${exclude}"/* ]]; then
      JGIT_BACKUP_SKIP_REPOSITORY=1
      return
    elif [[ ${exclude} == "${repository_path}"/* ]]; then
      local_exclude=${exclude#"${repository_path}"/}
    else
      continue
    fi
    for existing in "${JGIT_BACKUP_LOCAL_EXCLUDES[@]}"; do
      [[ ${existing} == "${local_exclude}" ]] && continue 2
    done
    JGIT_BACKUP_LOCAL_EXCLUDES+=("${local_exclude}")
  done
}

_jgit_backup_build_pathspecs() {
  local exclude
  JGIT_BACKUP_PATHS=(-- .)
  for exclude in "${JGIT_BACKUP_LOCAL_EXCLUDES[@]}"; do
    JGIT_BACKUP_PATHS+=(":(top,literal,exclude)${exclude}")
  done
}

_jgit_backup_capture_repository() {
  local repository=$1 repository_path=$2 destination=$3 preview=$4 summary=$5 untracked
  _jgit_backup_map_excludes "${repository_path}"
  ((JGIT_BACKUP_SKIP_REPOSITORY == 0)) || return 0
  _jgit_backup_preflight_repository "${repository}" "${repository_path}" ||
    _jgit_die "cannot save unresolved conflicts in ${repository_path:-the main repository}"
  _jgit_backup_build_pathspecs

  git -C "${repository}" diff --cached --binary --full-index \
    "${JGIT_BACKUP_PATHS[@]}" > "${destination}/staged.patch"
  git -C "${repository}" diff HEAD --binary --full-index --ignore-submodules=dirty \
    "${JGIT_BACKUP_PATHS[@]}" > "${destination}/tracked.patch"
  git -C "${repository}" ls-files --others --exclude-standard -z \
    "${JGIT_BACKUP_PATHS[@]}" > "${destination}/untracked.list"
  if [[ -s ${destination}/untracked.list ]]; then
    tar -czf "${destination}/untracked.tar.gz" -C "${repository}" \
      --null -T "${destination}/untracked.list"
  fi

  if [[ -s ${destination}/staged.patch || -s ${destination}/tracked.patch ||
    -s ${destination}/untracked.list ]]; then
    JGIT_BACKUP_HAS_CHANGES=1
  fi

  {
    printf '\n[%s]\n' "${repository_path:-main repository}"
    git -C "${repository}" diff --cached --stat "${JGIT_BACKUP_PATHS[@]}"
    git -C "${repository}" diff --stat --ignore-submodules=dirty "${JGIT_BACKUP_PATHS[@]}"
    while IFS= read -r -d '' untracked; do
      [[ ${untracked} != *$'\n'* ]] || _jgit_die 'untracked paths containing newlines are unsupported'
      printf ' untracked | %s\n' "${untracked}"
    done < "${destination}/untracked.list"
  } >> "${summary}"

  {
    printf '\n# %s: staged\n' "${repository_path:-main repository}"
    git -C "${repository}" diff --cached --no-ext-diff --no-color "${JGIT_BACKUP_PATHS[@]}"
    printf '\n# %s: unstaged\n' "${repository_path:-main repository}"
    git -C "${repository}" diff --no-ext-diff --no-color --ignore-submodules=dirty \
      "${JGIT_BACKUP_PATHS[@]}"
  } >> "${preview}"
}

_jgit_backup_write_manifest() {
  local destination=$1 created=$2 exclude
  {
    printf 'format=2\n'
    printf 'repository=%s\n' "${JGIT_BACKUP_REPOSITORY_ID}"
    printf 'origin=%s\n' "${JGIT_BACKUP_IDENTITY}"
    printf 'head=%s\n' "$(git -C "${JGIT_BACKUP_ROOT}" rev-parse HEAD)"
    printf 'created=%s\n' "${created}"
    for exclude in "${JGIT_BACKUP_EXCLUDES[@]}"; do
      printf 'exclude=%s\n' "${exclude}"
    done
  } > "${destination}"
}

_jgit_backup_metadata_field() {
  local metadata=$1 field=$2
  awk -F= -v wanted="${field}" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "${metadata}"
}

_jgit_backup_validate_gist() {
  local gist_id=$1 metadata
  metadata=${JGIT_BACKUP_WORK_DIR}/metadata-${gist_id}
  [[ ${gist_id} =~ ^[[:xdigit:]]+$ ]] || return 1
  gh gist view "${gist_id}" --filename jgit-backup.txt --raw > "${metadata}" 2> /dev/null || return 1
  [[ $(_jgit_backup_metadata_field "${metadata}" format) == 2 &&
    $(_jgit_backup_metadata_field "${metadata}" repository) == "${JGIT_BACKUP_REPOSITORY_ID}" ]]
}

_jgit_backup_discover_gists() {
  local listing=${JGIT_BACKUP_WORK_DIR}/gists.list gist_id updated description
  JGIT_BACKUP_GIST_IDS=()
  JGIT_BACKUP_GIST_UPDATED=()
  gh api --paginate 'gists?per_page=100' \
    --jq '.[] | [.id, .updated_at, .description] | @tsv' > "${listing}" ||
    _jgit_die 'could not list GitHub gists'
  while IFS=$'\t' read -r gist_id updated description; do
    [[ ${gist_id} =~ ^[[:xdigit:]]+$ &&
      ${description} == "${JGIT_BACKUP_DESCRIPTION}" ]] || continue
    JGIT_BACKUP_GIST_IDS+=("${gist_id}")
    JGIT_BACKUP_GIST_UPDATED+=("${updated}")
  done < "${listing}"
}

_jgit_backup_select_gist() {
  local index gist_id metadata created head selected
  local -a choices=()
  ((${#JGIT_BACKUP_GIST_IDS[@]} > 0)) || return 1
  if ((${#JGIT_BACKUP_GIST_IDS[@]} == 1)); then
    JGIT_BACKUP_SELECTED_GIST=${JGIT_BACKUP_GIST_IDS[0]}
    return
  fi

  index=0
  for gist_id in "${JGIT_BACKUP_GIST_IDS[@]}"; do
    metadata=${JGIT_BACKUP_WORK_DIR}/metadata-${gist_id}
    if [[ ! -s ${metadata} ]]; then
      gh gist view "${gist_id}" --filename jgit-backup.txt --raw > "${metadata}" 2> /dev/null || true
    fi
    created=$(_jgit_backup_metadata_field "${metadata}" created)
    head=$(_jgit_backup_metadata_field "${metadata}" head)
    choices+=("${gist_id}" "${created:-${JGIT_BACKUP_GIST_UPDATED[index]}}  ${gist_id}  ${head:-unknown}")
    index=$((index + 1))
  done
  selected=$(jsh::choose_one 'Applicable backups' "${choices[@]}") || return
  JGIT_BACKUP_SELECTED_GIST=${selected}
}

_jgit_backup_resolve_save_gist() {
  local configured
  configured=$(git -C "${JGIT_BACKUP_ROOT}" config --local --get jsh.backupGist 2> /dev/null || true)
  if [[ -n ${configured} ]] && _jgit_backup_validate_gist "${configured}"; then
    JGIT_BACKUP_SELECTED_GIST=${configured}
    return
  fi
  if [[ -n ${configured} ]]; then
    jsh::log_warn "Configured backup gist is unavailable or belongs to another repository: ${configured}"
    git -C "${JGIT_BACKUP_ROOT}" config --local --unset-all jsh.backupGist 2> /dev/null || true
  fi

  _jgit_backup_discover_gists
  ((${#JGIT_BACKUP_GIST_IDS[@]} > 0)) || {
    JGIT_BACKUP_SELECTED_GIST=
    return
  }
  _jgit_backup_select_gist || _jgit_die 'backup selection cancelled'
}

_jgit_backup_publish() {
  local payload=$1 gist_url gist_id
  _jgit_backup_resolve_save_gist
  gist_id=${JGIT_BACKUP_SELECTED_GIST}
  if [[ -z ${gist_id} ]]; then
    gist_url=$(gh gist create --desc "${JGIT_BACKUP_DESCRIPTION}" \
      "${payload}/jgit-backup.snapshot.b64" \
      "${payload}/jgit-backup.diff" \
      "${payload}/jgit-backup.txt") || _jgit_die 'could not create backup gist'
    gist_id=${gist_url##*/}
    [[ ${gist_id} =~ ^[[:xdigit:]]+$ ]] || _jgit_die 'GitHub CLI did not return a gist ID'
  else
    gh api --method PATCH "gists/${gist_id}" --silent \
      -f "description=${JGIT_BACKUP_DESCRIPTION}" \
      -F "files[jgit-backup.snapshot.b64][content]=@${payload}/jgit-backup.snapshot.b64" \
      -F "files[jgit-backup.diff][content]=@${payload}/jgit-backup.diff" \
      -F "files[jgit-backup.txt][content]=@${payload}/jgit-backup.txt" ||
      _jgit_die 'could not atomically update backup gist'
    _jgit_backup_validate_gist "${gist_id}" || _jgit_die 'could not verify updated backup gist'
  fi
  git -C "${JGIT_BACKUP_ROOT}" config --local jsh.backupGist "${gist_id}"
  JGIT_BACKUP_SELECTED_GIST=${gist_id}
}

_jgit_backup_save() {
  local created snapshot payload archive submodule_list submodule_path submodule_number=0
  local submodule_id submodule_dir archive_hash
  JGIT_BACKUP_ACTION=save
  _jgit_backup_repository_context
  _jgit_backup_parse_excludes "$@" || {
    [[ $? == 2 ]] && return
    return 1
  }
  _jgit_backup_require base64
  _jgit_backup_require tar
  _jgit_backup_authenticate

  JGIT_BACKUP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jgit-backup.XXXXXX") ||
    _jgit_die 'could not create a temporary directory'
  trap 'rm -rf "${JGIT_BACKUP_WORK_DIR}"' RETURN EXIT
  snapshot=${JGIT_BACKUP_WORK_DIR}/snapshot
  payload=${JGIT_BACKUP_WORK_DIR}/payload
  mkdir -p "${snapshot}/main" "${snapshot}/submodules" "${payload}"
  created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  _jgit_backup_write_manifest "${snapshot}/manifest" "${created}"
  cp "${snapshot}/manifest" "${payload}/jgit-backup.txt"
  printf 'Jgit uncommitted worktree backup\n' > "${payload}/jgit-backup.diff"
  printf 'Changes included in this backup:\n' > "${snapshot}/summary"

  JGIT_BACKUP_HAS_CHANGES=0
  _jgit_backup_capture_repository "${JGIT_BACKUP_ROOT}" '' "${snapshot}/main" \
    "${payload}/jgit-backup.diff" "${snapshot}/summary"

  submodule_list=${JGIT_BACKUP_WORK_DIR}/submodules.list
  git -C "${JGIT_BACKUP_ROOT}" submodule foreach --quiet --recursive \
    "printf '%s\\0' \"\$displaypath\"" > "${submodule_list}"
  while IFS= read -r -d '' submodule_path; do
    [[ ${submodule_path} != *$'\n'* ]] || _jgit_die 'submodule paths containing newlines are unsupported'
    _jgit_backup_map_excludes "${submodule_path}"
    ((JGIT_BACKUP_SKIP_REPOSITORY == 0)) || continue
    submodule_number=$((submodule_number + 1))
    printf -v submodule_id '%04d' "${submodule_number}"
    submodule_dir=${snapshot}/submodules/${submodule_id}
    mkdir -p "${submodule_dir}"
    printf '%s\n' "${submodule_path}" > "${submodule_dir}/path"
    git -C "${JGIT_BACKUP_ROOT}/${submodule_path}" rev-parse HEAD > "${submodule_dir}/head"
    _jgit_backup_capture_repository "${JGIT_BACKUP_ROOT}/${submodule_path}" "${submodule_path}" \
      "${submodule_dir}" "${payload}/jgit-backup.diff" "${snapshot}/summary"
  done < "${submodule_list}"

  if ((JGIT_BACKUP_HAS_CHANGES == 0)); then
    jsh::log_note 'No uncommitted changes matched the backup path set'
    return
  fi
  cat "${snapshot}/summary" >> "${payload}/jgit-backup.txt"
  archive=${JGIT_BACKUP_WORK_DIR}/jgit-backup.snapshot.tar.gz
  tar -czf "${archive}" -C "${snapshot}" .
  archive_hash=$(git hash-object --no-filters "${archive}")
  printf 'archive=%s\n' "${archive_hash}" >> "${payload}/jgit-backup.txt"
  base64 < "${archive}" > "${payload}/jgit-backup.snapshot.b64"

  _jgit_backup_publish "${payload}"
  jsh::log_success "Saved uncommitted changes to secret gist ${JGIT_BACKUP_SELECTED_GIST}"
}

_jgit_backup_discover_valid_gists() {
  local gist_id updated index=0
  local -a discovered_ids discovered_updated
  _jgit_backup_discover_gists
  discovered_ids=("${JGIT_BACKUP_GIST_IDS[@]}")
  discovered_updated=("${JGIT_BACKUP_GIST_UPDATED[@]}")
  JGIT_BACKUP_GIST_IDS=()
  JGIT_BACKUP_GIST_UPDATED=()
  for gist_id in "${discovered_ids[@]}"; do
    updated=${discovered_updated[index]:-}
    if _jgit_backup_validate_gist "${gist_id}"; then
      JGIT_BACKUP_GIST_IDS+=("${gist_id}")
      JGIT_BACKUP_GIST_UPDATED+=("${updated}")
    fi
    index=$((index + 1))
  done
}

_jgit_backup_decode() {
  local encoded=$1 archive=$2
  if base64 --decode < "${encoded}" > "${archive}" 2> /dev/null; then
    return
  fi
  base64 -D < "${encoded}" > "${archive}" 2> /dev/null
}

_jgit_backup_validate_archive_paths() {
  local archive=$1 listing=$2 entry
  tar -tzf "${archive}" > "${listing}" || return 1
  if LC_ALL=C sort "${listing}" | uniq -d | grep -q .; then
    return 1
  fi
  while IFS= read -r entry; do
    entry=${entry#./}
    case ${entry} in
      /* | .. | ../* | */../* | */..) return 1 ;;
    esac
  done < "${listing}"
}

_jgit_backup_validate_archive_types() {
  local archive=$1 allowed=$2 listing=$3 line member_type
  tar -tvzf "${archive}" > "${listing}" || return 1
  while IFS= read -r line; do
    member_type=${line:0:1}
    case ${allowed}:${member_type} in
      snapshot:- | snapshot:d | untracked:- | untracked:l) ;;
      *) return 1 ;;
    esac
  done < "${listing}"
}

_jgit_backup_validate_snapshot_archive() {
  local archive=$1 listing=${JGIT_BACKUP_WORK_DIR}/archive.list entry
  _jgit_backup_validate_archive_paths "${archive}" "${listing}" || return 1
  _jgit_backup_validate_archive_types "${archive}" snapshot \
    "${JGIT_BACKUP_WORK_DIR}/archive-types.list" || return 1
  while IFS= read -r entry; do
    entry=${entry#./}
    case ${entry} in
      '' | main | main/ | main/staged.patch | main/tracked.patch | main/untracked.list | \
        main/untracked.tar.gz | submodules | submodules/ | manifest | summary) ;;
      submodules/[0-9][0-9][0-9][0-9] | submodules/[0-9][0-9][0-9][0-9]/ | \
        submodules/[0-9][0-9][0-9][0-9]/path | \
        submodules/[0-9][0-9][0-9][0-9]/head | \
        submodules/[0-9][0-9][0-9][0-9]/staged.patch | \
        submodules/[0-9][0-9][0-9][0-9]/tracked.patch | \
        submodules/[0-9][0-9][0-9][0-9]/untracked.list | \
        submodules/[0-9][0-9][0-9][0-9]/untracked.tar.gz) ;;
      *) return 1 ;;
    esac
  done < "${listing}"
}

_jgit_backup_validate_untracked_archive() {
  local archive=$1 untracked_list=$2 actual expected untracked
  actual=${JGIT_BACKUP_WORK_DIR}/untracked-archive.list
  expected=${JGIT_BACKUP_WORK_DIR}/untracked-expected.list
  _jgit_backup_validate_archive_paths "${archive}" "${actual}" || return 1
  _jgit_backup_validate_archive_types "${archive}" untracked \
    "${JGIT_BACKUP_WORK_DIR}/untracked-types.list" || return 1
  : > "${expected}"
  while IFS= read -r -d '' untracked; do
    [[ ${untracked} != *$'\n'* ]] || return 1
    printf '%s\n' "${untracked}" >> "${expected}"
  done < "${untracked_list}"
  LC_ALL=C sort -o "${actual}" "${actual}"
  LC_ALL=C sort -o "${expected}" "${expected}"
  cmp -s "${actual}" "${expected}"
}

_jgit_backup_validate_relative_path() {
  local relative_path=$1
  [[ -n ${relative_path} && ${relative_path} != *$'\n'* ]] || return 1
  case ${relative_path} in
    /* | . | .. | ./* | ../* | */../* | */..) return 1 ;;
  esac
}

_jgit_backup_validate_submodule_metadata() {
  local submodule_dir submodule_path submodule_head seen=${JGIT_BACKUP_WORK_DIR}/submodule-paths.list
  : > "${seen}"
  for submodule_dir in "${JGIT_BACKUP_SNAPSHOT}"/submodules/*; do
    [[ -d ${submodule_dir} ]] || continue
    [[ $(wc -l < "${submodule_dir}/path" | tr -d ' ') == 1 ]] || return 1
    [[ $(wc -l < "${submodule_dir}/head" | tr -d ' ') == 1 ]] || return 1
    submodule_path=$(< "${submodule_dir}/path")
    submodule_head=$(< "${submodule_dir}/head")
    _jgit_backup_validate_relative_path "${submodule_path}" || return 1
    [[ ${submodule_head} =~ ^[[:xdigit:]]{40}$ || ${submodule_head} =~ ^[[:xdigit:]]{64}$ ]] ||
      return 1
    grep -Fxq "${submodule_path}" "${seen}" && return 1
    printf '%s\n' "${submodule_path}" >> "${seen}"
  done
}

_jgit_backup_download() {
  local gist_id=$1 metadata encoded archive expected_hash actual_hash manifest
  metadata=${JGIT_BACKUP_WORK_DIR}/jgit-backup.txt
  encoded=${JGIT_BACKUP_WORK_DIR}/jgit-backup.snapshot.b64
  archive=${JGIT_BACKUP_WORK_DIR}/jgit-backup.snapshot.tar.gz
  JGIT_BACKUP_SNAPSHOT=${JGIT_BACKUP_WORK_DIR}/snapshot
  mkdir -p "${JGIT_BACKUP_SNAPSHOT}"

  gh gist view "${gist_id}" --filename jgit-backup.txt --raw > "${metadata}" ||
    _jgit_die 'could not download backup metadata'
  gh gist view "${gist_id}" --filename jgit-backup.snapshot.b64 --raw > "${encoded}" ||
    _jgit_die 'could not download backup snapshot'
  _jgit_backup_decode "${encoded}" "${archive}" || _jgit_die 'could not decode backup snapshot'
  expected_hash=$(_jgit_backup_metadata_field "${metadata}" archive)
  actual_hash=$(git hash-object --no-filters "${archive}")
  [[ -n ${expected_hash} && ${actual_hash} == "${expected_hash}" ]] ||
    _jgit_die 'backup snapshot does not match its metadata'
  _jgit_backup_validate_snapshot_archive "${archive}" ||
    _jgit_die 'backup snapshot contains unsafe paths'
  tar -xzf "${archive}" -C "${JGIT_BACKUP_SNAPSHOT}"
  _jgit_backup_validate_submodule_metadata || _jgit_die 'backup contains invalid submodule metadata'

  manifest=${JGIT_BACKUP_SNAPSHOT}/manifest
  [[ $(_jgit_backup_metadata_field "${manifest}" format) == 2 ]] ||
    _jgit_die 'unsupported backup format'
  [[ $(_jgit_backup_metadata_field "${manifest}" repository) == "${JGIT_BACKUP_REPOSITORY_ID}" ]] ||
    _jgit_die 'backup belongs to another repository'
  [[ $(_jgit_backup_metadata_field "${metadata}" repository) == "${JGIT_BACKUP_REPOSITORY_ID}" ]] ||
    _jgit_die 'backup metadata belongs to another repository'
  JGIT_BACKUP_METADATA=${metadata}
}

_jgit_backup_path_is_excluded() {
  local path=$1 exclude
  for exclude in "${JGIT_BACKUP_LOCAL_EXCLUDES[@]}"; do
    [[ ${path} == "${exclude}" || ${path} == "${exclude}"/* ]] && return 0
  done
  return 1
}

_jgit_backup_preflight_repository() {
  local repository=$1 repository_path=$2 conflicts
  _jgit_backup_map_excludes "${repository_path}"
  ((JGIT_BACKUP_SKIP_REPOSITORY == 0)) || return 0
  conflicts=$(git -C "${repository}" ls-files -u) || {
    jsh::log_error "Could not inspect ${repository_path:-the main repository} for conflicts"
    return 1
  }
  if [[ -n ${conflicts} ]]; then
    jsh::log_error "Unresolved conflicts in ${repository_path:-the main repository}"
    return 1
  fi
}

_jgit_backup_stash_repository() {
  local repository=$1 repository_path=$2 status previous_stash stash_oid staged_patch
  _jgit_backup_map_excludes "${repository_path}"
  ((JGIT_BACKUP_SKIP_REPOSITORY == 0)) || return 0
  status=$(git -C "${repository}" status --porcelain --untracked-files=all \
    --ignore-submodules=dirty) || {
    jsh::log_error "Could not inspect ${repository_path:-the repository}"
    return 1
  }
  [[ -n ${status} ]] || return 0

  staged_patch=${JGIT_BACKUP_WORK_DIR}/recovery-staged-${#JGIT_BACKUP_STASH_OIDS[@]}.patch
  git -C "${repository}" diff --cached --binary --full-index > "${staged_patch}" || {
    jsh::log_error "Could not preserve staged changes in ${repository_path:-the repository}"
    return 1
  }
  previous_stash=$(git -C "${repository}" rev-parse --verify refs/stash 2> /dev/null || true)
  git -C "${repository}" stash push --include-untracked --quiet \
    --message "jgit load $(date -u '+%Y-%m-%dT%H:%M:%SZ')" ||
    {
      jsh::log_error "Could not stash ${repository_path:-repository} changes"
      return 1
    }
  stash_oid=$(git -C "${repository}" rev-parse --verify refs/stash 2> /dev/null || true)
  [[ -n ${stash_oid} && ${stash_oid} != "${previous_stash}" ]] ||
    {
      jsh::log_error "Could not identify the ${repository_path:-repository} recovery stash"
      return 1
    }
  JGIT_BACKUP_STASH_REPOSITORIES+=("${repository}")
  JGIT_BACKUP_STASH_PATHS+=("${repository_path:-main repository}")
  JGIT_BACKUP_STASH_OIDS+=("${stash_oid}")
  JGIT_BACKUP_STAGED_PATCHES+=("${staged_patch}")
  status=$(git -C "${repository}" status --porcelain --untracked-files=all \
    --ignore-submodules=dirty) || {
    jsh::log_error "Could not inspect ${repository_path:-the repository} after stashing"
    return 1
  }
  if [[ -n ${status} ]]; then
    jsh::log_error "Recovery stash retained for ${repository_path:-main repository}: ${stash_oid}"
    jsh::log_error "Could not stash all ${repository_path:-repository} changes"
    return 1
  fi
}

_jgit_backup_stash_current_changes() {
  local submodule_path repository submodule_list ordered_submodules
  JGIT_BACKUP_STASH_REPOSITORIES=()
  JGIT_BACKUP_STASH_PATHS=()
  JGIT_BACKUP_STASH_OIDS=()
  JGIT_BACKUP_STAGED_PATCHES=()
  submodule_list=${JGIT_BACKUP_WORK_DIR}/initialized-submodules.list
  ordered_submodules=${JGIT_BACKUP_WORK_DIR}/ordered-submodules.list
  git -C "${JGIT_BACKUP_ROOT}" submodule foreach --quiet --recursive \
    'printf "%s\n" "$displaypath"' > "${submodule_list}" || {
    jsh::log_error 'Could not inspect initialized submodules'
    return 1
  }
  awk -F/ '{ print NF "\t" $0 }' "${submodule_list}" |
    LC_ALL=C sort -k1,1nr -k2,2 | cut -f2- > "${ordered_submodules}" || {
    jsh::log_error 'Could not order initialized submodules'
    return 1
  }
  while IFS= read -r submodule_path; do
    _jgit_backup_validate_relative_path "${submodule_path}" ||
      _jgit_die 'an initialized submodule has an unsupported path'
    repository=${JGIT_BACKUP_ROOT}/${submodule_path}
    _jgit_backup_preflight_repository "${repository}" "${submodule_path}" || return 1
  done < "${ordered_submodules}"
  _jgit_backup_preflight_repository "${JGIT_BACKUP_ROOT}" '' || return 1
  while IFS= read -r submodule_path; do
    repository=${JGIT_BACKUP_ROOT}/${submodule_path}
    _jgit_backup_stash_repository "${repository}" "${submodule_path}" || return 1
  done < "${ordered_submodules}"
  _jgit_backup_stash_repository "${JGIT_BACKUP_ROOT}" '' || return 1
  ((${#JGIT_BACKUP_STASH_OIDS[@]} == 0)) ||
    jsh::log_info "Created ${#JGIT_BACKUP_STASH_OIDS[@]} recovery stash(es)"
}

_jgit_backup_report_stashes() {
  local index
  for ((index = 0; index < ${#JGIT_BACKUP_STASH_OIDS[@]}; index++)); do
    jsh::log_error "Recovery stash retained for ${JGIT_BACKUP_STASH_PATHS[index]}: ${JGIT_BACKUP_STASH_OIDS[index]}"
  done
}

_jgit_backup_restore_stashes() {
  local index repository stash_oid stash_path stash_ref staged_patch failed=0
  for ((index = ${#JGIT_BACKUP_STASH_OIDS[@]} - 1; index >= 0; index--)); do
    repository=${JGIT_BACKUP_STASH_REPOSITORIES[index]}
    stash_oid=${JGIT_BACKUP_STASH_OIDS[index]}
    stash_path=${JGIT_BACKUP_STASH_PATHS[index]}
    staged_patch=${JGIT_BACKUP_STAGED_PATCHES[index]}
    stash_ref=$(git -C "${repository}" stash list --format='%gd %H' |
      awk -v wanted="${stash_oid}" '$2 == wanted { print $1; exit }')
    if [[ -z ${stash_ref} ]] || ! git -C "${repository}" stash apply --quiet "${stash_ref}"; then
      jsh::log_error "Recovery stash retained for ${stash_path}: ${stash_oid}"
      failed=1
      continue
    fi
    if [[ -s ${staged_patch} ]] &&
      ! git -C "${repository}" apply --cached --3way "${staged_patch}"; then
      jsh::log_error "Recovery stash retained for ${stash_path}: ${stash_oid}"
      failed=1
      continue
    fi
    git -C "${repository}" stash drop --quiet "${stash_ref}"
  done
  ((failed == 0))
}

_jgit_backup_apply_untracked() {
  local repository=$1 source=$2 repository_path=$3 untracked parent component
  [[ -f ${source}/untracked.tar.gz ]] || return 0
  _jgit_backup_map_excludes "${repository_path}"
  ((JGIT_BACKUP_SKIP_REPOSITORY == 0)) || return 0
  _jgit_backup_validate_untracked_archive "${source}/untracked.tar.gz" "${source}/untracked.list" ||
    _jgit_die 'backup contains unsafe untracked archive paths'
  while IFS= read -r -d '' untracked; do
    case ${untracked} in
      /* | .. | ../* | */../* | */..) _jgit_die 'backup contains an unsafe untracked path' ;;
    esac
    _jgit_backup_path_is_excluded "${untracked}" && continue
    [[ ! -e ${repository}/${untracked} && ! -L ${repository}/${untracked} ]] ||
      _jgit_die "untracked backup path already exists: ${repository_path:+${repository_path}/}${untracked}"
    parent=${repository}
    IFS=/ read -r -a JGIT_BACKUP_PATH_COMPONENTS <<< "${untracked}"
    for component in "${JGIT_BACKUP_PATH_COMPONENTS[@]:0:${#JGIT_BACKUP_PATH_COMPONENTS[@]}-1}"; do
      parent=${parent}/${component}
      [[ ! -L ${parent} ]] ||
        _jgit_die "untracked backup path has a symlinked parent: ${repository_path:+${repository_path}/}${untracked}"
    done
    tar -xzkf "${source}/untracked.tar.gz" -C "${repository}" -- "${untracked}" || return 1
  done < "${source}/untracked.list"
}

_jgit_backup_apply_repository() {
  local repository=$1 source=$2 repository_path=$3 exclude escaped_exclude
  local -a apply_excludes
  _jgit_backup_map_excludes "${repository_path}"
  ((JGIT_BACKUP_SKIP_REPOSITORY == 0)) || return 0
  _jgit_backup_build_pathspecs
  apply_excludes=()
  for exclude in "${JGIT_BACKUP_LOCAL_EXCLUDES[@]}"; do
    escaped_exclude=${exclude//\\/\\\\}
    escaped_exclude=${escaped_exclude//\*/\\*}
    escaped_exclude=${escaped_exclude//\?/\\?}
    escaped_exclude=${escaped_exclude//\[/\\[}
    apply_excludes+=("--exclude=${escaped_exclude}" "--exclude=${escaped_exclude}/**")
  done

  if [[ -s ${source}/tracked.patch ]]; then
    git -C "${repository}" apply --index --3way "${apply_excludes[@]}" \
      "${source}/tracked.patch" || return 1
    git -C "${repository}" reset --quiet "${JGIT_BACKUP_PATHS[@]}" || return 1
  fi
  if [[ -s ${source}/staged.patch ]]; then
    git -C "${repository}" apply --cached --3way "${apply_excludes[@]}" \
      "${source}/staged.patch" || return 1
  fi
  _jgit_backup_apply_untracked "${repository}" "${source}" "${repository_path}"
}

_jgit_backup_prepare_submodule() {
  local full_path=$1 repository=${JGIT_BACKUP_ROOT} remaining
  local config_list candidate match
  remaining=${full_path}
  while [[ -n ${remaining} ]]; do
    [[ -f ${repository}/.gitmodules ]] || return 1
    config_list=${JGIT_BACKUP_WORK_DIR}/registered-${RANDOM}.list
    git -C "${repository}" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
      > "${config_list}" 2> /dev/null || return 1
    match=
    while read -r _ candidate; do
      _jgit_backup_validate_relative_path "${candidate}" || return 1
      if [[ ${remaining} == "${candidate}" || ${remaining} == "${candidate}"/* ]]; then
        if [[ -z ${match} || ${#candidate} -gt ${#match} ]]; then
          match=${candidate}
        fi
      fi
    done < "${config_list}"
    [[ -n ${match} ]] || return 1
    if ! git -C "${repository}/${match}" rev-parse --git-dir > /dev/null 2>&1; then
      git -C "${repository}" submodule update --init -- "${match}" || return 1
    fi
    repository=${repository}/${match}
    if [[ ${remaining} == "${match}" ]]; then
      remaining=
    else
      remaining=${remaining#"${match}"/}
    fi
  done
  git -C "${repository}" rev-parse --git-dir > /dev/null 2>&1
}

_jgit_backup_apply_snapshot() {
  local submodule_dir submodule_path repository
  for submodule_dir in "${JGIT_BACKUP_SNAPSHOT}"/submodules/*; do
    [[ -d ${submodule_dir} ]] || continue
    submodule_path=$(< "${submodule_dir}/path")
    _jgit_backup_prepare_submodule "${submodule_path}" || return 1
  done
  _jgit_backup_apply_repository "${JGIT_BACKUP_ROOT}" "${JGIT_BACKUP_SNAPSHOT}/main" '' ||
    return 1
  for submodule_dir in "${JGIT_BACKUP_SNAPSHOT}"/submodules/*; do
    [[ -d ${submodule_dir} ]] || continue
    submodule_path=$(< "${submodule_dir}/path")
    repository=${JGIT_BACKUP_ROOT}/${submodule_path}
    _jgit_backup_apply_repository "${repository}" "${submodule_dir}" "${submodule_path}" ||
      return 1
  done
}

_jgit_backup_preview() {
  local gist_id=$1 preview=${JGIT_BACKUP_WORK_DIR}/jgit-backup.diff
  printf '\nBackup summary:\n'
  cat "${JGIT_BACKUP_METADATA}"
  gh gist view "${gist_id}" --filename jgit-backup.diff --raw > "${preview}" ||
    _jgit_die 'could not download backup preview'
  printf '\nBackup diff:\n'
  cat "${preview}"
  printf '\n'
}

_jgit_backup_load() {
  local gist_id
  JGIT_BACKUP_ACTION=load
  _jgit_backup_repository_context
  _jgit_backup_parse_excludes "$@" || {
    [[ $? == 2 ]] && return
    return 1
  }
  _jgit_backup_require base64
  _jgit_backup_require tar
  _jgit_backup_authenticate

  JGIT_BACKUP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jgit-backup.XXXXXX") ||
    _jgit_die 'could not create a temporary directory'
  trap 'rm -rf "${JGIT_BACKUP_WORK_DIR}"' RETURN EXIT
  _jgit_backup_discover_valid_gists
  ((${#JGIT_BACKUP_GIST_IDS[@]} > 0)) || _jgit_die 'no applicable backup gists found'
  _jgit_backup_select_gist || _jgit_die 'backup selection cancelled'
  gist_id=${JGIT_BACKUP_SELECTED_GIST}
  git -C "${JGIT_BACKUP_ROOT}" config --local jsh.backupGist "${gist_id}"
  _jgit_backup_download "${gist_id}"
  _jgit_backup_preview "${gist_id}"
  _jgit_backup_confirm 'Apply this backup?' no || {
    jsh::log_note 'Backup load cancelled'
    return
  }

  if ! _jgit_backup_stash_current_changes; then
    if ((${#JGIT_BACKUP_STASH_OIDS[@]} > 0)); then
      if _jgit_backup_restore_stashes; then
        jsh::log_warn 'Restored changes stashed before backup setup failed'
      else
        jsh::log_error 'Some recovery stashes could not be restored'
      fi
    fi
    _jgit_die 'could not prepare local changes for backup load'
  fi
  if ! _jgit_backup_apply_snapshot; then
    _jgit_backup_report_stashes
    jsh::log_error 'Backup could not be applied; any recovery stashes were retained'
    return 1
  fi
  if ! _jgit_backup_restore_stashes; then
    _jgit_die 'backup applied, but some prior local changes remain in recovery stashes'
  fi
  jsh::log_success "Loaded uncommitted changes from secret gist ${gist_id}"
  git -C "${JGIT_BACKUP_ROOT}" status --short
}
