#!/usr/bin/env bats

setup() {
  project_root=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  test_root=$(mktemp -d "${BATS_TEST_TMPDIR}/jsh.XXXXXX")
  source_root=${test_root}/source
  home_root=${test_root}/home
  state_root=${test_root}/state
  bin_root=${test_root}/bin
  mkdir -p "${source_root}/bin" "${source_root}/dotfiles" \
    "${source_root}/config/homebrew" "${home_root}" "${bin_root}"
}

make_fixture() {
  fixture_mode=${1:-lite}
  cp "${project_root}/j.sh" "${source_root}/j.sh"
  cp "${project_root}/bin/jsh" "${source_root}/bin/jsh"
  cp "${project_root}/dotfiles/.bashrc" "${source_root}/dotfiles/.bashrc"
  cp "${project_root}/dotfiles/.zshrc" "${source_root}/dotfiles/.zshrc"
  cp "${project_root}/dotfiles/.bash_profile" "${source_root}/dotfiles/.bash_profile"
  cp "${project_root}/config/homebrew/Brewfile.core" \
    "${source_root}/config/homebrew/Brewfile.core"

  if [[ "${fixture_mode}" == full ]]; then
    mkdir -p "${source_root}/dotfiles/.config/example" \
      "${source_root}/dotfiles/.agents/agents" \
      "${source_root}/dotfiles/.codex" \
      "${source_root}/dotfiles/.copilot" \
      "${source_root}/dotfiles/.vscode/user" \
      "${source_root}/vendor/fzf" \
      "${source_root}/vendor/fzf-tab" \
      "${source_root}/vendor/zsh-completions/src" \
      "${source_root}/vendor/zsh-plugins" \
      "${source_root}/vendor/vim-config/autoload"
    printf '%s\n' \
      '[submodule "vendor/fzf-tab"]' \
      '  path = vendor/fzf-tab' \
      '  url = https://example.invalid/fzf-tab.git' \
      '[submodule "vendor/fzf"]' \
      '  path = vendor/fzf' \
      '  url = https://example.invalid/fzf.git' \
      '[submodule "vendor/zsh-completions"]' \
      '  path = vendor/zsh-completions' \
      '  url = https://example.invalid/zsh-completions.git' \
      >"${source_root}/.gitmodules"
    cat >"${source_root}/vendor/fzf/install" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" --bin "* ]] || exit 2
mkdir -p "$(dirname "$0")/bin"
printf '#!/usr/bin/env bash\n' >"$(dirname "$0")/bin/fzf"
chmod +x "$(dirname "$0")/bin/fzf"
EOF
    chmod +x "${source_root}/vendor/fzf/install"
    printf '%s\n' plugin >"${source_root}/vendor/fzf-tab/fzf-tab.plugin.zsh"
    printf '%s\n' completion >"${source_root}/vendor/zsh-completions/src/_example"
    printf '%s\n' autosuggest >"${source_root}/vendor/zsh-plugins/zsh-autosuggestions.zsh"
    printf '%s\n' plug >"${source_root}/vendor/vim-config/autoload/plug.vim"
    printf '%s\n' example >"${source_root}/dotfiles/.config/example/config"
    printf '%s\n' instructions >"${source_root}/dotfiles/.codex/AGENTS.md"
    printf '%s\n' instructions >"${source_root}/dotfiles/.copilot/copilot-instructions.md"
    printf '%s\n' '{}' >"${source_root}/dotfiles/.vscode/user/settings.json"
    printf '%s\n' agent >"${source_root}/dotfiles/.agents/agents/swe.agent.md"
    printf '%s\n' 'name = "swe"' >"${source_root}/dotfiles/.agents/agents/swe.toml"
  fi

  git -C "${source_root}" init -q
  git -C "${source_root}" config user.email test@example.invalid
  git -C "${source_root}" config user.name test
  git -C "${source_root}" config commit.gpgsign false
  git -C "${source_root}" add .
  git -C "${source_root}" commit -qm initial
}

run_installer() {
  run_mode=$1
  shift
  env \
    "HOME=${home_root}" \
    "XDG_STATE_HOME=${state_root}" \
    "JSH_BIN_DIR=${bin_root}" \
    "JSH_MODE=${run_mode}" \
    'JSH_PLAIN_OUTPUT=1' \
    'JSH_COLOR=never' \
    'JSH_NETWORK_CHECK=never' \
    "${source_root}/j.sh" "$@"
}

assert_banner_spacing() {
  local expected_next=$1
  local banner_end=$' =   :-=-:                          -:\n\n'"${expected_next}"

  [[ "${output}" == $'\n   :%@@@@@@@@@#*#@%-              +-:##'* ]]
  [[ "${output}" == *"${banner_end}"* ]]
}

