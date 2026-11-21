# jsh output contract

## Purpose

jsh output says what it is doing, what it found, and what it changed in one consistent form. Item text states a fact about the thing, not a log action.

## Scope

This contract covers `install.sh`, setup scripts, jsh-owned Bash commands, and human-readable output from jsh-owned Python commands. It requires Python 3.9 or newer with only the standard library. Bootstrap and remote use must still work with no Python through the Bash fallback. Setup never reads input or prompts, and privileged work remains in `jsh::root` with `sudo -n`.

It excludes `bin/git`, `lib/git/`, `bin/kubecolor`, `bin/kubectx`, `bin/kubens`, `bin/colours`, prompt and completion rendering, and genmon output from `bin/cafe` and `ansible/roles/desktop/files/audio/mic-check`.

## Vocabulary

| Symbol      | Kind    | Meaning                                    | Color     |
| ----------- | ------- | ------------------------------------------ | --------- |
| `›`         | group   | A group header                             | bold cyan |
| spinner     | step    | Transient work in progress at the bottom   | bold      |
| `✓`         | ok      | Checked and already correct                | green     |
| `!`         | drift   | Checked and not as wanted                  | yellow    |
| `+`         | added   | Added this run                             | green     |
| `~`         | changed | Changed this run                           | yellow    |
| `-`         | removed | Removed this run                           | red       |
| `✕`         | fail    | Failed work                                | red       |
| none        | info    | Context or detection                       | gray      |
| none        | skip    | Text starts with `Skipping` plus one space | gray      |
| `!`         | notice  | Action the user must take                  | yellow    |
| four spaces | output  | Command output under its work, dedented    | gray      |

## Line formats

- Real run: `! jq is not installed`, then `+ jq installed`.
- Preview: `! jq is not installed  would add`, with the planned action in gray.
- Failure: `✕ Failed to install just`.
- Skip: `Skipping Linux configuration on macOS`, in gray.
- Plain mode: `Checking macOS settings...`, then items as they arrive.

These are the target transcripts. On a terminal, the spinner is a transient bottom line. Each item clears it, prints permanently, and redraws the active step beneath the item. No step completion line remains.

```text
› macos  Apply managed macOS preferences
✓ ShowExternalHardDrivesOnDesktop is false
✓ ShowHardDrivesOnDesktop is false
✓ ShowMountedServersOnDesktop is false
<spinner> Checking macOS settings...
```

A real run can mix current, changed, and failed facts. A group ends with its final item; no result line follows.

```text
› core
✓ homebrew is installed
! jq is not installed
+ jq installed
✕ Failed to install just
    <last lines of the error output, gray>
    Log: ~/.local/state/jsh/logs/...
```

A preview uses the same layout and retains the planned action.

```text
› tools  Install everyday command-line tools
Checking packages...
! jq is not installed  would add
```

An interrupted active step prints the streamed items first, then the stopped line.

```text
› links  Dotfiles and commands
Checking links...
✓ ~/.zshrc linked
✕ Stopped checking links
```

Without a terminal, the renderer and Bash fallback print the step once and stream the same permanent item lines.

```text
› macos  Apply managed macOS preferences
Checking macOS settings...
✓ ShowHardDrivesOnDesktop is false
```

The closing summary lists notices under `Action needed` as yellow `•` bullets. A run with no changes reports `Everything is current`, or `No changes made` when notices are pending. On a terminal, long notices wrap at the window width with a four-space hanging indent. Write commands in a notice between backticks: wrapping never splits a code span, and with color it is shown in cyan without the backticks.

```text
Action needed
  • Configuration needs sudo; run `sudo -v`
    first, then rerun `make configure`
```

## APIs

