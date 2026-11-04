#!/usr/bin/env bash
# Project navigation and the existing path|visits|hour database, shared by Bash and Zsh.
# shellcheck disable=SC2154 # JSH, GIT_BASE and output helpers come from the interactive rc.

_j_abspath() (
  local -a quiet=()
  # Internal path resolution must not restart Zsh's directory-tracking hooks.
  [[ -z ${ZSH_VERSION:-} ]] || quiet=(-q)
  CDPATH='' builtin cd "${quiet[@]}" -P -- "$1" && pwd -P
)

# Jump between projects and stacks by frecency; `projects` summarizes their repos.

J_DATA=${J_DATA:-${XDG_STATE_HOME:-${HOME}/.local/state}/jsh/j.db}
[[ ! -f ${JSH}/local/j.db || -f ${J_DATA} ]] || J_DATA=${JSH}/local/j.db
J_EXCLUDE=${J_EXCLUDE:-${HOME}}
J_PATHS=${J_PATHS-${GIT_BASE:-${HOME}/Projects}}
J_STACKS=${J_STACKS:-${HOME}/Stacks}
_J_DECAY=0.99
_J_MIN_SCORE=0.01
_J_PREV_DIR=${_J_PREV_DIR:-}
_J_CODE_CMD=${_J_CODE_CMD:-}

_j_lowercase() {
  printf '%s' "$1" | LC_ALL=C command tr '[:upper:]' '[:lower:]'
}

# Exact-name key: case-insensitive, so `jsh` also names `.jsh`.
_j_name_key() {
  local name
  name=$(_j_lowercase "$1")
  printf '%s' "${name#.}"
}

_j_find_code() {
  [[ -n ${_J_CODE_CMD} ]] && {
    printf '%s' "${_J_CODE_CMD}"
    return 0
  }

  local candidate
  for candidate in /opt/homebrew/bin/code /usr/local/bin/code /usr/bin/code; do
    if [[ -x ${candidate} ]]; then
      _J_CODE_CMD=${candidate}
      printf '%s' "${candidate}"
      return 0
    fi
  done

  if has code; then
    _J_CODE_CMD=$(command -v code)
    printf '%s' "${_J_CODE_CMD}"
    return 0
  fi

  return 1
}

_j_open_code_path() {
  local target=${1:-.} code_command
  code_command=$(_j_find_code)
  if [[ -n ${code_command} ]]; then
    command "${code_command}" "${target}"
  elif [[ ${OSTYPE:-} == darwin* ]]; then
    command open -a 'Visual Studio Code' "${target}"
  else
    jsh::log_error 'VS Code command not found.'
    return 1
  fi
}

