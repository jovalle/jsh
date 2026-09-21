#!/usr/bin/env bats

: "${BATS_TEST_DIRNAME:=.}"
: "${BATS_TEST_TMPDIR:=${TMPDIR:-./tmp}}"

setup() {
  export JSH_ROOT
  JSH_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd -P)
}

run_in_pty() {
  python3 - "$1" <<'PY'
import errno
import os
import pty
import select
import signal
import subprocess
import sys
import time

command = sys.argv[1]
timeout = float(os.environ.get("JSH_TEST_PTY_TIMEOUT", "10"))
master, slave = pty.openpty()
process = subprocess.Popen(
  ["/bin/sh", "-c", command],
  stdin=slave,
  stdout=slave,
  stderr=slave,
  start_new_session=True,
)
os.close(slave)
deadline = time.monotonic() + timeout
timed_out = False

while process.poll() is None:
  remaining = deadline - time.monotonic()
  if remaining <= 0:
    timed_out = True
    os.killpg(process.pid, signal.SIGTERM)
    try:
      process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
      os.killpg(process.pid, signal.SIGKILL)
    break
  readable, _, _ = select.select([master], [], [], min(0.1, remaining))
  if readable:
    try:
      os.write(sys.stdout.fileno(), os.read(master, 4096))
    except OSError as error:
      if error.errno != errno.EIO:
        raise
      break

while select.select([master], [], [], 0)[0]:
  try:
    data = os.read(master, 4096)
  except OSError as error:
    if error.errno == errno.EIO:
      break
    raise
  if not data:
    break
  os.write(sys.stdout.fileno(), data)
os.close(master)

if timed_out:
  print(f"PTY command timed out after {timeout:g}s", file=sys.stderr)
  sys.exit(124)
sys.exit(process.wait())
PY
}

parse_bootstrap_command() {
  env JSH_DIR="${BATS_TEST_TMPDIR}/missing" bash -c '
    root=$1
    shift
    parser=$(sed "/^declare -F jsh_env_detect/,$ d" "$root/j.sh")
    eval "$parser"
    printf "%s|%s\n" "$mode" "${install_profile:-none}"
  ' _ "${JSH_ROOT}" "$@"
}

@test "non-interactive mode always selects the plain backend" {
  run env JSH_NON_INTERACTIVE=1 JSH_INTERACTIVE=1 JSH_REMOTE=0 \
    JSH_UI_BACKEND=auto bash -c '
      source "$1/lib/env.sh"
      printf "%s|%s|%s\n" "$JSH_TIER" "$JSH_UI_BACKEND" "$JSH_INTERACTIVE"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == '0|plain|0' ]]
}

@test "package-managed Gum supersedes the private bootstrap copy" {
  local bin_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin_dir}"
  printf '#!/bin/sh\nexit 0\n' > "${bin_dir}/gum"
  chmod +x "${bin_dir}/gum"

  run env PATH="${bin_dir}:${PATH}" JSH_GUM_VERSION= JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=auto \
    JSH_DATA_HOME="${BATS_TEST_TMPDIR}/data" \
    JSH_GUM="${BATS_TEST_TMPDIR}/data/tools/gum/1.0.0/darwin-arm64/gum" \
    JSH_UNAME=Darwin JSH_MACHINE=arm64 bash -c '
      source "$1/lib/env.sh"
      printf "%s|%s\n" "$JSH_GUM" "$JSH_UI_BACKEND"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == "${bin_dir}/gum|gum" ]]
}

@test "Gum version override selects the private bootstrap copy" {
  local bin_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin_dir}"
  printf '#!/bin/sh\nexit 0\n' > "${bin_dir}/gum"
  chmod +x "${bin_dir}/gum"

  run env PATH="${bin_dir}:${PATH}" JSH_GUM= JSH_GUM_VERSION=v1.9.0 \
    JSH_DATA_HOME="${BATS_TEST_TMPDIR}/data" JSH_UNAME=Linux JSH_MACHINE=x86_64 \
    bash -c '
      source "$1/lib/env.sh"
      printf "%s\n" "$JSH_GUM"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == "${BATS_TEST_TMPDIR}/data/tools/gum/1.9.0/linux-amd64/gum" ]]
}