assert_embedded_banner_header() {
  local header=$1 gap_width=26 left_width right_width banner_end banner_count
  left_width=$(((gap_width - ${#header}) / 2))
  right_width=$((gap_width - ${#header} - left_width))
  printf -v banner_end ' =   :-=-:%*s%s%*s-:\n\n' \
    "${left_width}" '' "${header}" "${right_width}" ''
  banner_count=$(printf '%s\n' "${output}" \
    | grep -Fc '   :%@@@@@@@@@#*#@%-              +-:##')

  [[ "${output}" == $'\n   :%@@@@@@@@@#*#@%-              +-:##'* ]]
  [[ "${output}" == *"${banner_end}"* ]]
  [[ "${output}" != *$'\n'"${header}"$'\n'* ]]
  [[ "${banner_count}" -eq 1 ]]
}

@test "status embeds its header in the banner" {
  make_fixture lite
  run env \
    COLUMNS=200 \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" status

  [ "${status}" -eq 1 ]
  assert_embedded_banner_header Status
}

@test "status shows and clears a loading spinner" {
  make_fixture lite
  cat >"${bin_root}/brew" <<'BREW'
#!/bin/sh
case "$1:$2" in
  list:--formula) printf '%s\n' fzf go-task jq just zsh ;;
  list:--cask) ;;
  *) exit 2 ;;
esac
BREW
  chmod +x "${bin_root}/brew"

  run env \
    PATH="${bin_root}:${PATH}" \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_STATUS_CHECK_UPDATES=never \
    JSH_SPINNER=always \
    JSH_SPINNER_DELAY=0 \
    JSH_COLOR=always \
    TERM=xterm-256color \
    "${source_root}/bin/jsh" status

  [[ "${output}" == *$'\033[?25l'* ]]
  [[ "${output}" == *'Loading...'* ]]
  [[ "${output}" == *$'\033[?25h\r\033[K'* ]]
}

@test "status aligns component summaries and counts Git changes" {
  make_fixture full
  printf '%s\n' staged >>"${source_root}/dotfiles/.bashrc"
  git -C "${source_root}" add dotfiles/.bashrc
  printf '%s\n' unstaged >>"${source_root}/dotfiles/.zshrc"
  printf '%s\n' untracked >"${source_root}/untracked.txt"

  run env \
    COLUMNS=200 \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_STATUS_CHECK_UPDATES=never \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" status

  [ "${status}" -eq 1 ]
  [[ "${output}" == *'[error] Shell'*'unconfigured, '* ]]
  [[ "${output}" == *'[warn]  Repository'* ]]
  [[ "${output}" == *'3 changes - 1 staged, 1 unstaged, 1 untracked'* ]]
  [[ "${output}" == *'[error] Submodules'* ]]
  [[ "${output}" == *'[ok]    Packages'*'4 defined'* ]]
}

@test "status indents wrapped summary values by two spaces" {
  make_fixture lite
  run env \
    COLUMNS=40 \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_STATUS_CHECK_UPDATES=never \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" status

  [[ "${output}" == *$'[ok]    Repository\n  main @ '* ]]
}

@test "status accepts installed Homebrew formula aliases" {
  make_fixture lite
  printf '%s\n' 'brew "python"' >"${source_root}/config/homebrew/Brewfile.core"
  cat >"${bin_root}/brew" <<'BREW'
#!/bin/sh
case "$1:$2:$3" in
  list:--formula:-1) printf '%s\n' python@3.14 ;;
  list:--formula:python) ;;
  list:--cask:-1) ;;
  *) exit 2 ;;
esac
BREW
  chmod +x "${bin_root}/brew"

  run env \
    PATH="${bin_root}:${PATH}" \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_STATUS_CHECK_UPDATES=never \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" status --verbose

  [[ "${output}" == *'[ok]    Packages'*'1 defined, 1 installed, 0 updates'* ]]
}

@test "verbose status highlights package versions and update command" {
  make_fixture lite
  cat >"${bin_root}/brew" <<'BREW'
#!/bin/sh
case "$1:$2" in
  list:--formula) printf '%s\n' fzf go-task jq just zsh ;;
  list:--cask) ;;
  outdated:--json=v2)
    printf '%s\n' '{"formulae":[{"name":"jq","installed_versions":["1.7"],"current_version":"1.8"}],"casks":[]}'
    ;;
  *) exit 2 ;;
esac
BREW
  chmod +x "${bin_root}/brew"

  run env -u NO_COLOR \
    PATH="${bin_root}:${PATH}" \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_COLOR=always \
    JSH_PLAIN_OUTPUT=0 \
    TERM=xterm-256color \
    COLORTERM=truecolor \
    "${source_root}/bin/jsh" status --verbose

  [ "${status}" -eq 1 ]
  [[ "${output}" == *'4 defined, 4 installed, 1 update'* ]]
  [[ "${output}" == *$'\033[38;2;255;233;0m1.7\033[0m'* ]]
  [[ "${output}" == *$'\033[38;2;0;208;132m1.8\033[0m'* ]]
  [[ "${output}" == *$'Run \033[1m\033[38;2;0;183;255mjsh update\033[0m'* ]]
}