_j_ensure_dir() {
  local data_dir=${J_DATA%/*}
  [[ ${data_dir} != "${J_DATA}" ]] || data_dir=.
  [[ -d ${data_dir} ]] || command mkdir -p -- "${data_dir}"
}

_j_array_contains() {
  local wanted=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == "${wanted}" ]] && return 0
    [[ -e ${item} && -e ${wanted} && ${item} -ef ${wanted} ]] && return 0
  done
  return 1
}

# Immediate children of J_PATHS roots, every stack, and every stack's children.
_j_get_projects() {
  local root candidate
  local -a roots=()
  local rest=${J_PATHS}:
  while [[ -n ${rest} ]]; do
    roots+=("${rest%%:*}")
    rest=${rest#*:}
  done
  [[ -z ${ZSH_VERSION:-} ]] || setopt localoptions nonomatch
  [[ ! -d ${J_STACKS} ]] || roots+=("${J_STACKS}")
  for root in "${J_STACKS}"/*; do [[ ! -d ${root} ]] || roots+=("${root}"); done
  for root in "${roots[@]}"; do
    root=${root/#\~/${HOME}}
    [[ -d ${root} ]] || continue
    for candidate in "${root}"/*; do
      [[ ! -d ${candidate} ]] || _j_abspath "${candidate}"
    done
  done
}

_j_lock_acquire() {
  local lock_dir=${J_DATA}.lock
  local -i tries=0
  while ! command mkdir "${lock_dir}" 2>/dev/null; do
    ((++tries < 100)) || return 1
    command sleep 0.01
  done
}

_j_lock_release() {
  command rmdir "${J_DATA}.lock" 2>/dev/null || true
}

_j_now() {
  printf '%s' "$((${EPOCHSECONDS:-$(command date +%s)} / 3600))"
}

_j_add() {
  local entry_path=$1 exclude exclusions now temp_file
  local -i result=0

  [[ -d ${entry_path} ]] || return 1
  [[ ${entry_path} != *'|'* && ${entry_path} != *$'\n'* ]] || return 1
  entry_path=$(_j_abspath "${entry_path}") || return
  exclusions=${J_EXCLUDE}:
  while [[ -n ${exclusions} ]]; do
    exclude=${exclusions%%:*}
    exclusions=${exclusions#*:}
    if [[ -d ${exclude} ]]; then
      exclude=$(_j_abspath "${exclude}")
    fi
    [[ -n ${exclude} && ${entry_path} == "${exclude}" ]] && return 0
  done

  ((${#entry_path} >= 4)) || return 0
  [[ ${entry_path} != *'|'* && ${entry_path} != *$'\n'* ]] || return 1
  _j_ensure_dir || return 1
  _j_lock_acquire || return 0

  now=$(_j_now)
  temp_file=$(mktemp "${J_DATA}.tmp.XXXXXX") || {
    _j_lock_release
    return 1
  }

  if [[ -f ${J_DATA} ]]; then
    JSH_ENTRY_PATH=${entry_path} command -p awk -F'|' -v now="${now}" '
      BEGIN { path = ENVIRON["JSH_ENTRY_PATH"]; found = 0; OFS = "|" }
      $1 == path { print path, $2 + 1, now; found = 1; next }
      { print }
      END { if (!found) print path, 1, now }
    ' "${J_DATA}" >"${temp_file}" && command mv -f -- "${temp_file}" "${J_DATA}" || result=$?
  else
    printf '%s|1|%s\n' "${entry_path}" "${now}" >"${temp_file}" &&
      command mv -f -- "${temp_file}" "${J_DATA}" || result=$?
  fi

  command rm -f -- "${temp_file}" 2>/dev/null || true
  _j_lock_release
  return ${result}
}

_j_remove() {
  local entry_path=$1 temp_file
  local -i count_before count_after
  [[ ! -d ${entry_path} ]] || entry_path=$(_j_abspath "${entry_path}")
  [[ -f ${J_DATA} ]] || return 1
  _j_lock_acquire || return 1

  count_before=$(command wc -l <"${J_DATA}")
  temp_file=$(mktemp "${J_DATA}.tmp.XXXXXX") || {
    _j_lock_release
    return 1
  }
  if ! JSH_ENTRY_PATH=${entry_path} command -p awk -F'|' 'BEGIN { path = ENVIRON["JSH_ENTRY_PATH"] } $1 != path' "${J_DATA}" >"${temp_file}" ||
    ! command mv -f -- "${temp_file}" "${J_DATA}"; then
    command rm -f -- "${temp_file}" 2>/dev/null || true
    _j_lock_release
    return 1
  fi
  _j_lock_release

  count_after=$(command wc -l <"${J_DATA}")
  ((count_after < count_before))
}

_j_clean() {
  [[ -f ${J_DATA} ]] || {
    jsh::log_info 'Database is empty'
    return 0
  }
  _j_lock_acquire || return 1

  local entry_path count last_access temp_file
  local -i removed=0 total=0
  temp_file=$(mktemp "${J_DATA}.tmp.XXXXXX") || {
    _j_lock_release
    return 1
  }

  while IFS='|' read -r entry_path count last_access; do
    [[ -n ${entry_path} ]] || continue
    ((++total))
    if [[ -d ${entry_path} ]]; then
      printf '%s|%s|%s\n' "${entry_path}" "${count}" "${last_access}"
    else
      ((++removed))
    fi
  done <"${J_DATA}" >"${temp_file}"

  if ! command mv -f -- "${temp_file}" "${J_DATA}"; then
    command rm -f -- "${temp_file}" 2>/dev/null || true
    _j_lock_release
    return 1
  fi
  _j_lock_release

  if ((removed)); then
    jsh::log_success "Removed ${removed} non-existent directories, kept $((total - removed))"
  else
    jsh::log_success "Database is clean: ${total} directories"
  fi
}

_j_calculate_scores() {
  [[ -f ${J_DATA} ]] || return 0
  local now
  now=$(_j_now)
  command -p awk -F'|' -v now="${now}" -v decay="${_J_DECAY}" -v min="${_J_MIN_SCORE}" '
    {
      hours = now - $3
      if (hours < 0) hours = 0
      score = $2 * (decay ^ hours)
      if (score >= min) printf "%.4f|%s\n", score, $1
    }
  ' "${J_DATA}"
}

_j_matches() {
  local candidate query
  candidate=$(_j_lowercase "$1")
  shift
  for query in "$@"; do
    [[ ${candidate} == *$(_j_lowercase "${query}")* ]] || return 1
  done
}

_j_query() {
  local exact_results="" results="" line score candidate exact_query=""
  (($# != 1)) || exact_query=$(_j_name_key "$1")

  while IFS='|' read -r score candidate; do
    [[ -n ${candidate} && -d ${candidate} ]] || continue
    if (($# == 0)) || _j_matches "${candidate}" "$@"; then
      line="${score}|${candidate}"$'\n'
      if [[ -n ${exact_query} && $(_j_name_key "${candidate##*/}") == "${exact_query}" ]]; then
        exact_results+=${line}
      else
        results+=${line}
      fi
    fi
  done < <(_j_calculate_scores)

  printf '%s' "${exact_results}" | command -p sort -t'|' -k1 -rn
  printf '%s' "${results}" | command -p sort -t'|' -k1 -rn
}

