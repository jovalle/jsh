#!/usr/bin/env bash

# Match the conventional terminal colors used by Jsh output.
UI_SURFACE=${UI_SURFACE:-'#000000'}
UI_TEXT_PRIMARY=${UI_TEXT_PRIMARY:-'#FFFFFF'}
UI_TEXT_MUTED=${UI_TEXT_MUTED:-'#808080'}
UI_ACCENT_PRIMARY=${UI_ACCENT_PRIMARY:-'#00CDCD'}
UI_ACCENT_SECONDARY=${UI_ACCENT_SECONDARY:-'#00CDCD'}
UI_SUCCESS=${UI_SUCCESS:-'#00CD00'}
UI_WARN=${UI_WARN:-'#CDCD00'}
UI_ERROR=${UI_ERROR:-'#CD0000'}

ui::color_mode() {
  case ${UI_COLOR_MODE:-auto} in
    truecolor | 24bit) printf '%s\n' truecolor ;;
    256) printf '%s\n' 256 ;;
    none | never) printf '%s\n' none ;;
    auto | '')
      if [[ -n ${NO_COLOR+x} || ${TERM:-} == dumb ]]; then
        printf '%s\n' none
      elif [[ ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit ]]; then
        printf '%s\n' truecolor
      else
        printf '%s\n' 256
      fi
      ;;
    *) return 2 ;;
  esac
}

ui::token() {
  case ${1:-} in
    SURFACE) printf '%s\n' "${UI_SURFACE}" ;;
    TEXT_PRIMARY) printf '%s\n' "${UI_TEXT_PRIMARY}" ;;
    TEXT_MUTED) printf '%s\n' "${UI_TEXT_MUTED}" ;;
    ACCENT_PRIMARY) printf '%s\n' "${UI_ACCENT_PRIMARY}" ;;
    ACCENT_SECONDARY) printf '%s\n' "${UI_ACCENT_SECONDARY}" ;;
    SUCCESS) printf '%s\n' "${UI_SUCCESS}" ;;
    WARN) printf '%s\n' "${UI_WARN}" ;;
    ERROR) printf '%s\n' "${UI_ERROR}" ;;
    \#[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]])
      printf '%s\n' "$1"
      ;;
    *) return 2 ;;
  esac
}

ui::_hex_channel() {
  local channel=$1
  printf '%d\n' "$((16#${channel}))"
}

ui::_rgb_to_256() {
  local red=$1 green=$2 blue=$3 red_cube green_cube blue_cube cube gray average
  local cube_red cube_green cube_blue cube_distance gray_level gray_distance

  red_cube=$(((red * 5 + 127) / 255))
  green_cube=$(((green * 5 + 127) / 255))
  blue_cube=$(((blue * 5 + 127) / 255))
  cube=$((16 + 36 * red_cube + 6 * green_cube + blue_cube))

  cube_red=$((red_cube == 0 ? 0 : 55 + 40 * red_cube))
  cube_green=$((green_cube == 0 ? 0 : 55 + 40 * green_cube))
  cube_blue=$((blue_cube == 0 ? 0 : 55 + 40 * blue_cube))
  cube_distance=$(((red - cube_red) ** 2 + (green - cube_green) ** 2 + (blue - cube_blue) ** 2))

  average=$(((red + green + blue) / 3))
  if ((average < 8)); then
    gray=232
    gray_level=8
  elif ((average > 238)); then
    gray=255
    gray_level=238
  else
    gray=$((232 + (average - 8 + 5) / 10))
    gray_level=$((8 + 10 * (gray - 232)))
  fi
  gray_distance=$(((red - gray_level) ** 2 + (green - gray_level) ** 2 + (blue - gray_level) ** 2))

  if ((gray_distance < cube_distance)); then
    printf '%d\n' "${gray}"
  else
    printf '%d\n' "${cube}"
  fi
}

ui::_ansi_color() {
  local plane=$1 color mode hex red green blue index
  color=$(ui::token "$2") || return 2
  mode=$(ui::color_mode) || return 2
  [[ ${mode} != none ]] || return 0

  hex=${color#\#}
  red=$(ui::_hex_channel "${hex:0:2}")
  green=$(ui::_hex_channel "${hex:2:2}")
  blue=$(ui::_hex_channel "${hex:4:2}")

  if [[ ${mode} == truecolor ]]; then
    printf '\033[%s;2;%d;%d;%dm' "${plane}" "${red}" "${green}" "${blue}"
  else
    index=$(ui::_rgb_to_256 "${red}" "${green}" "${blue}")
    printf '\033[%s;5;%dm' "${plane}" "${index}"
  fi
}

ui::ansi_fg() {
  ui::_ansi_color 38 "${1:-TEXT_PRIMARY}"
}

ui::ansi_bg() {
  ui::_ansi_color 48 "${1:-SURFACE}"
}

# Canonical animation shared by shell and imported/streamed progress displays.
ui::spinner_frames() {
  printf '%s\n' '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'
}