@test "bootstrap accepts the short non-interactive flag" {
  run "${JSH_ROOT}/j.sh" -y --help

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Usage: j.sh [-y|--yes]'* ]]
  [[ ${output} == *'runtime|install|setup|update'* ]]
}

@test "assume yes never widens the selected command" {
  run parse_bootstrap_command --yes
  [[ ${status} -eq 0 ]]
  [[ ${output} == 'runtime|none' ]]

  run parse_bootstrap_command --yes install
  [[ ${status} -eq 0 ]]
  [[ ${output} == 'install|slim' ]]

  run parse_bootstrap_command --yes setup
  [[ ${status} -eq 0 ]]
  [[ ${output} == 'setup|full' ]]
}

@test "launcher shows help instead of nesting inside an active Jsh shell" {
  run env JSH="${JSH_ROOT}" JSH_ZSH=missing-zsh "${JSH_ROOT}/bin/jsh"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'jsh [zsh-options]'* ]]

  run env JSH="${JSH_ROOT}" JSH_ZSH=missing-zsh "${JSH_ROOT}/bin/jsh" runtime

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'jsh [zsh-options]'* ]]
}

@test "Bash runtime shows command help for bare jsh invocation" {
  run bash -c '
    export JSH_BASH_RUNTIME=1 JSH_ROOT="$1" JSH_RUNTIME_DIR="$2" JSH_BASH="$BASH"
    source "$JSH_ROOT/bin/jsh"
    jsh
  ' _ "${JSH_ROOT}" "${BATS_TEST_TMPDIR}/runtime"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'jsh [zsh-options]'* ]]
}

@test "launcher help colors headings and commands unless NO_COLOR is set" {
  run env JSH_COLOR=always "${JSH_ROOT}/bin/jsh" --help

  [[ ${status} -eq 0 ]]
  [[ ${output} == *$'\033[1;36m   :%@@@@@@@@@#*#@%-'* ]]
  [[ ${output} == *$'\033[36mUsage\033[0m'* ]]
  [[ ${output} == *$'\033[32mruntime\033[0m'* ]]

  run env JSH_COLOR=always NO_COLOR= "${JSH_ROOT}/bin/jsh" --help

  [[ ${status} -eq 0 ]]
  [[ ${output} != *$'\033'* ]]
  [[ ${output} == *'jsh [OPTIONS] COMMAND [ARGUMENTS...]'* ]]
}

@test "isolated runtimes show the graffiti banner once on fresh startup" {
  local banner_marker=':%@@@@@@@@@#*#@%-' banner_tail

  run env JSH_BASH_RUNTIME=1 JSH_ROOT="${JSH_ROOT}" \
    JSH_RUNTIME_DIR="${BATS_TEST_TMPDIR}/bash-runtime" JSH_BASH="${BASH}" \
    JSH_COLOR=never bash -c 'source "$JSH_ROOT/bin/jsh"'

  [[ ${status} -eq 0 ]]
  [[ ${output} == *':%@@@@@@@@@#*#@%-'* ]]

  run env HOME="${BATS_TEST_TMPDIR}" JSH_LOAD_CONFIG=0 \
    JSH_RUNTIME_DIR="${BATS_TEST_TMPDIR}/zsh-runtime" JSH_COLOR=never \
    zsh -d -c 'source "$1/dotfiles/.zshrc"; jsh -r' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *"${banner_marker}"* ]]
  banner_tail=${output#*"${banner_marker}"}
  [[ ${banner_tail} != *"${banner_marker}"* ]]
}

