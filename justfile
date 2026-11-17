# Everyday jsh operations and local checks. Recipes stay one line and call install.sh,
# bin/jsh, or one tool; setup logic lives in scripts/.
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

shell_files := `{ printf '%s\n' install.sh; find scripts lib -type f -name '*.sh'; for file in bin/*; do [ -f "$file" ] && head -n 1 "$file" | grep -Eq 'sh$' && printf '%s\n' "$file" || true; done; } | tr '\n' ' '`
bash_rc := "dotfiles/.bashrc dotfiles/.bash_profile"
zsh_files := "dotfiles/.zshrc lib/shell/commands.sh lib/shell/navigation.sh"

[private]
default:
    @{{ just_executable() }} --list --unsorted

# Update installed software and settings; name groups to limit it
[group('use')]
update *groups:
    bin/jsh update "$@"

# Preview what setup would change; name groups to limit it
[group('use')]
status *groups:
    ./install.sh --dry-run "$@"

# Install and configure; name groups to limit it
[group('use')]
setup *groups:
    ./install.sh "$@"

# List setup groups
[group('use')]
list what='groups':
    {{ if what == "groups" { "./install.sh --list" } else { error("just list: only groups") } }}

# Run syntax, lint, and shell checks, or one of them, or the pre-commit hooks
[group('develop')]
check what='all':
    {{ just_executable() }} {{ if what == "all" { "syntax lint shell" } else if what =~ '^(syntax|lint|shell|hooks)$' { what } else { error("just check: syntax, lint, shell, or hooks") } }}

# Format shell files with shfmt
[group('develop')]
format:
    shfmt --write {{ shell_files }} {{ bash_rc }}

[private]
syntax:
    for file in {{ shell_files }} {{ bash_rc }}; do bash -n "$file"; done
    for file in {{ zsh_files }}; do zsh -n "$file"; done
    cache=$(mktemp -d); trap 'rm -rf -- "$cache"' EXIT; PYTHONPYCACHEPREFIX="$cache" python3 -m py_compile lib/output.py lib/git/*.py bin/cafe bin/microphone scripts/check.py

[private]
lint:
    shellcheck -x --severity=warning {{ shell_files }} {{ bash_rc }}

[private]
shell:
    python3 scripts/check.py

[private]
hooks:
    pre-commit run --all-files
