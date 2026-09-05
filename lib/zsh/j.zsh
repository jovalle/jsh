typeset -g J_DATA=${J_DATA:-${JSH}/local/j.db}
typeset -g J_EXCLUDE=${J_EXCLUDE:-${HOME}}
typeset -g J_PATHS=${J_PATHS-${GIT_BASE:-${HOME}/projects}}
typeset -gF _J_DECAY=0.99
typeset -gF _J_MIN_SCORE=0.01
typeset -g _J_PREV_DIR=""
typeset -g _J_CODE_CMD=""

_j_lowercase() {
  print -rn -- "${(L)1}"
}

_j_find_code() {
  [[ -n ${_J_CODE_CMD} ]] && {
    print -rn -- "${_J_CODE_CMD}"
    return 0
  }

  local candidate
  for candidate in /opt/homebrew/bin/code /usr/local/bin/code /usr/bin/code; do
    if [[ -x ${candidate} ]]; then
      _J_CODE_CMD=${candidate}
      print -rn -- "${candidate}"
      return 0
    fi
  done

  if (( $+commands[code] )); then
    _J_CODE_CMD=${commands[code]}
    print -rn -- "${_J_CODE_CMD}"
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
    _j_ui_message error 'VS Code command not found.'
    return 1
  fi
}

_j_ensure_dir() {
  local data_dir=${J_DATA:h}
  [[ -d ${data_dir} ]] || command mkdir -p -- "${data_dir}"
}

_j_array_contains() {
  local wanted=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == ${wanted} ]] && return 0
    [[ -e ${item} && -e ${wanted} && ${item} -ef ${wanted} ]] && return 0
  done
  return 1
}

_j_get_gitx_projects() {
  (( $+commands[gitx] || $+functions[gitx] )) || return 1
  gitx list 2>/dev/null | command -p awk 'NR > 2 && ($1 ~ /^~/ || $1 ~ /^\//) { print $1 }'
}