@test "reloads and ordinary Zsh startup omit the graffiti banner" {
  run env JSH_BASH_RUNTIME=1 JSH_RELOADING=1 JSH_ROOT="${JSH_ROOT}" \
    JSH_RUNTIME_DIR="${BATS_TEST_TMPDIR}/bash-runtime" JSH_BASH="${BASH}" \
    JSH_COLOR=never bash -c 'source "$JSH_ROOT/bin/jsh"'

  [[ ${status} -eq 0 ]]
  [[ ${output} != *':%@@@@@@@@@#*#@%-'* ]]

  run env HOME="${BATS_TEST_TMPDIR}" JSH_LOAD_CONFIG=0 JSH_RELOADING=1 \
    JSH_RUNTIME_DIR="${BATS_TEST_TMPDIR}/zsh-runtime" JSH_COLOR=never \
    zsh -d -c 'source "$1/dotfiles/.zshrc"' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} != *':%@@@@@@@@@#*#@%-'* ]]

  run env HOME="${BATS_TEST_TMPDIR}" JSH_LOAD_CONFIG=0 JSH_COLOR=never \
    zsh -d -c 'source "$1/dotfiles/.zshrc"' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} != *':%@@@@@@@@@#*#@%-'* ]]
}

@test "launcher dispatches setup and rejects removed install profiles" {
  run "${JSH_ROOT}/bin/jsh" setup --help

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Run with setup to install and configure'* ]]

  run "${JSH_ROOT}/j.sh" install slim

  [[ ${status} -eq 2 ]]
  [[ ${output} == *'Unknown argument: slim'* ]]
}

@test "launcher enters the Bash runtime when Zsh is unavailable" {
  local bash_wrapper="${BATS_TEST_TMPDIR}/bash-wrapper" calls="${BATS_TEST_TMPDIR}/bash-calls"
  cat > "${bash_wrapper}" << 'EOF'
#!/bin/sh
if [ "${1:-}" = -c ]; then
  exec "${REAL_BASH}" "$@"
fi
printf 'runtime=%s args=%s\n' "${JSH_BASH_RUNTIME:-0}" "$*" > "${BASH_CALLS}"
EOF
  chmod +x "${bash_wrapper}"

  run env JSH= JSH_ZSH=missing-zsh JSH_BASH="${bash_wrapper}" REAL_BASH="${BASH}" \
    BASH_CALLS="${calls}" JSH_SKIP_HEALTH_CHECK=1 "${JSH_ROOT}/bin/jsh"

  [[ ${status} -eq 0 ]]
  grep -Fq "runtime=1 args=--noprofile --rcfile ${JSH_ROOT}/bin/jsh -i" "${calls}"
}

@test "launcher spins through startup stages and clears before the shell" {
  local tool_dir="${BATS_TEST_TMPDIR}/healthy-tools"
  local clear_screen=$'\033[2J\033[H' launch_command
  mkdir -p "${tool_dir}"
  printf '#!/bin/sh\nexit 0\n' > "${tool_dir}/git"
  printf '#!/bin/sh\nprintf "test-version\\n"\n' > "${tool_dir}/fzf"
  printf '#!/bin/sh\nprintf "SHELL_STARTED\\n"\n' > "${tool_dir}/zsh"
  chmod +x "${tool_dir}/git" "${tool_dir}/fzf" "${tool_dir}/zsh"
  printf -v launch_command \
    'env JSH= PATH=%q TERM=xterm JSH_ZSH=%q JSH_COLOR=never %q' \
    "${tool_dir}:/usr/bin:/bin" "${tool_dir}/zsh" "${JSH_ROOT}/bin/jsh"

  run run_in_pty "${launch_command}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Checking required tools'* ]]
  [[ ${output} == *'Checking bundled plugins'* ]]
  [[ ${output} == *'Checking fzf runtime'* ]]
  [[ ${output} == *'Checking pinned revisions'* ]]
  [[ ${output} == *"${clear_screen}"*'SHELL_STARTED'* ]]
  [[ ${output} != *'✓ Git:'* ]]
}

