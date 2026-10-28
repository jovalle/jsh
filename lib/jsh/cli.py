"""jsh command line: setup, install, link, configure, update, list, and module commands."""

import os
import shlex
import sys

from jsh import modules as catalog
from jsh import runner, system
from jsh.modules import ManifestError
from jsh.output import Display, styled

PHASES = {
    "setup": ("install", "link", "configure"),
    "install": ("install",),
    "link": ("link",),
    "configure": ("configure",),
    "update": ("update",),
}

USAGE = """\
Usage: jsh COMMAND [MODULE...] [--dry-run]

  setup [MODULE...]       Install, link, and configure (default: every module)
  install [MODULE...]     Install missing software
  link [MODULE...]        Link module home/ files into your home directory
  configure [MODULE...]   Apply settings
  update [MODULE...]      Upgrade installed software
  list                    List modules and their commands
  MODULE COMMAND [ARG...] Run a module command
  runtime                 Open an isolated zsh with this checkout's dotfiles

--dry-run shows what would change without changing anything. Root changes need an
authorized sudo session (run sudo -v first); jsh never prompts for a password.
"""


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        return 0
    command, rest = argv[0], argv[1:]
    try:
        found = catalog.discover()
        if command in PHASES:
            options = [argument for argument in rest if argument.startswith("-")]
            if set(options) - {"--dry-run"}:
                raise ValueError(f"Unknown option: {(set(options) - {'--dry-run'}).pop()}")
            names = [argument for argument in rest if not argument.startswith("-")]
            return run(command, catalog.select(found, names), bool(names), "--dry-run" in options)
        if command == "list" and not rest:
            return show(found, system.Facts())
        module = next((module for module in found if module.name == command), None)
        if module is None:
            raise ValueError(f"Unknown command: {command} (see: jsh --help)")
        return invoke(module, rest)
    except (ManifestError, ValueError, RuntimeError) as error:
        paint = "\033[31m{}\033[0m" if styled(sys.stderr) else "{}"
        print(paint.format(f"✗ {error}"), file=sys.stderr)
        return 2


def run(command, selected, named, dry_run):
    facts = system.Facts()
    explicit = [module.name for module in selected] if named else ()
    tasks = runner.plan(selected, PHASES[command], facts, explicit)
    display = Display(dry_run=dry_run)
    commit = system.query(["git", "-C", str(system.ROOT), "rev-parse", "--short", "HEAD"])
    desktop = facts.desktop if facts.family == "linux" else ""
    detail = ", ".join(filter(None, [facts.platform, desktop, "dry run" if dry_run else ""]))
    display.header(f"jsh {command}", f"{commit} ({detail})".strip())
    if named:
        for module in selected:
            if not facts.matches(module.when):
                display.notice(module.name, "does not apply to this machine")
    interrupted = False
    try:
        ok = runner.execute(tasks, display, facts, dry_run)
    except KeyboardInterrupt:
        ok, interrupted = False, True
    display.summary(interrupted)
    if interrupted:
        return 130
    return 0 if ok else 1


def show(found, facts):
    color = styled(sys.stdout)
    width = max((len(module.name) for module in found), default=0)
    for module in found:
        applies = facts.matches(module.when)
        name = module.name.ljust(width)
        if color:
            name = f"\033[1m{name}\033[0m" if applies else f"\033[2m{name}\033[0m"
        jobs = [phase for phase in ("install", "configure") if module.steps[phase]]
        if module.home or module.steps["link"]:
            jobs.insert(1 if module.steps["install"] else 0, "link")
        tags = " · ".join(jobs)
        tags = f"\033[2m{tags}\033[0m" if color and tags else tags
        print(f"  {name}  {module.description}  {tags}".rstrip())
        for command, spec in module.commands.items():
            about = spec.get("about", "")
            line = f"  {' ' * width}    jsh {module.name} {command}"
            about = f"  \033[2m{about}\033[0m" if color and about else f"  {about}"
            print(f"{line}{about}".rstrip())
    return 0


def invoke(module, rest):
    if not rest or rest[0] not in module.commands:
        names = ", ".join(module.commands) or "none"
        raise ValueError(f"{module.name} commands: {names}")
    arguments = shlex.split(module.commands[rest[0]]["run"]) + rest[1:]
    script = module.path / arguments[0]
    if script.is_file():
        interpreter = {".sh": ["bash"], ".py": [sys.executable]}.get(script.suffix, [])
        arguments = [*interpreter, str(script), *arguments[1:]]
    facts = system.Facts()
    os.environ.update(
        JSH_ROOT=str(system.ROOT),
        JSH_MODULE=str(module.path),
        JSH_PLATFORM=facts.platform,
        JSH_DESKTOP=facts.desktop,
        JSH_HOST=facts.host,
    )
    os.execvp(arguments[0], arguments)
    return 0
