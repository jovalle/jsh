# AGENTS.md

jsh sets up a workstation (macOS, Debian-family Linux, RHEL-family Linux) from modules.
This checkout is live: it lives at `~/.jsh`, module `home/` files are symlinked into `$HOME`,
and `bin/` is on `PATH`, so edits take effect on the developer's machine immediately.

This is the only agent instruction file. Do not create `CLAUDE.md`, `GEMINI.md`, or
`.github/copilot-instructions.md`; jsh does not manage agent tools, skills, or prompts.

## commands

| Task             | Command                                                                                |
| ---------------- | -------------------------------------------------------------------------------------- |
| All checks       | `make check`                                                                           |
| One check        | `make syntax`, `make headers`, `make readme`, `make modules`, `make lint`, `make test` |
| One shell file   | `bash -n FILE` or `zsh -n FILE`, then `shellcheck --severity=warning FILE`             |
| One test module  | `python3 -m unittest tests.test_engine`                                                |
| Preview setup    | `./j.sh setup --dry-run` (or one module: `./j.sh configure helium --dry-run`)          |
| Pre-commit hooks | `make hooks`                                                                           |

`./j.sh setup|install|link|configure|update` without `--dry-run` changes the live machine.
Run them only when asked.

## layout

- `j.sh`: entry point. Finds Python 3.9+, installing one through
  Homebrew, apt, or dnf when none exists, then runs `python -m jsh` with `lib/` on
  `PYTHONPATH`. `j.sh runtime` and `bin/jsh` with no arguments open the isolated Zsh;
  `bin/jsh COMMAND` delegates to `j.sh`.
- `lib/jsh/`: the engine. `modules.py` (reads `module.json` and validates
  it), `runner.py` (plans phases into tasks, runs them, gives
  handlers a `Context`), `output.py` (bun-style display), `cli.py`, `system.py` (facts,
  sudo, queries). Helpers for module scripts: `files.py`, `apps.py`, `web.py`, `desktop.py`.
- `lib/jsh/handlers/`: one file per handler (`brew`, `apt`, `dnf`, `flatpak`, `appimage`,
  `uv`, `git`, `link`, `script`). `_native.py` is shared apt/dnf code, not a handler.
- `modules/NAME/`: `module.json`, optional `home/` (linked into `$HOME`), and the scripts
  and data its steps use.
- `lib/core.sh`, `lib/output.sh`: Bash helpers for module scripts and `bin/` tools.
  `lib/j.zsh`, `lib/prompt.zsh`: the `j` function and prompt, sourced by `.zshrc`.
- `conf/`: personal, gitignored machine data (`git.json`) and its example.
- `tests/`: Python `unittest` modules. Generated or machine-local, never edit:
  `local/` (vendor clones, logs, runtime), `.venv/`, `tmp/`. Scratch files go in `tmp/`.

## modules and handlers

- A module name is one lowercase word. Its manifest needs `description`; other keys are
  `when`, `install`, `configure`, `update`, `link`, and `commands`. `make modules` loads
  every manifest and plans it for each platform and desktop; run it after manifest edits.
- Phases: `setup` = `install` → `link` → `configure`. `update` reuses `install` steps of
  handlers with an `update` function, except `script` steps (declare those under `update`).
- Prefer a declarative handler step over a script. Use a `script` step for one-off logic.
- Steps must be idempotent: check current state, change only what differs, and report each
  unit exactly once with `added`, `changed`, `removed`, or `current`. Use `notice` only for
  something the user must act on. Honor `ctx.dry_run` (Python) or `JSH_DRY_RUN` (Bash; use
  `jsh::run`/`jsh::root`). Command output belongs in the task log (`ctx.run`, or stdout in
  Bash scripts), never on the terminal.
- Privileged work uses `sudo -n` (`ctx.run(..., root=True)`, `jsh::root`) or a step with
  `"root": true`. Never prompt for input or a password.
- A new handler module defines phase functions taking `(ctx, steps)`, plus optional
  `BATCH`, `PRIORITY`, `PLATFORMS`, `EXPLICIT`, `units(step)`, and `check(args)`; see
  `lib/jsh/handlers/__init__.py`. Read `system.ROOT` at call time so tests can patch it.

## conventions

- Module Bash scripts at `modules/NAME/*.sh` start with this header (`make headers`):

  ```bash
  #!/usr/bin/env bash
  # Configure Example with the managed settings.

  set -euo pipefail

  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
  readonly SCRIPT_DIR JSH_ROOT
  # shellcheck source=lib/core.sh
  . "${JSH_ROOT}/lib/core.sh"
  ```

- Output follows bun: one transient progress line, then `+`/`~`/`-` change lines and one
  summary. Do not add banners, prompts, or per-step success lines.
- Runtime is Bash and the Python 3.9+ standard library only. Python is 4-space indented with a
  100-column limit; shell is 2-space indented; see `.editorconfig`.
- Names: commands read like speech (`jsh install helium`), files and directories are one
  lowercase word when that stays clear.

## tests

- Tests are Python `unittest` files at `tests/test_<name>.py`. Never add Bats.
- Cover the engine, handlers, app module scripts, and standalone `bin/` programs. Do not
  test shell-environment code (`lib/*.sh`, `lib/*.zsh`, `.zshrc`); validate it with
  `bash -n`/`zsh -n` and ShellCheck.
- Tests must not touch the real `$HOME` or system settings: point `HOME` and `XDG_*` at a
  temporary directory under `tmp/` and mock commands. Never weaken a failing test.

## git

- Conventional Commits, enforced by commitlint: `type(scope): subject`, header at most 72
  characters, no trailing period, body lines at most 100. Scope names the module or
  component, for example `fix(waterfox): ...` or `feat(engine): ...`.
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
