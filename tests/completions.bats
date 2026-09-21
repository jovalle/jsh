#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
  export JSH_COMPLETION_RUNTIME="${BATS_TEST_TMPDIR}/jsh-runtime"
  mkdir -p "${JSH_COMPLETION_RUNTIME}"
}

@test "registers completions for recurring commands" {
  run env JSH="${JSH_ROOT}" JSH_LOAD_CONFIG=0 JSH_RUNTIME_DIR="${JSH_COMPLETION_RUNTIME}" \
    zsh -f -c '
      source "$JSH/dotfiles/.zshrc" >/dev/null 2>&1

      for pair in j:_j jsh:_jsh jgit:_jsh make:_make just:_just; do
        name=${pair%%:*}
        expected=${pair#*:}
        [[ ${_comps[$name]-} == $expected ]] || {
          print -u2 -- "$name: expected $expected, got ${_comps[$name]-missing}"
          exit 1
        }
      done

      for name in cd git ls curl cat cp dpkg open vim; do
        [[ -n ${_comps[$name]-} ]] || {
          print -u2 -- "$name: missing completion"
          exit 1
        }
      done

      [[ ${_comps[-default-]-} == _jsh_fallback ]]

      [[ ${aliases[l]-} == ls ]]
      [[ ${aliases[vi]-} == nvim || ${aliases[vi]-} == vim ]]
      [[ ${aliases[gl]-} == git\ log* ]]
      [[ ${aliases[glg]-} == git\ log* ]]
      [[ ! -o COMPLETE_ALIASES ]]
    '

  [[ ${status} -eq 0 ]]
}

@test "parses help only for unresolved command options" {
  run env JSH="${JSH_ROOT}" JSH_LOAD_CONFIG=0 JSH_RUNTIME_DIR="${JSH_COMPLETION_RUNTIME}" \
    zsh -f -c '
      source "$JSH/dotfiles/.zshrc" >/dev/null 2>&1

      _gnu_generic() { print -r -- generic; return ${generic_status:-0}; }
      _default() { print -r -- default; }

      words=(sh --version)
      PREFIX=--version
      _jsh_fallback

      words=(sh filename)
      PREFIX=filename
      _jsh_fallback

      words=(missing-command --version)
      PREFIX=--version
      _jsh_fallback

      generic_status=1
      words=(sh --unknown)
      PREFIX=--unknown
      _jsh_fallback
    '

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'generic\ndefault\ndefault\ngeneric\ndefault' ]]
}

@test "completes j controls and tracked directories" {
  local project_dir="${BATS_TEST_TMPDIR}/alpha-project"
  local database="${BATS_TEST_TMPDIR}/j.db"
  local now
  mkdir -p "${project_dir}"
  now=$(($(date +%s) / 3600))
  printf '%s|5|%s\n' "${project_dir}" "${now}" > "${database}"

  run env JSH="${JSH_ROOT}" J_DATA="${database}" J_PATHS="${BATS_TEST_TMPDIR}/missing" \
    zsh -f -c '
      _j_ui_message() { :; }
      source "$JSH/lib/zsh/j.zsh"
      fpath=("$JSH/dotfiles/.zsh/completions" $fpath)
      autoload -Uz _j
      _arguments() { state=directories; }
      _describe() {
        local array_name=$2
        print -l -- "${(@P)array_name}"
      }
      words=(j "")
      CURRENT=2
      _j
    '

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'-:previous directory'* ]]
  [[ ${output} == *'.:current directory'* ]]
  [[ ${output} == *'fetch:run jfetch'* ]]
  [[ ${output} == *"alpha-project:${project_dir}"* ]]
}
