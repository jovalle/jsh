#!/bin/sh

# Human output uses cyan for activity, green checks for success, yellow for
# warnings and skips, and red crosses for errors. Prompts use cyan without a
# status mark. Emitters terminate one record; composing callers use jsh_blank
# between blocks, never before the first or after the last. Keep structured
# data, command output, and generated files raw.

jsh_color_enabled() {
  jsh_output_descriptor=$1

  [[ "${JSH_PLAIN_OUTPUT:-0}" != 1 ]] || return 1
  [[ "${TERM:-}" != dumb ]] || return 1
  [[ -z "${NO_COLOR+x}" ]] || return 1

  case ${JSH_COLOR:-auto} in
    always) return 0 ;;
    never) return 1 ;;
    auto | '') [[ -t "${jsh_output_descriptor}" ]] ;;
    *) return 1 ;;
  esac
}

jsh_stdout() {
  jsh_output_color=$1
  jsh_output_prefix=$2
  shift 2

  if jsh_color_enabled 1; then
    printf '\033[%sm%s%s\033[0m\n' "${jsh_output_color}" "${jsh_output_prefix}" "$*"
  else
    printf '%s%s\n' "${jsh_output_prefix}" "$*"
  fi
}

jsh_stderr() {
  jsh_output_color=$1
  jsh_output_prefix=$2
  shift 2

  if jsh_color_enabled 2; then
    printf '\033[%sm%s%s\033[0m\n' "${jsh_output_color}" "${jsh_output_prefix}" "$*" >&2
  else
    printf '%s%s\n' "${jsh_output_prefix}" "$*" >&2
  fi
}

jsh_info() {
  jsh_stdout 36 '' "$*"
}

jsh_success() {
  jsh_stdout 32 '✓ ' "$*"
}

jsh_warn() {
  jsh_stderr 33 '' "$*"
}

jsh_error() {
  jsh_stderr 31 '✗ ' "$*"
}

jsh_prompt() {
  if jsh_color_enabled 1; then
    printf '\033[36m%s\033[0m' "$*"
  else
    printf '%s' "$*"
  fi
}

jsh_detail() {
  printf '%s\n' "$*"
}

jsh_blank() {
  printf '\n'
}