@test "launcher keeps startup failures visible without clearing the screen" {
  local tool_dir="${BATS_TEST_TMPDIR}/failing-tools"
  local clear_screen=$'\033[2J\033[H' launch_command
  mkdir -p "${tool_dir}"
  printf '#!/bin/sh\nprintf "test-version\\n"\n' > "${tool_dir}/fzf"
  printf '#!/bin/sh\nprintf "SHELL_STARTED\\n"\n' > "${tool_dir}/zsh"
  ln -s /bin/sleep "${tool_dir}/sleep"
  chmod +x "${tool_dir}/fzf" "${tool_dir}/zsh"
  printf -v launch_command \
    '/usr/bin/env JSH= PATH=%q TERM=xterm JSH_ZSH=%q JSH_COLOR=never %q </dev/null' \
    "${tool_dir}" "${tool_dir}/zsh" "${JSH_ROOT}/bin/jsh"

  run run_in_pty "${launch_command}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == *'Checking required tools'* ]]
  [[ ${output} == *'✗ Git is unavailable.'* ]]
  [[ ${output} == *'✗ Jsh needs attention.'* ]]
  [[ ${output} == *'Run `jsh repair` to fix startup dependencies'* ]]
  [[ ${output} == *'SHELL_STARTED'* ]]
  [[ ${output} != *"${clear_screen}"* ]]
}

@test "PTY launcher tests terminate stuck process groups" {
  JSH_TEST_PTY_TIMEOUT=0.1 run run_in_pty 'sleep 30'

  [[ ${status} -eq 124 ]]
  [[ ${output} == *'PTY command timed out after 0.1s'* ]]
}

@test "remote interactive sessions are capped at the shell backend" {
  local gum="${BATS_TEST_TMPDIR}/gum"
  printf '#!/bin/sh\nexit 0\n' > "${gum}"
  chmod +x "${gum}"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=1 JSH_UI_BACKEND=auto JSH_GUM="${gum}" \
    bash -c '
      source "$1/lib/env.sh"
      printf "%s|%s\n" "$JSH_TIER" "$JSH_UI_BACKEND"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == '1|shell' ]]
}

@test "child processes discard inherited internal UI policy" {
  run env JSH_INTERACTIVE_OVERRIDE=0 JSH_UI_BACKEND_REQUEST=plain \
    JSH_INTERACTIVE=1 JSH_REMOTE=1 JSH_UI_BACKEND=auto bash -c '
      source "$1/lib/env.sh"
      printf "%s|%s\n" "$JSH_TIER" "$JSH_UI_BACKEND"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == '1|shell' ]]
}

@test "local interactive sessions select a valid Gum backend" {
  local gum="${BATS_TEST_TMPDIR}/gum"
  printf '#!/bin/sh\nexit 0\n' > "${gum}"
  chmod +x "${gum}"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=auto JSH_GUM="${gum}" \
    bash -c '
      source "$1/lib/env.sh"
      printf "%s|%s|%s-%s\n" "$JSH_TIER" "$JSH_UI_BACKEND" "$JSH_PLATFORM" "$JSH_ARCH"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == 2\|gum\|*-* ]]
}

@test "auto backend promotes after Gum becomes available" {
  local gum="${BATS_TEST_TMPDIR}/promoted-gum"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=auto JSH_GUM="${gum}" \
    bash -c '
      source "$1/lib/env.sh"
      [[ $JSH_UI_BACKEND == shell ]]
      printf "#!/bin/sh\\nexit 0\\n" > "$JSH_GUM"
      chmod +x "$JSH_GUM"
      jsh_env_detect
      printf "%s|%s\n" "$JSH_TIER" "$JSH_UI_BACKEND"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == '2|gum' ]]
}

@test "plain facade returns clean values without blocking" {
  local prompt_log="${BATS_TEST_TMPDIR}/plain-prompts.err"

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    jsh::confirm "Continue?" --default no && exit 9
    value=$(jsh::input "Name" --default jay 2>"$2")
    printf "%s\n" "$value"
  ' _ "${JSH_ROOT}" "${prompt_log}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == jay ]]
}

@test "CLI bridge preserves non-interactive confirmation exit codes" {
  run env JSH_NON_INTERACTIVE=1 "${JSH_ROOT}/lib/ui/cli.sh" confirm --default yes -- "Continue?"
  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]

  run env JSH_NON_INTERACTIVE=1 "${JSH_ROOT}/lib/ui/cli.sh" confirm --default no -- "Continue?"
  [[ ${status} -eq 1 ]]
  [[ -z ${output} ]]

  run env JSH_NON_INTERACTIVE=1 "${JSH_ROOT}/lib/ui/cli.sh" confirm "Continue?"
  [[ ${status} -eq 2 ]]
}

