#!/usr/bin/env bash

set -u

UI_EXAMPLE_FILE=${BASH_SOURCE[0]}
case ${UI_EXAMPLE_FILE} in
  */*) UI_EXAMPLE_DIR=${UI_EXAMPLE_FILE%/*} ;;
  *) UI_EXAMPLE_DIR=. ;;
esac
UI_EXAMPLE_DIR=$(cd -- "${UI_EXAMPLE_DIR}" && pwd -P)
. "${UI_EXAMPLE_DIR}/gum.sh"
unset UI_EXAMPLE_FILE UI_EXAMPLE_DIR

ui::demo_cleanup() {
  printf '\033[?25h' >&2
  stty echo icanon 2> /dev/null || true
}

ui::demo_apply() {
  local iteration=0
  while ((iteration < ${UI_DEMO_ITERATIONS:-150000})); do
    iteration=$((iteration + 1))
  done
}

ui::demo_main() {
  local profile package_set passphrase answer

  printf '\033[2J\033[H'
  ui::box --border double --padding-x 3 --padding-y 1 --width 38 --align center \
    --fg TEXT_PRIMARY --border-fg ACCENT_PRIMARY -- \
    $'DOTFILES EXPRESS\nA portable workstation setup'
  printf '\n'

  printf '%s  %s  %s\n\n' \
    "$(ui::badge '1 PROFILE')" \
    "$(ui::tag '2 PACKAGES')" \
    "$(ui::tag '3 APPLY' SUCCESS)"

  profile=$(ui::input 'Profile name' --default "${USER:-operator}" \
    --placeholder 'workstation') || return
  package_set=$(ui::choose 'Choose a package set' \
    'Core · shell, git, editor' \
    'Developer · core, containers, language tools' \
    'Complete · developer, desktop, media') || return
  passphrase=$(ui::input 'Backup passphrase' --mask \
    --placeholder 'stored only for this demo') || return

  printf '\n'
  ui::box --border rounded --padding-x 2 --padding-y 1 --width 44 -- \
    "Profile: ${profile}
Packages: ${package_set}
Secret:   ${#passphrase} characters captured"
  unset passphrase
  printf '\n'

  if ! ui::confirm 'Apply this setup?' --default yes; then
    printf '%s\n' "$(ui::style --fg WARN --bold -- 'Setup cancelled.')"
    return 1
  fi

  ui::demo_apply &
  answer=$!
  ui::spin "${answer}" 'Applying dotfiles'

  printf '\n%s %s\n' \
    "$(ui::badge READY SUCCESS)" \
    "$(ui::style --fg TEXT_PRIMARY -- "${profile} is configured.")"
}

trap 'ui::demo_cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ui::demo_main "$@"