_j_get_path_projects() {
  local root candidate
  for root in ${(s.:.)J_PATHS}; do
    root=${root/#\~/${HOME}}
    [[ -d ${root} ]] || continue
    for candidate in "${root}"/*(N); do
      [[ -d ${candidate} ]] && print -r -- "${candidate:A}"
    done
  done
}

_j_get_projects() {
  _j_get_path_projects
  _j_get_gitx_projects
}

_j_lock_acquire() {
  local lock_dir=${J_DATA}.lock
  local -i tries=0
  while ! command mkdir "${lock_dir}" 2>/dev/null; do
    (( ++tries < 100 )) || return 1
    command sleep 0.01
  done
}

_j_lock_release() {
  command rmdir "${J_DATA}.lock" 2>/dev/null || true
}

_j_now() {
  print -rn -- "$(( $(command -p date +%s) / 3600 ))"
}

_j_add() {
  local entry_path=$1 exclude exclusions now temp_file
  local -i result=0

  [[ -d ${entry_path} ]] || return 1
  entry_path=${entry_path:A}
  exclusions=${J_EXCLUDE}:
  while [[ -n ${exclusions} ]]; do
    exclude=${exclusions%%:*}
    exclusions=${exclusions#*:}
    if [[ -d ${exclude} ]]; then
      exclude=${exclude:A}
    fi
    [[ -n ${exclude} && ${entry_path} == ${exclude} ]] && return 0
  done

  (( ${#entry_path} >= 4 )) || return 0
  [[ ${entry_path} != *'|'* && ${entry_path} != *$'\n'* ]] || return 1
  _j_ensure_dir || return 1
  _j_lock_acquire || return 0

  now=$(_j_now)
  temp_file=$(mktemp "${J_DATA}.tmp.XXXXXX") || {
    _j_lock_release
    return 1
  }

  if [[ -f ${J_DATA} ]]; then
    command -p awk -F'|' -v path="${entry_path}" -v now="${now}" '
      BEGIN { found = 0; OFS = "|" }
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
  [[ ! -d ${entry_path} ]] || entry_path=${entry_path:A}
  [[ -f ${J_DATA} ]] || return 1
  _j_lock_acquire || return 1

  count_before=$(command wc -l <"${J_DATA}")
  temp_file=$(mktemp "${J_DATA}.tmp.XXXXXX") || {
    _j_lock_release
    return 1
  }
  if ! command -p awk -F'|' -v path="${entry_path}" '$1 != path' "${J_DATA}" >"${temp_file}" ||
    ! command mv -f -- "${temp_file}" "${J_DATA}"; then
    command rm -f -- "${temp_file}" 2>/dev/null || true
    _j_lock_release
    return 1
  fi
  _j_lock_release

  count_after=$(command wc -l <"${J_DATA}")
  (( count_after < count_before ))
}

_j_clean() {
  [[ -f ${J_DATA} ]] || {
    _j_ui_message info 'Database is empty'
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
    (( ++total ))
    if [[ -d ${entry_path} ]]; then
      printf '%s|%s|%s\n' "${entry_path}" "${count}" "${last_access}"
    else
      (( ++removed ))
    fi
  done <"${J_DATA}" >"${temp_file}"

  if ! command mv -f -- "${temp_file}" "${J_DATA}"; then
    command rm -f -- "${temp_file}" 2>/dev/null || true
    _j_lock_release
    return 1
  fi
  _j_lock_release

  if (( removed )); then
    _j_ui_message success "Removed ${removed} non-existent directories, kept $(( total - removed ))"
  else
    _j_ui_message success "Database is clean: ${total} directories"
  fi
}

_j_calculate_scores() {
  [[ -f ${J_DATA} ]] || return 0
  local now=$(_j_now)
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
  local candidate=$(_j_lowercase "$1") query
  shift
  for query in "$@"; do
    [[ ${candidate} == *$(_j_lowercase "${query}")* ]] || return 1
  done
}

_j_query() {
  local exact_results="" results="" line score candidate exact_query=""
  (( $# != 1 )) || exact_query=$(_j_lowercase "$1")

  while IFS='|' read -r score candidate; do
    [[ -n ${candidate} && -d ${candidate} && ${candidate} != ${PWD} ]] || continue
    if (( $# == 0 )) || _j_matches "${candidate}" "$@"; then
      line="${score}|${candidate}"$'\n'
      if [[ -n ${exact_query} && $(_j_lowercase "${candidate:t}") == ${exact_query} ]]; then
        exact_results+=${line}
      else
        results+=${line}
      fi
    fi
  done < <(_j_calculate_scores)

  print -rn -- "${exact_results}" | command -p sort -t'|' -k1 -rn
  print -rn -- "${results}" | command -p sort -t'|' -k1 -rn
}

_j_display_path() {
  local display=$1
  if [[ ${display} == ${HOME} ]]; then
    print -rn -- '~'
  elif [[ ${display} == ${HOME}/* ]]; then
    print -rn -- "~${display#${HOME}}"
  else
    print -rn -- "${display}"
  fi
}

_j_list() {
  local line score entry_path
  local -a entries
  while IFS= read -r line; do
    [[ -n ${line} ]] && entries+=("${line}")
  done < <(_j_query)

  if (( ! ${#entries} )); then
    _j_ui_message info 'No directories tracked yet.'
    return 0
  fi

  printf '%-8s  %s\n' SCORE PATH
  for line in "${entries[@]}"; do
    score=${line%%|*}
    entry_path=${line#*|}
    printf '%-8s  %s\n' "${score}" "$(_j_display_path "${entry_path}")"
  done
}

_j_interactive() {
  local line entry_path selected choice project_path absolute_path sorted_path
  local preferred_project=${_J_INTERACTIVE_PROJECT_PATH:-} exact_query=""
  local -a paths extra_paths
  local -i index=1

  [[ ${_J_INTERACTIVE_EXACT_ONLY:-} != true || $# != 1 ]] || exact_query=$(_j_lowercase "$1")

  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    if [[ -n ${exact_query} && $(_j_lowercase "${${line#*|}:t}") != ${exact_query} ]]; then
      continue
    fi
    paths+=("${line#*|}")
  done < <(_j_query "$@")

  if [[ -d ${preferred_project} && ${preferred_project} != ${PWD} ]] &&
    ! _j_array_contains "${preferred_project}" "${paths[@]}"; then
    extra_paths+=("${preferred_project}")
  fi
  while IFS= read -r project_path; do
    [[ -n ${project_path} ]] || continue
    absolute_path=${project_path/#\~/${HOME}}
    [[ -d ${absolute_path} && ${absolute_path} != ${PWD} ]] || continue
    if [[ -n ${exact_query} && $(_j_lowercase "${absolute_path:t}") != ${exact_query} ]]; then
      continue
    fi
    _j_array_contains "${absolute_path}" "${paths[@]}" "${extra_paths[@]}" && continue
    if (( $# == 0 )) || _j_matches "${absolute_path}" "$@"; then
      extra_paths+=("${absolute_path}")
    fi
  done < <(_j_get_projects)

  if (( ${#extra_paths} )); then
    while IFS= read -r sorted_path; do
      paths+=("${sorted_path}")
    done < <(printf '%s\n' "${extra_paths[@]}" | command -p sort)
  fi

  if (( ! ${#paths} )); then
    _j_ui_message warn 'No directories found.'
    return 1
  fi

  if (( $+commands[fzf] || $+functions[fzf] )); then
    {
      for entry_path in "${paths[@]}"; do
        _j_display_path "${entry_path}"
        printf '\n'
      done
    } | fzf --height=40% --reverse --no-sort --prompt='j> ' | {
      IFS= read -r selected
      if [[ ${selected} == '~'* ]]; then
        print -rn -- "${HOME}${selected#\~}"
      else
        print -rn -- "${selected}"
      fi
    }
    return ${pipestatus[2]}
  fi

  print -u2 -- 'Select directory:'
  for entry_path in "${paths[@]}"; do
    (( index <= 10 )) || break
    printf '[%d] %s\n' ${index} "$(_j_display_path "${entry_path}")" >&2
    (( ++index ))
  done
  printf 'Enter number (1-%d): ' $(( index - 1 )) >&2
  read -r choice
  [[ ${choice} == <-> ]] && (( choice >= 1 && choice < index )) || return 1
  print -rn -- "${paths[choice]}"
}

_j_resolve_path() {
  local query=$1 candidate
  for candidate in "${query}" "${PWD}/${query}" "${HOME}/${query}"; do
    if [[ -d ${candidate} ]]; then
      print -rn -- "${candidate:A}"
      return 0
    fi
  done
  if [[ ${query} != .* && -d ${HOME}/.${query} ]]; then
    candidate=${HOME}/.${query}
    print -rn -- "${candidate:A}"
    return 0
  fi
  return 1
}

_j_track_directory() {
  [[ -z ${J_NO_HOOK:-} ]] || return 0
  local track_path=$1
  setopt localoptions no_bg_nice
  (_j_add "${track_path}") >/dev/null 2>&1 &!
}

_j_chpwd() {
  [[ -z ${OLDPWD:-} ]] || _J_PREV_DIR=${OLDPWD}
  _j_track_directory "${PWD}"
}

_j_help() {
  cat <<'EOF'
Usage:
  j [query ...]       Jump to the best matching directory or choose one
  j -                 Jump to the previous directory
  j -c [query ...]    Open the match in VS Code
  j -v [query ...]    Show search details
  j fetch             Run jfetch
  j -a, --add         Add the current directory
  j --remove          Remove the current directory
  j --db              Show tracked directories and scores
  j --clean           Remove missing directories

Environment:
  J_DATA              Database path (default: $JSH/local/j.db)
  J_EXCLUDE           Colon-separated paths excluded from tracking
  J_PATHS             Colon-separated project roots (default: $GIT_BASE)
  J_NO_HOOK           Disable automatic directory tracking
EOF
}

j() {
  local open_code=false verbose=false line best="" selected resolved project_path exact_match
  local project_candidate gitx_path absolute_path
  local has_exact_conflict=false
  local -a exact_matches project_matches
  local -i count=0

  while (( $# )); do
    case $1 in
      -v|--verbose) verbose=true; shift ;;
      -c|--code) open_code=true; shift ;;
      -a|--add)
        _j_add "${PWD}" || return
        _j_ui_message success "Added: $(_j_display_path "${PWD}")"
        return 0
        ;;
      --remove)
        if _j_remove "${PWD}"; then
          _j_ui_message success "Removed: $(_j_display_path "${PWD}")"
        else
          _j_ui_message warn "Not in database: $(_j_display_path "${PWD}")"
          return 1
        fi
        return 0
        ;;
      --db) _j_list; return ;;
      --clean) _j_clean; return ;;
      -h|--help) _j_help; return 0 ;;
      -)
        if [[ -n ${_J_PREV_DIR} && -d ${_J_PREV_DIR} ]]; then
          if [[ ${open_code} == true ]]; then
            _j_open_code_path "${_J_PREV_DIR}"
          else
            builtin cd -- "${_J_PREV_DIR}"
          fi
        else
          _j_ui_message warn 'No previous directory'
          return 1
        fi
        return
        ;;
      -*) _j_ui_message error "Unknown option: $1"; return 1 ;;
      *) break ;;
    esac
  done

  if [[ $# == 1 && $1 == . ]]; then
    [[ ${open_code} == true ]] && _j_open_code_path "${PWD}" || builtin cd -- "${PWD}"
    return
  fi

  if (( $# == 0 )); then
    selected=$(_j_interactive)
    [[ -n ${selected} ]] || return 0
    if [[ ${open_code} == true ]]; then
      _j_open_code_path "${selected}"
    else
      builtin cd -- "${selected}"
    fi
    return
  fi

  [[ ${verbose} != true ]] || _j_ui_message info "Searching frecency database: ${J_DATA}"
  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    [[ -n ${best} ]] || best=${line}
    if (( $# == 1 )) && [[ $(_j_lowercase "${${line#*|}:t}") == $(_j_lowercase "$1") ]]; then
      exact_matches+=("${line#*|}")
    fi
    (( ++count ))
  done < <(_j_query "$@")

  if (( $# == 1 )); then
    while IFS= read -r project_candidate; do
      [[ -n ${project_candidate} ]] || continue
      absolute_path=${project_candidate/#\~/${HOME}}
      [[ -d ${absolute_path} ]] || continue
      [[ $(_j_lowercase "${absolute_path:t}") == $(_j_lowercase "$1") ]] || continue
      if [[ -n ${project_path} ]] &&
        ! _j_array_contains "${absolute_path}" "${project_path}"; then
        has_exact_conflict=true
      else
        project_path=${absolute_path}
      fi
    done < <(_j_get_projects)

    if (( $+commands[gitx] || $+functions[gitx] )); then
      gitx_path=$(gitx path "$1" 2>/dev/null || true)
      absolute_path=${gitx_path/#\~/${HOME}}
      if [[ -n ${gitx_path} && -d ${absolute_path} ]]; then
        if [[ -n ${project_path} ]] &&
          ! _j_array_contains "${absolute_path}" "${project_path}"; then
          has_exact_conflict=true
        else
          project_path=${absolute_path}
        fi
      fi
    fi

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

  if (( count )); then
    local best_path=${best#*|}
    [[ ${verbose} != true ]] ||
      _j_ui_message success "${count} database match(es), best $(_j_display_path "${best_path}")"
    [[ ${open_code} == true ]] && _j_open_code_path "${best_path}" || builtin cd -- "${best_path}"
    return
  fi

  while IFS= read -r project_candidate; do
    [[ -n ${project_candidate} && -d ${project_candidate} ]] || continue
    _j_matches "${project_candidate}" "$@" || continue
    _j_array_contains "${project_candidate}" "${project_matches[@]}" ||
      project_matches+=("${project_candidate}")
  done < <(_j_get_path_projects)

  if (( ${#project_matches} == 1 )); then
    selected=${project_matches[1]}
  elif (( ${#project_matches} > 1 )); then
    selected=$(_j_interactive "$@")
    [[ -n ${selected} ]] || return 1
  fi
  if [[ -n ${selected} ]]; then
    [[ ${open_code} == true ]] && _j_open_code_path "${selected}" || builtin cd -- "${selected}"
    return
  fi

  if (( $# == 1 )); then
    resolved=$(_j_resolve_path "$1")
    if [[ -n ${resolved} && -d ${resolved} ]]; then
      [[ ${open_code} == true ]] && _j_open_code_path "${resolved}" || builtin cd -- "${resolved}"
      return
    fi
  fi

  _j_ui_message error "No matching directory: $*"
  return 1
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _j_chpwd
alias p='j'

_j_migrate_marks() {
  local marks_file=${HOME}/.marks name mark_path now
  local -i count=0
  [[ -f ${marks_file} && ! -f ${J_DATA} ]] || return 0
  _j_ensure_dir || return 1
  now=$(_j_now)
  while IFS=':' read -r name mark_path; do
    [[ -n ${mark_path} && -d ${mark_path} ]] || continue
    printf '%s|10|%s\n' "${mark_path}" "${now}" >>"${J_DATA}"
    (( ++count ))
  done <"${marks_file}"
  (( count == 0 )) || _j_ui_message success "Migrated ${count} bookmarks, original preserved at ~/.marks"
}

_j_migrate_marks
