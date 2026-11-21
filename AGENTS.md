# AGENTS.md

jsh sets up a workstation (macOS, Debian-family Linux, RHEL-family Linux) with a Bash
bootstrap and Ansible roles.
This checkout is live: `install.sh` links each file under `dotfiles/` into `$HOME` and each
`bin/` command into `~/.local/bin`, so edits take effect on the developer's machine immediately.

This is the only agent instruction file in this repository. Do not create `CLAUDE.md`,
`GEMINI.md`, or `.github/copilot-instructions.md`. Agent skills come from the `agentics` role.
Rules every agent follows in every project live in `ansible/roles/agentics/files/instructions.md`;
the `agentics` role writes them to each installed agent's home (`~/.copilot/instructions/`,
`~/.codex/AGENTS.md`, and the OpenCode, Claude, and Gemini equivalents). Custom agents and
prompts stay in VS Code Settings Sync, not here.

## commands

| Task             | Command                                                                       |
| ---------------- | ----------------------------------------------------------------------------- |
| All checks       | `make check`                                                                  |
| One check        | `make check syntax`, `make check lint`, `make check shell`                    |
| Lint             | `make lint` (shellcheck and yamllint; same as `make check lint`)              |
| Format           | `make fmt` (shfmt, and rewrites inline YAML lists `[a]` as block lists)       |
| Ansible checks   | `make check ansible` (installs Ansible into `local/ansible/`)                 |
| One shell file   | `bash -n FILE` or `zsh -n FILE`, then `shellcheck -x --severity=warning FILE` |
| Preview setup    | `scripts/configure.sh --dry-run [ROLE ...]`                                   |
| List roles       | `make list roles`                                                             |
| Pre-commit hooks | `make check hooks`                                                            |

`make configure`, `jsh update`, `./install.sh`, `scripts/configure.sh`,
`ansible-playbook`, or a bootstrap/helper script without `--dry-run` changes the live machine;
`jsh update` and `--update` also upgrade installed software. Run them only when asked.

## layout

- `install.sh`: bootstrap (the curl one-liner). Installs `core` packages and shell plugins,
  then links dotfiles and `bin/`. It runs no setup roles.
- `scripts/configure.sh` (`make configure [ROLE ...]`): runs the setup roles through
  `ansible/site.yml`, limited to this host; with no roles, every role when the user has admin
  rights.
- `scripts/`: bootstrap scripts (`shell.sh`, `ansible.sh`, and `packages.sh`), `lists.py` (run
  by `make fmt`), and the only test file, `check.py`. `scripts/lib/` holds Bash shared by the bootstrap;
  `ansible/helpers/` holds role libraries; `scripts/packages.sh` declares only `core` and global
  `maintenance` packages.
- `lib/output.md`: output contract. `lib/output.py`: renderer and Python API.
  `lib/verbs.tsv`: step conjugations.
- `lib/shell/`: commands, navigation, prompt, and completion sourced by `.zshrc`/`.bashrc`.
  `lib/shell/output.sh` is shared by the runtime, `bin/` commands, and setup.
  `lib/git/`: Python helpers run by `bin/git`, and `hooks/`, the global Git hooks
  `examples/gitconfig` sets as `core.hooksPath` (one `dispatch.sh` linked under each hook name;
  it runs a repository's tracked `.githooks/` after `git config jsh.hooks true`, then
  `.git/hooks`).
- `ansible/`: host configuration. `site.yml` defines setup role order; each included role's
  metadata declares its purpose and supported platforms. `inventory.yml` lists `localhost` and
  the named hosts; `group_vars/all/` holds jsh settings (`jsh.yml`) and every package
  (`packages.yml`), and `host_vars/HOST.yml` holds per-host additions. Shared roles that
  `site.yml` doesn't list are `app` and `link`; plugins (output callback, `settings` module,
  filters) are in `ansible/plugins/`. Shared role libraries live in `ansible/helpers/`; setup
  helper scripts in `roles/ROLE/files/` source
  `scripts/lib/common.sh` and print output events. `scripts/ansible.sh` installs the pinned
  versions from `ansible/requirements.*` into `local/ansible/`. To run it directly, set `ANSIBLE_CONFIG=ansible/ansible.cfg` and run
  `local/ansible/venv/bin/ansible-playbook ansible/site.yml --limit localhost --tags ROLE --check --diff`.
