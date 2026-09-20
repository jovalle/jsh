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
  jsh::log_error() { jsh_error "$@"; }
  jsh::log_detail() { jsh_detail "$@"; }
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/lib/linux.sh"
  # shellcheck source=/dev/null
  source "${JSH_ROOT}/scripts/linux/install/packages.sh"
  eval "$(sed -n '/^install_prerequisites() {$/,/^}$/p' "${JSH_ROOT}/j.sh")"
}

write_os_release() {
  printf '%s\n' "$@" > "${JSH_OS_RELEASE}"
}

prerequisite_path() {
  local directory="${BATS_TEST_TMPDIR}/prerequisite-bin"
  mkdir -p "${directory}"
  for tool in bash git make zsh; do
    ln -sf "${BASH}" "${directory}/${tool}"
  done
  printf '%s\n' "${directory}"
}

load_ssh_agent_service_functions() {
  local script="${JSH_ROOT}/scripts/linux/configure/services.sh"
  eval "$(sed -n '/^remove_managed_text() {$/,/^}$/p' "${script}")"
  eval "$(sed -n '/^ssh_agent_socket_path() {$/,/^}$/p' "${script}")"
  eval "$(sed -n '/^ssh_agent_service_socket_path() {$/,/^}$/p' "${script}")"
  eval "$(sed -n '/^configure_ssh_agent() {$/,/^}$/p' "${script}")"
  eval "$(sed -n '/^activate_ssh_agent() {$/,/^}$/p' "${script}")"
}

@test "requires Python 3 during Debian-family installation" {
  linux_package_manager() { printf '%s\n' apt-get; }
  install_linux_prerequisites() { printf '%s\n' "$*"; }
  jsh_warn() { :; }
  jsh_note() { :; }

  output=$(PATH="$(prerequisite_path)" install_prerequisites install 0)

  [[ " ${output} " = *' python3 '* ]]
  [[ " ${output} " = *' jq '* ]]
  [[ " ${output} " = *' curl '* ]]
}

@test "uses the Python package name during Arch-family installation" {
  linux_package_manager() { printf '%s\n' pacman; }
  install_linux_prerequisites() { printf '%s\n' "$*"; }
  jsh_warn() { :; }
  jsh_note() { :; }

  output=$(PATH="$(prerequisite_path)" install_prerequisites install 0)

  [[ " ${output} " = *' python '* ]]
  [[ " ${output} " = *' jq '* ]]
  [[ " ${output} " = *' curl '* ]]
}

@test "does not require Python for the lightweight runtime" {
  linux_package_manager() { printf '%s\n' apt-get; }
  install_linux_prerequisites() { printf 'unexpected install: %s\n' "$*"; }
  jsh_warn() { :; }
  jsh_note() { :; }

  output=$(PATH="$(prerequisite_path)" install_prerequisites shell 0)

  [[ -z "${output}" ]]
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
  [[ " ${NATIVE_PACKAGES[*]} " = *' python3-poetry '* ]]
  [[ " ${NATIVE_PACKAGES[*]} " != *' poetry '* ]]
  [[ " ${NATIVE_PACKAGES[*]} " = *' systemd-zram-generator '* ]]
  [[ " ${NATIVE_PACKAGES[*]} " = *' nodejs '* ]]
  [[ " ${NATIVE_PACKAGES[*]} " = *' sqlite3 '* ]]
}

@test "does not refresh package metadata when native packages are current" {
  local calls="${BATS_TEST_TMPDIR}/native-calls"
  DISTRO_FAMILY=debian
  NATIVE_PACKAGES=(curl)
  DRY_RUN=0
  NATIVE_PREPARED=0
  [[ ${NATIVE_PREPARED} == 0 ]]
  package_installed() { [[ $1 != light-locker ]]; }
  prepare_native_packages() { printf '%s\n' prepare >> "${calls}"; }
  jsh::log_note() { :; }
  jsh::log_success() { :; }
  jsh::log_error() { :; }

  install_native_packages

  [[ ! -e ${calls} ]]
}

