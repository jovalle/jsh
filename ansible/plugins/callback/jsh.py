"""Render playbook results as jsh output events.

Each event uses the wire format from lib/output.md. With JSH_OUTPUT=renderer the events go to
stdout for the renderer install.sh started; otherwise lib/output.py formats them in-process.
Like jsh::event in lib/shell/output.sh, events are also recorded under JSH_REPORT for the run
summary.

Rules:
- A play-level include_role whose name is a group in scripts/groups.tsv opens that group. Its
  tasks, meta dependencies, and nested includes report under it until the next group.
- Task names and loop labels are the item text, so they state the end state.
- Changed results are added (package installs, files that did not exist), removed (state
  absent), or changed. In check mode, diff lines follow as output items.
- Probes are silent unless they fail: informational actions, tasks with check_mode false and
  changed_when false, and tasks forced into check mode to see whether a change is pending.
- A debug task named notice, info, or ok becomes that kind of item with its message; roles use
  ok to list what was already in place without a module call per entry.
- Command output lines that already are events (helper scripts) pass through unchanged.
"""

from __future__ import annotations

DOCUMENTATION = """
name: jsh
type: stdout
short_description: jsh setup output
description:
  - Writes jsh output events for the renderer in lib/output.py.
"""

import difflib
import importlib.util
import json
import os
import sys
from pathlib import Path

from ansible import context
from ansible.plugins.callback import CallbackBase

MARKER = "\x1e"
SILENT = {
    "add_host", "assert", "command_info", "debug", "find", "gather_facts", "group_by",
    "import_role", "import_tasks", "include_role", "include_tasks", "include_vars", "meta",
    "package_facts", "service_facts", "set_fact", "setup", "slurp", "stat",
}
PACKAGES = {
    "apt", "dnf", "flatpak", "flatpak_remote", "homebrew", "homebrew_cask", "homebrew_tap", "mas",
    "package", "pip",
}
SUDO_ERRORS = ("a password is required", "Missing sudo password", "incorrect sudo password")


def _short(action: str) -> str:
    return (action or "").rsplit(".", 1)[-1]


def _field(value: object) -> str:
    text = str(value)
    for character in ("\t", "\r", "\n"):
        text = text.replace(character, " ")
    return text.replace(MARKER, "")


def _diffs(result: dict) -> list:
    diff = result.get("diff")
    if isinstance(diff, dict):
        return [diff]
    return [entry for entry in diff or [] if isinstance(entry, dict)]


def _was_absent(diff: dict) -> bool:
    before = diff.get("before")
    if isinstance(before, dict):
        return before.get("state") == "absent"
    return before == "" and diff.get("after") not in (None, "")


