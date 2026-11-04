#!/usr/bin/env bash
# Extend native Git completion and expose the runtime's commands in Bash 3.2+.

_jsh_complete() {
  local suggestion
  COMPREPLY=()
  [[ ${COMP_CWORD} == 1 ]] || return 0
  while IFS= read -r suggestion; do COMPREPLY+=("${suggestion}"); done < <(
    compgen -W '--help -r reload -c -i' -- "${COMP_WORDS[COMP_CWORD]}"
  )
}
complete -F _jsh_complete jsh

_jsh_git_complete() {
  local suggestion current=${COMP_WORDS[COMP_CWORD]} native=''
  COMPREPLY=()
  if ! declare -F _git >/dev/null && ! declare -F __git_wrap__git_main >/dev/null &&
    declare -F _completion_loader >/dev/null; then
    _completion_loader git >/dev/null 2>&1 || true
    complete -o bashdefault -o default -o nospace -F _jsh_git_complete git
  fi
  if declare -F __git_wrap__git_main >/dev/null; then
    native=__git_wrap__git_main
  elif declare -F _git >/dev/null; then native=_git; fi
  [[ -z ${native} ]] || "${native}" "$@"
  [[ ${COMP_CWORD} == 1 ]] || return 0
  while IFS= read -r suggestion; do COMPREPLY+=("${suggestion}"); done < <(
    compgen -W 'create get commits amend profile save load refresh handoff' -- "${current}"
  )
  if [[ -z ${native} ]]; then
    while IFS= read -r suggestion; do COMPREPLY+=("${suggestion}"); done < <(
      compgen -W "$(command git --list-cmds=main,alias 2>/dev/null)" -- "${current}"
    )
  fi
}
complete -o bashdefault -o default -o nospace -F _jsh_git_complete git

_jsh_jump_complete() {
  local candidate name current=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=()
  while IFS= read -r candidate; do
    name=${candidate##*/}
    [[ ${name} != "${current}"* ]] || COMPREPLY+=("${name}")
  done < <(_j_get_projects)
  if [[ ${current} == -* ]]; then
    while IFS= read -r candidate; do COMPREPLY+=("${candidate}"); done < <(
      compgen -W '-c -v -a --add --remove --db --clean --help' -- "${current}"
    )
  fi
}
complete -o bashdefault -o default -F _jsh_jump_complete j p