@test "doctor uses comprehensive verbose status output" {
  make_fixture full
  for submodule_path in vendor/fzf vendor/fzf-tab vendor/zsh-completions; do
    git -C "${source_root}/${submodule_path}" init -q
    git -C "${source_root}/${submodule_path}" config user.email test@example.invalid
    git -C "${source_root}/${submodule_path}" config user.name test
    git -C "${source_root}/${submodule_path}" config commit.gpgsign false
    git -C "${source_root}/${submodule_path}" add .
    GIT_AUTHOR_DATE=2024-01-02T00:00:00Z GIT_COMMITTER_DATE=2024-01-02T00:00:00Z \
      git -C "${source_root}/${submodule_path}" commit -qm initial
  done
  git -C "${source_root}/vendor/fzf" tag v1.0.0
  git -C "${source_root}" rm -qr --cached vendor/fzf vendor/fzf-tab vendor/zsh-completions
  git -C "${source_root}" add vendor/fzf vendor/fzf-tab vendor/zsh-completions 2>/dev/null
  git -C "${source_root}" commit -qm submodules
  git -C "${source_root}" submodule absorbgitdirs >/dev/null
  git -C "${source_root}" submodule init >/dev/null
  fzf_head=$(git -C "${source_root}/vendor/fzf" rev-parse --short=7 HEAD)
  homebrew_root=${test_root}/homebrew
  mkdir -p "${homebrew_root}/bin" "${home_root}/.local/bin" \
    "${home_root}/Library/Application Support/Code/User" "${state_root}/jsh"
  cat >"${homebrew_root}/bin/zsh" <<'ZSH'
#!/bin/sh
printf '%s\n' 'zsh 5.9.2 (test)'
ZSH
  cat >"${bin_root}/brew" <<BREW
#!/bin/sh
case "\$1:\${2:-}" in
  --prefix:) printf '%s\n' '${homebrew_root}' ;;
  list:--formula) printf '%s\n' fzf go-task jq just zsh ;;
  list:--cask) ;;
  *) exit 2 ;;
esac
BREW
  chmod +x "${homebrew_root}/bin/zsh" "${bin_root}/brew"
  ln -s "${source_root}/bin/jsh" "${home_root}/.local/bin/jsh"
  ln -s "${source_root}/dotfiles/.vscode/user/settings.json" \
    "${home_root}/Library/Application Support/Code/User/settings.json"
  printf '%s|%s|\n%s|%s|\n' \
    "${source_root}/bin/jsh" "${home_root}/.local/bin/jsh" \
    "${source_root}/dotfiles/.vscode/user/settings.json" \
    "${home_root}/Library/Application Support/Code/User/settings.json" \
    >"${state_root}/jsh/managed-links"
  printf '%s\n' install >"${state_root}/jsh/mode"

  cd "${home_root}"
  run env \
    COLUMNS=200 \
    PATH="${homebrew_root}/bin:${bin_root}:${PATH}" \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_STATUS_CHECK_UPDATES=never \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" doctor

  [[ "${output}" == *$'[ok]    Shell                             full, zsh, standard profile\n  [ok]    bash'* ]]
  [[ "${output}" == *$'  [ok]    zsh                             Homebrew zsh 5.9.2\n'* ]]
  summary_column=$(awk 'match($0, /[0-9]+\/[0-9]+ available$/) && /Commands/ { print RSTART; exit }' <<<"${output}")
  detail_column=$(awk '/clone and update network operation$/ { print index($0, "clone and update network operation"); exit }' <<<"${output}")
  [ "${summary_column}" = "${detail_column}" ]
  [[ "${output}" != *'fuzzy history and completion'* ]]
  [[ "${output}" == *"${fzf_head} (v1.0.0), 2024-01-02"* ]]
  [[ "${output}" == *$'  [ok]    "~/Library/Application Support/Code/User/settings.json"\n    → '* ]]
  [[ "${output}" == *$'[ok]    Project shell config              none discovered'* ]]
  [[ "${output}" == *$'  [ok]    Working tree'* ]]
  [[ "${output}" != *$'\nInstaller\n'* ]]
}

@test "update coordinates submodule and package workflows" {
  make_fixture lite
  trace_file=${test_root}/update.trace
  cat >"${bin_root}/just" <<'JUST'
#!/bin/sh
printf 'just:%s\n' "$*" >>"${TRACE_FILE}"
printf 'just output\n'
JUST
  cat >"${bin_root}/task" <<'TASK'
#!/bin/sh
printf 'task:%s\n' "$*" >>"${TRACE_FILE}"
printf 'task output\n'
TASK
  chmod +x "${bin_root}/just" "${bin_root}/task"

  run env \
    PATH="${bin_root}:${PATH}" \
    TRACE_FILE="${trace_file}" \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" update

  [ "${status}" -eq 0 ]
  [ "$(cat "${trace_file}")" = $'just:update\ntask:packages' ]
  [[ "${output}" == *'just output'* ]]
  [[ "${output}" == *'task output'* ]]
  assert_embedded_banner_header Update
  [[ "${output}" == *'[ok] Submodules updated from their configured remotes'* ]]
  [[ "${output}" == *'[ok] Packages installed and upgraded'* ]]
}

