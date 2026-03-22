# CLI design

jsh keeps terminal output quiet and operational. One banner identifies the
project. The remaining output reports state and next actions in lines that are
easy to scan, without turning the command into a dashboard.

## Structure

- Use the `jsh` graffiti banner once at the start of every human-facing,
  top-level `jsh` invocation, including the `j.sh` installer, workflows, help,
  version output, and usage errors. Emit exactly one blank line before the banner
  and one after it. All workflow output follows the lower blank line. Delegated
  standalone commands do not inherit or repeat it.
- When the graffiti banner would exceed the detected terminal width, replace it
  with `jsh` in the same bold cyan style when color is enabled. The compact form
  follows the same blank line rules. Compare the longest banner line with
  `COLUMNS`. Do not use a separate fixed breakpoint.
- Default to flat status messages. Start each message with its status mark and a
  complete description of what happened.
- Use a short cyan, bold heading only when a report needs named sections.
- Use `[current/total] Title` only when knowing the workflow's order or remaining
  stages helps the user.
- Reserve trees and connectors for true parent-child relationships or lists whose
  grouping would be unclear in flat output.
- Reserve dotted leaders for compact key-value reports. Do not use them for
  conversational progress messages.
- Wrap a long message onto an indented continuation line. Do not add a tree
  connector just to support wrapping.
- Keep raw command output, manifests, color charts, and editor sessions unframed.
- Standalone `bin/*` commands emit their sections or data directly. Do not add a
  command-name banner or descriptive subtitle before the output.

The flat rich form is:

```text
✔ Created symlinks
✔ Set local Git repo to Personal profile
▲ Personal profile has no signing key
✖ Failed to change profiles
✔ Successfully installed jsh
```

Marks begin in the first column and messages begin one space later. Keep a flat
sequence continuous by leaving out blank lines between individual updates. Add a
blank line only between sections. Single-line messages do not end with
punctuation. The banner contains the brand only. Put the version, active mode,
command name, and other context below the banner when a command needs them.

A staged workflow may combine a stage heading with flat messages:

```text
[2/3] Configuring Runtime
✔ Created launcher at ~/.local/bin/jsh
✔ Configured runtime
```

Repeated records with multiple health fields have a parent-child structure and
may use nested trees:

```text
Profiles
  ├── personal (active)
  │   ├── Email ....................... ✔ user@example.com
  │   ├── SSH key ..................... ✔ ~/.ssh/personal
  │   └── Signing key ................. ▲ not configured
  └── work
      ├── Email ....................... ✔ user@work.example
      ├── SSH key ..................... ✖ ~/.ssh/work · not found
      └── Signing key ................. ▲ not configured
```

Put each status mark on its field row, immediately before the value it
describes. Selection and other neutral context belong on the parent node in
parentheses, not in a warning status. Omit facts implied by membership in the
list. For example, do not label every listed profile "configured". If a complete
status and value does not fit, move both to an indented continuation line.

Filesystem-backed fields show their configured path and replace `HOME` with `~`.
A regular readable file or expected valid symlink is healthy. An unexpected
symlink is a warning and includes its target. A broken symlink, missing path, or
non-file target is an error. An error takes precedence over a warning.

## Status language

Color reinforces a status. It never carries the meaning by itself.
Color the status mark, not the full message. Reserve cyan bold text for the
graffiti banner, stage titles, and report headings.

| Meaning | Rich mark | Plain mark | Color |
| --- | --- | --- | --- |
| verified, confirmed, expected | `✔` | `[ok]` | green |
| attention, degraded, unverified, unexpected | `▲` | `[warn]` | yellow |
| missing, failed, error | `✖` | `[error]` | red |
| in progress | `➜` | `[plan]` | cyan |
| planned by a dry run | `➜` | `[plan]` | gray |
| note or optional detail | `›` | `[note]` | white |
| informational, neutral | `•` | `[info]` | gray |

Marks describe the resulting state, not the operation. Give a changed value `✔`
when the command verifies that it matches the expected state. Use `▲` when the
result still needs attention or the command cannot verify it. Do not use `▲` just
to announce a change. The verb distinguishes a verified change from an existing
correct state: `Set profile to Personal` versus `Profile is Personal`.

For idempotent mutating commands, use green state wording for work that was
already satisfied, such as `✔ Launcher is current`. Reserve past-tense action
verbs for changes made during the current invocation.

Use sentence case for headings, labels, and messages. Keep identifiers and
initialisms such as `GIT_AUTHOR_NAME`, `SSH`, and `URL` uppercase. Name the
outcome in the user's terms, not the internal implementation step. Use past tense
for completed work and `Failed to ...` for failures. Use an imperative only when
the user must act. Keep success messages factual and say what failed in errors.
Close a workflow with one final success message that does not repeat every
result.

Use direct verbs without first- or second-person pronouns: `Created symlinks`,
`Profile is Personal`, and `Run jsh repair`. When the recovery is known, pair an
error with that next action. Include a low-level system or command error only
when it helps the user choose a different action.

Human-facing messages are English only. Add localization only when the project
can maintain translated help, errors, and status words as one contract.

