"""Plan and run phases: group module steps into tasks and drive the display."""

import os
import re
import shutil
import subprocess
import time

from jsh import handlers, system
from jsh.modules import Step

VERBS = {"install": "installed", "link": "linked", "configure": "configured", "update": "updated"}
DOING = {
    "install": "installing",
    "link": "linking",
    "configure": "configuring",
    "update": "updating",
}
# Batched tasks are named after their handler; these say what the handler works on.
SUBJECTS = {
    "appimage": "AppImages",
    "apt": "apt packages",
    "brew": "Homebrew packages",
    "dnf": "dnf packages",
    "flatpak": "Flatpak apps",
    "git": "Git repositories",
    "link": "files",
    "uv": "uv tools",
}
SOURCES = {
    "appimage": "AppImage",
    "apt": "apt",
    "brew": "Homebrew",
    "dnf": "dnf",
    "flatpak": "Flatpak",
    "uv": "uv",
}
FAILURES = (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError)


class Task:
    def __init__(self, phase, label, handler, steps):
        self.phase = phase
        self.label = label
        self.handler = handler
        self.steps = steps
        self.units = sum(handlers.units(handler, step) for step in steps)
        self.root = any(step.root for step in steps)

    def describe(self):
        """Reads as speech on the progress line: "updating ai module", "installing uv tools"."""
        if handlers.batch(self.handler):
            return f"{DOING[self.phase]} {SUBJECTS.get(self.label, self.label)}"
        return f"{DOING[self.phase]} {self.label} module"


class Context:  # pylint: disable=too-many-instance-attributes
    """What a handler sees: the steps' phase, machine facts, output, and command execution."""

    def __init__(  # pylint: disable=too-many-positional-arguments
        self, display, facts, phase, label, logs, dry_run, module=None
    ):
        self.display = display
        self.facts = facts
        self.phase = phase
        self.label = label
        self.dry_run = dry_run
        self.module = module
        self.user_only = False
        self.handler = None
        self.root = system.ROOT
        self.noticed = False
        self.limit = None
        self.log_file = None
        self.deferred = set()
        self._logs = logs

    @property
    def log(self):
        if self.log_file is None:
            self._logs.mkdir(parents=True, exist_ok=True)
            name = re.sub(r"[^a-z0-9]+", "-", f"{self.phase} {self.label}".lower())
            self.log_file = self._logs / f"{name}.log"
        return self.log_file

    def advance(self, units=1):
        done = self.display.done + units
        self.display.reach(done if self.limit is None else min(done, self.limit))

    def added(self, text):
        self.change("+", text, VERBS[self.phase])
        self.advance()

    def changed(self, text, details=()):
        self.change("~", text, VERBS[self.phase], details)
        self.advance()

    def removed(self, text):
        self.change("-", text, "removed")
        self.advance()

    def change(self, mark, text, verb, details=()):
        if self.phase == "link":
            category, source = "Links", None
        elif self.handler in SOURCES:
            category, source = "Packages", SOURCES[self.handler]
        elif self.handler == "git":
            category, source = "Repositories", None
        elif self.phase == "configure":
            category, source = "Configuration", self.label
        else:
            category, source = "Other changes", self.label
        self.display.change(mark, text, verb, category, source, details=details)

    def current(self, units=1):
        for _ in range(units):
            self.display.current()
        self.advance(units)

    def progress(self, text):
        self.display.progress(text)

    def notice(self, text):
        self.noticed = True
        self.display.notice(self.label, text)

    def defer_system(self):
        """Record a system change omitted by the user-only wizard."""
        self.deferred.add(self.module.name)

    def admin(self):
        return not getattr(self, "user_only", False) and system.admin()

    def write_log(self, text):
        with open(self.log, "a", encoding="utf-8") as stream:
            stream.write(text if text.endswith("\n") else text + "\n")

    def run(self, arguments, root=False, env=None, cwd=None, check=True):
        """Run a command with its output kept in this task's log; dry runs only log it."""
        arguments = [str(argument) for argument in arguments]
        if root:
            if getattr(self, "user_only", False):
                raise RuntimeError("system changes are available through jsh")
            arguments = system.privileged(arguments)
        if self.dry_run:
            self.write_log(f"would run: {system.quoted(arguments)}")
            return 0
        with open(self.log, "a", encoding="utf-8") as stream:
            stream.write(f"$ {system.quoted(arguments)}\n")
            stream.flush()
            result = subprocess.run(
                arguments,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=stream,
                stderr=subprocess.STDOUT,
                env={**os.environ, **(env or {})},
                cwd=cwd,
            )
        if check and result.returncode:
            raise RuntimeError(f"{system.quoted(arguments)} exited with {result.returncode}")
        return result.returncode