@test "help surrounds its banner with one blank line" {
  make_fixture lite
  run env \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" help

  [ "${status}" -eq 0 ]
  assert_banner_spacing Usage
}

@test "audit reports unmanaged Linuxbrew leaves and casks in columns" {
  make_fixture lite
  cat >"${source_root}/config/homebrew/Brewfile" <<'BREWFILE'
brew "managed-parent"
cask "managed-cask"
BREWFILE
  cat >"${source_root}/config/homebrew/Brewfile.linux" <<'BREWFILE'
brew "managed-linux"
BREWFILE
  cat >"${bin_root}/brew" <<'BREW'
#!/bin/sh
case "$1" in
  shellenv) ;;
  leaves) printf '%s\n' managed-parent managed-linux extra-a extra-b extra-c ;;
  list) printf '%s\n' managed-cask unmanaged-cask extra-cask ;;
  *) exit 2 ;;
esac
BREW
  cat >"${bin_root}/uname" <<'UNAME'
#!/bin/sh
printf '%s\n' Linux
UNAME
  chmod +x "${bin_root}/brew" "${bin_root}/uname"

  run env \
    PATH="${bin_root}:${PATH}" \
    COLUMNS=24 \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="${source_root}" \
    JSH_AUDIT_HOSTNAME=test \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    "${source_root}/bin/jsh" audit

  [ "${status}" -eq 0 ]
  assert_embedded_banner_header Audit
  printf '%s\n' "${output}" | grep -Eq 'extra-[abc].*extra-'
  [[ "${output}" == *extra-cask* ]]
  [[ "${output}" == *extra-b* ]]
  [[ "${output}" == *unmanaged-cask* ]]
  [[ "${output}" != *managed-parent* ]]
  [[ "${output}" != *managed-linux* ]]
  [[ "${output}" != *$'\nmanaged-cask'* ]]
  [[ "${output}" != *Applications* ]]
  [[ "${output}" != *"System packages"* ]]
}

@test "installer surrounds its banner with one blank line" {
  make_fixture lite
  run run_installer lite --dry-run

  [ "${status}" -eq 0 ]
  assert_banner_spacing 'Setup plan (lite)'
}

@test "curl bootstrap surrounds its banner with one blank line" {
  runner=${test_root}/runner.sh
  checkout_root=${home_root}/.jsh
  cp "${project_root}/j.sh" "${runner}"

  run env \
    HOME="${home_root}" \
    JSH_INSTALL_DIR="${checkout_root}" \
    JSH_INSTALL_REPO=https://example.invalid/jsh.git \
    JSH_MODE=lite \
    "${runner}" --dry-run

  [ "${status}" -eq 0 ]
  assert_banner_spacing 'Setup plan (lite)'
}

@test "lite dry-run resolves only checkout and launcher" {
  make_fixture lite
  run run_installer lite --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Setup plan (lite)"* ]]
  [[ "${output}" == *"Git checkout"* ]]
  [[ "${output}" == *"Launcher"* ]]
  [[ "${output}" != *"Homebrew"* ]]
  [[ "${output}" != *"Managed configuration"* ]]
  [ ! -e "${bin_root}/jsh" ]
  [ ! -e "${state_root}" ]
}

@test "full dry-run shows missing Homebrew, core, and zsh without mutation" {
  make_fixture full
  tools_root=${test_root}/tools
  mkdir -p "${tools_root}"
  for tool in bash git curl sed awk cut dirname basename uname id readlink cat date sleep; do
    ln -s "$(command -v "${tool}")" "${tools_root}/${tool}"
  done
  run env PATH="${tools_root}" JSH_BREW_PATHS=none \
    HOME="${home_root}" XDG_STATE_HOME="${state_root}" JSH_BIN_DIR="${bin_root}" \
    JSH_MODE=full JSH_PLAIN_OUTPUT=1 JSH_COLOR=never JSH_NETWORK_CHECK=never \
    "${source_root}/j.sh" --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Homebrew / Linuxbrew"* ]]
  [[ "${output}" == *"Core dependencies"* ]]
  [[ "${output}" == *"zsh"* ]]
  [[ "${output}" == *"Submodules and vendored assets"* ]]
  [ ! -e "${bin_root}/jsh" ]
  [ ! -e "${state_root}" ]
}

