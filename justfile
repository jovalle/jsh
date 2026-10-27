set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

export JSH_ROOT := justfile_directory()
export PYTHONDONTWRITEBYTECODE := "1"

[private]
default:
    @just --list --unsorted

# Run every setup job in order: install, dotfiles, tweak, customize, configure
[group('setup')]
setup *args:
    @. lib/core.sh; jsh::job setup "$@"

# Install software: core, tools, runtime, apps, extensions, or one app (default: all)
[group('setup')]
install *args:
    @. lib/core.sh; jsh::job install "$@"

# Link dotfiles (`just set dotfiles`)
[group('setup')]
set target *args:
    #!/usr/bin/env bash
    set -euo pipefail
    . lib/core.sh
    case $1 in
      dotfiles) shift; jsh::job dotfiles "$@" ;;
      *) jsh::log_error "Unknown target: set $1 (try: just set dotfiles)"; exit 2 ;;
    esac

# Apply OS preferences
[group('setup')]
tweak *args:
    @. lib/core.sh; jsh::job tweak "$@"

# Customize wallpaper, keybindings, desktop, dock, audio, or display (default: all)
[group('setup')]
customize *args:
    @. lib/core.sh; jsh::job customize "$@"

# Configure apps: helium, waterfox, vscode, sublime, agents (default: all)
[group('setup')]
configure *args:
    @. lib/core.sh; jsh::job configure "$@"

# List install groups, apps, and components
[group('setup')]
list:
    @printf '%s\n' 'install: core tools runtime apps extensions all helium waterfox vscode ghostty spotify todoist sublime' \
      'set: dotfiles' 'tweak: preferences' \
      'customize: wallpaper keybindings desktop dock audio display all' \
      'configure: helium waterfox vscode sublime agents all'

# Run every check, or one of: syntax, headers, readme, hooks
[group('develop')]
check what='all':
    #!/usr/bin/env bash
    set -euo pipefail
    shell_files=(bin/jsh $(find lib scripts -type f -name '*.sh'))
    case $1 in
      all)
        just check syntax
        just check headers
        just check readme
        just lint
        just test
        ;;
      syntax)
        for file in "${shell_files[@]}"; do bash -n "${file}"; done
        zsh -n dotfiles/.zshrc lib/j.zsh lib/prompt.zsh
        python3 -c 'from pathlib import Path; [compile(p.read_text(), str(p), "exec") for p in [*Path("lib").glob("*.py"), *Path("scripts").rglob("*.py")]]'
        python3 -c 'import json; from pathlib import Path; paths = [Path("conf/packages.json"), Path("conf/keybindings.json"), Path("conf/fonts.json"), *Path("conf/helium").glob("*.json"), *Path("conf/vscode").glob("*.json")]; [json.loads(p.read_text()) for p in paths]'
        ;;
      headers)
        for file in $(find scripts -name '*.sh'); do
          [[ $(head -n 1 "${file}") == '#!/usr/bin/env bash' ]] &&
            sed -n '2p' "${file}" | grep -Eq '^# [[:alnum:]]' &&
            grep -Fq '. "${JSH_ROOT}/lib/core.sh"' "${file}" || {
            echo "Missing script header: ${file}" >&2
            exit 1
          }
        done
        ;;
      readme)
        for file in bin/*; do
          [[ ! -f ${file} ]] || grep -Fq "](${file})" README.md || {
            echo "Undocumented command: ${file}" >&2
            exit 1
          }
        done
        ;;
      hooks) pre-commit run --all-files ;;
      *) echo "Unknown check: $1 (try: syntax, headers, readme, hooks)" >&2; exit 2 ;;
    esac

# Run every linter, or one of: shell, python, yaml, markdown
[group('develop')]
lint what='all':
    #!/usr/bin/env bash
    set -euo pipefail
    case $1 in
      all) for linter in shell python yaml markdown; do just lint "${linter}"; done ;;
      shell) shellcheck --severity=warning bin/jsh $(find lib scripts -type f -name '*.sh') ;;
      python) pylint --persistent=no $(find lib scripts tests -type f -name '*.py') ;;
      yaml) yamllint -c .yamllint .pre-commit-config.yaml ;;
      markdown) markdownlint README.md AGENTS.md ;;
      *) echo "Unknown linter: $1 (try: shell, python, yaml, markdown)" >&2; exit 2 ;;
    esac

# Run the Python unittest suite
[group('develop')]
test:
    python3 -m unittest discover -s tests -p 'test_*.py'
