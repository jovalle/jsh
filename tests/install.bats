#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_DIR
  JSH_DIR=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export JSH_ROOT=${JSH_DIR}
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/output.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/files.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/artifact.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/debian.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/manifest.sh"
  eval "$(sed -n '/^setup_system() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
}

@test "CTRL-C cleans registered staging paths and exits 130" {
  local staging="${BATS_TEST_TMPDIR}/interrupt-staging"

  run bash -c '
    source "$1/lib/interrupt.sh"
    mkdir -p "$2"
    jsh_interrupt_cleanup_path "$2"
    kill -INT "$$"
    printf "continued\n"
  ' _ "${JSH_ROOT}" "${staging}"

  [[ ${status} -eq 130 ]]
  [[ ${output} == *'Interrupted.'* ]]
  [[ ${output} != *'continued'* ]]
  [[ ! -e ${staging} ]]
}

@test "TERM cleans registered staging paths and exits 143 silently" {
  local staging="${BATS_TEST_TMPDIR}/term-staging"

  run bash -c '
    source "$1/lib/interrupt.sh"
    mkdir -p "$2"
    jsh_interrupt_cleanup_path "$2"
    kill -TERM "$$"
  ' _ "${JSH_ROOT}" "${staging}"

  [[ ${status} -eq 143 ]]
  [[ ${output} != *'Interrupted.'* ]]
  [[ ! -e ${staging} ]]
}

@test "setup orchestration stops after an interrupted component" {
  local root="${BATS_TEST_TMPDIR}/setup-root" events="${BATS_TEST_TMPDIR}/events"
  mkdir -p "${root}/lib" "${root}/scripts/unix/configure"
  cp "${JSH_ROOT}/lib/output.sh" "${root}/lib/output.sh"
  cat > "${root}/scripts/unix/configure/10-interrupt.sh" <<EOF
#!/bin/sh
printf '%s\n' interrupt >> "${events}"
exit 130
EOF
  cat > "${root}/scripts/unix/configure/20-after.sh" <<EOF
#!/bin/sh
printf '%s\n' after >> "${events}"
EOF
  chmod +x "${root}/scripts/unix/configure/"*.sh

  run env JSH_PLAIN_OUTPUT=1 JSH_CONTINUE_ON_ERROR=1 \
    make --no-print-directory -f "${JSH_ROOT}/Makefile" configure \
    JSH_ROOT="${root}" PLATFORM=darwin

  [[ ${status} -ne 0 ]]
  [[ $(cat "${events}") == interrupt ]]
  [[ $(grep -Foc 'Interrupted.' <<< "${output}") -eq 1 ]]
}

@test "jsh install updates packages without changing deploy or configure mode" {
  local calls="${BATS_TEST_TMPDIR}/make-targets"
  run_make_target() {
    JSH_TARGET=$1 bash -c 'printf "%s\t%s\n" "${JSH_TARGET}" "${JSH_UPDATE:-0}"' >> "${calls}"
  }

  setup_system

  diff -u <(printf 'install\t1\ndeploy\t0\nconfigure\t0\n') "${calls}"
}

@test "Homebrew update repairs outdated formula dependencies after bundle installs" {
  local calls="${BATS_TEST_TMPDIR}/brew-calls"

  run env JSH_UPDATE=1 JSH_ASSUME_YES=1 CALLS="${calls}" bash -c '
    source "$1"
    manifest() { printf "%s\n" "brew \"example\""; }
    load_brew() { :; }
    register_brew_packages() { :; }
    trust_declared_formulae() { :; }
    migrate_legacy_npm_packages() { :; }
    install_brew_manifest() { printf "manifest\n" >> "${CALLS}"; }
    brew() { printf "brew\t%s\n" "$*" >> "${CALLS}"; }
    install_brew_packages
  ' _ "${JSH_DIR}/scripts/unix/install/packages.sh"

  [[ ${status} -eq 0 ]]
  diff -u <(printf 'brew\tupdate\nmanifest\nbrew\tupgrade --formula --yes\n') "${calls}"
}

@test "package manifest resolves additive platform and host layers" {
  export JSH_MANIFEST_OS=darwin
  export JSH_MANIFEST_DISTRO=unknown
  export JSH_MANIFEST_DESKTOP=unknown
  export JSH_MANIFEST_HOST=archon
  export JSH_MANIFEST_ARCH=arm64

  run jsh_manifest_brewfile

  [[ ${status} -eq 0 ]]
  grep -Fxq 'brew "neovim"' <<< "${output}"
  grep -Fxq 'cask "bambu-studio"' <<< "${output}"
  [[ $(grep -Fxc 'brew "bash"' <<< "${output}") -eq 1 ]]
}

