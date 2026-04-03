# Recursive grep skips generated and dependency directories unless one is named explicitly.

unalias grep egrep fgrep ggrep 2>/dev/null || true
unset -f grep egrep fgrep ggrep 2>/dev/null || true

_jsh_grep_backend='grep'
_jsh_grep_has_gnu=0
if command -v ggrep >/dev/null 2>&1; then
  _jsh_grep_has_gnu=1
  if [[ $(uname -s 2>/dev/null) == Darwin ]]; then
    _jsh_grep_backend='ggrep'
  fi
fi

_jsh_grep_run() {
  local executable="$1" mode="$2" argument directory explicit option_value=''
  local pattern_supplied=0 options_done=0
  local -a exclusions paths
  shift 2

  for argument in "$@"; do
    if [[ -n ${option_value} ]]; then
      [[ ${option_value} == pattern ]] && pattern_supplied=1
      option_value=''
      continue
    fi
    if [[ ${options_done} == 0 ]]; then
      case "${argument}" in
        --)
          options_done=1
          continue
          ;;
        -e | -f | --regexp | --file)
          option_value=pattern
          continue
          ;;
        -A | -B | -C | -D | -d | -m | --after-context | --before-context | --binary-files | --context | --devices | --directories | --exclude | --exclude-dir | --exclude-from | --group-separator | --include | --label | --max-count)
          option_value=option
          continue
          ;;
        -e?* | -f?* | --regexp=* | --file=*)
          pattern_supplied=1
          continue
          ;;
        -*) continue ;;
      esac
    fi
    if [[ ${pattern_supplied} == 0 ]]; then
      pattern_supplied=1
    else
      paths+=("${argument}")
    fi
  done

  for directory in \
    .git .hg .svn \
    .venv venv .tox .nox .direnv \
    node_modules bower_components jspm_packages vendor Pods Carthage \
    __pycache__ .pytest_cache .mypy_cache .ruff_cache .hypothesis \
    .gradle .dart_tool .pub-cache .terraform \
    .cache .parcel-cache .turbo \
    build dist out target coverage htmlcov \
    .next .nuxt .svelte-kit .astro \
    zig-cache zig-out; do
    explicit=0
    for argument in "${paths[@]}"; do
      [[ -e ${argument} ]] || continue
      if [[ "/${argument#./}/" == *"/${directory}/"* ]]; then
        explicit=1
        break
      fi
    done
    [[ ${explicit} == 1 ]] || exclusions+=("--exclude-dir=${directory}")
  done

  if [[ -n ${mode} ]]; then
    command "${executable}" "${mode}" --color=auto "${exclusions[@]}" "$@"
  else
    command "${executable}" --color=auto "${exclusions[@]}" "$@"
  fi
}

grep() {
  _jsh_grep_run "${_jsh_grep_backend}" '' "$@"
}

egrep() {
  _jsh_grep_run "${_jsh_grep_backend}" -E "$@"
}

fgrep() {
  _jsh_grep_run "${_jsh_grep_backend}" -F "$@"
}

if [[ ${_jsh_grep_has_gnu} == 1 ]]; then
  ggrep() {
    _jsh_grep_run ggrep '' "$@"
  }
fi
