#!/usr/bin/env bash

# Sourceable styling and box-model primitives; rendered values go to stdout.

ui::_lipgloss_file() {
  if [[ -n ${BASH_VERSION:-} ]]; then
    printf '%s' "${BASH_SOURCE[0]}"
  else
    # funcsourcetrace is a Zsh special parameter.
    # shellcheck disable=SC2154
    printf '%s' "${funcsourcetrace[1]%:*}"
  fi
}

if ! typeset -f ui::ansi_fg > /dev/null 2>&1; then
  UI_LIPGLOSS_FILE=$(ui::_lipgloss_file)
  case ${UI_LIPGLOSS_FILE} in
    */*) UI_LIPGLOSS_DIR=${UI_LIPGLOSS_FILE%/*} ;;
    *) UI_LIPGLOSS_DIR=. ;;
  esac
  . "${UI_LIPGLOSS_DIR}/theme.sh"
  unset UI_LIPGLOSS_FILE UI_LIPGLOSS_DIR
fi
unset -f ui::_lipgloss_file

UI_ANSI_RESET=$'\033[0m'

ui::_repeat() {
  local value=$1 count=$2 output=
  while ((count > 0)); do
    output+=${value}
    count=$((count - 1))
  done
  printf '%s' "${output}"
}

ui::_strip_ansi() {
  local value=$1 marker=$'\033[' prefix remainder character

  # CSI styling sequences occupy bytes but no terminal columns.
  while [[ ${value} == *"${marker}"* ]]; do
    prefix=${value%%"${marker}"*}
    remainder=${value#*"${marker}"}
    while [[ -n ${remainder} ]]; do
      character=${remainder%"${remainder#?}"}
      remainder=${remainder#?}
      [[ ${character} == [@-~] ]] && break
    done
    value=${prefix}${remainder}
  done
  printf '%s' "${value}"
}

ui::width() {
  local plain
  plain=$(ui::_strip_ansi "$1")
  printf '%d\n' "${#plain}"
}

ui::style() {
  local foreground='' background='' bold=0 dim=0 italic=0 underline=0 code='' text

  while (($# > 0)); do
    case $1 in
      --fg)
        foreground=${2:-}
        shift 2
        ;;
      --bg)
        background=${2:-}
        shift 2
        ;;
      --bold)
        bold=1
        shift
        ;;
      --dim)
        dim=1
        shift
        ;;
      --italic)
        italic=1
        shift
        ;;
      --underline)
        underline=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done
  text=$*

  [[ -z ${foreground} ]] || code+=$(ui::ansi_fg "${foreground}") || return 2
  [[ -z ${background} ]] || code+=$(ui::ansi_bg "${background}") || return 2
  ((bold == 0)) || code+=$'\033[1m'
  ((dim == 0)) || code+=$'\033[2m'
  ((italic == 0)) || code+=$'\033[3m'
  ((underline == 0)) || code+=$'\033[4m'

  if [[ -n ${code} ]]; then
    printf '%s%s%s' "${code}" "${text}" "${UI_ANSI_RESET}"
  else
    printf '%s' "${text}"
  fi
}

ui::_wrap_line() {
  local line=$1 width=$2 output='' character escape_state=0 columns=0

  if ((width <= 0)); then
    printf '%s\n' "${line}"
    return
  fi

  # Preserve complete CSI sequences while counting only printable characters.
  while [[ -n ${line} ]]; do
    character=${line%"${line#?}"}
    line=${line#?}

    if ((escape_state == 1)); then
      output+=${character}
      escape_state=2
      continue
    fi
    if ((escape_state == 2)); then
      output+=${character}
      [[ ${character} != [@-~] ]] || escape_state=0
      continue
    fi
    if [[ ${character} == $'\033' && ${line%"${line#?}"} == '[' ]]; then
      output+=${character}
      escape_state=1
      continue
    fi
    if ((columns == width)); then
      printf '%s\n' "${output}"
      output=
      columns=0
    fi
    output+=${character}
    columns=$((columns + 1))
  done
  printf '%s\n' "${output}"
}

ui::_wrap_text() {
  local text=$1 width=$2 line
  while IFS= read -r line || [[ -n ${line} ]]; do
    ui::_wrap_line "${line}" "${width}"
  done <<< "${text}"
}

ui::_aligned_line() {
  local line=$1 width=$2 align=$3 length gap left right
  length=$(ui::width "${line}")
  gap=$((width - length))
  ((gap >= 0)) || gap=0

  case ${align} in
    left) left=0 ;;
    center) left=$((gap / 2)) ;;
    right) left=${gap} ;;
    *) return 2 ;;
  esac
  right=$((gap - left))
  printf '%s%s%s' "$(ui::_repeat ' ' "${left}")" "${line}" "$(ui::_repeat ' ' "${right}")"
}

ui::box() {
  local border=rounded padding_x=1 padding_y=0 width=0 align=left
  local foreground=TEXT_PRIMARY background='' border_foreground=ACCENT_PRIMARY text=
  local top_left top_right bottom_left bottom_right horizontal vertical
  local line line_width content_width inner_width horizontal_rule border_code content_code reset
  local padding_line wrapped

  while (($# > 0)); do
    case $1 in
      --border)
        border=${2:-}
        shift 2
        ;;
      --padding-x)
        padding_x=${2:-}
        shift 2
        ;;
      --padding-y)
        padding_y=${2:-}
        shift 2
        ;;
      --width)
        width=${2:-}
        shift 2
        ;;
      --align)
        align=${2:-}
        shift 2
        ;;
      --fg)
        foreground=${2:-}
        shift 2
        ;;
      --bg)
        background=${2:-}
        shift 2
        ;;
      --border-fg)
        border_foreground=${2:-}
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done
  text=$*

  [[ ${padding_x} == *[!0-9]* || ${padding_y} == *[!0-9]* || ${width} == *[!0-9]* ]] && return 2
  case ${align} in left | center | right) ;; *) return 2 ;; esac
  case ${border} in
    rounded)
      top_left='╭'
      top_right='╮'
      bottom_left='╰'
      bottom_right='╯'
      horizontal='─'
      vertical='│'
      ;;
    normal)
      top_left='┌'
      top_right='┐'
      bottom_left='└'
      bottom_right='┘'
      horizontal='─'
      vertical='│'
      ;;
    double)
      top_left='╔'
      top_right='╗'
      bottom_left='╚'
      bottom_right='╝'
      horizontal='═'
      vertical='║'
      ;;
    none)
      top_left=
      top_right=
      bottom_left=
      bottom_right=
      horizontal=
      vertical=
      ;;
    *) return 2 ;;
  esac

  if ((width == 0)); then
    while IFS= read -r line || [[ -n ${line} ]]; do
      line_width=$(ui::width "${line}")
      ((line_width <= width)) || width=${line_width}
    done <<< "${text}"
  fi
  content_width=${width}
  inner_width=$((content_width + 2 * padding_x))
  horizontal_rule=$(ui::_repeat "${horizontal}" "${inner_width}")
  padding_line=$(ui::_repeat ' ' "${inner_width}")
  wrapped=$(ui::_wrap_text "${text}" "${content_width}")

  border_code=$(ui::ansi_fg "${border_foreground}") || return 2
  content_code=$(ui::ansi_fg "${foreground}") || return 2
  [[ -z ${background} ]] || content_code+=$(ui::ansi_bg "${background}") || return 2
  [[ -z ${border_code}${content_code} ]] && reset= || reset=${UI_ANSI_RESET}

  [[ ${border} == none ]] || printf '%s%s%s%s%s\n' "${border_code}" "${top_left}" "${horizontal_rule}" "${top_right}" "${reset}"
  line=0
  while ((line < padding_y)); do
    printf '%s%s%s%s%s%s\n' "${border_code}" "${vertical}" "${content_code}" "${padding_line}" "${border_code}" "${vertical}${reset}"
    line=$((line + 1))
  done
  while IFS= read -r line || [[ -n ${line} ]]; do
    printf '%s%s%s%s%s%s%s%s\n' \
      "${border_code}" "${vertical}" "${content_code}" "$(ui::_repeat ' ' "${padding_x}")" \
      "$(ui::_aligned_line "${line}" "${content_width}" "${align}")" "$(ui::_repeat ' ' "${padding_x}")" \
      "${border_code}" "${vertical}${reset}"
  done <<< "${wrapped}"
  line=0
  while ((line < padding_y)); do
    printf '%s%s%s%s%s%s\n' "${border_code}" "${vertical}" "${content_code}" "${padding_line}" "${border_code}" "${vertical}${reset}"
    line=$((line + 1))
  done
  [[ ${border} == none ]] || printf '%s%s%s%s%s\n' "${border_code}" "${bottom_left}" "${horizontal_rule}" "${bottom_right}" "${reset}"
}

ui::badge() {
  ui::style --fg SURFACE --bg "${2:-ACCENT_PRIMARY}" --bold -- " ${1:-} "
}

ui::tag() {
  ui::style --fg SURFACE --bg "${2:-ACCENT_SECONDARY}" -- " ${1:-} "
}
