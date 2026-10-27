#!/usr/bin/env bash
# Manage packages, dotfiles, OS preferences, and applications.

set -euo pipefail

JSH_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export JSH_ROOT
# shellcheck source=lib/core.sh
. "${JSH_ROOT}/lib/core.sh"

usage() {
  cat <<'HELP'
Usage: jsh COMMAND [COMPONENT] [--dry-run] [--yes]

  install [GROUP|APP]     Install missing software (default: all)
  dotfiles               Link every file in dotfiles/ into HOME
  tweak [COMPONENT]      Apply OS preferences (default: preferences)
  customize [COMPONENT]  Apply desktop and hardware settings (default: all)
  configure [APP]        Configure an app (default: all)
  setup                  Run all five jobs in order
  runtime                Open an isolated zsh with this checkout's dotfiles
  list                   List groups, apps, and OS components

Groups: core, tools, runtime, apps, extensions, all
Apps: helium, waterfox, vscode, ghostty, spotify, todoist
Tweaks: preferences
Customization: wallpaper, keybindings, desktop, dock, audio, display, all

--dry-run shows changes without writes, downloads, or privileged commands.
--yes accepts prompts for the selected command. Privileged operations require
an already-authorized sudo session. No arguments shows this help; the jsh
launcher opens the runtime instead when run outside a Jsh shell.
HELP
}

action=
component=
flags=()
for argument in "$@"; do
  case ${argument} in
    --dry-run) flags+=(--dry-run) ;;
    -y | --yes) flags+=(--yes) ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    -*)
      jsh::log_error "Unknown option: ${argument}"
      exit 2
      ;;
    *)
      if [[ -z ${action} ]]; then
        action=${argument}
      elif [[ -z ${component} ]]; then
        component=${argument}
      else
        jsh::log_error 'Too many arguments.'
        exit 2
      fi
      ;;
  esac
done
[[ -n ${action} ]] || {
  usage
  exit 0
}
case ${action}:${component} in
  list:)
    printf '%s\n' 'install: core tools runtime apps extensions all helium waterfox vscode ghostty spotify todoist' \
      'dotfiles' 'tweak: preferences' \
      'customize: wallpaper keybindings desktop dock audio display all' \
      'configure: helium waterfox vscode all' 'setup' 'runtime'
    ;;
  runtime:)
    command -v zsh >/dev/null 2>&1 || {
      jsh::log_error 'zsh is required. Run: just install core'
      exit 1
    }
    [[ -d ${JSH_ROOT}/local/vendor/zsh-autosuggestions ]] ||
      jsh::log_warn 'Shell plugins are missing. Run: just install runtime'
    export JSH_RUNTIME_DIR=${JSH_RUNTIME_DIR:-${JSH_ROOT}/local/runtime}
    export ZDOTDIR=${JSH_ROOT}/dotfiles
    exec zsh -d -i
    ;;
  *) jsh::job "${action}" ${component:+"${component}"} ${flags[@]+"${flags[@]}"} ;;
esac
