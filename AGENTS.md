# AGENTS.md

Jsh is a small workstation setup tool for macOS, Debian-family Linux, and RHEL-family Linux.
This checkout is live: it lives at `~/.jsh`, `dotfiles/` is symlinked into `$HOME`, and `bin/` is on `PATH`, so edits
take effect on the developer's machine immediately.

This is the only project instruction file for every agent. Do not create `.github/copilot-instructions.md`,
`CLAUDE.md`, or `GEMINI.md`. If a tool generates one (for example `graphify vscode install`), merge anything new into
this file and delete the generated copy.

## commands

| Task             | Command                                                                    |
| ---------------- | -------------------------------------------------------------------------- |
| All checks       | `just check` (syntax, headers, README, linters, tests)                     |
| All linters      | `just lint` (shellcheck, pylint, yamllint, markdownlint)                   |
| One shell file   | `bash -n FILE` or `zsh -n FILE`, then `shellcheck --severity=warning FILE` |
| All tests        | `just test`                                                                |
| One test module  | `python3 -m unittest tests.test_apps`                                      |
| Pre-commit hooks | `just check hooks`                                                         |
| Setup targets    | `just list`                                                                |

ShellCheck info findings SC2310/SC2312 are pre-existing; only warnings and errors must be clean. Runtime uses Bash and the Python standard library.

`just install|set|tweak|customize|configure` change the live machine (packages, system defaults, application
settings). Run them only when asked, and prefer `--dry-run`.

## layout

- `justfile`: setup recipes (`just setup`, `just install`, `just set dotfiles`, ...) and development checks.
- `bin/jsh`: opens the isolated zsh runtime with this checkout's dotfiles.
- `lib/`: sourced or imported code only: logging (`output.sh`, `output.py`), shared Bash helpers including the
  `jsh::job` runner, and the `j` zsh function. Nothing here runs as its own process.
- `scripts/`: one internal program per job (`install.py`, `dotfiles.sh`, `customize.sh`, `configure.py`), run by
  `jsh::job`, not by hand. `scripts/tweak/darwin.sh` and `scripts/tweak/linux.sh` hold OS-specific preferences.
- `conf/`: declarative data. Package installs belong in `conf/packages.json`, not inline in scripts.
  `*.example.json` files are templates; `conf/git.json` and `conf/mounts.json` are gitignored personal data.
- `dotfiles/`: regular files and symlinks are discovered recursively and linked into `$HOME`.
- `tests/`: Python `unittest` modules.
- Generated or machine-local, never edit by hand: `graphify-out/`, `local/`, `node_modules/`, `.venv/`.
- Scratch files go in `tmp/` (gitignored), not `/tmp`.

## conventions

- Setup scripts start with this header, enforced by `just check headers` (use `../..` under `scripts/tweak/`):

  ```bash
  #!/usr/bin/env bash
  # Configure Example with the managed settings.

  set -euo pipefail

  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  JSH_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
  readonly SCRIPT_DIR JSH_ROOT
  # shellcheck source=lib/core.sh
  . "${JSH_ROOT}/lib/core.sh"
  ```

- Use `jsh::log_info`, `jsh::log_warn`, `jsh::log_success`, and `jsh::log_error` for user-facing output, not `echo`.
- Setup scripts are idempotent: check current state, skip when already correct, and change only what differs.
- A script that skips an unsupported desktop or unavailable optional component must `return 0`/`exit 0`, or `set -e` callers abort.
- Honor `--dry-run` (no writes) and `--yes` (accept prompts for the selected command only). A declined
  prompt skips only that action and anything that depends on it.
- Shell indent is 2 spaces; Python is 4 spaces with a 100-column limit; see `.editorconfig`.
- New files get single-word names when the directory supplies context (`conf/vscode/settings.json`, not
  `vscode-settings.json`). Use hyphens only to disambiguate or to match an existing name (`sublime-text.sh`).

## tests

- Never write Bats tests (`*.bats`) or add Bats tooling. Tests are Python `unittest` files at `tests/test_<name>.py`.
- Do not create or extend tests for shell-environment code: `lib/` (including `lib/*.zsh`), shell
  dotfiles, prompts, completions, aliases, environment setup, deploy/setup orchestration, or the `justfile`.
  Validate those changes with `bash -n`/`zsh -n` and `shellcheck --severity=warning` instead.
- Tests are allowed only for standalone programs (for example `bin/*`) and for scripts that install or
  configure standalone external apps (for example Sublime Text, Waterfox, mpv).
- Tests must not touch the real `$HOME` or system settings; point paths at a temporary directory.
- Never delete or weaken a failing test to make a run pass.

## git

- Conventional Commits, enforced by commitlint: `type(scope): subject`. Types: `feat`, `fix`, `docs`, `style`,
  `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. Header at most 72 characters, no trailing period;
  body lines at most 100. Scope names the component, for example `fix(waterfox): ...` or `feat(jgit): ...`.
- Commit only when asked. Stage only the files you changed; the worktree usually holds unrelated in-progress work, so
  never stash, reset, or revert it.
- Never bypass hooks (`--no-verify`), push, force-push, or rewrite published history without explicit approval.

## boundaries

- Always: read the surrounding code first, keep diffs minimal and in the existing style, run the narrowest relevant
  check from the commands table before reporting done, and say what was verified.
- Ask first: deleting files; adding packages or dependencies; running setup targets or anything that needs `sudo`;
  changing `.pre-commit-config.yaml`, `justfile` check recipes, or Git hooks; touching credentials, SSH, or Git
  identity handling.
- Never: commit secrets, tokens, or personal data; read or print credentials; edit generated or vendored paths; run
  commands that wait on a password prompt.

## graphify

For any question about this repo's architecture, structure, components, or how to add/modify/find
code, your first action should be `graphify query "<question>"` when `graphify-out/graph.json`
exists. Use `graphify path "<A>" "<B>"` for relationship questions and `graphify explain "<concept>"`
for focused-concept questions. These return a scoped subgraph, usually much smaller than the full
report or raw grep output.

Triggers: "how do I…", "where is…", "what does … do", "add/modify a <component>",
"explain the architecture", or anything that depends on how files or classes relate.

If `graphify-out/wiki/index.md` exists, use it for broad navigation. Read `graphify-out/GRAPH_REPORT.md`
only for broad architecture review or when query/path/explain do not surface enough context. Only read
source files when (a) modifying/debugging specific code, (b) the graph lacks the needed detail, or
(c) the graph is missing or stale.

Type `/graphify` in Copilot Chat to build or update the graph.

## archify

Use the global `archify` skill for architecture, workflow, sequence, data-flow,
and lifecycle diagrams. Run its Node commands with `ARCHIFY_UPDATE_CHECK_DISABLED=1`, and keep typed
sources and rendered HTML together under `docs/architecture/`.