- `bin/`: everyday commands and the isolated `jsh` runtime.
- `dotfiles/`: home-relative configuration. `dotfiles/.gitconfig` is an ignored local copy
  of `examples/gitconfig`.
- `Makefile`: one-line shortcuts and checks.
- `scripts/check.py`: `unittest` smoke checks for interactive Bash and Zsh.
- Generated or machine-local, never edit: `local/`, `archive/`, `.venv/`, `tmp/`.
  Scratch files go in `tmp/`.

## conventions

- Bootstrap scripts and setup helpers start with `#!/usr/bin/env bash`, a one-line purpose
  comment (printed by `--help` for standalone scripts), and `set -euo pipefail`. Setup helpers
  source `scripts/lib/common.sh` (or `apps.sh`) with `"$@"`; unknown options are rejected.
- Steps must be idempotent: check current state, change only what differs, and report each
  unit once with `jsh::ok`, `jsh::drift`, `jsh::added`, `jsh::changed`, or `jsh::removed`. Use
  `jsh::notice` only for something the user must act on. Honor `JSH_DRY_RUN` through
  `jsh::run`/`jsh::root`/`jsh::task`, and `JSH_UPDATE` for upgrades. Honor `JSH_MIRRORS_ONLY`:
  anything fetched from a public URL (not a package manager's configured index) goes behind
  `jsh::internet NAME` in Bash or `jsh_mirrors_only` with a `skip` debug task in Ansible.
- Output follows `lib/output.md`: items stream as facts, the active step is a transient
  bottom line, and groups close with ✓/✕/–.
- `bin/` commands load `lib/shell/output.sh`, never `scripts/lib/`.
- Privileged work uses `jsh::root` (`sudo -n`). Never prompt for input or a password.
- Runtime is Bash; Python (standard library only) is limited to `bin/`, `lib/git/`,
  `lib/output.py`, and `ansible/plugins/` (which may also use Ansible's own APIs), plus
  `scripts/lists.py`, which uses PyYAML from `local/ansible/venv/`. Shell is 2-space indented; see `.editorconfig`.
- YAML lists are block style (`- item`), even with one item; only `[]` stays inline. yamllint
  enforces it and `make fmt` converts inline lists.
- Names: commands read like speech, files and directories are one lowercase word when that
  stays clear.
- To add a setup role, create `ansible/roles/ROLE/` with a metadata description and MacOSX,
  Debian, and/or EL platforms, then add a tagged block/rescue `include_role` to
  `ansible/site.yml` in run order with the matching platform condition. Related settings become
  an area folder in an existing role (`tasks/AREA/`, `files/AREA/`, `AREA_` variables under the
  role prefix) rather than a new role. Packages go in `ansible/group_vars/all/packages.yml`:
  `packages_roles.ROLE` for what the role's tasks need (and add `ROLE` to the `packages` block
  tags in `site.yml`), `packages_common` for the rest. Host differences go in
  `ansible/host_vars/HOST.yml` with a matching `inventory.yml` host. Keep other data and helpers
  in the role.
- Linux parity uses the Debian 13 XFCE host `colossus`, only through dry-run scratch copies under
  `~/.cache/jsh-port`; never run against its live `~/.jsh`. RHEL behavior still needs a host.

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
  anything needing `sudo`; changing `.pre-commit-config.yaml`, `Makefile` checks, or Git
  hooks; touching credentials, SSH, or Git identity handling.
- Never: commit secrets or personal data; read or print credentials; edit generated or
  vendored paths; run commands that wait on a password prompt.
