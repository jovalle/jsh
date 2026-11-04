# AGENTS.md

jsh sets up a workstation (macOS, Debian-family Linux, RHEL-family Linux) with Bash scripts.
This checkout is live: `install.sh` links each file under `dotfiles/` into `$HOME` and each
`bin/` command into `~/.local/bin`, so edits take effect on the developer's machine immediately.

This is the only agent instruction file. Do not create `CLAUDE.md`, `GEMINI.md`, or
`.github/copilot-instructions.md`. Agent skills come from the `skills` and `ai` scripts;
custom agents and prompts stay in VS Code Settings Sync, not here.

## commands

| Task             | Command                                                                       |
| ---------------- | ----------------------------------------------------------------------------- |
| All checks       | `make check`                                                                  |
| One check        | `make syntax`, `make lint`, `make test-shell`                                 |
| One shell file   | `bash -n FILE` or `zsh -n FILE`, then `shellcheck -x --severity=warning FILE` |
| Preview setup    | `./install.sh --dry-run [GROUP ...]` or `./scripts/NAME.sh --dry-run`         |
| Pre-commit hooks | `make hooks`                                                                  |

`./install.sh` and `./scripts/NAME.sh` without `--dry-run` change the live machine; `--update`
also upgrades installed software. Run them only when asked.

## layout

- `install.sh`: bootstrap. Installs `core` packages and shell plugins, links dotfiles and
  `bin/`, then runs each named group's `scripts/GROUP.sh` (or just its packages).
- `scripts/NAME.sh`: one standalone setup group; data it uses lives in `scripts/NAME/`.
  `scripts/packages.sh` declares every group's packages in `install_group`.
  `scripts/lib/`: shared Bash (`common.sh` helpers, `apps.sh`, `desktop.sh`).
- `lib/shell/`: commands, navigation, prompt, and completion sourced by `.zshrc`/`.bashrc`.
  `lib/git/`: Python helpers run by `bin/git`.
- `bin/`: everyday commands and the isolated `jsh` runtime.
- `dotfiles/`: home-relative configuration.
- `scripts/check.py`: `unittest` smoke checks for interactive Bash and Zsh.
- Generated or machine-local, never edit: `local/`, `archive/`, `.venv/`, `tmp/`.
  Scratch files go in `tmp/`.

## conventions

- Setup scripts start with `#!/usr/bin/env bash`, a one-line purpose comment,
  `set -euo pipefail`, and source `scripts/lib/common.sh` (or `apps.sh`).
- Steps must be idempotent: check current state, change only what differs, and report each
  unit once with `jsh::added`, `jsh::changed`, `jsh::removed`, or `jsh::current`. Use
  `jsh::notice` only for something the user must act on. Honor `JSH_DRY_RUN` through
  `jsh::run`/`jsh::root`/`jsh::task`, and `JSH_UPDATE` for upgrades.
- Output: one transient progress line, then `+`/`~`/`-` change lines and one summary. No
  banners, prompts, or per-step success lines; command output goes to the task log.
- Privileged work uses `jsh::root` (`sudo -n`). Never prompt for input or a password.
- Runtime is Bash; Python (standard library only) is limited to `bin/` commands and
  `lib/git/`. Shell is 2-space indented; see `.editorconfig`.
- Names: commands read like speech, files and directories are one lowercase word when that
  stays clear.

## checks

- `scripts/check.py` is the only test file. Never add Bats or a new suite unless asked;
  otherwise validate with `bash -n`/`zsh -n` and ShellCheck.
- Checks must not touch the real `$HOME` or system settings: point `HOME`, `XDG_*`, and
  `JSH_*` at a temporary directory and mock commands. Never weaken a failing check.

## git

- Conventional Commits, enforced by commitlint: `type(scope): subject`, header at most 72
  characters, no trailing period, body lines at most 100. Scope names the script or
  component, for example `fix(waterfox): ...` or `feat(prompt): ...`.
- Commit only when asked. Stage only your files; the worktree often holds unrelated work,
  so never stash, reset, or revert it. Never bypass hooks, push, or rewrite published
  history without explicit approval.

## boundaries

- Always: read the surrounding code first, keep diffs minimal and in the existing style,
  run the narrowest relevant check, and say what was verified.
- Ask first: deleting files; adding dependencies; running setup without `--dry-run` or
  anything needing `sudo`; changing `.pre-commit-config.yaml`, `Makefile` checks, or Git
  hooks; touching credentials, SSH, or Git identity handling.
- Never: commit secrets or personal data; read or print credentials; edit generated or
  vendored paths; run commands that wait on a password prompt.

## 1Password

- For authorized tasks using the 1Password CLI, reuse one persistent terminal session for
  all `op` calls; authorization follows the terminal. Batch the needed secret references
  into one `op run --env-file=PATH -- COMMAND`, where the file holds only `op://`
  references and resolved secrets go straight to the consuming process, never to agent
  output. Close the session when done; do not cache secrets or add keepalive calls.
