# AGENTS.md

jsh sets up a workstation (macOS, Debian-family Linux, RHEL-family Linux) with Bash scripts.
This checkout is live: `install.sh` links each file under `dotfiles/` into `$HOME` and each
`bin/` command into `~/.local/bin`, so edits take effect on the developer's machine immediately.

This is the only agent instruction file in this repository. Do not create `CLAUDE.md`,
`GEMINI.md`, or `.github/copilot-instructions.md`. Agent skills come from the `skills` and `ai`
scripts. Rules every agent follows in every project live in `scripts/ai/instructions.md`;
`scripts/ai.sh` writes them to each installed agent's home (`~/.copilot/instructions/`,
`~/.codex/AGENTS.md`, and the OpenCode, Claude, and Gemini equivalents). Custom agents and
prompts stay in VS Code Settings Sync, not here.

## commands

| Task             | Command                                                                       |
| ---------------- | ----------------------------------------------------------------------------- |
| All checks       | `just check`                                                                  |
| One check        | `just check syntax`, `just check lint`, `just check shell`                    |
| Ansible checks   | `just check ansible` (installs Ansible into `local/ansible/`)                 |
| One shell file   | `bash -n FILE` or `zsh -n FILE`, then `shellcheck -x --severity=warning FILE` |
| Preview setup    | `just status [GROUP ...]` or `./scripts/NAME.sh --dry-run`                    |
| List groups      | `just list groups`                                                            |
| Pre-commit hooks | `just check hooks`                                                            |

`just setup`, `just update`, and `./install.sh` or `./scripts/NAME.sh` without `--dry-run`
change the live machine; `just update` and `--update` also upgrade installed software. Run
them only when asked.

## layout

- `install.sh`: bootstrap. Installs `core` packages and shell plugins, links dotfiles and
  `bin/`, then runs each named group's `scripts/GROUP.sh` (or just its packages).
- `scripts/NAME.sh`: one standalone setup group; data it uses lives in `scripts/NAME/`.
  `scripts/groups.tsv`: every group with its platforms and purpose, in run order.
  `scripts/lib/`: shared Bash (`common.sh` helpers, `apps.sh`, `desktop.sh`).
  `scripts/lib/packages.sh`: package-manager code; `scripts/packages.sh` declares each
  group's packages.
- `lib/output.md`: output contract. `lib/output.py`: renderer and Python API.
  `lib/verbs.tsv`: step conjugations.
- `lib/shell/`: commands, navigation, prompt, and completion sourced by `.zshrc`/`.bashrc`.
  `lib/shell/output.sh` is shared by the runtime, `bin/` commands, and setup.
  `lib/git/`: Python helpers run by `bin/git`, and `hooks/`, the global Git hooks
  `dotfiles/.gitconfig` sets as `core.hooksPath` (one `dispatch.sh` linked under each hook name;
  it runs a repository's tracked `.githooks/` after `git config jsh.hooks true`, then
  `.git/hooks`).
- `ansible/`: host configuration, moving here group by group. `site.yml` includes one role
  per group in `groups.tsv` order, tagged with the group name; `install.sh` runs a group's
  role when `ansible/roles/GROUP` exists, otherwise `scripts/GROUP.sh`. `scripts/ansible.sh`
  installs the pinned versions from `ansible/requirements.*` into `local/ansible/`. To run it
  directly, set `ANSIBLE_CONFIG=ansible/ansible.cfg` and run
  `local/ansible/venv/bin/ansible-playbook ansible/site.yml --tags GROUP --check --diff`.
- `bin/`: everyday commands and the isolated `jsh` runtime.
- `dotfiles/`: home-relative configuration.
- `justfile`: one-line shortcuts and checks.
- `scripts/check.py`: `unittest` smoke checks for interactive Bash and Zsh.
- Generated or machine-local, never edit: `local/`, `archive/`, `.venv/`, `tmp/`.
  Scratch files go in `tmp/`.

## conventions

- Setup scripts start with `#!/usr/bin/env bash`, a one-line purpose comment (printed by
  `--help`), `set -euo pipefail`, and source `scripts/lib/common.sh` (or `apps.sh`) with
  `"$@"`; unknown options are rejected.
- Steps must be idempotent: check current state, change only what differs, and report each
  unit once with `jsh::ok`, `jsh::drift`, `jsh::added`, `jsh::changed`, or `jsh::removed`. Use
  `jsh::notice` only for something the user must act on. Honor `JSH_DRY_RUN` through
  `jsh::run`/`jsh::root`/`jsh::task`, and `JSH_UPDATE` for upgrades.
- Output follows `lib/output.md`: items stream as facts, the active step is a transient
  bottom line, and groups close with ✓/✕/–.
- `bin/` commands load `lib/shell/output.sh`, never `scripts/lib/`.
- Privileged work uses `jsh::root` (`sudo -n`). Never prompt for input or a password.
- Runtime is Bash; Python (standard library only) is limited to `bin/`, `lib/git/`,
  `lib/output.py`, and `ansible/plugins/` (which may also use Ansible's own APIs). Shell is 2-space indented; see `.editorconfig`.
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
- No `Co-authored-by` trailers or other AI attribution; the global `commit-msg` hook rejects
  them in every repository.

## boundaries

- Always: read the surrounding code first, keep diffs minimal and in the existing style,
  run the narrowest relevant check, and say what was verified.
- Ask first: deleting files; adding dependencies; running setup without `--dry-run` or
  anything needing `sudo`; changing `.pre-commit-config.yaml`, `justfile` checks, or Git
  hooks; touching credentials, SSH, or Git identity handling.
- Never: commit secrets or personal data; read or print credentials; edit generated or
  vendored paths; run commands that wait on a password prompt.
