#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_DIR
  JSH_DIR=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export JSH_ROOT=${JSH_DIR}
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/output.sh"
  jsh::log_info() { jsh_info "$@"; }
  jsh::log_note() { jsh_note "$@"; }
  jsh::log_success() { jsh_success "$@"; }
  jsh::log_warn() { jsh_warn "$@"; }
  jsh::log_error() { jsh_error "$@"; }
  jsh::log_detail() { jsh_detail "$@"; }
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/files.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/artifact.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/debian.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/manifest.sh"
  eval "$(sed -n '/^install_core_packages() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
  eval "$(sed -n '/^setup_system() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
  eval "$(sed -n '/^install_profile_state_file() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
  eval "$(sed -n '/^read_install_profile() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
  eval "$(sed -n '/^record_install_profile() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
  eval "$(sed -n '/^update_environment() {$/,/^}$/p' "${JSH_DIR}/j.sh")"
}

file_identity() {
  if stat -c '%i:%Y' "$1" > /dev/null 2>&1; then
    stat -c '%i:%Y' "$1"
  else
    stat -f '%i:%m' "$1"
  fi
}

@test "manifest library can be sourced by zsh with nounset" {
  run zsh -c 'set -u; source "$1/lib/manifest.sh"; typeset -f jsh_manifest_main >/dev/null' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
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

@test "full setup updates packages without changing deploy or configure mode" {
  local calls="${BATS_TEST_TMPDIR}/make-targets"
  run_make_target() {
    JSH_TARGET=$1 bash -c 'printf "%s\t%s\n" "${JSH_TARGET}" "${JSH_UPDATE:-0}"' >> "${calls}"
  }

  setup_system

  diff -u <(printf 'install\t1\ndeploy\t0\nconfigure\t0\n') "${calls}"
}

@test "slim install limits packages to core and skips platform configuration" {
  local calls="${BATS_TEST_TMPDIR}/slim-make-targets"
  export TTY=/dev/null
  touch "${BATS_TEST_TMPDIR}/Makefile"
  run_make_target() {
    JSH_TARGET=$1 bash -c 'printf "%s\t%s\t%s\n" "${JSH_TARGET}" "${JSH_UPDATE:-0}" "${JSH_PACKAGE_LAYERS:-all}"' >> "${calls}"
  }

  JSH_DIR=${BATS_TEST_TMPDIR} setup_system slim

  diff -u <(printf 'essentials\t0\tall\ndeploy\t0\tall\n') "${calls}"
}

@test "essentials target excludes custom application installers" {
  local root="${BATS_TEST_TMPDIR}/essentials-root" events="${BATS_TEST_TMPDIR}/essentials-events"
  mkdir -p "${root}/lib" "${root}/scripts/unix/install"
  cat > "${root}/lib/ui.sh" <<'EOF'
jsh_blank() { :; }
jsh::status() { :; }
EOF
  cat > "${root}/scripts/unix/install/packages.sh" <<EOF
#!/bin/sh
printf 'packages\t%s\n' "\${JSH_PACKAGE_LAYERS:-}" >> "${events}"
EOF
  cat > "${root}/scripts/unix/install/application.sh" <<EOF
#!/bin/sh
printf 'application\n' >> "${events}"
EOF
  chmod +x "${root}/scripts/unix/install/"*.sh

  make --no-print-directory -f "${JSH_ROOT}/Makefile" essentials JSH_ROOT="${root}" PLATFORM=darwin

  diff -u <(printf 'packages\tcore\n') "${events}"
}

@test "install profile state defaults bare and recognizes legacy full dotfiles" {
  export JSH_PROFILE_STATE_FILE="${BATS_TEST_TMPDIR}/state/jsh/install-profile"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"

  [[ $(read_install_profile) == bare ]]
  ln -s "${JSH_DIR}/dotfiles/.zshrc" "${HOME}/.zshrc"
  [[ $(read_install_profile) == full ]]
  record_install_profile slim
  [[ $(read_install_profile) == slim ]]
}

@test "slim update reconciles only core packages and dotfiles" {
  local calls="${BATS_TEST_TMPDIR}/slim-update-targets"
  run_update_step() {
    shift
    "$@"
  }
  update_repository() { printf 'repository\n' >> "${calls}"; }
  install_prerequisites() { printf 'prerequisites\t%s\n' "$*" >> "${calls}"; }
  run_make_target() { printf 'make\t%s\t%s\n' "$1" "${JSH_PACKAGE_LAYERS:-all}" >> "${calls}"; }

  update_environment slim

  diff -u <(printf 'repository\nprerequisites\tinstall 0\nmake\tessentials\tall\nmake\tdeploy\tall\n') "${calls}"
}

@test "Homebrew update upgrades formulae and casks after bundle installs" {
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
  diff -u <(printf 'brew\tupdate\nmanifest\nbrew\tupgrade --yes\n') "${calls}"
}

@test "Homebrew update accepts the Xcode license and retries once" {
  local calls="${BATS_TEST_TMPDIR}/xcode-license-calls"

  run env CALLS="${calls}" bash -c '
    source "$1"
    brew_attempts=0
    brew() {
      brew_attempts=$((brew_attempts + 1))
      printf "brew\t%s\n" "$*" >> "${CALLS}"
      if [[ ${brew_attempts} -eq 1 ]]; then
        printf "Error: You have not agreed to the Xcode license. Please resolve this by running:\n" >&2
        printf "  sudo xcodebuild -license accept\n" >&2
        return 1
      fi
    }
    jsh::confirm() { printf "confirm\t%s\n" "$*" >> "${CALLS}"; }
    sudo() { printf "sudo\t%s\n" "$*" >> "${CALLS}"; }
    update_brew
  ' _ "${JSH_DIR}/scripts/unix/install/packages.sh"

  [[ ${status} -eq 0 ]]
  diff -u <(printf 'brew\tupdate\nconfirm\tAccept the Xcode license with sudo? --default no\nsudo\txcodebuild -license accept\nbrew\tupdate\n') "${calls}"
}

@test "Homebrew license recovery requires confirmation despite assume yes" {
  local calls="${BATS_TEST_TMPDIR}/declined-xcode-license-calls"

  run bash -c '
    printf "n\n" | env JSH_ASSUME_YES=1 JSH_INTERACTIVE=1 JSH_NON_INTERACTIVE=0 \
      JSH_UI_BACKEND=plain JSH_UI_INPUT_FD=0 CALLS="$2" bash -c '\''
        source "$1"
        brew() {
          printf "brew\n" >> "${CALLS}"
          printf "Error: You have not agreed to the Xcode license.\n" >&2
          return 1
        }
        sudo() { printf "sudo\n" >> "${CALLS}"; }
        update_brew
      '\'' _ "$1"
  ' _ "${JSH_DIR}/scripts/unix/install/packages.sh" "${calls}"

  [[ ${status} -eq 1 ]]
  [[ ${output} == *'Accept the Xcode license with sudo? [y/N]:'* ]]
  [[ $(cat "${calls}") == brew ]]
}

@test "Homebrew update leaves unrelated failures untouched" {
  local calls="${BATS_TEST_TMPDIR}/unrelated-brew-calls"

  run env CALLS="${calls}" bash -c '
    source "$1"
    brew() { printf "Another Homebrew error.\n" >&2; return 1; }
    jsh::confirm() { printf "confirm\n" >> "${CALLS}"; }
    sudo() { printf "sudo\n" >> "${CALLS}"; }
    update_brew
  ' _ "${JSH_DIR}/scripts/unix/install/packages.sh"

  [[ ${status} -eq 1 ]]
  [[ ${output} == 'Another Homebrew error.' ]]
  [[ ! -e ${calls} ]]
}

@test "Homebrew skips formulae that conflict with installed or declared formulae" {
  local brewfile="${BATS_TEST_TMPDIR}/Brewfile"
  printf '%s\n' 'brew "jq"' 'brew "leaf"' 'brew "old"' 'brew "fresh"' 'cask "app"' > "${brewfile}"

  run bash -c '
    source "$1"
    brew() {
      case $1 in
        list) printf "%s\n" jq leaf-markdown-viewer ;;
        info) printf "%s" "{\"formulae\": [
          {\"name\": \"leaf\", \"full_name\": \"leaf\", \"conflicts_with\": [\"leaf-markdown-viewer\"], \"deprecated\": false, \"disabled\": false},
          {\"name\": \"old\", \"full_name\": \"old\", \"conflicts_with\": [], \"deprecated\": true, \"disabled\": true, \"disable_reason\": \"unmaintained\"},
          {\"name\": \"fresh\", \"full_name\": \"fresh\", \"conflicts_with\": [], \"deprecated\": true, \"disabled\": false, \"deprecation_reason\": \"unsupported\", \"disable_date\": \"2027-01-01\"}
        ]}" ;;
      esac
    }
    exclude_blocked_formulae "$2"
    printf "blocked=%s\n" "${BLOCKED_FORMULAE[*]}"
  ' _ "${JSH_DIR}/scripts/unix/install/packages.sh" "${brewfile}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'fresh is deprecated (unsupported; disabled on 2027-01-01).'* ]]
  [[ ${output} == *'Skipping leaf: conflicts with leaf-markdown-viewer.'* ]]
  [[ ${output} == *'Skipping old: disabled (unmaintained).'* ]]
  [[ ${output} == *'blocked=leaf old'* ]]
  diff -u <(printf '%s\n' 'brew "jq"' 'brew "fresh"' 'cask "app"') "${brewfile}"
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

@test "core package profile excludes opinionated tools and applications" {
  export JSH_MANIFEST_OS=darwin
  export JSH_MANIFEST_DISTRO=unknown
  export JSH_MANIFEST_DESKTOP=unknown
  export JSH_MANIFEST_HOST=archon
  export JSH_MANIFEST_ARCH=arm64
  export JSH_PACKAGE_LAYERS=core

  run jsh_manifest_resolve

  [[ ${status} -eq 0 ]]
  jq -e '
    .layers == ["core"]
    and .brew.formulae == ["bash", "gum", "jq", "unzip", "zip", "zsh"]
    and .brew.casks == []
    and .cargo == []
    and .flatpak == []
  ' <<< "${output}" > /dev/null
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
  [[ $(jsh_file_mode "${manifest}") == 640 ]]
  before=$(file_identity "${manifest}")

  jsh_manifest_adopt brew bash unix "${manifest}"

  [[ $(file_identity "${manifest}") == "${before}" ]]
}

@test "managed files back up changes and leave converged files untouched" {
  local source_file="${BATS_TEST_TMPDIR}/source" target="${BATS_TEST_TMPDIR}/config/settings"
  export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state"
  printf before > "${source_file}"
  jsh_ensure_file "${target}" "${source_file}" 0644
  printf after > "${source_file}"
  jsh_ensure_file "${target}" "${source_file}" 0644
  local before_stat
  before_stat=$(file_identity "${target}")

  run jsh_ensure_file "${target}" "${source_file}" 0644

  [[ ${status} -eq 1 ]]
  [[ $(file_identity "${target}") == "${before_stat}" ]]
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

@test "managed files require consent to replace broken symlinks" {
  local source_file="${BATS_TEST_TMPDIR}/source" link="${BATS_TEST_TMPDIR}/settings"
  printf managed > "${source_file}"
  ln -s "${BATS_TEST_TMPDIR}/missing" "${link}"

  run jsh_ensure_file "${link}" "${source_file}" 0644 < /dev/null

  [[ ${status} -eq 1 ]]
  [[ -L ${link} ]]
  [[ ${output} == *'Non-interactive setup cannot replace it without --yes.'* ]]

  export JSH_CONFIGURE_ASSUME_YES=1
  run jsh_ensure_file "${link}" "${source_file}" 0644

  [[ ${status} -eq 0 ]]
  [[ ! -L ${link} ]]
  [[ $(cat "${link}") == managed ]]
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
  dpkg() { [[ $* == '--compare-versions 2.0 ge 1.0' ]]; }
  jsh_download_artifact() { return 99; }

  run jsh_debian_install_package example example 1.0 https://example.invalid/example.deb '' example

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'example is current (2.0).'* ]]
}

@test "Debian installer skips a running application noninteractively" {
  run bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/ui.sh"
    source "$1/lib/debian.sh"
    dpkg-query() { return 1; }
    pgrep() { return 0; }
    jsh_download_artifact() { return 99; }
    jsh_debian_install_package example example 1.0 https://example.invalid/example.deb "" example
  ' _ "${JSH_ROOT}" < /dev/null

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Skipping update for running app: example (noninteractive).'* ]]
}

@test "managed file replacement uses the shared confirmation default" {
  run env JSH_INTERACTIVE=1 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/ui.sh"
    source "$1/lib/files.sh"
    exec 3<<<$'"'"'\n'"'"'
    JSH_UI_INPUT_FD=3
    jsh_approve_broken_symlink /tmp/broken-link
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Replace it with the managed file? [Y/n]:'* ]]
}
