#!/usr/bin/env bash
# Bash 3.2 prompt adapter. Shared commands and navigation live in shell-*.sh.
# shellcheck disable=SC2154 # Interactive rc supplies JSH, JSH_OS and navigation helpers.

# Dynamic prompt text is expanded from a variable, so its contents are never evaluated.
_jsh_bash_prompt_escape() {
  REPLY=${1//[[:cntrl:]]/?}
}

_jsh_bash_capture_status() {
  _JSH_BASH_STATUS=$?
  _JSH_BASH_STATUS_SET=1
  jsh::reload_pending
  return "${_JSH_BASH_STATUS}"
}

_jsh_bash_prompt() {
  local result=$? line branch='' oid='' xy ahead=0 behind=0 staged=0 modified=0 untracked=0 conflicts=0 stash=0
  local reset='' dir_color='' git_color='' changed_color='' new_color='' error_color='' env_color='' time_color=''
  local mode=${JSH_PROMPT_MODE:-nerdfont-v3} os=${JSH_OS} mark='>' branch_mark='git:' environment='' context='' jobs_count=0
  local directory=${PWD} right='' stamp='' REPLY='' room
  if [[ ${_JSH_BASH_STATUS_SET:-0} == 1 ]]; then
    result=${_JSH_BASH_STATUS}
    _JSH_BASH_STATUS_SET=0
  fi
  # shortcut: Bash 3.2's first empty history session saves at exit; newer Bash shares immediately.
  history -a
  history -n
  if [[ ${_JSH_BASH_PWD:-} != "${PWD}" ]]; then
    [[ -z ${OLDPWD:-} ]] || _J_PREV_DIR=${OLDPWD}
    _JSH_BASH_PWD=${PWD}
    if [[ -z ${J_NO_HOOK:-} ]]; then _j_add "${PWD}" >/dev/null 2>&1; fi
  fi
  case ${LC_ALL:-${LC_CTYPE:-${LANG:-C}}} in *[Uu][Tt][Ff]*8*) ;; *) mode=ascii ;; esac
  case ${mode} in
    nerdfont-v3)
      if [[ ${JSH_OS} == macos ]]; then os=$'\xef\x85\xb9'; else os=$'\xef\x85\xbc'; fi
      branch_mark=$'\xef\x84\xa6 '
      mark='❯'
      ;;
    unicode) mark='❯' ;;
    ascii) ;;
    *) mode=ascii ;;
  esac
  if [[ -z ${NO_COLOR+x} && ${JSH_COLOR:-auto} != never && ${JSH_PLAIN_OUTPUT:-0} != 1 && ${TERM:-dumb} != dumb ]]; then
    reset=$'\001\e[0m\002'
    dir_color=$'\001\e[1;38;2;0;191;255m\002'
    git_color=$'\001\e[38;2;95;255;0m\002'
    changed_color=$'\001\e[38;2;255;215;0m\002'
    new_color=$'\001\e[38;2;0;215;255m\002'
    error_color=$'\001\e[38;2;255;59;48m\002'
    env_color=$'\001\e[38;2;41;184;219m\002'
    time_color=$'\001\e[38;2;128;128;128m\002'
  fi
  while IFS= read -r line; do
    case ${line} in
      '# branch.head '*) branch=${line#\# branch.head } ;;
      '# branch.oid '*) oid=${line#\# branch.oid } ;;
      '# branch.ab '*)
        xy=${line#\# branch.ab }
        ahead=${xy%% *}
        ahead=${ahead#+}
        behind=${xy##* }
        behind=${behind#-}
        ;;
      '# stash '*) stash=${line#\# stash } ;;
      '1 '* | '2 '*)
        xy=${line:2:2}
        [[ ${xy:0:1} == . ]] || staged=$((staged + 1))
        [[ ${xy:1:1} == . ]] || modified=$((modified + 1))
        ;;
      '? '*) untracked=$((untracked + 1)) ;;
      'u '*) conflicts=$((conflicts + 1)) ;;
    esac
  done < <(GIT_OPTIONAL_LOCKS=0 command git -c core.fsmonitor=false status --porcelain=v2 \
    --branch --show-stash --untracked-files=normal --ignore-submodules=dirty 2>/dev/null)
  [[ ${branch} != '(detached)' ]] || branch=@${oid:0:7}
  if [[ ${directory} == "${HOME}" ]]; then
    directory='~'
  elif [[ ${directory} == "${HOME}/"* ]]; then directory="~${directory#"${HOME}"}"; fi
  # shortcut: use a clipped first line on narrow terminals; add segment layout only if needed.
  room=$((${COLUMNS:-80} / 2))
  ((room >= 4)) || room=4
  if ((${#directory} > room)); then
    if [[ ${mode} == ascii ]]; then
      directory=...${directory: -$((room - 3))}
    else directory=…${directory: -$((room - 1))}; fi
  fi
  _jsh_bash_prompt_escape "${directory}"
  directory=${REPLY}
  _jsh_bash_prompt_escape "${branch}"
  branch=${REPLY}
  PS1="${os} ${dir_color}${directory}${reset}"
  [[ -z ${branch} ]] || PS1+=" ${git_color}${branch_mark}${branch}${reset}"
  ((behind == 0)) || PS1+=" ${git_color}v${behind}${reset}"
  ((ahead == 0)) || PS1+=" ${git_color}^${ahead}${reset}"
  ((stash == 0)) || PS1+=" ${changed_color}*${stash}${reset}"
  ((staged == 0)) || PS1+=" ${changed_color}+${staged}${reset}"
  ((modified == 0)) || PS1+=" ${changed_color}!${modified}${reset}"
  ((untracked == 0)) || PS1+=" ${new_color}?${untracked}${reset}"
  ((conflicts == 0)) || PS1+=" ${error_color}~${conflicts}${reset}"
  [[ -z ${DIRENV_DIR:-} ]] || right+=' direnv'
  environment=${VIRTUAL_ENV:-${CONDA_DEFAULT_ENV:-}}
  [[ -z ${environment} ]] || right+=" py:${environment##*/}"
  [[ -z ${NODE_VERSION:-} ]] || right+=" node:${NODE_VERSION#v}"
  [[ -z ${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}} ]] || right+=" aws:${AWS_PROFILE:-${AWS_DEFAULT_PROFILE}}"
  jobs_count=$(jobs -p | command wc -l)
  ((jobs_count == 0)) || right+=" jobs:${jobs_count//[[:space:]]/}"
  _jsh_bash_prompt_escape "${right}"
  right=${REPLY}
  [[ -z ${right} ]] || PS1+=" ${env_color}${right# }${reset}"
  if [[ -n ${SSH_CONNECTION:-} || ${EUID} == 0 ]]; then
    _jsh_bash_prompt_escape "${USER:-user}@${HOSTNAME%%.*} "
    context=${REPLY}
  fi
  PS1="${context}${PS1}"
  if ((${COLUMNS:-80} >= 80)); then
    # Bash 3.2 lacks printf's time format.
    stamp=$(command date +%H:%M:%S)
    PS1+=" ${time_color}${stamp}${reset}"
  fi
  if ((result != 0)); then
    PS1+=$'\n'"${error_color}x ${result} ${mark}${reset} "
  else
    PS1+=$'\n'"${git_color}${mark}${reset} "
  fi
  _JSH_BASH_RENDERED_PROMPT=${PS1}
  PS1='${_JSH_BASH_RENDERED_PROMPT}'
}

_jsh_bash_strip_prompt_hooks() {
  local hook text=$1
  case ${text} in
    _jsh_bash_capture_status\;* | _jsh_bash_prompt\;*) text=${text#*;} ;;
  esac
  text=${text%;_jsh_bash_prompt}
  text=$'\n'"${text}"$'\n'
  for hook in _jsh_bash_capture_status _jsh_bash_prompt; do
    while [[ ${text} == *$'\n'"${hook}"$'\n'* ]]; do
      text=${text//$'\n'"${hook}"$'\n'/$'\n'}
    done
  done
  text=${text#$'\n'}
  REPLY=${text%$'\n'}
}

_jsh_bash_install_prompt() {
  local hook command='' declaration REPLY
  local -a hooks=()
  declaration=$(declare -p PROMPT_COMMAND 2>/dev/null)
  if [[ ${declaration} == 'declare -a '* ]]; then
    for hook in "${PROMPT_COMMAND[@]}"; do
      _jsh_bash_strip_prompt_hooks "${hook}"
      [[ -z ${REPLY} ]] || hooks+=("${REPLY}")
    done
    PROMPT_COMMAND=(_jsh_bash_capture_status "${hooks[@]}" _jsh_bash_prompt)
  else
    # bash-preexec may surround our hooks; remove only complete lines we installed.
    _jsh_bash_strip_prompt_hooks "${PROMPT_COMMAND:-}"
    command=${REPLY}
    # shellcheck disable=SC2178 # Bash supports scalar and array PROMPT_COMMAND.
    PROMPT_COMMAND=$'_jsh_bash_capture_status\n'"${command}"$'\n_jsh_bash_prompt'
  fi
  # PS0 needs expansion for preexec hooks; PS1 expands only the trusted variable reference.
  shopt -s promptvars
}

jsh_prompt_refresh() { _jsh_bash_prompt; }
jsh_prompt_status() { printf 'runtime=jsh shell=bash glyphs=%s async=0\n' "${JSH_PROMPT_MODE:-nerdfont-v3}"; }
