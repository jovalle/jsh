#!/usr/bin/env bats

setup() {
  ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd -P)
  TEST_HOME="${BATS_TEST_TMPDIR}/home"
  RUNTIME_CONFIG="${BATS_TEST_TMPDIR}/runtime"
  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  LOCAL_DIR="${BATS_TEST_TMPDIR}/local"
  mkdir -p "${TEST_HOME}"
  cat >"${TEST_HOME}/.gitconfig.local" <<'EOF'
[user]
    name = Runtime Test
    email = runtime@example.invalid
EOF
}

run_runtime() {
  run env -u GIT_CONFIG_GLOBAL -u RIPGREP_CONFIG_PATH -u INPUTRC -u VIMINIT \
    HOME="${TEST_HOME}" JSH_RUNTIME_CONFIG_DIR="${RUNTIME_CONFIG}" \
    GIT_CEILING_DIRECTORIES="${ROOT}/tmp" \
    JSH_BREW_SKIP_SETUP=1 JSH_FEATURE_ATUIN=0 JSH_FEATURE_DIRENV=0 \
    JSH_FEATURE_FNM=0 JSH_FEATURE_ZOXIDE=0 \
    "${ROOT}/bin/jsh" -c "$1"
}

create_fake_commands() {
  mkdir -p "${FAKE_BIN}"
  cat >"${FAKE_BIN}/nvim" <<'EOF'
#!/bin/sh
printf '%s\n%s\n%s\n%s\n' "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
EOF
  cat >"${FAKE_BIN}/tmux" <<'EOF'
#!/bin/sh
printf 'tmux'
for argument do
  printf '|%s' "$argument"
done
printf '\n'
EOF
  cat >"${FAKE_BIN}/shellcheck" <<'EOF'
#!/bin/sh
printf 'shellcheck|XDG_CONFIG_HOME=%s' "${XDG_CONFIG_HOME:-}"
for argument do
  printf '|%s' "$argument"
done
printf '\n'
EOF
  chmod +x "${FAKE_BIN}/nvim" "${FAKE_BIN}/tmux" "${FAKE_BIN}/shellcheck"
}

create_tmux_probe() {
  TMUX_PROBE="${BATS_TEST_TMPDIR}/tmux-probe.sh"
  cat >"${TMUX_PROBE}" <<'EOF'
source "${JSH_DIR}/dotfiles/.config/shell/runtime.sh"
tmux attach -f read-only
tmux -L probe -f custom.conf attach
JSH_TMUX_CONFIG="${WORK}/custom-tmux.conf"
tmux ls
JSH_TMUX_CONFIG=
tmux ls
EOF
}

run_tmux_probe() {
  local shell_name="$1"
  run env PATH="${FAKE_BIN}:/usr/bin:/bin" JSH_DIR="${ROOT}" \
    WORK="${BATS_TEST_TMPDIR}" HOME="${TEST_HOME}" \
    JSH_RUNTIME_CONFIG_DIR="${RUNTIME_CONFIG}" \
    "${shell_name}" "${TMUX_PROBE}"
}

@test "runtime exports managed native config paths" {
  run_runtime \
    'printf "%s\n%s\n%s\n%s\n" "$RIPGREP_CONFIG_PATH" "$INPUTRC" "$VIMINIT" "$GIT_CONFIG_GLOBAL"'

  expected=$(printf '%s\n%s\n%s\n%s' \
    "${ROOT}/dotfiles/.ripgreprc" \
    "${ROOT}/dotfiles/.inputrc" \
    'execute "source " . fnameescape($JSH_DIR . "/dotfiles/.vimrc")' \
    "${RUNTIME_CONFIG}/gitconfig")
  [[ ${status} -eq 0 ]]
  [[ ${output} == "${expected}" ]]
}

@test "Git global writes use the runtime overlay" {
  managed_before=$(cksum "${ROOT}/dotfiles/.gitconfig")

  run_runtime \
    'printf "%s|%s\n" "$(git config --get color.status.changed)" "$(git -C "$HOME" config --get user.email)"; git config --global runtime.probe value; git config --file "$GIT_CONFIG_GLOBAL" --get runtime.probe'

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'yellow|runtime@example.invalid\nvalue' ]]
  [[ $(cksum "${ROOT}/dotfiles/.gitconfig") == "${managed_before}" ]]
  [[ $(git config --file "${RUNTIME_CONFIG}/gitconfig" --get include.path) == "${ROOT}/dotfiles/.gitconfig" ]]
}

@test "runtime preserves caller config overrides" {
  custom_git="${BATS_TEST_TMPDIR}/custom.gitconfig"

  run env HOME="${TEST_HOME}" JSH_RUNTIME_CONFIG_DIR="${RUNTIME_CONFIG}" \
    GIT_CONFIG_GLOBAL="${custom_git}" RIPGREP_CONFIG_PATH= \
    INPUTRC=/custom/inputrc VIMINIT='set number' \
    JSH_BREW_SKIP_SETUP=1 JSH_FEATURE_ATUIN=0 JSH_FEATURE_DIRENV=0 \
    JSH_FEATURE_FNM=0 JSH_FEATURE_ZOXIDE=0 \
    "${ROOT}/bin/jsh" -c \
    'printf "%s\n%s\n%s\n%s\n" "$RIPGREP_CONFIG_PATH" "$INPUTRC" "$VIMINIT" "$GIT_CONFIG_GLOBAL"'

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'\n/custom/inputrc\nset number\n'"${custom_git}" ]]
}

