#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export SYNCTHING_SERVICE_CALLS="${BATS_TEST_TMPDIR}/syncthing-service-calls"
  export DRY_RUN=0
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/unix/install/services.sh"
  jsh_error() { :; }
  jsh_detail() { :; }
  jsh_note() { :; }
  jsh_success() { :; }
}

@test "excludes the complete Git metadata directory from Syncthing" {
  grep -Fxq '.git' "${JSH_ROOT}/.stignore"
  run ! grep -Fq '.git/' "${JSH_ROOT}/.stignore"
}

@test "enables and starts the Linux Syncthing user service" {
  systemctl() {
    printf '%s\n' "$*" >> "${SYNCTHING_SERVICE_CALLS}"
    [[ $* != '--user is-enabled --quiet syncthing.service' ]]
  }

  run enable_linux_syncthing

  [[ ${status} -eq 0 ]]
  grep -Fxq -- '--user daemon-reload' "${SYNCTHING_SERVICE_CALLS}"
  grep -Fxq -- '--user cat syncthing.service' "${SYNCTHING_SERVICE_CALLS}"
  grep -Fxq -- '--user enable --now syncthing.service' "${SYNCTHING_SERVICE_CALLS}"
}

@test "leaves an active Linux Syncthing user service unchanged" {
  systemctl() { printf '%s\n' "$*" >> "${SYNCTHING_SERVICE_CALLS}"; }

  run enable_linux_syncthing

  [[ ${status} -eq 0 ]]
  [[ $(wc -l < "${SYNCTHING_SERVICE_CALLS}") -eq 4 ]]
  run ! grep -Fq -- '--user enable --now' "${SYNCTHING_SERVICE_CALLS}"
}

@test "starts Syncthing through Homebrew services on macOS" {
  brew() { printf '%s\n' "$*" >> "${SYNCTHING_SERVICE_CALLS}"; }

  run enable_macos_syncthing

  [[ ${status} -eq 0 ]]
  grep -Fxq 'services info syncthing' "${SYNCTHING_SERVICE_CALLS}"
  grep -Fxq 'services start syncthing' "${SYNCTHING_SERVICE_CALLS}"
}

@test "leaves an active macOS Syncthing service unchanged" {
  brew() {
    printf '%s\n' "$*" >> "${SYNCTHING_SERVICE_CALLS}"
    if [[ $* == 'services info syncthing' ]]; then
      printf 'Running: true\n'
    fi
  }

  run enable_macos_syncthing

  [[ ${status} -eq 0 ]]
  grep -Fxq 'services info syncthing' "${SYNCTHING_SERVICE_CALLS}"
  run ! grep -Fq 'services start syncthing' "${SYNCTHING_SERVICE_CALLS}"
}
