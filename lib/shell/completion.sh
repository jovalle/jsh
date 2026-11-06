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

# Complete arguments of jsh's own git subcommands; return 1 for any other subcommand.
_jsh_git_extra() {
  local current=${COMP_WORDS[COMP_CWORD]} i
  case ${COMP_WORDS[1]} in
    profile)
      if [[ ${COMP_CWORD} == 2 ]]; then
        # shellcheck disable=SC2154  # JSH is exported by the rc
        _jsh_reply "$("${JSH}/bin/git" __complete profile 2>/dev/null)" "${current}"
        _jsh_reply '--list -h --help' "${current}"
      fi
      ;;
    create)
      if [[ ${COMP_CWORD} == 3 ]]; then
        # shellcheck disable=SC2154  # JSH is exported by the rc
        _jsh_reply "$("${JSH}/bin/git" __complete profile 2>/dev/null)" "${current}"
      fi
      ;;
    load) _jsh_reply '-f --force -h --help' "${current}" ;;
    handoff) _jsh_reply '-n --dry-run --clean -h --help' "${current}" ;;
    amend) _jsh_reply '-x -t -h --help' "${current}" ;;
    save | refresh | get | commits) _jsh_reply '-h --help' "${current}" ;;
    *) return 1 ;;
  esac
  # Native git completions end in a space and the git spec has nospace.
  for i in "${!COMPREPLY[@]}"; do COMPREPLY[i]+=' '; done
  return 0
}