@test "fails when a Flatpak is still absent after installation" {
  FLATPAK_APPLICATIONS=(com.example.App)
  [[ ${FLATPAK_APPLICATIONS[0]} == com.example.App ]]
  DRY_RUN=0
  flatpak() {
    case $1 in
      info) return 1 ;;
      remote-add | install) return 0 ;;
    esac
  }
  jsh::log_success() { :; }
  jsh::log_note() { :; }
  jsh::log_error() { printf '%s\n' "$*"; }

  run install_flatpaks

  [[ ${status} -ne 0 ]]
  [[ ${output} == *'Flatpak verification failed: com.example.App'* ]]
}

@test "installs Syncthing natively on every Linux family" {
  local release

  for release in arch fedora debian; do
    write_os_release "ID=${release}"
    select_native_packages
    [[ " ${NATIVE_PACKAGES[*]} " = *' syncthing '* ]]
  done
}

@test "repairs the managed SSH agent socket mismatch idempotently" {
  local calls="${BATS_TEST_TMPDIR}/systemctl-calls"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.config/systemd/user" "${HOME}/.config/environment.d"
  printf '%s\n' '[Unit]
Description=SSH Agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a $SSH_AUTH_SOCK

[Install]
WantedBy=default.target' > "${HOME}/.config/systemd/user/ssh-agent.service"
  printf '%s\n' 'SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"' \
    > "${HOME}/.config/environment.d/ssh-agent.conf"
  systemctl() {
    printf '%s\n' "$*" >> "${calls}"
    case "$*" in
      '--user cat ssh-agent.socket') return 0 ;;
      '--user show ssh-agent.socket --property=Listen --value')
        printf '%s\n' '/run/user/1000/openssh_agent (Stream)'
        ;;
      '--user show ssh-agent.service --property=Environment --value')
        printf '%s\n' 'SSH_AUTH_SOCK=/run/user/1000/ssh-agent.socket'
        ;;
    esac
  }
  jsh::log_error() { printf '%s\n' "$*"; }
  jsh::log_note() { :; }
  export DRY_RUN=0
  USER_UNITS_CHANGED=0
  SSH_AGENT_CHANGED=0
  SSH_AGENT_UNIT=ssh-agent.service
  load_ssh_agent_service_functions

  configure_ssh_agent

  [[ ! -e "${HOME}/.config/systemd/user/ssh-agent.service" ]]
  [[ ! -e "${HOME}/.config/environment.d/ssh-agent.conf" ]]
  [[ "${SSH_AGENT_UNIT}" = ssh-agent.socket ]]
  [[ "${USER_UNITS_CHANGED}" = 1 ]]
  [[ "${SSH_AGENT_CHANGED}" = 1 ]]
  grep -Fxq -- '--user disable --now ssh-agent.service' "${calls}"
  activate_ssh_agent
  grep -Fxq -- '--user enable ssh-agent.socket' "${calls}"
  grep -Fxq -- '--user restart ssh-agent.socket' "${calls}"

  : > "${calls}"
  USER_UNITS_CHANGED=0
  SSH_AGENT_CHANGED=0
  configure_ssh_agent

  [[ "${USER_UNITS_CHANGED}" = 0 ]]
  [[ "${SSH_AGENT_CHANGED}" = 0 ]]
  run grep -Fq -- '--user disable' "${calls}"
  [[ "${status}" -ne 0 ]]
}

@test "declares Neovim for the jvim wrapper" {
  jsh_manifest_brewfile | grep -Fxq 'brew "neovim"'
}