@test "full mode renders its plan with the default network check" {
  make_fixture full
  tools_root=${test_root}/tools
  mkdir -p "${tools_root}"
  for tool in bash git curl sed awk cut dirname basename uname id readlink cat date sleep; do
    ln -s "$(command -v "${tool}")" "${tools_root}/${tool}"
  done
  run env \
    PATH="${tools_root}" \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_BIN_DIR="${bin_root}" \
    JSH_MODE=full \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    JSH_NETWORK_CHECK=auto \
    JSH_NETWORK_URL=file:///dev/null \
    JSH_BREW_PATHS=none \
    "${source_root}/j.sh" --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Setup plan (full)"* ]]
  [[ "${output}" == *"Network access is available"* ]]
  [ ! -e "${state_root}" ]
}

@test "dirty checkout is reported without hiding the lite plan" {
  make_fixture lite
  printf '%s\n' dirty >>"${source_root}/dotfiles/.bashrc"
  run run_installer lite --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"local changes"* ]]
  [ ! -e "${bin_root}/jsh" ]
}

@test "dirty lite checkout still applies the launcher from current files" {
  make_fixture lite
  printf '%s\n' dirty >>"${source_root}/dotfiles/.bashrc"
  run run_installer lite --yes

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"local changes"* ]]
  [ -L "${bin_root}/jsh" ]
}

@test "dirty full checkout still resolves downstream components" {
  make_fixture full
  printf '%s\n' dirty >>"${source_root}/dotfiles/.zshrc"
  run run_installer full --dry-run

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"local checkout has local changes"* ]]
  [[ "${output}" != *"[skip] Core dependencies"* ]]
  [[ "${output}" != *"[skip] Submodules and vendored assets"* ]]
  [[ "${output}" != *"[skip] Launcher"* ]]
  [[ "${output}" != *"[skip] Managed configuration"* ]]
}

@test "full setup backs up an existing dotfile before linking" {
  make_fixture full
  printf '%s\n' preserve >"${home_root}/.zshrc"
  run run_installer full --yes

  [ "${status}" -eq 0 ]
  [ -L "${bin_root}/jsh" ]
  [ -L "${home_root}/.zshrc" ]
  [ -x "${source_root}/vendor/fzf/bin/fzf" ]
  [ ! -e "${home_root}/.fzf.bash" ]
  [ ! -e "${home_root}/.fzf.zsh" ]
  backup=$(find "${state_root}/jsh/backups" -type f -name .zshrc -print -quit)
  [ -n "${backup}" ]
  [ "$(sed -n '1p' "${backup}")" = preserve ]
  [ "$(readlink "${home_root}/.zshrc")" = "$(cd "${source_root}/dotfiles" && pwd -P)/.zshrc" ]
}

@test "full setup links one canonical agent directory into every client" {
  make_fixture full
  canonical_agents=$(cd "${source_root}/dotfiles/.agents/agents" && pwd -P)
  mkdir -p "${home_root}/.agents/agents" \
    "${home_root}/.copilot/agents" \
    "${home_root}/.codex/agents" \
    "${home_root}/Library/Application Support/Code/User/prompts"
  printf '%s\n' keep >"${home_root}/.agents/agents/generated.md"
  printf '%s\n' keep >"${home_root}/.copilot/agents/generated.md"
  printf '%s\n' keep >"${home_root}/.codex/agents/generated.toml"
  printf '%s\n' keep >"${home_root}/Library/Application Support/Code/User/prompts/local.prompt.md"
  run run_installer full --yes

  [ "${status}" -eq 0 ]
  [ "$(readlink "${home_root}/.agents/agents")" = "${canonical_agents}" ]
  [ "$(readlink "${home_root}/.copilot/agents")" = "${canonical_agents}" ]
  [ "$(readlink "${home_root}/.codex/agents")" = "${canonical_agents}" ]
  [ -f "${home_root}/.copilot/agents/swe.agent.md" ]
  [ -f "${home_root}/.codex/agents/swe.toml" ]
  [ -f "${home_root}/Library/Application Support/Code/User/prompts/local.prompt.md" ]
  [ ! -e "${home_root}/Library/Application Support/Code/User/prompts/swe.agent.md" ]
  [ -L "${home_root}/.codex/AGENTS.md" ]
  [ -L "${home_root}/.copilot/copilot-instructions.md" ]
  [ -f "$(find "${state_root}/jsh/backups" -path '*/.agents/agents/generated.md' -print -quit)" ]
  [ -f "$(find "${state_root}/jsh/backups" -path '*/.copilot/agents/generated.md' -print -quit)" ]
  [ -f "$(find "${state_root}/jsh/backups" -path '*/.codex/agents/generated.toml' -print -quit)" ]
}