_jsh_git_complete() {
  local suggestion current=${COMP_WORDS[COMP_CWORD]} native=''
  COMPREPLY=()
  if ! declare -F _git >/dev/null && ! declare -F __git_wrap__git_main >/dev/null &&
    declare -F _completion_loader >/dev/null; then
    _completion_loader git >/dev/null 2>&1 || true
    complete -o bashdefault -o default -o nospace -F _jsh_git_complete git
  fi
  if [[ ${COMP_CWORD} -ge 2 ]] && _jsh_git_extra; then return 0; fi
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

# Append the whitespace-separated words in LIST that start with CURRENT to COMPREPLY.
_jsh_reply() {
  local candidate
  while IFS= read -r candidate; do
    [[ -z ${candidate} || ${candidate} != "$2"* ]] || COMPREPLY+=("${candidate}")
  done < <(printf '%s\n' "$1" | tr -s ' \t' '\n\n')
}

_jsh_kube_contexts() {
  command kubectl config get-contexts -o name --request-timeout=2s 2>/dev/null || true
}

_jsh_kube_namespaces() {
  command kubectl --request-timeout=2s get namespaces \
    -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# Set cur, words and cword, rejoining the pieces Bash splits at ':' in COMP_WORDBREAKS.
_jsh_kube_words() {
  local i word last join=0
  words=()
  cword=0
  for ((i = 0; i < ${#COMP_WORDS[@]}; i++)); do
    word=${COMP_WORDS[i]}
    last=$((${#words[@]} - 1))
    if [[ -n ${word} && -z ${word//:/} && ${last} -ge 0 ]]; then
      words[last]+=${word}
      join=1
    elif [[ ${join} == 1 && -n ${word} ]]; then
      words[last]+=${word}
      join=0
    else
      words+=("${word}")
      join=0
    fi
    [[ ${i} != "${COMP_CWORD}" ]] || cword=$((${#words[@]} - 1))
  done
  cur=${words[cword]}
}

# Readline replaces only the text after the last ':', so drop the rest from each reply.
_jsh_kube_finish() {
  local prefix i
  [[ $1 == *:* && ${COMP_WORDBREAKS} == *:* ]] || return 0
  prefix=${1%"${1##*:}"}
  for i in "${!COMPREPLY[@]}"; do COMPREPLY[i]=${COMPREPLY[i]#"${prefix}"}; done
}

_jsh_kubectx_complete() {
  local cur words cword
  COMPREPLY=()
  _jsh_kube_words
  if [[ ${cword} == 1 ]]; then
    _jsh_reply "$(_jsh_kube_contexts)" "${cur}"
    _jsh_reply '- -a --add -c --current -d --delete -u --unset -h --help' "${cur}"
  elif [[ ${cword} -ge 2 && ( ${words[1]} == -d || ${words[1]} == --delete ) ]]; then
    _jsh_reply "$(_jsh_kube_contexts)" "${cur}"
  fi
  _jsh_kube_finish "${cur}"
}
complete -o default -F _jsh_kubectx_complete kubectx

_jsh_kubens_complete() {
  local cur words cword
  COMPREPLY=()
  _jsh_kube_words
  [[ ${cword} == 1 ]] || return 0
  _jsh_reply "$(_jsh_kube_namespaces)" "${cur}"
  _jsh_reply '- -c --current -h --help' "${cur}"
  _jsh_kube_finish "${cur}"
}
complete -F _jsh_kubens_complete kubens

_jsh_nukem_complete() {
  local cur words cword i ctx='' positional=0
  COMPREPLY=()
  _jsh_kube_words
  for ((i = 1; i < cword; i++)); do
    case ${words[i]} in
      -c | --context)
        i=$((i + 1))
        ctx=${words[i]:-}
        ;;
      -*) ;;
      *) positional=1 ;;
    esac
  done
  if [[ ${words[cword - 1]} == -c || ${words[cword - 1]} == --context ]]; then
    _jsh_reply "$(_jsh_kube_contexts)" "${cur}"
  else
    if [[ ${positional} == 0 && ${cur} != -* ]]; then
      # shellcheck disable=SC2154  # JSH is exported by the rc
      _jsh_reply "$(NUKEM_TIMEOUT=2 "${JSH}/bin/nukem" __complete namespace ${ctx:+"${ctx}"} 2>/dev/null)" "${cur}"
    fi
    _jsh_reply '-l --list -f --force -n --dry-run -c --context -v --verbose -h --help --version' "${cur}"
  fi
  _jsh_kube_finish "${cur}"
}
complete -F _jsh_nukem_complete nukem

_jsh_jssh_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=()
  if [[ ${COMP_CWORD} == 1 && ${cur} == -* ]]; then
    _jsh_reply '--check --rebuild -r --raw -h --help --version' "${cur}"
  else
    # shellcheck disable=SC2154  # JSH is exported by the rc
    _jsh_reply "$("${JSH}/bin/jssh" __complete host 2>/dev/null | cut -f1)" "${cur}"
  fi
}
complete -F _jsh_jssh_complete jssh

_jsh_proxy_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]} i cmd=-1 value='' opts=1
  COMPREPLY=()
  for ((i = 1; i < COMP_CWORD; i++)); do
    case ${COMP_WORDS[i]} in
      -p | --preset | -u | --url | -s | --socks | -n | --no-proxy)
        if [[ ${COMP_WORDS[i]} == -p || ${COMP_WORDS[i]} == --preset ]]; then
          value=preset
        else
          value=none
        fi
        i=$((i + 1))
        [[ ${i} != "${COMP_CWORD}" ]] || break
        value=''
        ;;
      --)
        cmd=$((i + 1))
        opts=0
        break
        ;;
      -*) ;;
      *)
        cmd=${i}
        break
        ;;
    esac
  done
  if [[ ${value} == preset ]]; then
    # shellcheck disable=SC2154  # JSH is exported by the rc
    _jsh_reply "$("${JSH}/bin/proxy" __complete preset 2>/dev/null | cut -f1)" "${cur}"
  elif [[ ${value} == none ]]; then
    return 0
  else
    [[ ${cmd} -ge 0 || ${cur} == -* ]] || cmd=${COMP_CWORD}
    if [[ ${cmd} -ge 0 ]]; then
      if declare -F _command_offset >/dev/null; then
        _command_offset "${cmd}"
      elif [[ ${cmd} == "${COMP_CWORD}" ]]; then
        _jsh_reply "$(compgen -c -- "${cur}")" "${cur}"
      fi
    fi
    if [[ ${opts} == 1 && (${cmd} -lt 0 || (${cmd} == "${COMP_CWORD}" && -z ${cur})) ]]; then
      _jsh_reply '-p --preset -u --url -s --socks -n --no-proxy --shell --env --test --list -v --verbose -h --help --version' "${cur}"
    fi
  fi
}
complete -o bashdefault -o default -F _jsh_proxy_complete proxy

# Reuse kubectl's completion for the kubecolor wrapper.
declare -F __start_kubectl >/dev/null && complete -o default -F __start_kubectl kubecolor

# Bash does not complete through aliases: rewrite the line as the aliased command and defer to its spec.
_jsh_alias_complete() {
  local name=${COMP_WORDS[0]} value word lead rest joined spec func target quote="'" escaped
  local -a original=("${COMP_WORDS[@]}") expanded=() target_words=()
  local COMP_WORDS COMP_CWORD=${COMP_CWORD} COMP_LINE=${COMP_LINE} COMP_POINT=${COMP_POINT}
  escaped="'\\''"
  COMPREPLY=()
  [[ ${COMP_CWORD} -ge 1 ]] || return 0
  value=$(alias "${name}" 2>/dev/null) || return 0
  value=${value#*=}
  value=${value#\'}
  value=${value%\'}
  value=${value//"${escaped}"/${quote}}
  read -r -a expanded <<<"${value}"
  for word in ${expanded[@]+"${expanded[@]}"}; do
    [[ ${word} != *[\|\&\;\<\>]* ]] || break
    target_words+=("${word}")
  done
  [[ ${#target_words[@]} -gt 0 ]] || return 0
  target=${target_words[0]}
  spec=$(complete -p "${target}" 2>/dev/null) || spec=''
  if [[ -z ${spec} ]] && declare -F _completion_loader >/dev/null; then
    _completion_loader "${target}" >/dev/null 2>&1 || true
    spec=$(complete -p "${target}" 2>/dev/null) || spec=''
  fi
  [[ ${spec} == *' -F '* ]] || return 0
  func=${spec#* -F }
  func=${func%% *}
  [[ ${func} != _jsh_alias_complete ]] && declare -F "${func}" >/dev/null || return 0

  joined=${target_words[0]}
  for word in "${target_words[@]:1}"; do joined+=" ${word}"; done
  lead=${COMP_LINE%%[![:space:]]*}
  rest=${COMP_LINE#"${lead}"}
  rest=${rest#"${name}"}
  COMP_LINE=${lead}${joined}${rest}
  COMP_POINT=$((COMP_POINT + ${#joined} - ${#name}))
  COMP_WORDS=("${target_words[@]}" "${original[@]:1}")
  COMP_CWORD=$((COMP_CWORD + ${#target_words[@]} - 1))
  "${func}" "${target}" "$2" "${COMP_WORDS[COMP_CWORD - 1]}"
}

# Register aliases whose command has a -F spec but which have none of their own.
_jsh_alias_register() {
  local line rest func name value first specs flags opt all=' ' funcs=' ' optmap='' restore=1
  local -a opts
  local IFS=$'\n'
  [[ $- != *f* ]] || restore=0
  set -f
  specs=$(complete -p 2>/dev/null)
  for line in ${specs}; do
    name=${line##* }
    all+="${name} "
    [[ ${line} == *' -F '* ]] || continue
    rest=${line#* -F }
    func=${rest%% *}
    [[ ${func} != _jsh_alias_complete ]] || continue
    funcs+="${name} "
    flags=''
    for opt in bashdefault default nospace filenames; do
      [[ ${line} != *" -o ${opt} "* ]] || flags+="-o ${opt} "
    done
    optmap+=$'\001'"${name}"$'\002'"${flags}"
  done
  specs=$(alias -p)
  for line in ${specs}; do
    [[ ${line} == 'alias '* ]] || continue
    value=${line#alias }
    value=${value#-- }
    first=${value#*=\'}
    first=${first%%[[:space:]\']*}
    [[ ${funcs} == *" ${first} "* ]] || continue
    name=${value%%=*}
    [[ ${name} != -* && ${all} != *" ${name} "* ]] || continue
    rest=${optmap#*$'\001'"${first}"$'\002'}
    IFS=' ' read -r -a opts <<<"${rest%%$'\001'*}"
    complete ${opts[@]+"${opts[@]}"} -F _jsh_alias_complete "${name}"
  done
  [[ ${restore} == 0 ]] || set +f
}
_jsh_alias_register
