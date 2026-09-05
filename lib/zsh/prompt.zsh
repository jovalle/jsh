setopt PROMPT_SUBST
zmodload zsh/datetime 2>/dev/null || true
autoload -Uz add-zsh-hook

typeset -gA _JSH_PROMPT_ICON
case ${JSH_PROMPT_MODE:-nerdfont-v3} in
	nerdfont-v3)
		_JSH_PROMPT_ICON=(
			apple $'\uf179' linux $'\uf17c' branch $'\uf126 '
			prompt '❯' command '❮' visual 'V' overwrite '▶'
			fail '✘' ahead '⇡' behind '⇣' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs $'\uf013' python $'\ue73c' node $'\ue718' kube '⎈'
		)
		;;
	unicode)
		_JSH_PROMPT_ICON=(
			apple 'mac' linux 'linux' branch 'git:'
			prompt '❯' command '❮' visual 'V' overwrite '▶'
			fail '✘' ahead '⇡' behind '⇣' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs '⚙' python 'py:' node 'node:' kube '⎈'
		)
		;;
	ascii)
		_JSH_PROMPT_ICON=(
			apple 'mac' linux 'linux' branch 'git:'
			prompt '>' command '<' visual 'V' overwrite '>>'
			fail 'x' ahead '^' behind 'v' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs 'jobs:' python 'py:' node 'node:' kube 'kube:'
		)
		;;
	*)
		print -u2 -- "jsh: unsupported JSH_PROMPT_MODE: ${JSH_PROMPT_MODE}"
		print -u2 -- 'jsh: expected nerdfont-v3, unicode, or ascii'
		JSH_PROMPT_MODE=nerdfont-v3
		_JSH_PROMPT_ICON=(
			apple $'\uf179' linux $'\uf17c' branch $'\uf126 '
			prompt '❯' command '❮' visual 'V' overwrite '▶'
			fail '✘' ahead '⇡' behind '⇣' stash '*'
			conflict '~' staged '+' unstaged '!' untracked '?'
			jobs $'\uf013' python $'\ue73c' node $'\ue718' kube '⎈'
		)
		;;
esac