@test "loads the shared vimrc in available editors" {
  local editor
  local -a editors=()
  [[ -x /usr/bin/vi ]] && editors+=(/usr/bin/vi)
  command -v vim > /dev/null 2>&1 && editors+=("$(command -v vim)")
  command -v nvim > /dev/null 2>&1 && editors+=("$(command -v nvim)")

  for editor in "${editors[@]}"; do
    if [[ "$(basename "${editor}")" == nvim ]]; then
      run env SSHHOME=1 "${editor}" --headless -u "${JSH_ROOT}/dotfiles/.vimrc" '+qall!'
    else
      run env SSHHOME=1 "${editor}" -Nu "${JSH_ROOT}/dotfiles/.vimrc" -es -c 'qall!'
    fi
    [[ "${status}" -eq 0 ]]
    [[ ! "${output}" =~ E[0-9]{3}: ]]
  done
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
  local installed=0
  package_installed() { [[ ${installed} == 1 ]]; }
  package_available() { return 0; }
  jsh_run_root() { printf '%s\n' "$*" >> "${calls}"; installed=1; }

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

@test "skips kernel tweaks when already set" {
  local calls="${BATS_TEST_TMPDIR}/root-calls"
  run bash -c '
    calls="'"${calls}"'"
    export JSH_ROOT="'"${JSH_ROOT}"'"
    source "${JSH_ROOT}/scripts/linux/configure/system.sh"
    jsh_run_root() { printf "%s\n" "$*" >> "${calls}"; }
    sysctl() {
      case $2 in
        vm.swappiness) echo 180 ;;
        vm.watermark_boost_factor) echo 0 ;;
        vm.watermark_scale_factor) echo 125 ;;
        vm.page-cluster) echo 0 ;;
        *) return 1 ;;
      esac
    }
    root_text_matches() { return 0; }
    configure_kernel_tweaks
  '
  [[ "${status}" -eq 0 ]]
  [[ ! -e "${calls}" ]]
}

@test "applies individual kernel tweaks when values differ" {
  local calls="${BATS_TEST_TMPDIR}/root-calls"
  run bash -c '
    calls="'"${calls}"'"
    export JSH_ROOT="'"${JSH_ROOT}"'"
    source "${JSH_ROOT}/scripts/linux/configure/system.sh"
    jsh_run_root() { printf "%s\n" "$*" >> "${calls}"; }
    sysctl() {
      case $2 in
        vm.swappiness) echo 60 ;;
        vm.watermark_boost_factor) echo 0 ;;
        vm.watermark_scale_factor) echo 125 ;;
        vm.page-cluster) echo 0 ;;
        *) return 1 ;;
      esac
    }
    root_text_matches() { return 0; }
    configure_kernel_tweaks
  '
  [[ "${status}" -eq 0 ]]
  grep -Fxq 'sysctl -w vm.swappiness=180' "${calls}"
}

@test "invokes Debian installers for Citrix and Zoom on Debian" {
  local calls="${BATS_TEST_TMPDIR}/work-calls"
  run bash -c '
    calls="'"${calls}"'"
    export JSH_ROOT="'"${JSH_ROOT}"'"
    source "${JSH_ROOT}/scripts/linux/configure/work.sh"
    jsh_linux_family() { echo debian; }
    install_citrix_debian() { echo citrix >> "${calls}"; }
    install_zoom_debian() { echo zoom >> "${calls}"; }
    install_work_packages
  '
  [[ "${status}" -eq 0 ]]
  grep -Fxq 'citrix' "${calls}"
  grep -Fxq 'zoom' "${calls}"
}

@test "skips AMD64-only Debian work packages on ARM" {
  run bash -c '
    export JSH_ROOT="'"${JSH_ROOT}"'"
    source "${JSH_ROOT}/scripts/linux/configure/work.sh"
    uname() { printf "aarch64\n"; }
    curl() { return 99; }
    install_citrix_debian
    install_zoom_debian
  '

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Citrix Workspace is unavailable for architecture aarch64.'* ]]
  [[ ${output} == *'Zoom is unavailable for architecture aarch64.'* ]]
}