@test "Neovim keeps managed config separate from mutable data" {
  create_fake_commands

  run env JSH_DIR="${ROOT}" JSH_LOCAL_DIR="${LOCAL_DIR}" \
    PATH="${ROOT}/bin:${FAKE_BIN}:/usr/bin:/bin" "${ROOT}/bin/nvim"

  expected=$(printf '%s\n%s\n%s\n%s' \
    "${ROOT}/dotfiles/.config" "${LOCAL_DIR}/share" \
    "${LOCAL_DIR}/cache" "${LOCAL_DIR}/state")
  [[ ${status} -eq 0 ]]
  [[ ${output} == "${expected}" ]]
}

@test "Neovim preserves its config override" {
  create_fake_commands

  run env JSH_DIR="${ROOT}" JSH_LOCAL_DIR="${LOCAL_DIR}" \
    JSH_NVIM_CONFIG_HOME="${BATS_TEST_TMPDIR}/custom-nvim" \
    PATH="${ROOT}/bin:${FAKE_BIN}:/usr/bin:/bin" "${ROOT}/bin/nvim"

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} == "${BATS_TEST_TMPDIR}/custom-nvim" ]]
}

@test "Bash tmux wrapper injects only the selected config" {
  create_fake_commands
  create_tmux_probe

  run_tmux_probe bash

  expected=$(printf '%s\n%s\n%s\n%s' \
    "tmux|-f|${ROOT}/dotfiles/.tmux.conf|attach|-f|read-only" \
    'tmux|-L|probe|-f|custom.conf|attach' \
    "tmux|-f|${BATS_TEST_TMPDIR}/custom-tmux.conf|ls" \
    'tmux|ls')
  [[ ${status} -eq 0 ]]
  [[ ${output} == "${expected}" ]]
}

@test "Zsh tmux wrapper injects only the selected config" {
  command -v zsh >/dev/null 2>&1 || skip 'zsh not available'
  create_fake_commands
  create_tmux_probe

  run_tmux_probe zsh

  expected=$(printf '%s\n%s\n%s\n%s' \
    "tmux|-f|${ROOT}/dotfiles/.tmux.conf|attach|-f|read-only" \
    'tmux|-L|probe|-f|custom.conf|attach' \
    "tmux|-f|${BATS_TEST_TMPDIR}/custom-tmux.conf|ls" \
    'tmux|ls')
  [[ ${status} -eq 0 ]]
  [[ ${output} == "${expected}" ]]
}

@test "ShellCheck wrapper respects explicit config options" {
  create_fake_commands
  probe="${BATS_TEST_TMPDIR}/shellcheck-probe.sh"
  cat >"${probe}" <<'EOF'
source "${JSH_DIR}/dotfiles/.config/shell/runtime.sh"
shellcheck sample.sh
shellcheck --norc sample.sh
shellcheck --rcfile custom.rc sample.sh
EOF

  run env PATH="${FAKE_BIN}:/usr/bin:/bin" JSH_DIR="${ROOT}" \
    HOME="${TEST_HOME}" JSH_RUNTIME_CONFIG_DIR="${RUNTIME_CONFIG}" \
    XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/user-xdg" bash "${probe}"

  expected=$(printf '%s\n%s\n%s' \
    "shellcheck|XDG_CONFIG_HOME=${RUNTIME_CONFIG}|sample.sh" \
    "shellcheck|XDG_CONFIG_HOME=${BATS_TEST_TMPDIR}/user-xdg|--norc|sample.sh" \
    "shellcheck|XDG_CONFIG_HOME=${BATS_TEST_TMPDIR}/user-xdg|--rcfile|custom.rc|sample.sh")
  [[ ${status} -eq 0 ]]
  [[ ${output} == "${expected}" ]]
}

@test "ShellCheck wrapper preserves an existing user config" {
  create_fake_commands
  user_config="${BATS_TEST_TMPDIR}/user-xdg"
  mkdir -p "${user_config}"
  printf 'shell=bash\n' >"${user_config}/shellcheckrc"
  probe="${BATS_TEST_TMPDIR}/user-config-probe.sh"
  cat >"${probe}" <<'EOF'
source "${JSH_DIR}/dotfiles/.config/shell/runtime.sh"
shellcheck sample.sh
EOF

  run env PATH="${FAKE_BIN}:/usr/bin:/bin" JSH_DIR="${ROOT}" \
    HOME="${TEST_HOME}" JSH_RUNTIME_CONFIG_DIR="${RUNTIME_CONFIG}" \
    XDG_CONFIG_HOME="${user_config}" bash "${probe}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == "shellcheck|XDG_CONFIG_HOME=${user_config}|sample.sh" ]]
}

@test "runtime creates no native config files in HOME" {
  run_runtime ':'
  [[ ${status} -eq 0 ]]

  for config_path in .gitconfig .ripgreprc .inputrc .vimrc .tmux.conf .shellcheckrc; do
    [[ ! -e ${TEST_HOME}/${config_path} ]]
  done
}
