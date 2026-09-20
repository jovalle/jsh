#!/usr/bin/env bash
# Route semantic Jsh UI calls to plain shell, enhanced shell, or Gum backends.

jsh_ui_library_dir() {
  local source_file
  if [[ -n ${BASH_VERSION:-} ]]; then
    source_file=${BASH_SOURCE[0]}
  else
    # funcsourcetrace is a Zsh special parameter.
    # shellcheck disable=SC2154
    source_file=${funcsourcetrace[1]%:*}
  fi
  case ${source_file} in
    */*) printf '%s\n' "${source_file%/*}" ;;
    *) printf '%s\n' . ;;
  esac
}

JSH_UI_LIBRARY_DIR=$(jsh_ui_library_dir)
typeset -f jsh_env_detect > /dev/null 2>&1 || . "${JSH_UI_LIBRARY_DIR}/env.sh"
typeset -f jsh_info > /dev/null 2>&1 || . "${JSH_UI_LIBRARY_DIR}/output.sh"
typeset -f ui::token > /dev/null 2>&1 || . "${JSH_UI_LIBRARY_DIR}/ui/theme.sh"
: "${JSH_UI_BACKEND:=plain}"
: "${JSH_GUM:=}"
: "${JSH_UI_INPUT_FD:=0}"
: "${JSH_UI_OUTPUT_FD:=2}"
: "${JSH_UI_OWNS_FD:=0}"
: "${JSH_SPINNER_PID:=}"
: "${JSH_SPINNER_VISIBLE:=0}"
if [[ ${JSH_UI_BACKEND} == shell ]] && ! typeset -f ui::choose > /dev/null 2>&1; then
  . "${JSH_UI_LIBRARY_DIR}/ui/gum.sh"
fi
JSH_UI_PROGRESS_RENDERER="$(cd -- "${JSH_UI_LIBRARY_DIR}" && pwd -P)/ui/progress.py"
unset -f jsh_ui_library_dir

jsh_gum() (
  local surface text_primary text_muted accent_secondary
  surface=$(ui::token SURFACE) || return
  text_primary=$(ui::token TEXT_PRIMARY) || return
  text_muted=$(ui::token TEXT_MUTED) || return
  accent_secondary=$(ui::token ACCENT_SECONDARY) || return

  export GUM_CONFIRM_PROMPT_FOREGROUND=${text_primary}
  export GUM_CONFIRM_SELECTED_FOREGROUND=${surface}
  export GUM_CONFIRM_SELECTED_BACKGROUND=${accent_secondary}
  export GUM_CONFIRM_UNSELECTED_FOREGROUND=${text_muted}
  export GUM_CONFIRM_UNSELECTED_BACKGROUND=${surface}
  export GUM_CHOOSE_CURSOR_FOREGROUND=${accent_secondary}
  export GUM_CHOOSE_HEADER_FOREGROUND=${text_primary}
  export GUM_CHOOSE_ITEM_FOREGROUND=${text_muted}
  export GUM_CHOOSE_SELECTED_FOREGROUND=${accent_secondary}
  export GUM_INPUT_PROMPT_FOREGROUND=${accent_secondary}
  export GUM_INPUT_PLACEHOLDER_FOREGROUND=${text_muted}
  export GUM_INPUT_CURSOR_FOREGROUND=${accent_secondary}
  export GUM_INPUT_HEADER_FOREGROUND=${text_primary}
  export GUM_SPIN_SPINNER_FOREGROUND=${accent_secondary}
  export GUM_SPIN_TITLE_FOREGROUND=${text_primary}
  "${JSH_GUM}" "$@"
)

jsh::init() {
  local input_fd=${JSH_UI_INPUT_FD} output_fd=${JSH_UI_OUTPUT_FD}

  while (($# > 0)); do
    case $1 in
      --input-fd)
        input_fd=${2:-}
        shift 2
        ;;
      --output-fd)
        output_fd=${2:-}
        shift 2
        ;;
      --owns-fd)
        JSH_UI_OWNS_FD=1
        shift
        ;;
      *) return 2 ;;
    esac
  done
  [[ ${input_fd} != *[!0-9]* && -n ${input_fd} ]] || return 2
  [[ ${output_fd} != *[!0-9]* && -n ${output_fd} ]] || return 2

  JSH_UI_INPUT_FD=${input_fd}
  JSH_UI_OUTPUT_FD=${output_fd}
  UI_INPUT_FD=${input_fd}
  UI_OUTPUT_FD=${output_fd}
  export JSH_UI_INPUT_FD JSH_UI_OUTPUT_FD UI_INPUT_FD UI_OUTPUT_FD
  jsh_env_detect
  if [[ ${JSH_UI_BACKEND} == shell ]] && ! typeset -f ui::choose > /dev/null 2>&1; then
    . "${JSH_UI_LIBRARY_DIR:-${JSH_DIR:-${JSH_ROOT:-.}}/lib}/ui/gum.sh"
  fi
}

jsh::log_info() { jsh_info "$@"; }
jsh::log_note() { jsh_note "$@"; }
jsh::log_success() { jsh_success "$@"; }
jsh::log_warn() { jsh_warn "$@"; }
jsh::log_error() { jsh_error "$@"; }
jsh::log_detail() { jsh_detail "$@"; }

jsh::section() {
  local index=${1:-} title=${2:-} detail=${3:-}
  printf '\n' >&1
  if [[ -n ${index} ]]; then
    jsh::log_info "[${index}] ${title}"
  else
    jsh::log_info "${title}"
  fi
  [[ -z ${detail} ]] || jsh::log_detail "${detail}"
}

jsh::status() {
  local state=${1:-info}
  shift || true
  case ${state} in
    info) jsh::log_info "$@" ;;
    note | skip) jsh::log_note "$@" ;;
    success | ok) jsh::log_success "$@" ;;
    warn | warning) jsh::log_warn "$@" ;;
    error | fail) jsh::log_error "$@" ;;
    detail) jsh::log_detail "$@" ;;
    *) return 2 ;;
  esac
}

jsh::title() {
  local text=$*
  case ${JSH_UI_BACKEND} in
    gum)
      jsh_gum style --border rounded --padding '0 2' \
        --border-foreground '#0039A6' --foreground '#F5F5F5' -- "${text}"
      ;;
    shell)
      ui::box --border rounded --padding-x 2 --border-fg ACCENT_PRIMARY -- "${text}"
      ;;
    *)
      printf '\n=== %s ===\n\n' "${text}"
      ;;
  esac
}

jsh::confirm() {
  local prompt=${1:-Continue?} default=yes answer gum_default
  (($# == 0)) || shift
  while (($# > 0)); do
    case $1 in
      --default)
        default=${2:-}
        shift 2
        ;;
      *) return 2 ;;
    esac
  done
  case ${default} in yes | no) ;; *) return 2 ;; esac

  [[ ${JSH_ASSUME_YES:-0} != 1 ]] || return 0
  if [[ ${JSH_NON_INTERACTIVE:-0} == 1 || ${JSH_INTERACTIVE:-0} != 1 ]]; then
    [[ ${default} == yes ]]
    return
  fi

  case ${JSH_UI_BACKEND} in
    gum)
      [[ ${default} == yes ]] && gum_default=true || gum_default=false
      jsh_gum confirm "--default=${gum_default}" "${prompt}" <&"${JSH_UI_INPUT_FD}" >&"${JSH_UI_OUTPUT_FD}"
      ;;
    shell) ui::confirm "${prompt}" --default "${default}" ;;
    *)
      while :; do
        if [[ ${default} == yes ]]; then
          printf '%s [Y/n]: ' "${prompt}" >&"${JSH_UI_OUTPUT_FD}"
        else
          printf '%s [y/N]: ' "${prompt}" >&"${JSH_UI_OUTPUT_FD}"
        fi
        IFS= read -r -u "${JSH_UI_INPUT_FD}" answer || answer=
        case ${answer} in
          '')
            [[ ${default} == yes ]]
            return
            ;;
          y | Y | yes | YES) return 0 ;;
          n | N | no | NO) return 1 ;;
          *) printf 'Please answer yes or no.\n' >&"${JSH_UI_OUTPUT_FD}" ;;
        esac
      done
      ;;
  esac
}

jsh_choice_header() {
  local header=$1 count=$2 mode=${3:-cursor} width=4
  [[ ${mode} != numbered ]] || width=$((4 + ${#count}))
  printf '%*s%s' "${width}" '' "${header}"
}

jsh::choose() {
  local header=${1:-Choose:} answer option index count index_width
  (($# == 0)) || shift
  (($# > 0)) || return 2
  [[ ${JSH_NON_INTERACTIVE:-0} != 1 && ${JSH_INTERACTIVE:-0} == 1 ]] || return 2

  count=$#
  case ${JSH_UI_BACKEND} in
    gum)
      jsh_gum choose --header "$(jsh_choice_header "${header}" "${count}")" -- "$@" \
        <&"${JSH_UI_INPUT_FD}" 2>&"${JSH_UI_OUTPUT_FD}"
      ;;
    shell) ui::choose "$(jsh_choice_header "${header}" "${count}")" "$@" ;;
    *)
      index_width=${#count}
      while :; do
        printf '%s\n' "$(jsh_choice_header "${header}" "${count}" numbered)" >&"${JSH_UI_OUTPUT_FD}"
        index=1
        for option in "$@"; do
          printf '  %*d) %s\n' "${index_width}" "${index}" "${option}" >&"${JSH_UI_OUTPUT_FD}"
          index=$((index + 1))
        done
        printf 'Selection: ' >&"${JSH_UI_OUTPUT_FD}"
        IFS= read -r -u "${JSH_UI_INPUT_FD}" answer || return 1
        case ${answer} in
          *[!0-9]* | '') ;;
          *)
            if ((answer >= 1 && answer <= $#)); then
              index=${answer}
              while ((index > 1)); do
                shift
                index=$((index - 1))
              done
              printf '%s\n' "$1"
              return
            fi
            ;;
        esac
        printf 'Choose a number from 1 to %d.\n' "$#" >&"${JSH_UI_OUTPUT_FD}"
      done
      ;;
  esac
}

jsh::choose_one() {
  local header=${1:-Choose:} id label selected existing
  local -a labels=() options=()
  (($# == 0)) || shift
  (($# > 0 && $# % 2 == 0)) || return 2

  while (($# >= 2)); do
    id=$1
    label=$2
    [[ -n ${id} && ${id} != *$'\n'* && ${label} != *$'\n'* ]] || return 2
    for existing in "${labels[@]}"; do
      [[ ${existing} != "${label}" ]] || return 2
    done
    labels+=("${label}")
    options+=("${label}"$'\t'"${id}")
    shift 2
  done

  if [[ ${JSH_UI_BACKEND} == gum ]]; then
    jsh_gum choose --header "$(jsh_choice_header "${header}" "${#labels[@]}")" \
      --label-delimiter=$'\t' -- "${options[@]}" \
      <&"${JSH_UI_INPUT_FD}" 2>&"${JSH_UI_OUTPUT_FD}"
    return
  fi
  selected=$(jsh::choose "${header}" "${labels[@]}") || return

  set -- "${options[@]}"
  while (($# > 0)); do
    label=${1%%$'\t'*}
    id=${1#*$'\t'}
    if [[ ${label} == "${selected}" ]]; then
      printf '%s\n' "${id}"
      return
    fi
    shift
  done
  return 1
}

jsh::choose_many() {
  local header=${1:-Choose:} id label answer selection index index_width existing selected_ids=''
  local -a options=() ids=() labels=() selections=()
  (($# == 0)) || shift
  (($# > 0 && $# % 2 == 0)) || return 2
  [[ ${JSH_NON_INTERACTIVE:-0} != 1 && ${JSH_INTERACTIVE:-0} == 1 ]] || return 2

  while (($# >= 2)); do
    id=$1
    label=$2
    [[ -n ${id} && ${id} != *$'\n'* && ${label} != *$'\n'* ]] || return 2
    ids+=("${id}")
    labels+=("${label}")
    options+=("${label}"$'\t'"${id}")
    shift 2
  done

  if [[ ${JSH_UI_BACKEND} == gum ]]; then
    jsh_gum choose --header "$(jsh_choice_header "${header}" "${#labels[@]}")" --no-limit --ordered \
      --label-delimiter=$'\t' -- "${options[@]}" \
      <&"${JSH_UI_INPUT_FD}" 2>&"${JSH_UI_OUTPUT_FD}"
    return
  fi

  index_width=${#labels[@]}
  index_width=${#index_width}
  printf '%s\n' "$(jsh_choice_header "${header}" "${#labels[@]}" numbered)" >&"${JSH_UI_OUTPUT_FD}"
  index=1
  for label in "${labels[@]}"; do
    printf '  %*d) %s\n' "${index_width}" "${index}" "${label}" >&"${JSH_UI_OUTPUT_FD}"
    index=$((index + 1))
  done
  printf 'Selections (comma-separated, all, or empty to cancel): ' >&"${JSH_UI_OUTPUT_FD}"
  IFS= read -r -u "${JSH_UI_INPUT_FD}" answer || return 1
  [[ -n ${answer} ]] || return 130
  if [[ ${answer} == all ]]; then
    printf '%s\n' "${ids[@]}"
    return
  fi
  [[ ${answer} != *[!0-9,[:space:]]* ]] || return 2
  answer=${answer//,/ }
  if [[ -n ${ZSH_VERSION:-} ]]; then
    read -r -A selections <<< "${answer}"
  else
    read -r -a selections <<< "${answer}"
  fi
  for selection in "${selections[@]}"; do
    ((selection >= 1 && selection <= ${#ids[@]})) || return 2
    if [[ -n ${ZSH_VERSION:-} ]]; then
      id=${ids[selection]}
    else
      id=${ids[selection - 1]}
    fi
    case $'\n'${selected_ids}$'\n' in
      *$'\n'"${id}"$'\n'*) continue ;;
    esac
    [[ -z ${selected_ids} ]] || selected_ids+=$'\n'
    selected_ids+=${id}
  done
  [[ -n ${selected_ids} ]] || return 130
  printf '%s\n' "${selected_ids}"
}

jsh::input() {
  local prompt=${1:-Value} placeholder='' default='' secret=0 mask=0 hidden=0 value
  (($# == 0)) || shift
  while (($# > 0)); do
    case $1 in
      --placeholder)
        placeholder=${2:-}
        shift 2
        ;;
      --default)
        default=${2:-}
        shift 2
        ;;
      --secret)
        secret=1
        shift
        ;;
      --mask)
        mask=1
        shift
        ;;
      --hidden)
        hidden=1
        shift
        ;;
      *) return 2 ;;
    esac
  done
  ((hidden == 0)) || ((mask == 0)) || return 2
  if [[ ${JSH_NON_INTERACTIVE:-0} == 1 || ${JSH_INTERACTIVE:-0} != 1 ]]; then
    [[ -n ${default} ]] || return 2
    printf '%s\n' "${default}"
    return
  fi

  case ${JSH_UI_BACKEND} in
    gum)
      set -- input --prompt "${prompt}: "
      [[ -z ${placeholder} ]] || set -- "$@" --placeholder "${placeholder}"
      [[ -z ${default} ]] || set -- "$@" --value "${default}"
      ((secret == 0 && mask == 0 && hidden == 0)) || set -- "$@" --password
      jsh_gum "$@" <&"${JSH_UI_INPUT_FD}" 2>&"${JSH_UI_OUTPUT_FD}"
      ;;
    shell)
      set -- "${prompt}"
      [[ -z ${placeholder} ]] || set -- "$@" --placeholder "${placeholder}"
      [[ -z ${default} ]] || set -- "$@" --default "${default}"
      ((secret == 0)) || set -- "$@" --secret
      ((mask == 0)) || set -- "$@" --mask
      ((hidden == 0)) || set -- "$@" --hidden
      ui::input "$@"
      ;;
    *)
      if [[ -n ${default} ]]; then
        printf '%s [%s]: ' "${prompt}" "${default}" >&"${JSH_UI_OUTPUT_FD}"
      elif [[ -n ${placeholder} ]]; then
        printf '%s (%s): ' "${prompt}" "${placeholder}" >&"${JSH_UI_OUTPUT_FD}"
      else
        printf '%s: ' "${prompt}" >&"${JSH_UI_OUTPUT_FD}"
      fi
      if (( (secret || mask) && hidden == 0 )) && typeset -f ui::_read_masked > /dev/null 2>&1 && [[ -t ${JSH_UI_INPUT_FD} ]]; then
        local UI_INPUT_FD=${JSH_UI_INPUT_FD} UI_OUTPUT_FD=${JSH_UI_OUTPUT_FD}
        value=$(
          trap 'ui::_terminal_cleanup' EXIT
          trap 'exit 130' INT
          ui::_terminal_begin key 0 || exit 1
          ui::_read_masked '•'
        ) || return
      elif ((secret || mask || hidden)); then
        IFS= read -r -s -u "${JSH_UI_INPUT_FD}" value || [[ -n ${value} ]] || return 1
        printf '\n' >&"${JSH_UI_OUTPUT_FD}"
      else
        IFS= read -r -u "${JSH_UI_INPUT_FD}" value || [[ -n ${value} ]] || return 1
      fi
      [[ -n ${value} ]] || value=${default}
      printf '%s\n' "${value}"
      ;;
  esac
}

jsh::spin() {
  local title=${1:-Working} output_policy=failure log exit_status
  (($# == 0)) || shift
  if [[ ${1:-} == --output ]]; then
    output_policy=${2:-}
    shift 2
  fi
  case ${output_policy} in inherit | failure | quiet) ;; *) return 2 ;; esac
  [[ ${1:-} == -- ]] || return 2
  shift
  (($# > 0)) || return 2

  if [[ ${output_policy} == inherit ]]; then
    case ${JSH_UI_BACKEND} in
      gum) jsh_gum spin --show-output --title "${title}" -- "$@" ;;
      *)
        printf '[-] %s...\n' "${title}" >&"${JSH_UI_OUTPUT_FD}"
        "$@"
        ;;
    esac
    return
  fi

  log=$(mktemp "${TMPDIR:-/tmp}/jsh-spin.XXXXXXXXXX") || return
  typeset -f jsh_interrupt_cleanup_path > /dev/null 2>&1 && jsh_interrupt_cleanup_path "${log}"
  case ${JSH_UI_BACKEND} in
    gum)
      if jsh_gum spin --title "${title}" -- "$@" > "${log}" 2>&1; then
        exit_status=0
      else
        exit_status=$?
      fi
      ;;
    shell)
      "$@" > "${log}" 2>&1 &
      if ui::spin "$!" "${title}"; then
        exit_status=0
      else
        exit_status=$?
      fi
      ;;
    *)
      printf '[-] %s...\n' "${title}" >&"${JSH_UI_OUTPUT_FD}"
      if "$@" > "${log}" 2>&1; then
        exit_status=0
        printf '[OK] %s\n' "${title}" >&"${JSH_UI_OUTPUT_FD}"
      else
        exit_status=$?
        printf '[FAIL] %s\n' "${title}" >&"${JSH_UI_OUTPUT_FD}"
      fi
      ;;
  esac
  if [[ ${output_policy} == failure && ${exit_status} != 0 ]]; then
    cat -- "${log}" >&"${JSH_UI_OUTPUT_FD}"
  fi
  rm -f -- "${log}"
  return "${exit_status}"
}

# Consume JSON progress events from stdin. Diagnostics and verdicts remain on stdout.
jsh::progress() {
  python3 "${JSH_UI_PROGRESS_RENDERER}" "$@"
}

jsh::spinner_static() {
  jsh::spinner_stop
  jsh::log_info "$*" >&"${JSH_UI_OUTPUT_FD}"
}

jsh::spinner_start() {
  local spinner_color spinner_reset=''
  jsh::spinner_stop

  if [[ ! -t ${JSH_UI_OUTPUT_FD} || ${TERM:-} == dumb || ${JSH_PLAIN_OUTPUT:-0} == 1 ]]; then
    jsh::log_info "$*" >&"${JSH_UI_OUTPUT_FD}"
    return
  fi

  spinner_color=$(ui::ansi_fg ACCENT_SECONDARY)
  [[ -z ${spinner_color} ]] || spinner_reset=$'\033[0m'
  JSH_SPINNER_VISIBLE=1
  (
    trap 'exit 0' INT TERM
    while :; do
      while IFS= read -r frame; do
        printf '\r%s%s%s %s' "${spinner_color}" "${frame}" "${spinner_reset}" "$*" >&"${JSH_UI_OUTPUT_FD}"
        sleep 0.1
      done < <(ui::spinner_frames)
    done
  ) &
  JSH_SPINNER_PID=$!
}

jsh::spinner_stop() {
  if [[ -n ${JSH_SPINNER_PID:-} ]]; then
    kill "${JSH_SPINNER_PID}" 2>/dev/null || true
    wait "${JSH_SPINNER_PID}" 2>/dev/null || true
  fi
  if [[ ${JSH_SPINNER_VISIBLE:-0} == 1 ]]; then
    printf '\r\033[2K' >&"${JSH_UI_OUTPUT_FD}"
  fi
  JSH_SPINNER_PID=
  JSH_SPINNER_VISIBLE=0
}

jsh::cleanup() {
  jsh::spinner_stop
  if typeset -f ui::_terminal_cleanup > /dev/null 2>&1; then
    ui::_terminal_cleanup
  fi
  jsh::sudo_keepalive_stop
  if [[ ${JSH_UI_OWNS_FD:-0} == 1 ]]; then
    if [[ ${JSH_UI_INPUT_FD:-0} == "${JSH_UI_OUTPUT_FD:-2}" ]]; then
      eval "exec ${JSH_UI_INPUT_FD}>&-"
    else
      eval "exec ${JSH_UI_INPUT_FD}<&-"
      eval "exec ${JSH_UI_OUTPUT_FD}>&-"
    fi
    JSH_UI_OWNS_FD=0
  fi
}

jsh::sudo_preflight() {
  [[ ${JSH_SUDO_PREFLIGHTED:-0} != 1 ]] || return 0
  if [[ $(id -u) == 0 ]]; then
    JSH_SUDO_PREFLIGHTED=1
    export JSH_SUDO_PREFLIGHTED
    return 0
  fi
  command -v sudo > /dev/null 2>&1 || {
    jsh::log_error 'sudo is required for privileged setup.'
    return 1
  }
  sudo -v || return
  JSH_SUDO_PREFLIGHTED=1
  export JSH_SUDO_PREFLIGHTED
}

jsh::sudo_keepalive() {
  local interval=${JSH_SUDO_KEEPALIVE_INTERVAL:-50}
  jsh::sudo_preflight || return
  jsh::sudo_keepalive_stop
  (
    elapsed=0
    trap 'exit 0' HUP INT TERM
    while :; do
      sleep 1
      elapsed=$((elapsed + 1))
      if ((elapsed >= interval)); then
        sudo -n true > /dev/null 2>&1 || exit
        elapsed=0
      fi
    done
  ) &
  JSH_SUDO_KEEPALIVE_PID=$!
}

jsh::sudo_keepalive_stop() {
  if [[ -n ${JSH_SUDO_KEEPALIVE_PID:-} ]]; then
    kill "${JSH_SUDO_KEEPALIVE_PID}" 2> /dev/null || true
    wait "${JSH_SUDO_KEEPALIVE_PID}" 2> /dev/null || true
    JSH_SUDO_KEEPALIVE_PID=
  fi
}

unset JSH_UI_LIBRARY_DIR