@test "CLI bridge exposes semantic presentation primitives" {
  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/lib/ui/cli.sh" status success -- "Removed Vimium"
  [[ ${status} -eq 0 ]]
  [[ ${output} == '✓ Removed Vimium' ]]

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/lib/ui/cli.sh" title -- "Waterfix"
  [[ ${status} -eq 0 ]]
  [[ ${output} == $'\n=== Waterfix ===' ]]

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain JSH_PLAIN_OUTPUT=1 \
    "${JSH_ROOT}/lib/ui/cli.sh" section -- "Bookmark changes"
  [[ ${status} -eq 0 ]]
  [[ ${output} == $'\nBookmark changes' ]]
}

@test "UI initialization routes prompts through explicit descriptors" {
  local prompt_log="${BATS_TEST_TMPDIR}/fd-prompts.err"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    exec 3<<<y
    exec 4>"$2"
    jsh::init --input-fd 3 --output-fd 4
    jsh::confirm "Continue?" --default no
  ' _ "${JSH_ROOT}" "${prompt_log}"

  [[ ${status} -eq 0 ]]
  [[ -z ${output} ]]
  grep -Fqx 'Continue? [y/N]: ' "${prompt_log}"
}

@test "sections preserve plain output without terminal decoration" {
  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    jsh::section "2/3" "Packages" "Install selected packages."
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'\n[2/3] Packages\nInstall selected packages.' ]]
}

@test "Gum facade applies the NYC palette and preserves stdout values" {
  local gum="${BATS_TEST_TMPDIR}/gum" calls="${BATS_TEST_TMPDIR}/gum-calls"
  cat > "${gum}" << 'EOF'
#!/bin/sh
test "${GUM_CONFIRM_PROMPT_FOREGROUND}" = '#F5F5F5' || exit 91
test "${GUM_CONFIRM_SELECTED_BACKGROUND}" = '#0099AA' || exit 91
test "${GUM_CHOOSE_CURSOR_FOREGROUND}" = '#0099AA' || exit 91
test "${GUM_CHOOSE_HEADER_FOREGROUND}" = '#F5F5F5' || exit 91
test "${GUM_CHOOSE_ITEM_FOREGROUND}" = '#A7A9AC' || exit 91
test "${GUM_INPUT_PROMPT_FOREGROUND}" = '#0099AA' || exit 91
test "${GUM_INPUT_CURSOR_FOREGROUND}" = '#0099AA' || exit 91
test "${GUM_SPIN_SPINNER_FOREGROUND}" = '#0099AA' || exit 91
printf '%s\n' "$*" >> "${GUM_CALLS}"
case $1 in
  choose) printf '%s\n' beta ;;
  input) printf '%s\n' jay ;;
  confirm) exit 0 ;;
  style) shift; printf '%s\n' "$*" ;;
  spin)
    while [ "$1" != -- ]; do shift; done
    shift
    "$@"
    ;;
esac
EOF
  chmod +x "${gum}"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=gum JSH_GUM="${gum}" \
    GUM_CALLS="${calls}" bash -c '
      source "$1/lib/output.sh"
      source "$1/lib/env.sh"
      source "$1/lib/ui.sh"
      choice=$(jsh::choose "Pick" alpha beta)
      [[ $choice == beta ]]
      jsh::confirm "Continue?" --default yes
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  grep -Fqx 'choose --header     Pick -- alpha beta' "${calls}"
  grep -Fqx 'confirm --default=true Continue?' "${calls}"
}

@test "Zsh Git helpers confirm through the shared UI" {
  local gum="${BATS_TEST_TMPDIR}/gum" calls="${BATS_TEST_TMPDIR}/git-confirm-calls"
  local script="${BATS_TEST_TMPDIR}/git-confirm.zsh"
  cat > "${gum}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${GUM_CALLS}"
exit 1
EOF
  chmod +x "${gum}"

  cat > "${script}" <<'EOF'
source "${JSH_ROOT}/dotfiles/.zshrc" >/dev/null
_git_confirm "Push main?"
EOF
  export GUM_CALLS="${calls}" JSH_GUM="${gum}" JSH_TEST_SCRIPT="${script}"
  run run_in_pty 'env HOME="$BATS_TEST_TMPDIR" JSH_LOAD_CONFIG=0 JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=gum zsh -f "$JSH_TEST_SCRIPT"'

  [[ ${status} -eq 1 ]]
  [[ ${output} == *'Cancelled'* ]]
  grep -Fqx 'confirm --default=false Push main?' "${calls}"
}