typeset -ga JSH_PROMPT_LEFT JSH_PROMPT_RIGHT
(( ${#JSH_PROMPT_LEFT} )) || JSH_PROMPT_LEFT=(os directory git)
(( ${#JSH_PROMPT_RIGHT} )) || \
	JSH_PROMPT_RIGHT=(status duration jobs direnv node python kube aws context time)
[[ ${JSH_PROMPT_ASYNC:-1} == (0|1) ]] || JSH_PROMPT_ASYNC=1
[[ ${JSH_PROMPT_DURATION_MS:-3000} == <-> ]] || JSH_PROMPT_DURATION_MS=3000
[[ ${JSH_PROMPT_DIR_MIN:-14} == <-> ]] || JSH_PROMPT_DIR_MIN=14
typeset -gi JSH_PROMPT_ASYNC=${JSH_PROMPT_ASYNC:-1}
typeset -gi JSH_PROMPT_DURATION_MS=${JSH_PROMPT_DURATION_MS:-3000}
typeset -gi JSH_PROMPT_DIR_MIN=${JSH_PROMPT_DIR_MIN:-14}
typeset -g JSH_PROMPT_KUBE=${JSH_PROMPT_KUBE:-auto}

if [[ ${JSH_PLAIN_OUTPUT:-0} != 1 && ${JSH_COLOR:-auto} != never && \
	-z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
	typeset -g _JSH_C_RESET=$'%{\e[0m%}'
	typeset -g _JSH_C_OS=''
	typeset -g _JSH_C_DIR=$'%{\e[1;38;5;31m%}'
	typeset -g _JSH_C_CLEAN=$'%{\e[38;5;76m%}'
	typeset -g _JSH_C_MODIFIED=$'%{\e[38;5;178m%}'
	typeset -g _JSH_C_UNTRACKED=$'%{\e[38;5;39m%}'
	typeset -g _JSH_C_ERROR=$'%{\e[38;5;196m%}'
	typeset -g _JSH_C_STATUS_ERROR=$'%{\e[38;5;160m%}'
	typeset -g _JSH_C_DURATION=$'%{\e[38;5;101m%}'
	typeset -g _JSH_C_JOBS=$'%{\e[38;5;70m%}'
	typeset -g _JSH_C_ENV=$'%{\e[38;5;37m%}'
	typeset -g _JSH_C_KUBE=$'%{\e[38;5;134m%}'
	typeset -g _JSH_C_AWS=$'%{\e[38;5;208m%}'
	typeset -g _JSH_C_CONTEXT=$'%{\e[38;5;180m%}'
	typeset -g _JSH_C_CONTEXT_ROOT=$'%{\e[38;5;178m%}'
	typeset -g _JSH_C_TIME=$'%{\e[38;5;66m%}'
else
	typeset -g _JSH_C_RESET='' _JSH_C_OS='' _JSH_C_DIR='' _JSH_C_CLEAN=''
	typeset -g _JSH_C_MODIFIED='' _JSH_C_UNTRACKED='' _JSH_C_ERROR=''
	typeset -g _JSH_C_STATUS_ERROR='' _JSH_C_DURATION='' _JSH_C_JOBS=''
	typeset -g _JSH_C_ENV='' _JSH_C_KUBE='' _JSH_C_AWS=''
	typeset -g _JSH_C_CONTEXT='' _JSH_C_CONTEXT_ROOT='' _JSH_C_TIME=''
fi

typeset -g _JSH_PROMPT_EXIT='' _JSH_PROMPT_STARTED='' _JSH_PROMPT_DURATION=0
typeset -g _JSH_PROMPT_GIT_PWD='' _JSH_PROMPT_GIT_BRANCH='' _JSH_PROMPT_GIT_STATE=''
typeset -gi _JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_GIT_DIRTY=1 _JSH_PROMPT_GIT_FD=-1
typeset -gi _JSH_PROMPT_GIT_STAGED=0 _JSH_PROMPT_GIT_UNSTAGED=0
typeset -gi _JSH_PROMPT_GIT_UNTRACKED=0 _JSH_PROMPT_GIT_CONFLICTED=0
typeset -gi _JSH_PROMPT_GIT_AHEAD=0 _JSH_PROMPT_GIT_BEHIND=0 _JSH_PROMPT_GIT_STASH=0
typeset -g _JSH_PROMPT_NODE='' _JSH_PROMPT_NODE_PWD='' _JSH_PROMPT_KUBE_CACHE=''
typeset -gi _JSH_PROMPT_KUBE_DIRTY=1 _JSH_PROMPT_DIR_MAX=0 _JSH_PROMPT_BRANCH_MAX=0
typeset -gi _JSH_PROMPT_HIDE_OS=0 _JSH_PROMPT_HIDE_GIT=0
typeset -gi _JSH_PROMPT_HIDE_DURATION=0 _JSH_PROMPT_HIDE_JOBS=0
typeset -gi _JSH_PROMPT_HIDE_NODE=0 _JSH_PROMPT_HIDE_PYTHON=0
typeset -gi _JSH_PROMPT_HIDE_KUBE=0 _JSH_PROMPT_HIDE_CONTEXT=0
typeset -g _JSH_PROMPT_TIME_MODE=full

_jsh_prompt_escape() {
	REPLY=${1//\%/%%}
}

_jsh_prompt_visible_length() {
	emulate -L zsh -o extended_glob
	local text=${1//\%\{/}
	text=${text//\%\}/}
	text=${text//$'\e'\[[0-9;]##m/}
	text=${text//\%\%/\%}
	REPLY=${#text}
}

_jsh_prompt_directory() {
	if [[ ${PWD} == ${HOME} ]]; then
		REPLY='~'
	elif [[ ${PWD} == ${HOME}/* ]]; then
		REPLY="~/${PWD#${HOME}/}"
	else
		REPLY=${PWD}
	fi
}

_jsh_prompt_abbreviate() {
	local value=$1 max=$2 leaf keep
	REPLY=${value}
	(( max > 0 && ${#value} > max )) || return
	leaf=${value:t}
	keep=$((max - 2))
	(( keep > 0 )) || keep=1
	if (( ${#leaf} >= max )); then
		REPLY="…${leaf[-${keep},-1]}"
	else
		REPLY="…/${leaf}"
	fi
}

_jsh_prompt_join() {
	local separator=$1 name function part result=''
	shift
	for name in "$@"; do
		function=_jsh_prompt_segment_${name}
		(( $+functions[${function}] )) || continue
		${function} || continue
		part=${REPLY}
		[[ -n ${part} ]] || continue
		[[ -z ${result} ]] || result+=${separator}
		result+=${part}
	done
	REPLY=${result}
}

_jsh_prompt_segment_os() {
	(( !_JSH_PROMPT_HIDE_OS )) || { REPLY=''; return; }
	case ${OSTYPE} in
		darwin*) REPLY="${_JSH_C_OS}${_JSH_PROMPT_ICON[apple]}${_JSH_C_RESET}" ;;
		*) REPLY="${_JSH_C_OS}${_JSH_PROMPT_ICON[linux]}${_JSH_C_RESET}" ;;
	esac
}

_jsh_prompt_segment_directory() {
	local directory
	_jsh_prompt_directory
	directory=${REPLY}
	(( _JSH_PROMPT_DIR_MAX == 0 )) || {
		_jsh_prompt_abbreviate "${directory}" ${_JSH_PROMPT_DIR_MAX}
		directory=${REPLY}
	}
	_jsh_prompt_escape "${directory}"
	REPLY="${_JSH_C_DIR}${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_git() {
	local branch=${_JSH_PROMPT_GIT_BRANCH} result
	REPLY=''
	(( !_JSH_PROMPT_HIDE_GIT )) && [[ -n ${branch} ]] || return
	(( _JSH_PROMPT_BRANCH_MAX == 0 )) || {
		_jsh_prompt_abbreviate "${branch}" ${_JSH_PROMPT_BRANCH_MAX}
		branch=${REPLY}
	}
	_jsh_prompt_escape "${branch}"
	result="${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[branch]}${REPLY}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_BEHIND )) && \
		result+=" ${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[behind]}${_JSH_PROMPT_GIT_BEHIND}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_AHEAD && !_JSH_PROMPT_GIT_BEHIND )) && result+=' '
	(( _JSH_PROMPT_GIT_AHEAD )) && \
		result+="${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[ahead]}${_JSH_PROMPT_GIT_AHEAD}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_STASH )) && \
		result+=" ${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[stash]}${_JSH_PROMPT_GIT_STASH}${_JSH_C_RESET}"
	[[ -z ${_JSH_PROMPT_GIT_STATE} ]] || \
		result+=" ${_JSH_C_ERROR}${_JSH_PROMPT_GIT_STATE}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_CONFLICTED )) && \
		result+=" ${_JSH_C_ERROR}${_JSH_PROMPT_ICON[conflict]}${_JSH_PROMPT_GIT_CONFLICTED}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_STAGED )) && \
		result+=" ${_JSH_C_MODIFIED}${_JSH_PROMPT_ICON[staged]}${_JSH_PROMPT_GIT_STAGED}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_UNSTAGED )) && \
		result+=" ${_JSH_C_MODIFIED}${_JSH_PROMPT_ICON[unstaged]}${_JSH_PROMPT_GIT_UNSTAGED}${_JSH_C_RESET}"
	(( _JSH_PROMPT_GIT_UNTRACKED )) && \
		result+=" ${_JSH_C_UNTRACKED}${_JSH_PROMPT_ICON[untracked]}${_JSH_PROMPT_GIT_UNTRACKED}${_JSH_C_RESET}"
	REPLY=${result}
}

_jsh_prompt_segment_status() {
	local exit_code=${_JSH_PROMPT_EXIT}
	REPLY=''
	[[ -n ${exit_code} && ${exit_code} != 0 ]] || return
	case ${exit_code} in
		129) exit_code=HUP ;; 130) exit_code=INT ;; 131) exit_code=QUIT ;;
		137) exit_code=KILL ;; 143) exit_code=TERM ;;
	esac
	REPLY="${_JSH_C_STATUS_ERROR}${_JSH_PROMPT_ICON[fail]} ${exit_code}${_JSH_C_RESET}"
}

_jsh_prompt_segment_duration() {
	local milliseconds=${_JSH_PROMPT_DURATION} seconds result=''
	REPLY=''
	(( !_JSH_PROMPT_HIDE_DURATION && milliseconds >= JSH_PROMPT_DURATION_MS )) || return
	seconds=$((milliseconds / 1000))
	(( seconds < 86400 )) || { result+="$((seconds / 86400))d"; seconds=$((seconds % 86400)); }
	(( seconds < 3600 )) || { result+="$((seconds / 3600))h"; seconds=$((seconds % 3600)); }
	(( seconds < 60 )) || { result+="$((seconds / 60))m"; seconds=$((seconds % 60)); }
	[[ -n ${result} && ${seconds} == 0 ]] || result+="${seconds}s"
	REPLY="${_JSH_C_DURATION}${result}${_JSH_C_RESET}"
}

_jsh_prompt_segment_jobs() {
	REPLY=''
	(( !_JSH_PROMPT_HIDE_JOBS && ${#jobstates} )) || return
	REPLY="${_JSH_C_JOBS}${_JSH_PROMPT_ICON[jobs]} ${#jobstates}${_JSH_C_RESET}"
}

_jsh_prompt_segment_direnv() {
	REPLY=''
	[[ -n ${DIRENV_DIR:-} ]] || return
	REPLY="${_JSH_C_MODIFIED}direnv${_JSH_C_RESET}"
}

_jsh_prompt_segment_node() {
	REPLY=''
	(( !_JSH_PROMPT_HIDE_NODE )) && [[ -n ${_JSH_PROMPT_NODE} ]] || return
	_jsh_prompt_escape "${_JSH_PROMPT_NODE}"
	REPLY="${_JSH_C_CLEAN}${_JSH_PROMPT_ICON[node]}${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_python() {
	local environment=${VIRTUAL_ENV:-${CONDA_DEFAULT_ENV:-}}
	REPLY=''
	(( !_JSH_PROMPT_HIDE_PYTHON )) && [[ -n ${environment} ]] || return
	environment=${environment:t}
	_jsh_prompt_escape "${environment}"
	REPLY="${_JSH_C_ENV}${_JSH_PROMPT_ICON[python]}${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_kube() {
	REPLY=''
	(( !_JSH_PROMPT_HIDE_KUBE )) && [[ -n ${_JSH_PROMPT_KUBE_CACHE} ]] || return
	_jsh_prompt_escape "${_JSH_PROMPT_KUBE_CACHE}"
	REPLY="${_JSH_C_KUBE}${_JSH_PROMPT_ICON[kube]} ${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_aws() {
	local profile=${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}}
	REPLY=''
	[[ -n ${profile} ]] || return
	_jsh_prompt_escape "${profile}"
	REPLY="${_JSH_C_AWS}aws:${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_context() {
	local color=${_JSH_C_CONTEXT}
	REPLY=''
	(( !_JSH_PROMPT_HIDE_CONTEXT )) || return
	[[ -n ${SSH_CONNECTION:-} || ${EUID} == 0 ]] || return
	(( EUID != 0 )) || color=${_JSH_C_CONTEXT_ROOT}
	_jsh_prompt_escape "${USER:-?}@${HOST%%.*}"
	REPLY="${color}${REPLY}${_JSH_C_RESET}"
}

_jsh_prompt_segment_time() {
	local value format='%H:%M:%S'
	REPLY=''
	[[ ${_JSH_PROMPT_TIME_MODE} != none ]] || return
	[[ ${_JSH_PROMPT_TIME_MODE} != compact ]] || format='%H:%M'
	if (( $+builtins[strftime] )); then
		strftime -s value "${format}" ${EPOCHSECONDS:-0}
	elif [[ ${_JSH_PROMPT_TIME_MODE} == compact ]]; then
		value=${(%):-%D{%H:%M}}
	else
		value=${(%):-%D{%H:%M:%S}}
	fi
	REPLY="${_JSH_C_TIME}${value}${_JSH_C_RESET}"
}

_jsh_prompt_segment_character() {
	local icon
	case ${KEYMAP:-viins} in
		vicmd) icon=${_JSH_PROMPT_ICON[command]} ;;
		vivis) icon=${_JSH_PROMPT_ICON[visual]} ;;
		viopp) icon=${_JSH_PROMPT_ICON[overwrite]} ;;
		*) icon=${_JSH_PROMPT_ICON[prompt]} ;;
	esac
	if [[ -n ${_JSH_PROMPT_EXIT} && ${_JSH_PROMPT_EXIT} != 0 ]]; then
		REPLY="${_JSH_C_ERROR}${icon}${_JSH_C_RESET} "
	else
		REPLY="${_JSH_C_CLEAN}${icon}${_JSH_C_RESET} "
	fi
}

_jsh_prompt_build_left() {
	local width=$1 full git full_length git_length room indicators
	_JSH_PROMPT_DIR_MAX=0 _JSH_PROMPT_BRANCH_MAX=0
	_JSH_PROMPT_HIDE_OS=0 _JSH_PROMPT_HIDE_GIT=0
	_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
	_jsh_prompt_visible_length "${full}"; full_length=${REPLY}
	(( full_length < width )) && { REPLY=${full}; return; }
	_jsh_prompt_segment_git; git=${REPLY}
	_jsh_prompt_visible_length "${git}"; git_length=${REPLY}
	room=$((width - git_length - 1))
	if (( room >= JSH_PROMPT_DIR_MIN )); then
		_JSH_PROMPT_DIR_MAX=${room}
	else
		_JSH_PROMPT_DIR_MAX=$((width / 2))
		(( _JSH_PROMPT_DIR_MAX >= 4 )) || _JSH_PROMPT_DIR_MAX=4
		indicators=$((git_length - ${#_JSH_PROMPT_GIT_BRANCH}))
		(( indicators >= 0 )) || indicators=0
		room=$((width - _JSH_PROMPT_DIR_MAX - indicators - 1))
		(( room >= 4 )) && _JSH_PROMPT_BRANCH_MAX=${room} || _JSH_PROMPT_BRANCH_MAX=1
	fi
	_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
	_jsh_prompt_visible_length "${full}"; full_length=${REPLY}
	if (( full_length > width )); then
		_JSH_PROMPT_HIDE_GIT=1
		_JSH_PROMPT_DIR_MAX=$((width - 4))
		(( _JSH_PROMPT_DIR_MAX > 0 )) || _JSH_PROMPT_DIR_MAX=1
		_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
		_jsh_prompt_visible_length "${full}"; full_length=${REPLY}
	fi
	if (( full_length > width )); then
		_JSH_PROMPT_HIDE_OS=1
		_JSH_PROMPT_DIR_MAX=${width}
		_jsh_prompt_join ' ' ${JSH_PROMPT_LEFT}; full=${REPLY}
	fi
	REPLY=${full}
}

_jsh_prompt_build_right() {
	local width=$1 value length name
	_JSH_PROMPT_TIME_MODE=full _JSH_PROMPT_HIDE_DURATION=0 _JSH_PROMPT_HIDE_JOBS=0
	_JSH_PROMPT_HIDE_NODE=0 _JSH_PROMPT_HIDE_PYTHON=0 _JSH_PROMPT_HIDE_KUBE=0
	_JSH_PROMPT_HIDE_CONTEXT=0
	_jsh_prompt_join '  ' ${JSH_PROMPT_RIGHT}; value=${REPLY}
	_jsh_prompt_visible_length "${value}"; length=${REPLY}
	(( length + 4 < width )) || {
		_JSH_PROMPT_TIME_MODE=compact
		_jsh_prompt_join '  ' ${JSH_PROMPT_RIGHT}; value=${REPLY}
	}
	for name in jobs context kube node python duration; do
		_jsh_prompt_visible_length "${value}"; length=${REPLY}
		(( length + 4 < width )) && break
		typeset -g "_JSH_PROMPT_HIDE_${(U)name}=1"
		_jsh_prompt_join '  ' ${JSH_PROMPT_RIGHT}; value=${REPLY}
	done
	_jsh_prompt_visible_length "${value}"; length=${REPLY}
	if (( length + 4 >= width )); then
		_JSH_PROMPT_TIME_MODE=none
		_jsh_prompt_join '  ' ${JSH_PROMPT_RIGHT}; value=${REPLY}
	fi
	REPLY=${value}
}

_jsh_prompt_git_clear() {
	_JSH_PROMPT_GIT_BRANCH='' _JSH_PROMPT_GIT_STATE=''
	_JSH_PROMPT_GIT_STAGED=0 _JSH_PROMPT_GIT_UNSTAGED=0 _JSH_PROMPT_GIT_UNTRACKED=0
	_JSH_PROMPT_GIT_CONFLICTED=0 _JSH_PROMPT_GIT_AHEAD=0 _JSH_PROMPT_GIT_BEHIND=0
	_JSH_PROMPT_GIT_STASH=0
}

_jsh_prompt_git_parse() {
	local data=$1
	_jsh_prompt_git_clear
	[[ -n ${data} && ${data} != - ]] || return
	IFS='|' read -r _JSH_PROMPT_GIT_BRANCH _JSH_PROMPT_GIT_STAGED \
		_JSH_PROMPT_GIT_UNSTAGED _JSH_PROMPT_GIT_UNTRACKED _JSH_PROMPT_GIT_AHEAD \
		_JSH_PROMPT_GIT_BEHIND _JSH_PROMPT_GIT_STASH _JSH_PROMPT_GIT_CONFLICTED \
		_JSH_PROMPT_GIT_STATE <<< "${data}"
	_JSH_PROMPT_GIT_BRANCH=${_JSH_PROMPT_GIT_BRANCH//\%7C/|}
	_JSH_PROMPT_GIT_BRANCH=${_JSH_PROMPT_GIT_BRANCH//\%25/\%}
}

_jsh_prompt_git_operation() {
	local directory=$1 git_directory current='' total=''
	REPLY=''
	git_directory=$(command git -C "${directory}" rev-parse --absolute-git-dir 2>/dev/null) || return
	if [[ -d ${git_directory}/rebase-merge ]]; then
		REPLY=REBASE
		IFS= read -r current < "${git_directory}/rebase-merge/msgnum" 2>/dev/null || true
		IFS= read -r total < "${git_directory}/rebase-merge/end" 2>/dev/null || true
	elif [[ -d ${git_directory}/rebase-apply ]]; then
		[[ -f ${git_directory}/rebase-apply/applying ]] && REPLY=AM || REPLY=REBASE
		IFS= read -r current < "${git_directory}/rebase-apply/next" 2>/dev/null || true
		IFS= read -r total < "${git_directory}/rebase-apply/last" 2>/dev/null || true
	elif [[ -f ${git_directory}/MERGE_HEAD ]]; then REPLY=MERGE
	elif [[ -f ${git_directory}/CHERRY_PICK_HEAD ]]; then REPLY=CHERRY-PICK
	elif [[ -f ${git_directory}/REVERT_HEAD ]]; then REPLY=REVERT
	elif [[ -f ${git_directory}/BISECT_LOG ]]; then REPLY=BISECT
	fi
	if [[ -n ${REPLY} && ${current} == <-> && ${total} == <-> ]]; then
		REPLY+=" ${current}/${total}"
	fi
}

_jsh_prompt_git_worker() {
	emulate -L zsh
	local directory=$1 output line head='' oid='' xy state=''
	local -i staged=0 unstaged=0 untracked=0 conflicted=0 ahead=0 behind=0 stash=0
	output=$(GIT_OPTIONAL_LOCKS=0 command git -c core.fsmonitor=false -C "${directory}" status \
		--porcelain=v2 --branch --show-stash --untracked-files=normal \
		--ignore-submodules=dirty 2>/dev/null) || { print -r -- -; return; }
	for line in ${(f)output}; do
		case ${line} in
			'# branch.oid '*) oid=${line#\# branch.oid } ;;
			'# branch.head '*) head=${line#\# branch.head } ;;
			'# branch.ab '* )
				line=${line#\# branch.ab }
				ahead=${${line%% *}#+}
				behind=${${line##* }#-}
				;;
			'# stash '*) stash=${line#\# stash } ;;
			'1 '*|'2 '*)
				xy=${line[3,4]}
				[[ ${xy[1]} == . ]] || (( staged++ ))
				[[ ${xy[2]} == . ]] || (( unstaged++ ))
				;;
			'u '*) (( conflicted++ )) ;;
			'? '*) (( untracked++ )) ;;
		esac
	done
	[[ -n ${head} && ${head} != '(detached)' ]] || head="@${oid[1,7]}"
	_jsh_prompt_git_operation "${directory}"; state=${REPLY}
	head=${head//\%/%25}
	head=${head//|/%7C}
	print -r -- "${head}|${staged}|${unstaged}|${untracked}|${ahead}|${behind}|${stash}|${conflicted}|${state}"
}

_jsh_prompt_git_async_stop() {
	(( _JSH_PROMPT_GIT_FD >= 0 )) || return
	zle -F ${_JSH_PROMPT_GIT_FD} 2>/dev/null || true
	exec {_JSH_PROMPT_GIT_FD}<&-
	_JSH_PROMPT_GIT_FD=-1
}

_jsh_prompt_git_async_callback() {
	emulate -L zsh
	local descriptor=$1 data directory=${_JSH_PROMPT_GIT_PWD}
	IFS= read -r data <&${descriptor} || data=-
	zle -F ${descriptor} 2>/dev/null || true
	exec {descriptor}<&-
	_JSH_PROMPT_GIT_FD=-1
	[[ ${directory} == ${PWD} ]] || return
	_jsh_prompt_git_parse "${data}"
	_JSH_PROMPT_GIT_VALID=1 _JSH_PROMPT_GIT_DIRTY=0
	_jsh_prompt_render
	zle reset-prompt 2>/dev/null || true
}

_jsh_prompt_git_async_start() {
	_jsh_prompt_git_async_stop
	_JSH_PROMPT_GIT_PWD=${PWD}
	exec {_JSH_PROMPT_GIT_FD}< <(_jsh_prompt_git_worker "${PWD}") || return
	zle -F ${_JSH_PROMPT_GIT_FD} _jsh_prompt_git_async_callback 2>/dev/null || {
		exec {_JSH_PROMPT_GIT_FD}<&-
		_JSH_PROMPT_GIT_FD=-1
		return 1
	}
}

_jsh_prompt_git_update() {
	local data
	(( $+commands[git] )) || { _jsh_prompt_git_clear; return; }
	if [[ ${_JSH_PROMPT_GIT_PWD} != ${PWD} ]]; then
		_jsh_prompt_git_clear
		_JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_GIT_DIRTY=1
	fi
	(( _JSH_PROMPT_GIT_DIRTY || !_JSH_PROMPT_GIT_VALID )) || return
	if (( JSH_PROMPT_ASYNC )) && _jsh_prompt_git_async_start; then
		return
	fi
	data=$(_jsh_prompt_git_worker "${PWD}")
	_jsh_prompt_git_parse "${data}"
	_JSH_PROMPT_GIT_PWD=${PWD} _JSH_PROMPT_GIT_VALID=1 _JSH_PROMPT_GIT_DIRTY=0
}

_jsh_prompt_find_up() {
	local name=$1 directory=${PWD}
	REPLY=''
	while [[ -n ${directory} ]]; do
		[[ ! -r ${directory}/${name} ]] || { REPLY=${directory}/${name}; return; }
		[[ ${directory} != / ]] || break
		directory=${directory:h}
	done
	return 1
}

_jsh_prompt_node_update() {
	local file version
	[[ ${_JSH_PROMPT_NODE_PWD} != ${PWD} ]] || return
	_JSH_PROMPT_NODE_PWD=${PWD} _JSH_PROMPT_NODE=''
	if _jsh_prompt_find_up .nvmrc || _jsh_prompt_find_up .node-version; then
		file=${REPLY}
		IFS= read -r version < "${file}" || true
		version=${version#v}
		[[ -z ${version} ]] || _JSH_PROMPT_NODE=${version}
	elif [[ -n ${NODE_VERSION:-} ]]; then
		_JSH_PROMPT_NODE=${NODE_VERSION#v}
	fi
}

_jsh_prompt_kube_update() {
	_JSH_PROMPT_KUBE_CACHE=''
	[[ ${JSH_PROMPT_KUBE} != 0 ]] || return
	(( $+commands[kubectl] )) || return
	_JSH_PROMPT_KUBE_CACHE=$(command kubectl config current-context 2>/dev/null) || \
		_JSH_PROMPT_KUBE_CACHE=''
}

_jsh_prompt_now() {
	if [[ -n ${EPOCHREALTIME:-} ]]; then
		printf -v REPLY '%.0f' "$((EPOCHREALTIME * 1000))"
	else
		REPLY=$((SECONDS * 1000))
	fi
}

_jsh_prompt_preexec() {
	_jsh_prompt_now
	_JSH_PROMPT_STARTED=${REPLY}
	_JSH_PROMPT_GIT_DIRTY=1
	case ${1%% *} in
		kubectl | kubectx | kubens) _JSH_PROMPT_KUBE_DIRTY=1 ;;
	esac
}

_jsh_prompt_precmd() {
	local exit_code=$? now
	_JSH_PROMPT_EXIT=${exit_code}
	if [[ -n ${_JSH_PROMPT_STARTED} ]]; then
		_jsh_prompt_now; now=${REPLY}
		_JSH_PROMPT_DURATION=$((now - _JSH_PROMPT_STARTED))
	else
		_JSH_PROMPT_DURATION=0
	fi
	_JSH_PROMPT_STARTED=''
	_jsh_prompt_git_update
	_jsh_prompt_node_update
	if (( _JSH_PROMPT_KUBE_DIRTY )); then
		_jsh_prompt_kube_update
		_JSH_PROMPT_KUBE_DIRTY=0
	fi
	_jsh_prompt_render
}

_jsh_prompt_render() {
	local width=${COLUMNS:-80} left right character padding
	local -i left_length right_length spaces right_budget left_budget
	[[ ${width} == <-> && ${width} -gt 0 ]] || width=80
	right_budget=$((width / 2))
	(( right_budget >= 8 )) || right_budget=8
	_jsh_prompt_build_right ${right_budget}; right=${REPLY}
	_jsh_prompt_visible_length "${right}"; right_length=${REPLY}
	left_budget=$((width - right_length - 1))
	(( left_budget > 0 )) || left_budget=1
	_jsh_prompt_build_left ${left_budget}; left=${REPLY}
	_jsh_prompt_visible_length "${left}"; left_length=${REPLY}
	spaces=$((width - left_length - right_length))
	(( spaces > 0 )) || spaces=1
	printf -v padding '%*s' ${spaces} ''
	_jsh_prompt_segment_character; character=${REPLY}
	PROMPT="${left}${padding}${right}"$'\n'"${character}"
	RPROMPT=''
}

_jsh_prompt_chpwd() {
	_JSH_PROMPT_GIT_DIRTY=1 _JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_KUBE_DIRTY=1
	_jsh_prompt_git_clear
	_jsh_prompt_node_update
}

_jsh_prompt_keymap_select() {
	_jsh_prompt_render
	zle reset-prompt 2>/dev/null || true
}

jsh_prompt_refresh() {
	_JSH_PROMPT_GIT_DIRTY=1 _JSH_PROMPT_GIT_VALID=0 _JSH_PROMPT_KUBE_DIRTY=1
	_jsh_prompt_precmd
}

jsh_prompt_status() {
	print -r -- "runtime=jsh glyphs=${JSH_PROMPT_MODE:-nerdfont-v3} async=${JSH_PROMPT_ASYNC}"
}

add-zsh-hook preexec _jsh_prompt_preexec
add-zsh-hook precmd _jsh_prompt_precmd
add-zsh-hook chpwd _jsh_prompt_chpwd
add-zsh-hook zshexit _jsh_prompt_git_async_stop
zle -N zle-keymap-select _jsh_prompt_keymap_select
_jsh_prompt_node_update
_jsh_prompt_render