@test "Citrix preferences preserve unrelated keys and converge" {
  local home="${BATS_TEST_TMPDIR}/citrix-home" stage="${BATS_TEST_TMPDIR}/citrix-stage"
  mkdir -p "${home}/.ICAClient" "${stage}"
  printf '[WFClient]\nOther=True\nMouseSendsControlV=True\n[Other]\nValue=1\n' \
    > "${home}/.ICAClient/wfclient.ini"

  run env HOME="${home}" XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state" JSH_ROOT="${JSH_ROOT}" \
    bash -c 'source "$1"; configure_citrix_preferences "$2"; before=$(stat -c "%i:%Y" "$HOME/.ICAClient/wfclient.ini"); configure_citrix_preferences "$2"; [[ $(stat -c "%i:%Y" "$HOME/.ICAClient/wfclient.ini") == "$before" ]]' \
    _ "${JSH_ROOT}/scripts/linux/configure/work.sh" "${stage}"

  [[ ${status} -eq 0 ]]
  grep -Fxq Other=True "${home}/.ICAClient/wfclient.ini"
  [[ $(grep -Fxc MouseSendsControlV=False "${home}/.ICAClient/wfclient.ini") -eq 1 ]]
}

@test "VS Code configuration preserves personal JSON settings" {
  local home="${BATS_TEST_TMPDIR}/vscode-home" config="${BATS_TEST_TMPDIR}/vscode-config"
  mkdir -p "${config}/Code/User"
  printf '%s\n' '{"editor.fontSize":15,"terminal.integrated.profiles.linux":{"bash":{"path":"/bin/bash"}}}' \
    > "${config}/Code/User/settings.json"
  printf '%s\n' '[{"key":"ctrl+x","command":"test.keep"}]' \
    > "${config}/Code/User/keybindings.json"

  run env HOME="${home}" XDG_CONFIG_HOME="${config}" XDG_DATA_HOME="${BATS_TEST_TMPDIR}/data" \
    XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state" JSH_ROOT="${JSH_ROOT}" bash -c '
      source "$1"
      code() { :; }
      zsh() { :; }
      uname() { printf "Linux\n"; }
      configure_vscode
    ' _ "${JSH_ROOT}/scripts/unix/configure/vscode.sh"

  [[ ${status} -eq 0 ]]
  jq -e '."editor.fontSize" == 15 and ."terminal.integrated.profiles.linux".bash.path == "/bin/bash" and ."terminal.integrated.defaultProfile.linux" == "zsh"' \
    "${config}/Code/User/settings.json" >/dev/null
  jq -e 'any(.[]; .command == "test.keep")' "${config}/Code/User/keybindings.json" >/dev/null
}

@test "registers shell and changes default shell via usermod" {
  local calls="${BATS_TEST_TMPDIR}/shell-calls"
  local shells_file="${BATS_TEST_TMPDIR}/shells"
  printf '/bin/bash\n' > "${shells_file}"
  run bash -c '
    calls="'"${calls}"'"
    export JSH_ROOT="'"${JSH_ROOT}"'"
    export JSH_SHELLS_FILE="'"${shells_file}"'"
    source "${JSH_ROOT}/scripts/unix/configure/shell.sh"
    jsh_run_root() {
      printf "%s\n" "$*" >> "${calls}"
      if [[ $1 == tee ]]; then
        cat >> "${JSH_SHELLS_FILE}"
      fi
    }
    usermod() { return 0; }
    ensure_shell_registered "/usr/bin/zsh"
    change_shell "/usr/bin/zsh" "testuser"
  '
  [[ "${status}" -eq 0 ]]
  grep -Fxq '/usr/bin/zsh' "${shells_file}"
  grep -Fxq 'usermod -s /usr/bin/zsh testuser' "${calls}"
}

@test "does not mistake dpkg not-installed state for installed" {
  DISTRO_FAMILY=debian
  dpkg-query() { printf 'not-installed'; }
  run package_installed absent-package
  [[ "${status}" -ne 0 ]]
}