@test "full setup retires managed VS Code profile agent links" {
  make_fixture full
  mkdir -p "${source_root}/dotfiles/.vscode/user/prompts"
  source_prompts=$(cd "${source_root}/dotfiles/.vscode/user/prompts" && pwd -P)
  source_agent=${source_prompts}/swe.agent.md
  printf '%s\n' legacy >"${source_agent}"
  git -C "${source_root}" add dotfiles/.vscode/user/prompts/swe.agent.md
  git -C "${source_root}" commit -qm legacy
  vscode_prompts="${home_root}/Library/Application Support/Code/User/prompts"
  vscode_agent=${vscode_prompts}/swe.agent.md
  mkdir -p "${vscode_prompts}" "${state_root}/jsh"
  printf '%s\n' keep >"${vscode_prompts}/local.prompt.md"
  ln -s "${source_agent}" "${vscode_agent}"
  printf '%s|%s|\n' "${source_agent}" "${vscode_agent}" \
    >"${state_root}/jsh/managed-links"
  printf '%s\n' install >"${state_root}/jsh/mode"

  run run_installer full --yes

  [ "${status}" -eq 0 ]
  [ ! -e "${vscode_agent}" ]
  [ -f "${vscode_prompts}/local.prompt.md" ]
  [ -f "${home_root}/.copilot/agents/swe.agent.md" ]
  ! grep -Fq "${source_agent}|${vscode_agent}|" "${state_root}/jsh/managed-links"
}

@test "full setup migrates the legacy prompts directory link" {
  make_fixture full
  mkdir -p "${source_root}/dotfiles/.vscode/user/prompts"
  source_prompts=$(cd "${source_root}/dotfiles/.vscode/user/prompts" && pwd -P)
  vscode_prompts="${home_root}/Library/Application Support/Code/User/prompts"
  mkdir -p "$(dirname "${vscode_prompts}")" "${state_root}/jsh"
  ln -s "${source_prompts}" "${vscode_prompts}"
  printf '%s|%s|\n' \
    "${source_prompts}" "${vscode_prompts}" \
    >"${state_root}/jsh/managed-links"
  printf '%s\n' install >"${state_root}/jsh/mode"

  run run_installer full --yes

  [ "${status}" -eq 0 ]
  [ -d "${vscode_prompts}" ]
  [ ! -L "${vscode_prompts}" ]
  [ ! -e "${vscode_prompts}/swe.agent.md" ]
  [ -f "${home_root}/.copilot/agents/swe.agent.md" ]
  ! grep -Fq "${source_prompts}|${vscode_prompts}|" \
    "${state_root}/jsh/managed-links"
}

@test "full setup recovers agent sources from a failed prompts migration" {
  make_fixture full
  mkdir -p "${source_root}/dotfiles/.vscode/user/prompts"
  source_prompts=$(cd "${source_root}/dotfiles/.vscode/user/prompts" && pwd -P)
  source_agent=${source_prompts}/swe.agent.md
  vscode_prompts="${home_root}/Library/Application Support/Code/User/prompts"
  vscode_agent=${vscode_prompts}/swe.agent.md
  backup_agent="${state_root}/jsh/backups/failed/Library/Application Support/Code/User/prompts/swe.agent.md"
  mkdir -p "$(dirname "${vscode_prompts}")" "$(dirname "${backup_agent}")"
  printf '%s\n' agent >"${source_agent}"
  git -C "${source_root}" add dotfiles/.vscode/user/prompts/swe.agent.md
  git -C "${source_root}" commit -qm legacy
  ln -s "${source_prompts}" "${vscode_prompts}"
  mv "${source_agent}" "${backup_agent}"
  ln -s "${source_agent}" "${source_agent}"
  git -C "${source_root}" add dotfiles/.vscode/user/prompts/swe.agent.md
  git -C "${source_root}" commit -qm damaged
  printf '%s|%s|\n%s|%s|%s\n' \
    "${source_prompts}" "${vscode_prompts}" \
    "${source_agent}" "${vscode_agent}" "${backup_agent}" \
    >"${state_root}/jsh/managed-links"
  printf '%s\n' install >"${state_root}/jsh/mode"

  run run_installer full --yes

  [ "${status}" -eq 0 ]
  [ -f "${source_agent}" ]
  [ ! -L "${source_agent}" ]
  [ "$(cat "${source_agent}")" = agent ]
  [ ! -e "${vscode_agent}" ]
  [ -f "${home_root}/.copilot/agents/swe.agent.md" ]
  [ ! -e "${backup_agent}" ]
  ! grep -Fq "${source_agent}|${vscode_agent}|" "${state_root}/jsh/managed-links"
}