## Output modes

Interactive output may use ANSI color and Unicode when stdout is a terminal.
Every command must remain understandable without either.

- `JSH_COLOR=auto|always|never` controls color.
- `NO_COLOR` disables color, even when `JSH_COLOR=always`.
- `JSH_PLAIN_OUTPUT=1` disables color, Unicode decoration, and animation.
- `TERM=dumb` and redirected output default to plain output. Redirected output
  includes stdout sent to a file, pipe, or command substitution.
- Redirected human-readable output keeps the full graffiti banner. It is
  uncolored unless the user forces color. Redirection alone does not
  select the compact banner because no terminal width applies.
- Spinners belong on stderr and must leave one final status row when stopped.
- `--porcelain` is the sole machine-readable contract. It must never contain a
  banner, color, glyphs, animation, or prose. Do not add parallel machine formats
  without a concrete consumer that porcelain cannot support.
- Generated payloads such as shell completions and configuration files also omit
  the banner and decoration. They are raw command payloads, not status formats.
  Send generation diagnostics to stderr.
- Human output uses portable text and ANSI color only. Do not emit terminal
  hyperlinks, notifications, or other optional escape-sequence features.
- Reject invalid output-control values with a usage error. Do not silently fall
  back when, for example, `JSH_COLOR` has an unsupported value.

The banner and routine human output go to stdout. Errors go to stderr. Data
intended for a pipe goes to stdout. A command that wraps another program should
not decorate that program's output.

Warnings exit successfully unless they leave the requested outcome incomplete or
unsafe. Exit status describes whether the command fulfilled its contract, not
the color of every reported state.

Default reports show a summary. `--verbose` adds the underlying records without
changing their meaning or exit status. Long operations may show a spinner on a
TTY. They must replace it with one durable final status row. Noninteractive
output never animates.

Do not add a separate debug-output dialect. `--verbose` is the single public
diagnostic level and may include useful underlying errors without exposing
secrets. Routine output has no timestamps. Commands do not invoke a pager. Users
may pipe output to one.

Preserve workflow or configuration order when it carries meaning. Sort records
alphabetically only when their source has no order. Do not reorder a
report by severity. Wrap long rows onto indented continuation lines and preserve
their full values. Human-readable output does not truncate meaningful data.
Concurrent work follows the same rule. Buffer completed rows when needed to
print them in stable workflow or configuration order.

Mutating workflows such as install, repair, and uninstall end with one final
summary message. Read-only reports end with their last fact and do not announce
that the report completed.

A dry run uses gray `➜` rows with conditional verbs such as `Would create` and
`Would remove`. Never use a green verified mark for work that did not happen.

Before repair, uninstall, overwrite, or another destructive action, show the
exact planned changes and ask for confirmation on a TTY. `--yes` accepts that
plan. Noninteractive destructive use requires `--yes` and must not wait for
input. Interactive confirmation defaults to no and displays `[y/N]`.

For an invalid argument or command, print the banner, a concise error that says
how to correct it, one usage line, and the command that displays full help. Do
not append the full help text.

Full help contains usage, commands, and options. Group top-level commands by
workflow, such as install and runtime, inspection, maintenance, and help. Put
examples in command-specific help or longer documentation rather than expanding
the top-level reference.

Mutating commands stop after the first failed mutation to avoid more changes to
a partial state. Read-only reports continue through independent checks, report
all findings, and then return their combined exit status.

On interruption, restore the cursor, clear transient output, print an
`✖ Interrupted` row, and exit 130.

Help, version, status, and other read-only commands do not perform unsolicited
network requests. Network access must follow an explicit command or option.

Never print tokens, passwords, private key contents, or credential-bearing URLs,
including in verbose output or underlying error text. Profile names and email
addresses may appear when the report is about them.

Default configuration reports show the effective value. `--verbose` may add
whether it came from a command option, environment variable, configuration file,
or default. Effective settings follow this precedence, from highest to lowest:
command option, environment variable, configuration file, built-in default.

Remove renamed commands and options immediately rather than retaining deprecated
aliases. The documented command and porcelain formats are the compatibility
contract. Call out breaking changes in release notes.

Human `jsh --version` prints one concise build-detail line below the banner with
the available semantic version, source commit, platform, architecture, and
runtime. Omit unavailable details instead of printing placeholders. Porcelain
version output remains banner-free structured data.

Documentation examples show rich Unicode marks without embedded ANSI escape
codes. Add a plain-output example only when its exact ASCII form is relevant to
the subject.

## Command fit

Use the flat status grammar for installation and destructive-operation previews.
Use trees for health checks and configuration reports only when they contain
nested records. Some bins need their own format:

- `colours` is a terminal color chart.
- `httpstat` is a request timing visualization.
- `kubedectl` emits manifests for pipelines.
- `kubectx` and `kubens` emit selectable names.
- `nvim` is a transparent editor launcher.

Those commands keep their domain output. They still follow the same rules for
help, errors, and metadata. Color controls apply when color is presentation. The
color cells emitted by `colours` are the command's payload.