@test "fails when the shell change command succeeds but the account stays on bash" {
  run bash -c '
    export JSH_ROOT="'"${JSH_ROOT}"'"
    export JSH_CURRENT_SHELL=/usr/bin/zsh
    source "${JSH_ROOT}/scripts/unix/configure/shell.sh"
    get_current_shell() { printf "/bin/bash\n"; }
    find_target_shell() { printf "/usr/bin/zsh\n"; }
    jsh::confirm() { return 0; }
    change_shell() { return 0; }
    main
  '
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"default shell is currently /bin/bash"* ]]
}

prepare_adopt_fixture() {
  ADOPT_ROOT="${BATS_TEST_TMPDIR}/adopt-root"
  ADOPT_HOME="${BATS_TEST_TMPDIR}/adopt-home"
  mkdir -p "${ADOPT_ROOT}/bin" "${ADOPT_ROOT}/lib" "${ADOPT_ROOT}/dotfiles" "${ADOPT_HOME}"
  cp "${JSH_ROOT}/bin/jstow" "${ADOPT_ROOT}/bin/jstow"
  cp "${JSH_ROOT}/lib/env.sh" "${ADOPT_ROOT}/lib/env.sh"
  cp "${JSH_ROOT}/lib/output.sh" "${ADOPT_ROOT}/lib/output.sh"
  cp "${JSH_ROOT}/lib/ui.sh" "${ADOPT_ROOT}/lib/ui.sh"
  cp -R "${JSH_ROOT}/lib/ui" "${ADOPT_ROOT}/lib/"
  chmod +x "${ADOPT_ROOT}/bin/jstow"
}

run_adopt() {
  run env HOME="${ADOPT_HOME}" JSH_DIR="${ADOPT_ROOT}" JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/bin/jsh" adopt "$@"
}

@test "adopts selected home files and directories into shared dotfiles" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/xfce4"
  printf '<channel/>\n' > "${ADOPT_HOME}/.config/xfce4/settings.xml"
  printf 'export EXAMPLE=1\n' > "${ADOPT_HOME}/.example"
  printf 'leave unstowed\n' > "${ADOPT_ROOT}/dotfiles/.unrelated"

  run_adopt --yes "${ADOPT_HOME}/.config/xfce4" "${ADOPT_HOME}/.example"

  [[ "${status}" -eq 0 ]]
  [[ -L "${ADOPT_HOME}/.config/xfce4" ]]
  [[ -L "${ADOPT_HOME}/.example" ]]
  [[ "${ADOPT_HOME}/.config/xfce4/settings.xml" -ef "${ADOPT_ROOT}/dotfiles/.config/xfce4/settings.xml" ]]
  [[ "${ADOPT_HOME}/.example" -ef "${ADOPT_ROOT}/dotfiles/.example" ]]
  [[ "$(cat "${ADOPT_ROOT}/dotfiles/.example")" == 'export EXAMPLE=1' ]]
  [[ ! -e "${ADOPT_HOME}/.unrelated" ]]

  run env HOME="${ADOPT_HOME}" "${ADOPT_ROOT}/bin/jstow" --simulate --stow \
    --dir "${ADOPT_ROOT}" --target "${ADOPT_HOME}" dotfiles
  [[ "${status}" -eq 0 ]]

  run_adopt --yes "${ADOPT_HOME}/.config/xfce4"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"already adopted"* ]]
}

@test "adopt consolidates selected siblings at their common parent" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example/one" "${ADOPT_HOME}/.config/example/two"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/settings"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/settings"

  run_adopt --yes \
    "${ADOPT_HOME}/.config/example/one" \
    "${ADOPT_HOME}/.config/example/two"

  [[ "${status}" -eq 0 ]]
  [[ -L "${ADOPT_HOME}/.config/example" ]]
  [[ ! -L "${ADOPT_HOME}/.config/example/one" ]]
  [[ "${ADOPT_HOME}/.config/example/one/settings" -ef \
    "${ADOPT_ROOT}/dotfiles/.config/example/one/settings" ]]
  [[ "${ADOPT_HOME}/.config/example/two/settings" -ef \
    "${ADOPT_ROOT}/dotfiles/.config/example/two/settings" ]]
}