@test "Zsh Git helpers preserve piped confirmation input" {
  run env HOME="${BATS_TEST_TMPDIR}" JSH_LOAD_CONFIG=0 zsh -f -c '
    source "$1/dotfiles/.zshrc" >/dev/null
    printf "yes\n" | _git_confirm "Push main?"
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == 'Push main? [y/N] ' ]]
}

@test "Zsh convenience selectors use the shared chooser" {
  local commands="${BATS_TEST_TMPDIR}/commands"
  mkdir -p "${commands}"
  cat > "${commands}/aws" <<'EOF'
#!/bin/sh
test "$1 $2" = 'configure list-profiles' || exit 1
printf '%s\n' personal work
EOF
  chmod +x "${commands}/aws"

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${commands}:${PATH}" JSH_LOAD_CONFIG=0 \
    zsh -f -c '
      source "$1/dotfiles/.zshrc" >/dev/null
      aws() { printf "%s\n" personal work; }
      jsh::choose() {
        [[ $1 == "AWS profile" && $2 == personal && $3 == work ]] || return 2
        print -r -- work
      }
      awsp
      print -r -- "$AWS_PROFILE"
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == work ]]
}

@test "open uses leaf for Markdown targets" {
  local commands="${BATS_TEST_TMPDIR}/commands" calls="${BATS_TEST_TMPDIR}/open-calls"
  mkdir -p "${commands}"
  for command in leaf xdg-open; do
    cat > "${commands}/${command}" <<'EOF'
#!/bin/sh
printf '%s:%s\n' "${0##*/}" "$*" >> "${OPEN_CALLS}"
EOF
    chmod +x "${commands}/${command}"
  done

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${commands}:${PATH}" JSH_LOAD_CONFIG=0 \
    OPEN_CALLS="${calls}" zsh -f -c '
      source "$1/dotfiles/.zshrc" >/dev/null
      path=("$3" $path)
      rehash
      JSH_OS=linux
      open "$2/guide.MD" "$2/notes.txt"
    ' _ "${JSH_ROOT}" "${BATS_TEST_TMPDIR}" "${commands}"

  [[ ${status} -eq 0 ]]
  [[ $(cat "${calls}") == $'leaf:'"${BATS_TEST_TMPDIR}"$'/guide.MD\nxdg-open:'"${BATS_TEST_TMPDIR}"'/notes.txt' ]]
}

@test "Zsh reload replaces the legacy AWS profile alias" {
  local commands="${BATS_TEST_TMPDIR}/commands"
  mkdir -p "${commands}"
  printf '#!/bin/sh\nexit 0\n' > "${commands}/aws"
  chmod +x "${commands}/aws"

  run env HOME="${BATS_TEST_TMPDIR}" PATH="${commands}:${PATH}" JSH_LOAD_CONFIG=0 zsh -f -c '
    alias awsp="echo legacy"
    source "$1/dotfiles/.zshrc" >/dev/null
    [[ $+functions[awsp] -eq 1 && $+aliases[awsp] -eq 0 ]]
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}

@test "plain selectors return stable IDs instead of labels" {
  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    exec 3<<<2
    jsh::init --input-fd 3 --output-fd 2
    jsh::choose_one "Profile" personal "Personal profile" work "Work profile" 2>"$2"
  ' _ "${JSH_ROOT}" "${BATS_TEST_TMPDIR}/choose-one.err"

  [[ ${status} -eq 0 ]]
  [[ ${output} == work ]]
  [[ $(head -n 1 "${BATS_TEST_TMPDIR}/choose-one.err") == '     Profile' ]]
}

