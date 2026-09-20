#!/usr/bin/env bash
# Expose the tiered Jsh UI facade to non-shell commands.

set -u

JSH_UI_CLI_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
. "${JSH_UI_CLI_DIR}/../ui.sh"
unset JSH_UI_CLI_DIR

# Stream rendering must keep stdin/stdout intact and must not acquire /dev/tty.
case ${1:-} in
  progress)
    shift
    jsh::progress "$@"
    exit $?
    ;;
  progress-theme)
    printf '%s\n' "$(ui::ansi_fg ACCENT_SECONDARY)" "$(ui::ansi_fg SUCCESS)" \
      "$(ui::ansi_fg ERROR)" "$(ui::ansi_fg TEXT_MUTED)" "$(ui::ansi_fg WARN)"
    ui::spinner_frames
    exit
    ;;
esac

if ( : <> /dev/tty ) 2> /dev/null; then
  exec 8<> /dev/tty
  jsh::init --input-fd 8 --output-fd 8 --owns-fd
fi
trap 'jsh::cleanup' EXIT

case ${1:-} in
  confirm)
    shift
    default=no
    if [[ ${1:-} == --default ]]; then
      default=${2:-}
      shift 2
    fi
    [[ ${1:-} == -- ]] || exit 2
    shift
    jsh::confirm "$*" --default "${default}"
    ;;
  input)
    shift
    jsh::input "$@"
    ;;
  choose-one)
    shift
    jsh::choose_one "$@"
    ;;
  choose-many)
    shift
    jsh::choose_many "$@"
    ;;
  status)
    shift
    state=${1:-}
    shift || true
    [[ ${1:-} == -- ]] || exit 2
    shift
    jsh::status "${state}" "$*"
    ;;
  title)
    shift
    [[ ${1:-} == -- ]] || exit 2
    shift
    jsh::title "$*"
    ;;
  section)
    shift
    [[ ${1:-} == -- ]] || exit 2
    shift
    jsh::section '' "$*"
    ;;
  *)
    printf 'Usage: %s {confirm|input|choose-one|choose-many|status|title|section|progress} ...\n' \
      "${0##*/}" >&2
    exit 2
    ;;
esac
