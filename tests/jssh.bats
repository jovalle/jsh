#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  work=${BATS_TEST_TMPDIR}/jssh
  session=${work}/session
  mkdir -p "${work}/cache" "${session}" "${work}/home" "${work}/runtime"
  chmod 700 "${work}/cache"

  run env JSH_ROOT="${JSH_ROOT}" JSSH_CACHE_DIR="${work}/cache" bash -c '
    source "$JSH_ROOT/bin/jssh"
    _jssh_build_payload
  '
  [[ ${status} -eq 0 ]]
  tar -xf "${output##*$'\n'}" -C "${session}"
}

# Mirrors the environment _jssh_remote_launch_script exports on the remote host.
runtime_env() {
  env -i HOME="${work}/home" TERM=dumb PATH="${session}/jsh/bin:/usr/bin:/bin" \
    SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22' \
    JSH_ROOT="${session}/jsh" JSH_RUNTIME_DIR="${work}/runtime" \
    JSH_LOAD_CONFIG=0 JSH_LANG=C "$@"
}

@test "Zsh runtime starts from the payload without missing sources" {
  command -v zsh > /dev/null || skip 'zsh is unavailable'

  run runtime_env JSH_ZSH="$(command -v zsh)" ZDOTDIR="${session}/jsh/dotfiles" \
    zsh -d -i +m -c 'jsh_info probe; print RUNTIME_READY' < /dev/null

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'probe'*'RUNTIME_READY'* ]]
  [[ ${output} != *':%@@@@@@@@@#*#@%-'* ]]
  [[ ${output} != *'no such file'* && ${output} != *'command not found'* ]]
}

@test "Bash runtime starts from the payload without missing sources" {
  run runtime_env JSH_BASH="$(command -v bash)" JSH_BASH_RUNTIME=1 \
    bash --noprofile --rcfile "${session}/jsh/bin/jsh" -i +m \
    < <(printf '%s\n' 'jsh_info probe' 'echo RUNTIME_READY' exit)

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'probe'*'RUNTIME_READY'* ]]
  [[ ${output} != *':%@@@@@@@@@#*#@%-'* ]]
  [[ ${output} != *'No such file'* && ${output} != *'command not found'* ]]
}

@test "doctor scans managed symlinks inside the payload runtime" {
  local posix_sh=sh
  # Debian-family hosts run /bin/sh scripts with dash.
  command -v dash > /dev/null && posix_sh=dash
  run runtime_env "$(command -v "${posix_sh}")" "${session}/jsh/bin/jsh" doctor < /dev/null

  [[ ${output} == *'Installation'* ]]
  [[ ${output} != *'Managed symlinks could not be scanned'* ]]
  [[ ${output} != *'No such file'* && ${output} != *'not found'* ]]
}
