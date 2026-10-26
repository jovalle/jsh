# AGENTS.md

Jsh is an opinionated shell environment, command set, and workstation automation for macOS, Linux, and Windows.
This checkout is live: it lives at `~/.jsh`, `dotfiles/` is symlinked into `$HOME`, and `bin/` is on `PATH`, so edits
take effect on the developer's machine immediately.

This is the only project instruction file for every agent. Do not create `.github/copilot-instructions.md`,
`CLAUDE.md`, or `GEMINI.md`. If a tool generates one (for example `graphify vscode install`), merge anything new into
this file and delete the generated copy.

## commands

| Task             | Command                                                                    |
| ---------------- | -------------------------------------------------------------------------- |
| All checks       | `make check` (syntax, setup script headers, README coverage)               |
| All linters      | `make lint` (shellcheck, pylint, yamllint, markdownlint, eslint)           |
| One shell file   | `bash -n FILE` or `zsh -n FILE`, then `shellcheck --severity=warning FILE` |
| All tests        | `make test`                                                                |
| One test module  | `python3 -m unittest tests.test_sublime`                                   |
| Pre-commit hooks | `make pre-commit-run`                                                      |
| Setup scopes     | `make list-scopes`                                                         |

ShellCheck info findings SC2310/SC2312 are pre-existing; only warnings and errors must be clean.

`make install|update|setup|deploy|configure|patch|uninstall` and `jsh setup|install|update|repair` change the live
machine (packages, system defaults, application settings). Run them only when asked, and prefer `--dry-run`.

## layout

- `j.sh`: bootstrap and setup orchestrator; phases are listed in `SETUP_PHASES`.
- `bin/`: standalone commands on `PATH`. Every file needs a README entry (`make check-readme`).
- `lib/`: shared shell libraries sourced by scripts; `lib/zsh/` holds interactive Zsh code (prompt, `j`).
- `scripts/<platform>/<phase>/`: setup scripts. Platforms: `unix`, `darwin`, `linux`, `windows`. Phases: `install`,
  `deploy`, `configure`, `patch`.
- `conf/`: declarative data. Package installs belong in `conf/packages.json`, not inline in scripts.
  `*.example.json` files are templates; `conf/git.json` and `conf/mounts.json` are gitignored personal data.
- `dotfiles/`: linked into `$HOME` file by file with `bin/jstow --no-folding`.
- `tests/`: Python `unittest` modules.
- Generated or machine-local, never edit by hand: `graphify-out/`, `local/`, `node_modules/`, `.venv/`.
- Scratch files go in `tmp/` (gitignored), not `/tmp`.

## conventions

- Setup scripts start with this header, enforced by `make check-script-headers`:

  ```bash
  #!/usr/bin/env bash
  # Configure Example with the managed settings.

  set -euo pipefail

  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  JSH_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)
  readonly SCRIPT_DIR JSH_ROOT
  for library_file in "${JSH_ROOT}"/lib/*; do
    [[ -f ${library_file} && -x ${library_file} ]] || continue
    # shellcheck source=/dev/null
    . "${library_file}"
  done
  ```

- Use `jsh::log_info`, `jsh::log_warn`, `jsh::log_success`, and `jsh::log_error` for user-facing output, not `echo`.
- Setup scripts are idempotent: check current state, skip when already correct, and change only what differs.
- A script that skips an unsupported platform or architecture must `return 0`/`exit 0`, or `set -e` callers abort.
- Honor `--dry-run` (no writes) and `--yes` (accept prompts, never pick or widen a profile or scope). A declined
  prompt skips only that action and anything that depends on it.
- Shell indent is 2 spaces; Python is 4 spaces with a 100-column limit; see `.editorconfig`.
- New files get single-word names when the directory supplies context (`lib/zsh/vault.zsh`, not
  `op-vault.zsh`). Use hyphens only to disambiguate or to match an existing name (`sublime-text.sh`).

## tests

- Never write Bats tests (`*.bats`) or add Bats tooling. Tests are Python `unittest` files at `tests/test_<name>.py`.
- Do not create or extend tests for shell-environment code: `j.sh`, `lib/` (including `lib/zsh/`), shell
  dotfiles, prompts, completions, aliases, environment setup, deploy/setup orchestration, or the `Makefile`.
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
  changing `.pre-commit-config.yaml`, `Makefile` check targets, or Git hooks; touching credentials, SSH, or Git
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
