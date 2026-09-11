#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"
DISTRO_FAMILY=
PACKAGE_MANAGER=
NATIVE_PACKAGES=()

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export JSH_UNAME=Linux
  export JSH_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
  export JSH_DESKTOP=GNOME
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/linux.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/linux/install/packages.sh"
}

write_os_release() {
  printf '%s\n' "$@" > "${JSH_OS_RELEASE}"
}

@test "detects Arch-family distributions" {
  write_os_release 'ID=endeavouros' 'ID_LIKE=arch'

  run jsh_linux_family

  [[ "${status}" -eq 0 ]]
  [[ "${output}" = arch ]]
}

@test "selects Fedora packages without XFCE plugins on GNOME" {
  write_os_release 'ID=fedora'

  select_native_packages

  [[ "${DISTRO_FAMILY}" = fedora ]]
  [[ "${PACKAGE_MANAGER}" = dnf || "${PACKAGE_MANAGER}" = dnf5 ]]
  [[ " ${NATIVE_PACKAGES[*]} " = *' flatpak '* ]]
  [[ " ${NATIVE_PACKAGES[*]} " != *' xfce4-docklike-plugin '* ]]
}

@test "adds XFCE packages only for an XFCE session" {
  write_os_release 'ID=fedora'
  export JSH_DESKTOP=XFCE

  select_native_packages

  [[ " ${NATIVE_PACKAGES[*]} " = *' xfce4-docklike-plugin '* ]]
}

@test "selects Debian-family packages" {
  write_os_release 'ID=ubuntu' 'ID_LIKE=debian'

  select_native_packages

  [[ "${DISTRO_FAMILY}" = debian ]]
  [[ "${PACKAGE_MANAGER}" = apt-get ]]
  [[ " ${NATIVE_PACKAGES[*]} " = *' systemd-zram-generator '* ]]
}

@test "leaves unknown distributions to portable installers" {
  write_os_release 'ID=void'

  run select_native_packages

  [[ "${status}" -ne 0 ]]
}

@test "installs available Fedora packages with DNF" {
  local calls="${BATS_TEST_TMPDIR}/root-calls"
  DISTRO_FAMILY=fedora
  PACKAGE_MANAGER=dnf
  NATIVE_PACKAGES=(example-package)
  package_installed() { return 1; }
  package_available() { return 0; }
  jsh_run_root() { printf '%s\n' "$*" >> "${calls}"; }

  install_native_packages

  grep -Fxq 'dnf install -y -- example-package' "${calls}"
}

@test "updates Debian packages with APT" {
  local calls="${BATS_TEST_TMPDIR}/root-calls"
  DISTRO_FAMILY=debian
  jsh_run_root() { printf '%s\n' "$*" >> "${calls}"; }

  update_native_packages

  grep -Fxq 'apt-get update' "${calls}"
  grep -Fxq 'apt-get upgrade -y' "${calls}"
}

@test "does not upgrade Fedora during a normal install" {
  local calls="${BATS_TEST_TMPDIR}/root-calls"
  DISTRO_FAMILY=fedora
  PACKAGE_MANAGER=dnf
  export JSH_UPDATE=0
  jsh_run_root() { printf '%s\n' "$*" >> "${calls}"; }

  prepare_native_packages

  [[ ! -e "${calls}" ]]
}

@test "detects GNOME and XFCE sessions case-insensitively" {
  export JSH_DESKTOP='ubuntu:GNOME'
  [[ "$(jsh_linux_desktop)" = gnome ]]
  export JSH_DESKTOP=XFCE
  [[ "$(jsh_linux_desktop)" = xfce ]]
}

@test "preserves GNOME shortcuts while adding a managed shortcut" {
  local calls="${BATS_TEST_TMPDIR}/gsettings-calls"
  export calls
  gsettings() {
    if [[ $1 = get ]]; then
      printf "['/org/example/existing/']\n"
    else
      printf '%s|%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "${calls}"
    fi
  }

  jsh_gnome_custom_shortcut 'Jsh audio output' '<Control><Alt><Super>a' '/opt/jsh/audio.sh cycle'

  grep -Fq "['/org/example/existing/', '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/jsh-audio-output/']" "${calls}"
  grep -Fq 'binding|<Control><Alt><Super>a' "${calls}"
  grep -Fq 'command|/opt/jsh/audio.sh cycle' "${calls}"
}

@test "does not replace GNOME shortcuts after a failed read" {
  local calls="${BATS_TEST_TMPDIR}/gsettings-calls"
  export calls
  gsettings() {
    if [[ $1 = get ]]; then
      return 1
    fi
    printf '%s\n' "$*" >> "${calls}"
  }

  run jsh_gnome_custom_shortcut 'Jsh audio output' '<Control><Alt><Super>a' '/opt/jsh/audio.sh cycle'

  [[ "${status}" -ne 0 ]]
  [[ ! -e "${calls}" ]]
}
