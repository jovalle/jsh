set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes.
default:
  @just --list

# Install jsh locally, or install and update workstation packages.
install target="full":
  #!/usr/bin/env bash
  set -euo pipefail
  case "{{ target }}" in
    lite) ./bin/jsh install --mode runtime ;;
    full) ./bin/jsh install --mode install ;;
    packages) task packages ;;
    *) printf 'Unknown install target: %s\n' "{{ target }}" >&2; exit 2 ;;
  esac

# Install declared Homebrew packages and upgrade installed formulae and casks.
brew:
  task brew

# Configure every component for this platform, or one named component.
configure component="":
  task configure COMPONENT="{{ component }}"

# Report runtime and managed-link health.
doctor:
  ./bin/jsh doctor

# Update submodules to their latest remote commits.
update:
  git submodule sync --recursive
  git submodule update --init --remote --recursive

# Run formatting, lint, and Bats.
test: fmt-check lint
  #!/usr/bin/env bash
  set -euo pipefail
  shopt -s nullglob
  files=(tests/*.bats)
  ((${#files[@]})) || exit 0
  if command -v parallel >/dev/null 2>&1; then
    jobs="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '2')}"
    bats --jobs "${jobs}" "${files[@]}"
  else
    printf 'GNU Parallel not found; running tests sequentially.\n' >&2
    bats "${files[@]}"
  fi

# Run ShellCheck and shell syntax checks.
lint:
  #!/usr/bin/env bash
  set -euo pipefail
  shopt -s nullglob
  shell_files=(j.sh)
  bats_files=(tests/*.bats)
  while IFS= read -r -d '' file; do
    shell_files+=("${file}")
  done < <(find scripts dotfiles/.config/shell -type f \( -name '*.sh' -o -name '*.bash' \) -print0)
  for file in bin/*; do
    [[ -f ${file} ]] || continue
    case "$(head -n 1 "${file}")" in
      '#!'*bash*|'#!'*'/sh') shell_files+=("${file}") ;;
    esac
  done

  shellcheck --severity=warning "${shell_files[@]}"
  if ((${#bats_files[@]})); then
    shellcheck --shell=bats --severity=warning "${bats_files[@]}"
  fi
  sh -n j.sh
  bash -n "${shell_files[@]:1}" dotfiles/.bash_profile dotfiles/.bashrc
  if command -v zsh >/dev/null 2>&1; then
    zsh -n dotfiles/.zshrc
  fi

# Format active first-party shell and Bats files.
fmt:
  #!/usr/bin/env bash
  set -euo pipefail
  shopt -s nullglob
  shell_files=(j.sh)
  bats_files=(tests/*.bats)
  while IFS= read -r -d '' file; do
    shell_files+=("${file}")
  done < <(find scripts dotfiles/.config/shell -type f \( -name '*.sh' -o -name '*.bash' \) -print0)
  for file in bin/*; do
    [[ -f ${file} ]] || continue
    case "$(head -n 1 "${file}")" in
      '#!'*bash*|'#!'*'/sh') shell_files+=("${file}") ;;
    esac
  done

  shfmt -w -i 2 -ci -bn "${shell_files[@]}"
  if ((${#bats_files[@]})); then
    shfmt -ln=bats -w -i 2 -ci -bn "${bats_files[@]}"
  fi

# Check formatting without modifying files.
fmt-check:
  #!/usr/bin/env bash
  set -euo pipefail
  shopt -s nullglob
  shell_files=(j.sh)
  bats_files=(tests/*.bats)
  while IFS= read -r -d '' file; do
    shell_files+=("${file}")
  done < <(find scripts dotfiles/.config/shell -type f \( -name '*.sh' -o -name '*.bash' \) -print0)
  for file in bin/*; do
    [[ -f ${file} ]] || continue
    case "$(head -n 1 "${file}")" in
      '#!'*bash*|'#!'*'/sh') shell_files+=("${file}") ;;
    esac
  done

  shfmt -d -i 2 -ci -bn "${shell_files[@]}"
  if ((${#bats_files[@]})); then
    shfmt -ln=bats -d -i 2 -ci -bn "${bats_files[@]}"
  fi

# Prepare a checkout for contributing.
prepare: hooks

# Verify tools required by hooks and repository checks.
check:
  #!/usr/bin/env bash
  set -euo pipefail
  missing=()
  for dependency in bats gitleaks jq pre-commit prettier shellcheck shfmt task; do
    command -v "${dependency}" >/dev/null 2>&1 || missing+=("${dependency}")
  done
  if ((${#missing[@]})); then
    printf 'Missing contributor dependencies:' >&2
    printf ' %s' "${missing[@]}" >&2
    printf '\nInstall them, then run `just prepare` again.\n' >&2
    exit 1
  fi

# Install repository Git hooks and local filters.
hooks: check
  #!/usr/bin/env bash
  set -euo pipefail

  attributes_file="$(git rev-parse --git-path info/attributes)"
  attribute='dotfiles/.vscode/user/settings.json filter=vscode-local-settings'
  mkdir -p "$(dirname "${attributes_file}")"
  touch "${attributes_file}"
  grep -Fqx "${attribute}" "${attributes_file}" || printf '%s\n' "${attribute}" >>"${attributes_file}"

  git config --local filter.vscode-local-settings.clean ./scripts/git/filter-vscode-settings.sh
  git config --local filter.vscode-local-settings.required true

  pre-commit install --hook-type pre-commit --hook-type pre-push --hook-type commit-msg