@test "adopt consolidates a new sibling with an existing managed link" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example/one"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/settings"
  run_adopt --yes "${ADOPT_HOME}/.config/example/one"
  [[ "${status}" -eq 0 ]]

  mkdir -p "${ADOPT_HOME}/.config/example/two"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/settings"
  run_adopt --yes "${ADOPT_HOME}/.config/example/two"

  [[ "${status}" -eq 0 ]]
  [[ -L "${ADOPT_HOME}/.config/example" ]]
  [[ ! -L "${ADOPT_HOME}/.config/example/one" ]]
  [[ "${ADOPT_HOME}/.config/example/one/settings" -ef \
    "${ADOPT_ROOT}/dotfiles/.config/example/one/settings" ]]
  [[ "${ADOPT_HOME}/.config/example/two/settings" -ef \
    "${ADOPT_ROOT}/dotfiles/.config/example/two/settings" ]]
}

@test "adopt consolidates nested selections at their greatest common path" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example/one/leaf" \
    "${ADOPT_HOME}/.config/example/two/leaf"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/leaf/settings"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/leaf/settings"

  run_adopt --yes \
    "${ADOPT_HOME}/.config/example/one/leaf" \
    "${ADOPT_HOME}/.config/example/two/leaf"

  [[ "${status}" -eq 0 ]]
  [[ -L "${ADOPT_HOME}/.config/example" ]]
  [[ ! -L "${ADOPT_HOME}/.config" ]]
}

@test "adopt does not consolidate above the selected common path" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/other" "${ADOPT_HOME}/.config/example/one"
  printf 'other\n' > "${ADOPT_HOME}/.config/other/settings"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/settings"
  run_adopt --yes "${ADOPT_HOME}/.config/other"
  [[ "${status}" -eq 0 ]]
  run_adopt --yes "${ADOPT_HOME}/.config/example/one"
  [[ "${status}" -eq 0 ]]

  mkdir -p "${ADOPT_HOME}/.config/example/two"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/settings"
  run_adopt --yes "${ADOPT_HOME}/.config/example/two"

  [[ "${status}" -eq 0 ]]
  [[ -d "${ADOPT_HOME}/.config" ]]
  [[ ! -L "${ADOPT_HOME}/.config" ]]
  [[ -L "${ADOPT_HOME}/.config/example" ]]
  [[ -L "${ADOPT_HOME}/.config/other" ]]
}

@test "adopt keeps separate links when their parent has unmanaged contents" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example/one" \
    "${ADOPT_HOME}/.config/example/two" \
    "${ADOPT_HOME}/.config/example/local"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/settings"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/settings"
  printf 'local\n' > "${ADOPT_HOME}/.config/example/local/settings"

  run_adopt --yes \
    "${ADOPT_HOME}/.config/example/one" \
    "${ADOPT_HOME}/.config/example/two"

  [[ "${status}" -eq 0 ]]
  [[ -d "${ADOPT_HOME}/.config/example" ]]
  [[ ! -L "${ADOPT_HOME}/.config/example" ]]
  [[ -L "${ADOPT_HOME}/.config/example/one" ]]
  [[ -L "${ADOPT_HOME}/.config/example/two" ]]
  [[ ! -L "${ADOPT_HOME}/.config/example/local" ]]
  [[ "$(cat "${ADOPT_HOME}/.config/example/local/settings")" == local ]]
}

@test "adopt merges existing managed descendants when their parent is selected" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example/one"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/settings"
  run_adopt --yes "${ADOPT_HOME}/.config/example/one"
  [[ "${status}" -eq 0 ]]

  mkdir -p "${ADOPT_HOME}/.config/example/two"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/settings"
  run_adopt --yes \
    "${ADOPT_HOME}/.config/example/two" \
    "${ADOPT_HOME}/.config/example"

  [[ "${status}" -eq 0 ]]
  [[ -L "${ADOPT_HOME}/.config/example" ]]
  [[ "${ADOPT_HOME}/.config/example/one/settings" -ef \
    "${ADOPT_ROOT}/dotfiles/.config/example/one/settings" ]]
  [[ "${ADOPT_HOME}/.config/example/two/settings" -ef \
    "${ADOPT_ROOT}/dotfiles/.config/example/two/settings" ]]
}