def plan(modules, phases, facts, named=()):
    """Return the tasks for the given phases over modules that apply to this machine.

    Steps marked optional run only when their module is named explicitly.
    """
    tasks = []
    for phase in phases:
        steps = []
        for module in modules:
            if not facts.matches(module.when):
                continue
            steps += [
                step
                for step in phase_steps(module, phase)
                if facts.matches(step.when)
                and (not step.optional or module.name in named)
                and handlers.applies(handlers.get(step.handler), facts)
            ]
        tasks += group(phase, steps)
    return tasks


def phase_steps(module, phase):
    if phase == "link":
        implicit = [Step(module, "link", "link", {"from": "home", "to": "~", "tree": True})]
        return (implicit if module.home else []) + module.steps["link"]
    if phase == "update":
        updatable = [
            step
            for step in module.steps["install"]
            if handlers.supports(handlers.get(step.handler), "update")
            and not getattr(handlers.get(step.handler), "EXPLICIT", False)
        ]
        return updatable + module.steps["update"]
    return module.steps[phase]


def group(phase, steps):
    batches, singles = {}, []
    for step in steps:
        handler = handlers.get(step.handler)
        check = getattr(handler, "check", None)
        if check:
            try:
                check(step.args)
            except ValueError as error:
                raise ValueError(f"{step.module.name}: {step.handler}: {error}") from error
        if not handlers.supports(handler, phase):
            raise ValueError(f"{step.module.name}: {step.handler} does not support {phase}")
        if handlers.batch(handler):
            batches.setdefault(step.handler, []).append(step)
        else:
            singles.append(Task(phase, step.module.name, handler, [step]))
    ordered = sorted(batches.items(), key=lambda item: handlers.priority(handlers.get(item[0])))
    return [Task(phase, name, handlers.get(name), steps) for name, steps in ordered] + singles


def execute(tasks, display, facts, dry_run, user_only=False):
    """Run tasks in order; a failed task is reported and the rest still run."""
    logs = system.ROOT / "local/logs" / time.strftime("%Y%m%d-%H%M%S")
    display.begin(sum(task.units for task in tasks))
    deferred = set()
    for task in tasks:
        start = display.done
        display.task(task.describe())
        module = None if handlers.batch(task.handler) else task.steps[0].module
        ctx = Context(display, facts, task.phase, task.label, logs, dry_run, module)
        ctx.user_only = user_only
        ctx.deferred = deferred
        ctx.handler = task.steps[0].handler
        ctx.limit = start + task.units
        failed = False
        if user_only and (task.root or task.label in ("apt", "dnf")):
            deferred.update(step.module.name for step in task.steps)
        elif task.root and not dry_run and not system.admin():
            ctx.notice("needs sudo; run sudo -v first, then rerun")
        else:
            try:
                getattr(task.handler, task.phase)(ctx, task.steps)
            except FAILURES as error:
                failed = True
                message = (
                    f"missing required key {error}" if isinstance(error, KeyError) else str(error)
                )
                display.failure(task.label, message, ctx.log_file)
        display.reach(start + task.units)
        if ctx.log_file and not (failed or ctx.noticed):
            ctx.log_file.unlink(missing_ok=True)
    if deferred:
        names = " ".join(sorted(deferred))
        display.notice(
            "System changes skipped",
            "the wizard does not run package installs via "
            "apt/dnf or privileged changes; "
            f"use `jsh setup {names}` to apply them",
        )
    if logs.is_dir() and not any(logs.iterdir()):
        shutil.rmtree(logs, ignore_errors=True)
    return display.failed == 0