def _diff_lines(diff: dict) -> list:
    def text(value):
        if isinstance(value, str):
            return value.splitlines()
        return json.dumps(value, indent=2, sort_keys=True, default=str).splitlines()

    lines = difflib.unified_diff(text(diff.get("before", "")), text(diff.get("after", "")),
                                 lineterm="", n=0)
    return [line for line in lines if not line.startswith(("---", "+++", "@@"))]


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "jsh"

    def __init__(self):
        super().__init__()
        self._root = Path(os.environ.get("JSH_ROOT") or Path(__file__).resolve().parents[3])
        self._groups = {}
        groups = self._root / "scripts/groups.tsv"
        if groups.is_file():
            for line in groups.read_text(encoding="utf-8").splitlines():
                fields = line.split("\t")
                if line and not line.startswith("#") and len(fields) == 3:
                    self._groups[fields[0]] = (fields[1], fields[2])
        report = os.environ.get("JSH_REPORT")
        self._report = Path(report) if report and Path(report).is_dir() else None
        self._wire = os.environ.get("JSH_OUTPUT") == "renderer"
        self._renderer = None
        self._group = None
        self._step = False
        self._check = False

    # Output

    def v2_playbook_on_start(self, playbook):
        self._check = bool(context.CLIARGS.get("check"))
        if not self._wire:
            spec = importlib.util.spec_from_file_location("jsh_output", self._root / "lib/output.py")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            color = getattr(module, "_color_enabled", lambda stream: False)(sys.stdout)
            self._renderer = module.Renderer(sys.stdout, tty=False, color=color,
                                             preview=self._check, report=None)

    def _write(self, line: str) -> None:
        if self._wire:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        elif self._renderer is not None:
            self._renderer.feed(line)

    def _emit(self, kind: str, *fields: object) -> None:
        values = [_field(value) for value in fields]
        self._record(kind, values)
        self._write(MARKER + "\t".join([kind, *values]))

    def _record(self, kind: str, values: list) -> None:
        if self._report is None:
            return
        if kind in ("group", "stepclose"):
            (self._report / "step").write_text("", encoding="utf-8")
        elif kind == "step":
            (self._report / "step").write_text("\t".join(values[:2]) + "\n", encoding="utf-8")
        if kind != "item":
            return
        item, text = values[0], values[1] if len(values) > 1 else ""
        self._append("items", item)
        if item in ("added", "changed", "removed"):
            self._append("events", item)
        elif item == "skip":
            self._append("skips", text)
        elif item == "fail":
            self._append("failures", text)
        elif item == "notice":
            notices = self._report / "notices"
            if not notices.is_file() or text not in notices.read_text(encoding="utf-8").splitlines():
                self._append("notices", text)

    def _append(self, name: str, line: str) -> None:
        with open(self._report / name, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def _item(self, kind: str, text: str) -> None:
        if self._group is not None and not self._step:
            self._emit("step", "check", self._group)
            self._step = True
        self._emit("item", kind, text)

    def _close(self) -> None:
        if self._group is not None:
            self._emit("stepclose")
        self._group = None
        self._step = False

    def v2_playbook_on_stats(self, stats):
        self._close()
        if not self._wire and self._renderer is not None:
            self._renderer.feed(MARKER + "end\t0\t0")

    # Groups

    def _group_include(self, task) -> str | None:
        if task._role is None and _short(task.action) in ("include_role", "import_role"):
            name = (task.args or {}).get("name")
            if name in self._groups:
                return name
        return None

    def v2_playbook_on_task_start(self, task, is_conditional):
        group = self._group_include(task)
        if group is not None:
            self._close()
            self._group = group
            self._emit("group", group, self._groups[group][1])
        elif self._group is not None and task.name:
            self._emit("progress", task.name)

    v2_playbook_on_handler_task_start = v2_playbook_on_task_start

    def _skip_text(self, group: str) -> str:
        platform = self._groups[group][0]
        if platform == "linux":
            return "Linux configuration on macOS" if group == "linux" else f"{group} on macOS: Linux only"
        if platform == "darwin":
            return "macOS configuration on Linux" if group == "macos" else f"{group} on Linux: macOS only"
        return f"{group}: not needed here"

    # Results

    def _text(self, result, item: bool) -> str:
        if item:
            raw = result._result
            label = raw.get("_ansible_item_label", raw.get("item"))
            if label is not None:
                return label if isinstance(label, str) else json.dumps(label, default=str)
        return result._task.name or _short(result._task.action)

    def _silent(self, task, action: str) -> bool:
        if action in SILENT:
            return True
        # task.check_mode also follows --check, so read what the task itself declares.
        declared = (task.get_ds() or {}).get("check_mode")
        if declared is True:
            return True
        changed_when = task.changed_when
        never = changed_when is False or changed_when == [False]
        return never and declared is False

    def _passthrough(self, raw: dict) -> bool:
        stdout = raw.get("stdout")
        if not isinstance(stdout, str) or MARKER not in stdout:
            return False
        # str.splitlines() would also split at the marker, so split on newlines only.
        for line in stdout.split("\n"):
            if line.startswith(MARKER):
                self._write(line)
        return True

    def _done(self, result, item: bool = False) -> None:
        task, raw = result._task, result._result
        if self._group is None or (not item and "results" in raw):
            return
        action = _short(task.action)
        if action == "debug" and task.name in ("notice", "info", "ok"):
            if not raw.get("skipped"):
                self._item(task.name, raw.get("msg", ""))
            return
        if self._passthrough(raw) or self._silent(task, action):
            return
        text = self._text(result, item)
        if not raw.get("changed"):
            self._item("ok", text)
            return
        self._item(self._change_kind(action, raw, task.args or {}), text)
        if self._check:
            lines = [line for diff in _diffs(raw) for line in _diff_lines(diff)]
            for line in lines[:20]:
                self._emit("item", "output", line)

    def _change_kind(self, action: str, raw: dict, args: dict) -> str:
        state = (raw.get("invocation") or {}).get("module_args", {}).get("state") or args.get("state")
        if state == "absent":
            return "removed"
        if action in PACKAGES:
            return "changed" if state == "latest" else "added"
        if action == "git" and not raw.get("before"):
            return "added"
        if action in ("command", "shell") and args.get("creates"):
            return "added"
        if any(_was_absent(diff) for diff in _diffs(raw)):
            return "added"
        return "changed"

    def _failed(self, result, item: bool = False) -> None:
        raw = result._result
        if not item and "results" in raw:
            return
        self._passthrough(raw)
        self._item("fail", f"{self._text(result, item)} failed")
        details = []
        for key in ("msg", "stderr", "module_stderr", "stdout"):
            value = raw.get(key)
            if isinstance(value, str) and value.strip():
                details.extend(line for line in value.split("\n")
                               if line.strip() and MARKER not in line)
                if key != "msg":
                    break
        for line in details[-10:]:
            self._emit("item", "output", line)
        if any(error in json.dumps(raw, default=str) for error in SUDO_ERRORS):
            self._emit("item", "notice", "run sudo -v first, then rerun")

    def v2_runner_on_ok(self, result):
        self._done(result)

    def v2_runner_item_on_ok(self, result):
        self._done(result, item=True)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if not ignore_errors:
            self._failed(result)

    def v2_runner_item_on_failed(self, result):
        if not result._task.ignore_errors:
            self._failed(result, item=True)

    def v2_runner_on_unreachable(self, result):
        self._failed(result)

    def v2_runner_on_skipped(self, result):
        group = self._group_include(result._task)
        if group is not None and group == self._group:
            self._emit("item", "skip", "Skipping " + self._skip_text(group))