@test "package adoption is atomic and idempotent" {
  local manifest="${BATS_TEST_TMPDIR}/packages.json" before
  cat > "${manifest}" <<'JSON'
{
  "schema": 1,
  "layers": [
    {
      "id": "unix",
      "match": { "os": ["darwin", "linux"] },
      "install": { "brew": { "formulae": ["jq"] } }
    }
  ]
}
JSON
  chmod 0640 "${manifest}"

  jsh_manifest_adopt brew bash unix "${manifest}"
  jq -e '.layers[0].install.brew.formulae == ["bash", "jq"]' "${manifest}" > /dev/null
  [[ $(stat -c '%a' "${manifest}") == 640 ]]
  before=$(stat -c '%i:%Y' "${manifest}")

  jsh_manifest_adopt brew bash unix "${manifest}"

  [[ $(stat -c '%i:%Y' "${manifest}") == "${before}" ]]
}

@test "managed files back up changes and leave converged files untouched" {
  local source_file="${BATS_TEST_TMPDIR}/source" target="${BATS_TEST_TMPDIR}/config/settings"
  export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state"
  printf before > "${source_file}"
  jsh_ensure_file "${target}" "${source_file}" 0644
  printf after > "${source_file}"
  jsh_ensure_file "${target}" "${source_file}" 0644
  local before_stat
  before_stat=$(stat -c '%i:%Y' "${target}")

  run jsh_ensure_file "${target}" "${source_file}" 0644

  [[ ${status} -eq 1 ]]
  [[ $(stat -c '%i:%Y' "${target}") == "${before_stat}" ]]
  [[ $(find "${XDG_STATE_HOME}/jsh/backups" -type f | wc -l) -eq 1 ]]
  [[ $(find "${XDG_STATE_HOME}/jsh/backups" -type f -exec cat {} \;) == before ]]
}

@test "managed files refuse live symlinks and preserve dry-run state" {
  local source_file="${BATS_TEST_TMPDIR}/source" owned="${BATS_TEST_TMPDIR}/owned"
  local link="${BATS_TEST_TMPDIR}/settings" absent="${BATS_TEST_TMPDIR}/absent/settings"
  printf managed > "${source_file}"
  printf mine > "${owned}"
  ln -s "${owned}" "${link}"

  run jsh_ensure_file "${link}" "${source_file}" 0644
  [[ ${status} -eq 2 ]]
  [[ $(cat "${owned}") == mine ]]

  export JSH_CONFIGURE_DRY_RUN=1
  run jsh_ensure_file "${absent}" "${source_file}" 0644
  [[ ${status} -eq 0 ]]
  [[ ! -e ${absent%/*} ]]
}

@test "artifact checksum failure never activates a download" {
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  curl() {
    local output
    while (($#)); do
      if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
    done
    printf tampered > "${output}"
  }

  run jsh_download_artifact example 1.0 https://example.invalid/example .bin \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  [[ ${status} -ne 0 ]]
  [[ ! -e ${XDG_CACHE_HOME}/jsh/artifacts/example-1.0.bin ]]
  [[ ! -e ${XDG_CACHE_HOME}/jsh/artifacts/example-1.0.bin.partial ]]
}

@test "artifact downloads accept vendor SHA-512 checksums" {
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  local checksum
  checksum=$(printf trusted | sha512sum | awk '{print $1}')
  curl() {
    local output
    while (($#)); do
      if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
    done
    printf trusted > "${output}"
  }

  run jsh_download_artifact example 1.0 https://example.invalid/example .bin \
    "${checksum}" sha512

  [[ ${status} -eq 0 ]]
  [[ $(cat "${output}") == trusted ]]
}

@test "CTRL-C removes a partial artifact download" {
  local cache="${BATS_TEST_TMPDIR}/cache"

  run env XDG_CACHE_HOME="${cache}" JSH_PLAIN_OUTPUT=1 bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/interrupt.sh"
    source "$1/lib/artifact.sh"
    curl() {
      local output
      while (($#)); do
        if [[ $1 == --output ]]; then output=$2; shift 2; else shift; fi
      done
      printf partial > "$output"
      kill -INT "$$"
    }
    jsh_download_artifact example 1.0 https://example.invalid/example .bin
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 130 ]]
  [[ $(grep -Foc 'Interrupted.' <<< "${output}") -eq 1 ]]
  [[ ! -e ${cache}/jsh/artifacts/example-1.0.bin.partial ]]
  [[ ! -e ${cache}/jsh/artifacts/example-1.0.bin ]]
}

@test "Debian installer preserves newer installed versions" {
  dpkg-query() { printf 'installed\t2.0'; }
  jsh_download_artifact() { return 99; }

  run jsh_debian_install_package example example 1.0 https://example.invalid/example.deb '' example

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'example is current (2.0).'* ]]
}

@test "Debian installer skips a running application noninteractively" {
  run bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/debian.sh"
    dpkg-query() { return 1; }
    pgrep() { return 0; }
    jsh_download_artifact() { return 99; }
    jsh_debian_install_package example example 1.0 https://example.invalid/example.deb "" example
  ' _ "${JSH_ROOT}" < /dev/null

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Skipping update for running app: example (noninteractive).'* ]]
}
