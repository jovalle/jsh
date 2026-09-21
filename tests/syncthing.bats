#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export SYNCTHING_SERVICE_CALLS="${BATS_TEST_TMPDIR}/syncthing-service-calls"
  export SYNCTHING_CONFIG_CALLS="${BATS_TEST_TMPDIR}/syncthing-config-calls"
  export SYNCTHING_NAT_STATE="${BATS_TEST_TMPDIR}/syncthing-nat-state"
  export HOME="${BATS_TEST_TMPDIR}/home"
  export DRY_RUN=0
  mkdir -p "${HOME}"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/unix/install/services.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/unix/install/syncthing.sh"
  jsh::log_error() { :; }
  jsh::log_detail() { :; }
  jsh::log_note() { :; }
  jsh::log_success() { :; }
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

@test "merges Projects ignores without replacing custom patterns" {
  local -a expected_patterns=(
    '(?d).git' '(?d)node_modules' '(?d).venv' '(?d)venv' '(?d)target' '(?d).next'
    '(?d)__pycache__' '(?d).cache'
  )
  mkdir -p "${HOME}/Projects"
  printf '%s\n' custom '(?d)node_modules' > "${HOME}/Projects/.stignore"

  run configure_projects_ignores

  [[ ${status} -eq 0 ]]
  grep -Fxq custom "${HOME}/Projects/.stignore"
  for pattern in "${expected_patterns[@]}"; do
    grep -Fxq -- "${pattern}" "${HOME}/Projects/.stignore"
  done
  [[ $(grep -Fxc '(?d)node_modules' "${HOME}/Projects/.stignore") -eq 1 ]]
  [[ $(jsh_file_mode "${HOME}/Projects/.stignore") == 600 ]]

  cp "${HOME}/Projects/.stignore" "${BATS_TEST_TMPDIR}/expected-stignore"
  run configure_projects_ignores

  [[ ${status} -eq 0 ]]
  cmp -s "${BATS_TEST_TMPDIR}/expected-stignore" "${HOME}/Projects/.stignore"
}

@test "dry run reports Syncthing configuration without changing files" {
  DRY_RUN=1
  syncthing() { return 1; }

  run main

  [[ ${status} -eq 0 ]]
  [[ ! -e ${HOME}/Projects ]]
}

@test "disables Syncthing NAT traversal and verifies the result" {
  syncthing() {
    printf '%s\n' "$*" >> "${SYNCTHING_CONFIG_CALLS}"
    if [[ $* == 'cli config options natenabled set false' ]]; then
      : > "${SYNCTHING_NAT_STATE}"
    elif [[ $* == 'cli config options natenabled get' ]]; then
      [[ -e ${SYNCTHING_NAT_STATE} ]] && printf 'false\n' || printf 'true\n'
    fi
  }

  run configure_syncthing_nat

  [[ ${status} -eq 0 ]]
  [[ $(grep -Fxc 'cli config options natenabled get' "${SYNCTHING_CONFIG_CALLS}") -eq 2 ]]
  grep -Fxq 'cli config options natenabled set false' "${SYNCTHING_CONFIG_CALLS}"
}

@test "leaves disabled Syncthing NAT traversal unchanged" {
  syncthing() {
    printf '%s\n' "$*" >> "${SYNCTHING_CONFIG_CALLS}"
    [[ $* != 'cli config options natenabled get' ]] || printf 'false\n'
  }

  run configure_syncthing_nat

  [[ ${status} -eq 0 ]]
  [[ $(wc -l < "${SYNCTHING_CONFIG_CALLS}") -eq 1 ]]
  grep -Fxq 'cli config options natenabled get' "${SYNCTHING_CONFIG_CALLS}"
}