@test "full setup removes managed Copilot agent links" {
  make_fixture full
  mkdir -p "${source_root}/dotfiles/.vscode/user/prompts"
  source_prompts=$(cd "${source_root}/dotfiles/.vscode/user/prompts" && pwd -P)
  source_agent=${source_prompts}/swe.agent.md
  printf '%s\n' legacy >"${source_agent}"
  git -C "${source_root}" add dotfiles/.vscode/user/prompts/swe.agent.md
  git -C "${source_root}" commit -qm legacy
  copilot_agent=${home_root}/.copilot/agents/swe.agent.md
  mkdir -p "${copilot_agent%/*}" "${state_root}/jsh"
  ln -s "${source_agent}" "${copilot_agent}"
  printf '%s|%s|\n' "${source_agent}" "${copilot_agent}" \
    >"${state_root}/jsh/managed-links"
  printf '%s\n' install >"${state_root}/jsh/mode"

  run run_installer full --yes

  [ "${status}" -eq 0 ]
  [ -f "${copilot_agent}" ]
  [ ! -L "${copilot_agent}" ]
  ! grep -Fq "${source_agent}|${copilot_agent}|" "${state_root}/jsh/managed-links"
}

@test "a declined launcher prevents its dependent configuration action" {
  make_fixture full
  run expect -c "
    set timeout 10
    spawn env HOME=${home_root} XDG_STATE_HOME=${state_root} JSH_BIN_DIR=${bin_root} JSH_MODE=full JSH_PLAIN_OUTPUT=1 JSH_COLOR=never JSH_NETWORK_CHECK=never ${source_root}/j.sh
    expect \"Apply Submodules and vendored assets?\"
    send \"y\"
    expect \"Apply Launcher?\"
    send \"n\"
    expect {
      \"Managed configuration skipped\" {}
      \"Apply Managed configuration?\" { puts \"configuration was prompted independently\"; exit 2 }
      timeout { puts \"timed out waiting for configuration skip\"; exit 3 }
    }
    expect eof
    exit 1
  "

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Managed configuration skipped"* ]]
  [ ! -e "${bin_root}/jsh" ]
  [ ! -e "${home_root}/.zshrc" ]
}

@test "noninteractive changes require --yes" {
  make_fixture lite
  run run_installer lite

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"requires --yes"* ]]
  [ ! -e "${bin_root}/jsh" ]
}

@test "colored output is opt-in and plain output has no escape codes" {
  make_fixture lite
  run env -u NO_COLOR HOME="${home_root}" XDG_STATE_HOME="${state_root}" JSH_BIN_DIR="${bin_root}" \
    JSH_MODE=lite JSH_PLAIN_OUTPUT=0 JSH_COLOR=always TERM=xterm \
    JSH_NETWORK_CHECK=never "${source_root}/j.sh" --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\033['* ]]

  run run_installer lite --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *$'\033['* ]]
}

@test "current lite setup has no planned action on the next run" {
  make_fixture lite
  run run_installer lite --yes
  [ "${status}" -eq 0 ]
  first_state_checksum=$(cksum "${state_root}/jsh/managed-links")

  run run_installer lite
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[ok] Launcher"* ]]
  [[ "${output}" != *"[plan] Launcher"* ]]
  second_state_checksum=$(cksum "${state_root}/jsh/managed-links")
  [ "${first_state_checksum}" = "${second_state_checksum}" ]
}

@test "checkout updates plan downstream reconciliation" {
  make_fixture full
  runner=${test_root}/runner.sh
  remote_root=${test_root}/remote.git
  checkout_root=${home_root}/checkout
  cp "${project_root}/j.sh" "${runner}"
  git clone --bare -q "${source_root}" "${remote_root}"
  branch=$(git -C "${source_root}" symbolic-ref --short HEAD)
  git clone -q "${remote_root}" "${checkout_root}"
  git -C "${checkout_root}" remote set-url origin "${remote_root}"
  old_head=$(git -C "${checkout_root}" rev-parse HEAD)
  printf '%s\n' updated >>"${source_root}/dotfiles/.config/example/config"
  git -C "${source_root}" add dotfiles/.config/example/config
  git -C "${source_root}" commit -qm update
  git -C "${source_root}" push -q "${remote_root}" "HEAD:${branch}"

  run env \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_BIN_DIR="${bin_root}" \
    JSH_INSTALL_DIR="${checkout_root}" \
    JSH_INSTALL_REPO="${remote_root}" \
    JSH_INSTALL_REF="${branch}" \
    JSH_MODE=full \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    JSH_NETWORK_CHECK=never \
    JSH_BREW_PATHS=none \
    "${runner}" --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"update available"* ]]
  [[ "${output}" == *"checkout update may change Brewfile.core"* ]]
  [[ "${output}" == *"checkout update may change vendored assets"* ]]
  [[ "${output}" == *"checkout update may change managed sources"* ]]
  [ "$(git -C "${checkout_root}" rev-parse HEAD)" = "${old_head}" ]
  [ ! -e "${state_root}" ]
}