@test "plain selector headers track numbered option width" {
  local menu="${BATS_TEST_TMPDIR}/numbered-menu.err"
  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    exec 3<<<10
    jsh::init --input-fd 3 --output-fd 2
    jsh::choose "Profile" one two three four five six seven eight nine ten 2>"$2"
  ' _ "${JSH_ROOT}" "${menu}"

  [[ ${status} -eq 0 ]]
  [[ ${output} == ten ]]
  [[ $(sed -n '1p' "${menu}") == '      Profile' ]]
  [[ $(sed -n '2p' "${menu}") == '   1) one' ]]
  [[ $(sed -n '11p' "${menu}") == '  10) ten' ]]
}

@test "plain multi-selector returns unique IDs" {
  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    exec 3<<<"1,3,1"
    jsh::init --input-fd 3 --output-fd 2
    jsh::choose_many "Add-ons" one "First" two "Second" three "Third" 2>"$2"
  ' _ "${JSH_ROOT}" "${BATS_TEST_TMPDIR}/choose-many.err"

  [[ ${status} -eq 0 ]]
  [[ ${output} == $'one\nthree' ]]
}

@test "shell spinner preserves failure status and diagnostics" {
  local failure_log="${BATS_TEST_TMPDIR}/spin.err"

  run env JSH_INTERACTIVE=1 JSH_REMOTE=1 JSH_UI_BACKEND=shell UI_COLOR_MODE=none \
    bash -c '
      source "$1/lib/output.sh"
      source "$1/lib/env.sh"
      source "$1/lib/ui.sh"
      jsh::spin "Running task" -- bash -c "printf failure-details >&2; exit 7" 2>"$2"
    ' _ "${JSH_ROOT}" "${failure_log}"

  [[ ${status} -eq 7 ]]
  grep -Fq 'failure-details' "${failure_log}"
}

@test "spinner output policies are backend independent" {
  local success_log="${BATS_TEST_TMPDIR}/spin-success.err"
  local failure_log="${BATS_TEST_TMPDIR}/spin-failure.err"

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    jsh::spin "Successful task" --output failure -- bash -c "printf hidden-output >&2" 2>"$2"
  ' _ "${JSH_ROOT}" "${success_log}"
  [[ ${status} -eq 0 ]]
  run grep -Fq hidden-output "${success_log}"
  [[ ${status} -eq 1 ]]

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    jsh::spin "Failed task" --output failure -- bash -c "printf failure-output >&2; exit 6" 2>"$2"
  ' _ "${JSH_ROOT}" "${failure_log}"
  [[ ${status} -eq 6 ]]
  grep -Fq failure-output "${failure_log}"
}

@test "UI cleanup stops background helpers and closes owned descriptors" {
  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    exec 9<>/dev/null
    JSH_UI_OWNS_FD=1
    JSH_UI_INPUT_FD=9
    JSH_UI_OUTPUT_FD=9
    jsh::cleanup
    ! : <&9
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}

@test "legacy spinner lifecycle delegates to the shared facade" {
  local spinner_log="${BATS_TEST_TMPDIR}/legacy-spinner.err"

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain JSH_PLAIN_OUTPUT=1 bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/ui.sh"
    source "$1/lib/spinner.sh"
    {
      jsh_spinner_start "Preparing runtime"
      [[ -z $JSH_SPINNER_PID ]]
      jsh_spinner_static "Checking host"
      jsh_spinner_stop
    } 2> "$2"
  ' _ "${JSH_ROOT}" "${spinner_log}"

  [[ ${status} -eq 0 ]]
  grep -Fqx 'Preparing runtime' "${spinner_log}"
  grep -Fqx 'Checking host' "${spinner_log}"
}

@test "UI cleanup stops a legacy spinner process" {
  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/ui.sh"
    sleep 30 &
    JSH_SPINNER_PID=$!
    spinner_pid=$JSH_SPINNER_PID
    jsh::cleanup
    [[ -z $JSH_SPINNER_PID ]]
    ! kill -0 "$spinner_pid" 2>/dev/null
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}