The Bash API is `jsh::group`, `jsh::step`, `jsh::status`, `jsh::ok`, `jsh::drift`, `jsh::added`, `jsh::changed`, `jsh::removed`, `jsh::fail`, `jsh::info`, `jsh::skipped`, `jsh::notice`, `jsh::output`, `jsh::skip`, and `jsh::task`; parents close a child-owned step with `jsh::event stepclose`. The change functions take `TEXT [WAS]`. `jsh::skipped TEXT` emits a `skip` item with `Skipping TEXT`; `jsh::skip TEXT` emits that item and exits successfully.

The Python API is `group`, `step`, `ok`, `drift`, `added`, `changed`, `removed`, `fail`, `info`, `notice`, `skipped`, and `session()`.

A compatibility block at the end of `lib/shell/output.sh` retains the legacy output aliases only for the out-of-scope `bin/git` and `bin/kubectx`. New code must not use them.

## Groups

`jsh::group NAME PURPOSE` closes any open group, prints a blank line and its header, and opens the new group. A group closes at the next group, session end, or renderer EOF. Closing a group prints nothing.

Plain sessions use the shared `JSH_REPORT` records to track item, skip, and failure events emitted by child processes. The process that opened a plain group closes it.

## Steps and verbs

`jsh::step VERB OBJECT` and `step(verb, obj)` begin a step. The next step, group, or session end completes it. `jsh::status TEXT` updates progress. `lib/verbs.tsv` is the single table of -ing and past forms. Every verb passed to `jsh::step` must be present there.

On terminals, a step is the transient bottom line `FRAME ING OBJECT...`; progress or task text appears on a separate indented gray line above it. Items print immediately above the transient lines. Both lines clear together, and a step never prints a permanent success line. Without a terminal, the step prints once as `ING OBJECT...` in gray and items follow immediately.

Steps do not nest: a `step` event ends the current step. Open a step only after calls that open their own steps, including package handlers and child setup scripts. A step that checks state and acts only on drift uses the `check` verb; use `configure`, `set`, or `apply` only when the step always acts. Action facts such as starts, restarts, and reloads include a `WAS` field that states why the action was needed.

A step belongs to the process that opened it. A parent emits `stepclose` after a child returns so any child-owned step closes silently. A session end prints `✕ Stopped ING OBJECT`, with the -ing form lowercased, only for interrupt status 130 or 143. Unexpected renderer EOF with a step open also prints the stopped line. Other nonzero end statuses close an open step silently.

## Event protocol

Each event is one line: ASCII record separator (`\x1e`), then the type and tab-separated fields. Before sending, replace tab, carriage return, and newline in every field with a space and remove record separators. Lines without the marker are command output.

Events are `group NAME PURPOSE`, `step VERB OBJECT`, `stepclose`, `progress TEXT`, `item KIND TEXT [WAS]`, `task LABEL LOG`, `taskend STATUS SAVED`, and `end ELAPSED [STATUS]`. Item kinds are `ok`, `drift`, `added`, `changed`, `removed`, `fail`, `info`, `skip`, `notice`, and `output`.

## Sessions

Only the outermost jsh process opens and ends a session: `install.sh`, a directly run setup script, or a command that owns a complete run. Children reuse it. When a directly run script owns the session and exits with a nonzero status other than 130 or 143, it emits `✕ NAME failed (STATUS)` before ending the session only if its group has not already recorded a failure. Interrupt statuses retain the stopped-step behavior instead. Installer groups report their own failures and do not receive this owner-level item. Commands that prompt or execute an interactive program never open a session; an existing session closes before an interactive handoff.

## Files and owners

- `lib/output.md` owns this contract.
- `lib/verbs.tsv` owns step conjugation.
- `lib/output.py` owns event rendering and the Python API.
- `lib/shell/output.sh` owns the Bash and Zsh API and no-Python fallback.
- `scripts/lib/common.sh` owns setup helpers and renderer session transport built on the output API.
- `scripts/check.py` owns output checks.

## How to change this

Edit this contract, `lib/output.py`, and `lib/shell/output.sh` together, then extend `OutputChecks` for the changed behavior and fallback parity.