@test "local checkout detects and can decline an upstream update" {
  make_fixture lite
  remote_root=${test_root}/remote.git
  updater_root=${test_root}/updater
  git clone --bare -q "${source_root}" "${remote_root}"
  branch=$(git -C "${source_root}" symbolic-ref --short HEAD)
  git -C "${source_root}" remote add origin "${remote_root}"
  git clone -q "${remote_root}" "${updater_root}"
  git -C "${updater_root}" config user.email test@example.invalid
  git -C "${updater_root}" config user.name test
  git -C "${updater_root}" config commit.gpgsign false
  old_head=$(git -C "${source_root}" rev-parse HEAD)
  printf '%s\n' upstream >>"${updater_root}/dotfiles/.bashrc"
  git -C "${updater_root}" add dotfiles/.bashrc
  git -C "${updater_root}" commit -qm upstream
  git -C "${updater_root}" push -q origin "HEAD:${branch}"

  run expect -c "
    set timeout 10
    spawn env HOME=${home_root} XDG_STATE_HOME=${state_root} JSH_BIN_DIR=${bin_root} JSH_MODE=lite JSH_PLAIN_OUTPUT=1 JSH_COLOR=never JSH_NETWORK_CHECK=never ${source_root}/j.sh
    expect \"Update Git checkout?\"
    send \"n\"
    expect \"Apply Launcher?\"
    send \"y\"
    expect \"Lite setup is complete\"
    expect eof
  "

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Keeping the current Git checkout"* ]]
  [ "$(git -C "${source_root}" rev-parse HEAD)" = "${old_head}" ]
  [ -L "${bin_root}/jsh" ]
}

@test "bin/jsh install is the canonical reconciliation command" {
  make_fixture lite
  run env \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_DIR="$(cd "${source_root}" && pwd -P)" \
    JSH_BIN_DIR="${bin_root}" \
    JSH_MODE=lite \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    JSH_NETWORK_CHECK=never \
    "${source_root}/bin/jsh" install --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Setup plan (lite)"* ]]
  [[ "${output}" == *"Git checkout"* ]]
  [[ "${output}" == *"Launcher"* ]]
  [ ! -e "${bin_root}/jsh" ]
  [ ! -e "${state_root}" ]
}

@test "install accepts the verbose option" {
  make_fixture lite
  run run_installer lite --dry-run -v

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Setup plan (lite)"* ]]
}

@test "verbose install exposes vendored asset failures" {
  make_fixture full
  cat >"${source_root}/vendor/fzf/install" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'fzf fixture failure' >&2
exit 23
EOF
  chmod +x "${source_root}/vendor/fzf/install"
  for submodule_path in vendor/fzf vendor/fzf-tab vendor/zsh-completions; do
    git -C "${source_root}/${submodule_path}" init -q
    git -C "${source_root}/${submodule_path}" config user.email test@example.invalid
    git -C "${source_root}/${submodule_path}" config user.name test
    git -C "${source_root}/${submodule_path}" config commit.gpgsign false
    git -C "${source_root}/${submodule_path}" add .
    git -C "${source_root}/${submodule_path}" commit -qm initial
  done

  run run_installer full --yes --verbose

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"fzf fixture failure"* ]]
  [[ "${output}" == *"Failed to initialize submodules and vendored assets"* ]]
}

@test "curl bootstrap acquires a checkout before delegating install" {
  make_fixture lite
  runner=${test_root}/runner.sh
  checkout_root=${home_root}/.jsh
  branch=$(git -C "${source_root}" symbolic-ref --short HEAD)
  cp "${project_root}/j.sh" "${runner}"

  run env \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_BIN_DIR="${bin_root}" \
    JSH_INSTALL_DIR="${checkout_root}" \
    JSH_INSTALL_REPO="${source_root}" \
    JSH_INSTALL_REF="${branch}" \
    JSH_MODE=lite \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    JSH_NETWORK_CHECK=never \
    "${runner}" --yes

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Setup plan (lite)"* ]]
  [ -d "${checkout_root}/.git" ]
  [ -L "${bin_root}/jsh" ]
}

@test "curl bootstrap dry-run does not create a checkout" {
  make_fixture lite
  runner=${test_root}/runner.sh
  checkout_root=${home_root}/.jsh
  branch=$(git -C "${source_root}" symbolic-ref --short HEAD)
  cp "${project_root}/j.sh" "${runner}"

  run env \
    HOME="${home_root}" \
    XDG_STATE_HOME="${state_root}" \
    JSH_INSTALL_DIR="${checkout_root}" \
    JSH_INSTALL_REPO="${source_root}" \
    JSH_INSTALL_REF="${branch}" \
    JSH_MODE=lite \
    JSH_PLAIN_OUTPUT=1 \
    JSH_COLOR=never \
    JSH_NETWORK_CHECK=never \
    "${runner}" --dry-run

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Setup plan (lite)"* ]]
  [[ "${output}" == *"Git checkout"* ]]
  [ ! -e "${checkout_root}" ]
  [ ! -e "${state_root}" ]
}