@test "adopt restores consolidated descendants when linking fails" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example/one"
  printf 'one\n' > "${ADOPT_HOME}/.config/example/one/settings"
  run_adopt --yes "${ADOPT_HOME}/.config/example/one"
  [[ "${status}" -eq 0 ]]

  mkdir -p "${ADOPT_HOME}/.config/example/two"
  printf 'two\n' > "${ADOPT_HOME}/.config/example/two/settings"
  fake_link="${BATS_TEST_TMPDIR}/fake-link"
  cat > "${fake_link}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_link}"

  run env HOME="${ADOPT_HOME}" JSH_DIR="${ADOPT_ROOT}" JSH_PLAIN_OUTPUT=1 \
    JADOPT_LINK_COMMAND="${fake_link}" \
    "${JSH_ROOT}/bin/jsh" adopt --yes "${ADOPT_HOME}/.config/example/two"

  [[ "${status}" -ne 0 ]]
  [[ -d "${ADOPT_HOME}/.config/example" ]]
  [[ ! -L "${ADOPT_HOME}/.config/example" ]]
  [[ -L "${ADOPT_HOME}/.config/example/one" ]]
  [[ -d "${ADOPT_HOME}/.config/example/two" ]]
  [[ "$(cat "${ADOPT_HOME}/.config/example/two/settings")" == two ]]
  [[ ! -e "${ADOPT_ROOT}/dotfiles/.config/example/two" ]]
  [[ "${output}" == *"restoring moved paths"* ]]
}

@test "adopt dry run leaves the home and repository unchanged" {
  prepare_adopt_fixture
  mkdir -p "${ADOPT_HOME}/.config/example"
  printf 'value\n' > "${ADOPT_HOME}/.config/example/settings"

  run_adopt --dry-run "${ADOPT_HOME}/.config/example"

  [[ "${status}" -eq 0 ]]
  [[ -d "${ADOPT_HOME}/.config/example" ]]
  [[ ! -e "${ADOPT_ROOT}/dotfiles/.config/example" ]]
  [[ "${output}" == *"Dry run complete"* ]]
}

@test "adopt rejects paths outside home and existing repository destinations" {
  prepare_adopt_fixture
  outside="${BATS_TEST_TMPDIR}/outside"
  printf 'outside\n' > "${outside}"

  run_adopt --yes "${outside}"
  [[ "${status}" -ne 0 ]]
  [[ "${output}" == *"must be inside the home directory"* ]]

  printf 'home\n' > "${ADOPT_HOME}/.example"
  printf 'repository\n' > "${ADOPT_ROOT}/dotfiles/.example"
  run_adopt --yes "${ADOPT_HOME}/.example"
  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${ADOPT_HOME}/.example")" == home ]]
  [[ "$(cat "${ADOPT_ROOT}/dotfiles/.example")" == repository ]]
}

@test "adopt restores moved paths when linking fails" {
  prepare_adopt_fixture
  printf 'restore me\n' > "${ADOPT_HOME}/.example"
  fake_link="${BATS_TEST_TMPDIR}/fake-link"
  cat > "${fake_link}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_link}"

  run env HOME="${ADOPT_HOME}" JSH_DIR="${ADOPT_ROOT}" JSH_PLAIN_OUTPUT=1 \
    JADOPT_LINK_COMMAND="${fake_link}" \
    "${JSH_ROOT}/bin/jsh" adopt --yes "${ADOPT_HOME}/.example"

  [[ "${status}" -ne 0 ]]
  [[ "$(cat "${ADOPT_HOME}/.example")" == 'restore me' ]]
  [[ ! -e "${ADOPT_ROOT}/dotfiles/.example" ]]
  [[ "${output}" == *"restoring moved paths"* ]]
}