_j_display_path() {
  local display=$1
  if [[ ${display} == "${HOME}" ]]; then
    printf '%s' '~'
  elif [[ ${display} == "${HOME}"/* ]]; then
    printf '%s' "~${display#${HOME}}"
  else
    printf '%s' "${display}"
  fi
}

_j_list() {
  local line score entry_path
  local -a entries
  while IFS= read -r line; do
    [[ -n ${line} ]] && entries+=("${line}")
  done < <(_j_query)

  if ((! ${#entries[@]})); then
    jsh::log_info 'No directories tracked yet.'
    return 0
  fi

  printf '%-8s  %s\n' SCORE PATH
  for line in "${entries[@]}"; do
    score=${line%%|*}
    entry_path=${line#*|}
    printf '%-8s  %s\n' "${score}" "$(_j_display_path "${entry_path}")"
  done
}

# Usage: _j_choose PATH... Prints the chosen path.
_j_choose() {
  local entry selected
  local -a displays
  for entry in "$@"; do
    displays+=("$(_j_display_path "${entry}")")
  done
  selected=$(jsh::choose Directory "${displays[@]}") || return 1
  printf '%s' "${selected/#\~/${HOME}}"
}

_j_interactive() {
  local line candidate project_path absolute_path sorted_path
  local preferred_project=${_J_INTERACTIVE_PROJECT_PATH:-} exact_query=""
  local -a paths extra_paths

  [[ ${_J_INTERACTIVE_EXACT_ONLY:-} != true || $# != 1 ]] || exact_query=$(_j_name_key "$1")

  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    candidate=${line#*|}
    if [[ -n ${exact_query} && $(_j_name_key "${candidate##*/}") != "${exact_query}" ]]; then
      continue
    fi
    paths+=("${line#*|}")
  done < <(_j_query "$@")

  if [[ -d ${preferred_project} && ${preferred_project} != "${PWD}" ]] &&
    ! _j_array_contains "${preferred_project}" "${paths[@]}"; then
    extra_paths+=("${preferred_project}")
  fi
  while IFS= read -r project_path; do
    [[ -n ${project_path} ]] || continue
    absolute_path=${project_path/#\~/${HOME}}
    [[ -d ${absolute_path} && ${absolute_path} != "${PWD}" ]] || continue
    if [[ -n ${exact_query} && $(_j_name_key "${absolute_path##*/}") != "${exact_query}" ]]; then
      continue
    fi
    _j_array_contains "${absolute_path}" "${paths[@]}" "${extra_paths[@]}" && continue
    if (($# == 0)) || _j_matches "${absolute_path}" "$@"; then
      extra_paths+=("${absolute_path}")
    fi
  done < <(_j_get_projects)

  if ((${#extra_paths[@]})); then
    while IFS= read -r sorted_path; do
      paths+=("${sorted_path}")
    done < <(printf '%s\n' "${extra_paths[@]}" | command -p sort)
  fi

  if ((! ${#paths[@]})); then
    jsh::log_warn 'No directories found.'
    return 1
  fi

  _j_choose "${paths[@]}"
}

_j_resolve_path() {
  local query=$1 candidate
  for candidate in "${query}" "${PWD}/${query}" "${HOME}/${query}"; do
    if [[ -d ${candidate} ]]; then
      printf '%s' "$(_j_abspath "${candidate}")"
      return 0
    fi
  done
  if [[ ${query} != .* && -d ${HOME}/.${query} ]]; then
    candidate=${HOME}/.${query}
    printf '%s' "$(_j_abspath "${candidate}")"
    return 0
  fi
  return 1
}

# Prints: commit-epoch branch upstream ahead behind staged modified untracked conflicts
_j_git_state() {
  local line branch='-' upstream='-' epoch
  local ab ahead_field behind_field
  local -i ahead=0 behind=0 staged=0 modified=0 untracked=0 conflicts=0
  while IFS= read -r line; do
    case ${line} in
      '# branch.head '*) branch=${line#\# branch.head } ;;
      '# branch.upstream '*) upstream=${line#\# branch.upstream } ;;
      '# branch.ab '*)
        ab=${line#\# branch.ab }
        read -r ahead_field behind_field <<<"${ab}"
        ahead=${ahead_field#+}
        behind=${behind_field#-}
        ;;
      [12]' '*)
        [[ ${line:2:1} == . ]] || ((++staged))
        [[ ${line:3:1} == . ]] || ((++modified))
        ;;
      'u '*) ((++conflicts)) ;;
      '? '*) ((++untracked)) ;;
    esac
  done < <(command git -C "$1" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
  epoch=$(command git -C "$1" log -1 --format=%ct 2>/dev/null)
  printf '%s\n' "${epoch:-0} ${branch} ${upstream} ${ahead} ${behind} ${staged} ${modified} ${untracked} ${conflicts}"
}

_j_age() {
  local -i seconds=$((${EPOCHSECONDS:-$(command date +%s)} - $1))
  if (($1 == 0)); then
    printf '%s' '-'
  elif ((seconds < 3600)); then
    printf '%s' "$((seconds / 60))m"
  elif ((seconds < 86400)); then
    printf '%s' "$((seconds / 3600))h"
  elif ((seconds < 1209600)); then
    printf '%s' "$((seconds / 86400))d"
  elif ((seconds < 5184000)); then
    printf '%s' "$((seconds / 604800))w"
  elif ((seconds < 31536000)); then
    printf '%s' "$((seconds / 2592000))mo"
  else
    printf '%s' "$((seconds / 31536000))y"
  fi
}

# Usage: _j_status_rows DIR... Prints one aligned row per repo, most recent commit first.
_j_status_rows() {
  local dir row sync changes mark epoch name branch upstream ahead behind staged modified untracked conflicts age
  local -a rows=()
  local -i name_width=0 branch_width=0 sync_width=0 change_width=0
  for dir in "$@"; do
    name=${dir##*/}
    if [[ ! -e ${dir}/.git ]]; then
      rows+=("0|${name}|-|missing|-|missing")
      continue
    fi
    read -r epoch branch upstream ahead behind staged modified untracked conflicts < <(_j_git_state "${dir}")
    sync=''
    ((ahead)) && sync+="↑${ahead} "
    ((behind)) && sync+="↓${behind} "
    changes=''
    ((staged)) && changes+="+${staged} "
    ((modified)) && changes+="~${modified} "
    ((untracked)) && changes+="?${untracked} "
    ((conflicts)) && changes+="!${conflicts} "
    mark=ok
    [[ -z ${sync}${changes} ]] || mark=warn
    [[ -n ${sync} ]] || { [[ ${upstream} == - ]] && sync=local || sync=synced; }
    changes=${changes% }
    rows+=("${epoch}|${name}|${branch}|${sync% }|${changes:-clean}|${mark}")
  done
  for row in "${rows[@]}"; do
    IFS='|' read -r epoch name branch sync changes mark <<<"${row}"
    ((${#name} <= name_width)) || name_width=${#name}
    ((${#branch} <= branch_width)) || branch_width=${#branch}
    ((${#sync} <= sync_width)) || sync_width=${#sync}
    ((${#changes} <= change_width)) || change_width=${#changes}
  done
  while IFS='|' read -r epoch name branch sync changes mark; do
    [[ -n ${name} ]] || continue
    case ${mark} in
      ok) mark=$(jsh::paint 1 32 '✓') ;;
      warn) mark=$(jsh::paint 1 33 '!') ;;
      *) mark=$(jsh::paint 1 31 '✗') ;;
    esac
    age=$(_j_age "${epoch}")
    printf '%s %-*s  %-*s  %-*s  %-*s  %s\n' "${mark}" "${name_width}" "${name}" \
      "${branch_width}" "${branch}" "${sync_width}" "${sync}" \
      "${change_width}" "${changes}" "${age}"
  done < <(printf '%s\n' "${rows[@]}" | command -p sort -t'|' -k1,1nr)
}

# Summarizes every repo under J_PATHS and in each stack.
_j_status() {
  local root dir
  local -a dirs=() roots=()
  local rest=${J_PATHS}:
  while [[ -n ${rest} ]]; do
    roots+=("${rest%%:*}")
    rest=${rest#*:}
  done
  [[ -z ${ZSH_VERSION:-} ]] || setopt localoptions nonomatch
  for root in "${J_STACKS}"/*; do [[ ! -d ${root} ]] || roots+=("${root}"); done
  printf '%s\n' "$(jsh::paint 1 1 Projects)"
  for root in "${roots[@]}"; do
    root=${root/#\~/${HOME}}
    for dir in "${root}"/*; do
      [[ ! -e ${dir}/.git ]] || dirs+=("${dir}")
    done
  done

  if ((! ${#dirs[@]})); then
    jsh::log_note 'No repositories found.'
    return 0
  fi
  _j_status_rows "${dirs[@]}"
}

projects() {
  jsh::color_init
  _j_status
}

_j_help() {
  cat <<'EOF'
Usage:
  j                   Choose a project or stack interactively
  j pick [query ...]  Choose a directory interactively
  j [query ...]       Jump to the best matching directory
  j -                 Jump to the previous directory
  j -c [query ...]    Open the match in VS Code
  j -v [query ...]    Show search details
  j -a, --add         Add the current directory
  j --remove          Remove the current directory
  j --db              Show tracked directories and scores
  j --clean           Remove missing directories

`projects` summarizes the Git repositories in J_PATHS and every stack.

Environment:
  J_DATA              Database path (default: $XDG_STATE_HOME/jsh/j.db)
  J_EXCLUDE           Colon-separated paths excluded from tracking
  J_PATHS             Colon-separated project roots (default: $GIT_BASE)
  J_STACKS            Stack root; its children and their children are jump targets
                      (default: ~/Stacks)
  J_NO_HOOK           Disable automatic directory tracking
EOF
}

_j_go() {
  local previous=${PWD}
  if [[ $1 == true ]]; then
    _j_open_code_path "$2"
  else
    builtin cd -- "$2" || return
    _J_PREV_DIR=${previous}
  fi
}

j() {
  local open_code=false verbose=false line best="" selected resolved project_path exact_match
  local project_candidate absolute_path
  local has_exact_conflict=false
  local -a exact_matches project_matches
  local -i count=0

  jsh::color_init
  if ((! $#)) || [[ $1 == pick ]]; then
    ((! $#)) || shift
    selected=$(_j_interactive "$@") || return
    _j_go false "${selected}"
    return
  fi

  while (($#)); do
    case $1 in
      -v | --verbose)
        verbose=true
        shift
        ;;
      -c | --code)
        open_code=true
        shift
        ;;
      -a | --add)
        _j_add "${PWD}" || return
        jsh::log_success "Added: $(_j_display_path "${PWD}")"
        return 0
        ;;
      --remove)
        if _j_remove "${PWD}"; then
          jsh::log_success "Removed: $(_j_display_path "${PWD}")"
        else
          jsh::log_warn "Not in database: $(_j_display_path "${PWD}")"
          return 1
        fi
        return 0
        ;;
      --db)
        _j_list
        return
        ;;
      --clean)
        _j_clean
        return
        ;;
      -h | --help)
        _j_help
        return 0
        ;;
      -)
        if [[ -n ${_J_PREV_DIR} && -d ${_J_PREV_DIR} ]]; then
          _j_go "${open_code}" "${_J_PREV_DIR}"
        else
          jsh::log_warn 'No previous directory'
          return 1
        fi
        return
        ;;
      -*)
        jsh::log_error "Unknown option: $1"
        return 1
        ;;
      *) break ;;
    esac
  done

  if [[ $# == 1 && $1 == . ]]; then
    _j_go "${open_code}" "${PWD}"
    return
  fi

  if (($# == 1)) && [[ $1 == */* || $1 == .* ]] && [[ -d $1 ]]; then
    _j_go "${open_code}" "$(_j_abspath "$1")"
    return
  fi

  if (($# == 0)); then
    selected=$(_j_interactive)
    [[ -n ${selected} ]] || return 0
    _j_go "${open_code}" "${selected}"
    return
  fi

  [[ ${verbose} != true ]] || jsh::log_info "Searching frecency database: ${J_DATA}"
  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    [[ -n ${best} ]] || best=${line}
    absolute_path=${line#*|}
    if (($# == 1)) && [[ $(_j_name_key "${absolute_path##*/}") == $(_j_name_key "$1") ]]; then
      exact_matches+=("${line#*|}")
    fi
    ((++count))
  done < <(_j_query "$@")

  if (($# == 1)); then
    while IFS= read -r project_candidate; do
      [[ -n ${project_candidate} ]] || continue
      absolute_path=${project_candidate/#\~/${HOME}}
      [[ -d ${absolute_path} ]] || continue
      [[ $(_j_name_key "${absolute_path##*/}") == $(_j_name_key "$1") ]] || continue
      if [[ -n ${project_path} ]] &&
        ! _j_array_contains "${absolute_path}" "${project_path}"; then
        has_exact_conflict=true
      else
        project_path=${absolute_path}
      fi
    done < <(_j_get_projects)

    if [[ -n ${project_path} ]]; then
      for exact_match in "${exact_matches[@]}"; do
        _j_array_contains "${project_path}" "${exact_match}" || has_exact_conflict=true
      done
      if [[ ${has_exact_conflict} == true ]]; then
        selected=$(_J_INTERACTIVE_EXACT_ONLY=true \
          _J_INTERACTIVE_PROJECT_PATH="${project_path}" _j_interactive "$@")
        [[ -n ${selected} ]] || return 1
        best="0|${selected}"
      else
        best="0|${project_path}"
      fi
      count=1
    fi
  fi

  if ((count)); then
    local best_path=${best#*|}
    [[ ${verbose} != true ]] ||
      jsh::log_success "${count} database match(es), best $(_j_display_path "${best_path}")"
    _j_go "${open_code}" "${best_path}"
    return
  fi

  while IFS= read -r project_candidate; do
    [[ -n ${project_candidate} && -d ${project_candidate} ]] || continue
    _j_matches "${project_candidate}" "$@" || continue
    _j_array_contains "${project_candidate}" "${project_matches[@]}" ||
      project_matches+=("${project_candidate}")
  done < <(_j_get_projects)

  if ((${#project_matches[@]} == 1)); then
    for selected in "${project_matches[@]}"; do break; done
  elif ((${#project_matches[@]} > 1)); then
    selected=$(_j_interactive "$@")
    [[ -n ${selected} ]] || return 1
  fi
  if [[ -n ${selected} ]]; then
    _j_go "${open_code}" "${selected}"
    return
  fi

  if (($# == 1)); then
    resolved=$(_j_resolve_path "$1")
    if [[ -n ${resolved} && -d ${resolved} ]]; then
      _j_go "${open_code}" "${resolved}"
      return
    fi
  fi

  jsh::log_error "No matching directory: $*"
  return 1
}

alias p='j'