@test "Gum release metadata follows latest and survives an offline retry" {
  run env JSH_GUM_VERSION= XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache" bash -c '
    source "$1/lib/bootstrap.sh"
    vendor_checksum=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    curl() {
      printf "%s  %s\n" "$vendor_checksum" gum_2.1.0_Linux_x86_64.tar.gz
    }
    jsh_gum_release linux amd64
    printf "%s|%s|%s\n" "$JSH_GUM_VERSION" "$JSH_GUM_ARCHIVE" "$JSH_GUM_CHECKSUM"
    unset JSH_GUM_VERSION
    curl() { return 1; }
    jsh_gum_release linux amd64
    printf "%s|%s|%s\n" "$JSH_GUM_VERSION" "$JSH_GUM_ARCHIVE" "$JSH_GUM_CHECKSUM"
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ ${lines[0]} == '2.1.0|gum_2.1.0_Linux_x86_64.tar.gz|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ]]
  [[ ${lines[1]} == "${lines[0]}" ]]
}

@test "Gum bootstrap activates the host executable atomically" {
  local source_dir="${BATS_TEST_TMPDIR}/gum_2.0.1_Linux_x86_64"
  local archive="${BATS_TEST_TMPDIR}/gum.tar.gz"
  local destination="${BATS_TEST_TMPDIR}/data/tools/gum/2.0.1/linux-amd64/gum"
  mkdir -p "${source_dir}"
  cat > "${source_dir}/gum" << 'EOF'
#!/bin/sh
printf '%s\n' 'gum version v2.0.1'
EOF
  chmod +x "${source_dir}/gum"
  tar -czf "${archive}" -C "${BATS_TEST_TMPDIR}" gum_2.0.1_Linux_x86_64

  run env JSH_INTERACTIVE=1 JSH_REMOTE=0 JSH_PLATFORM=linux JSH_ARCH=amd64 \
    JSH_GUM_VERSION=2.0.1 JSH_GUM="${destination}" GUM_ARCHIVE="${archive}" \
    bash -c '
      source "$1/lib/output.sh"
      source "$1/lib/bootstrap.sh"
      jsh_gum_release() {
        JSH_GUM_ARCHIVE=gum_2.0.1_Linux_x86_64.tar.gz
        JSH_GUM_MEMBER=gum_2.0.1_Linux_x86_64/gum
        JSH_GUM_CHECKSUM=test
        JSH_GUM_URL=https://example.invalid/gum.tar.gz
      }
      jsh_download_artifact() { printf "%s\n" "$GUM_ARCHIVE"; }
      jsh::bootstrap_gum
      [[ -x $JSH_GUM ]]
      [[ $($JSH_GUM --version) == "gum version v2.0.1" ]]
      [[ ! -e ${JSH_GUM}.partial.$$ ]]
    ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}

@test "root commands authenticate visibly once and then require non-interactive sudo" {
  local calls="${BATS_TEST_TMPDIR}/sudo-calls"

  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain SUDO_CALLS="${calls}" bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    source "$1/lib/linux.sh"
    id() { printf "%s\n" 1000; }
    sudo() { printf "%s\n" "$*" >> "$SUDO_CALLS"; }
    jsh_run_root printf first
    jsh_run_root printf second
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
  [[ $(grep -Fxc -- '-v' "${calls}") -eq 1 ]]
  grep -Fqx -- '-n -- printf first' "${calls}"
  grep -Fqx -- '-n -- printf second' "${calls}"
}

@test "sudo keepalive stops immediately and reaps its timer" {
  run env JSH_NON_INTERACTIVE=1 JSH_UI_BACKEND=plain JSH_SUDO_KEEPALIVE_INTERVAL=30 bash -c '
    source "$1/lib/output.sh"
    source "$1/lib/env.sh"
    source "$1/lib/ui.sh"
    id() { printf "%s\n" 1000; }
    sudo() { return 0; }
    jsh::sudo_keepalive
    keepalive_pid=$JSH_SUDO_KEEPALIVE_PID
    jsh::sudo_keepalive_stop
    ! kill -0 "$keepalive_pid" 2>/dev/null
  ' _ "${JSH_ROOT}"

  [[ ${status} -eq 0 ]]
}
