"""jsh command line: setup, install, link, configure, update, status, list, module commands."""

import os
import shlex
import subprocess
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
    "status": ("install", "link"),
}

USAGE = """\
Usage: jsh COMMAND [MODULE...] [--dry-run]

  setup [MODULE...]       Install, link, and configure
  install [MODULE...]     Install missing software
  link [MODULE...]        Link module home/ files into your home directory
  configure [MODULE...]   Apply settings
  update [MODULE...]      Upgrade installed software
  status [MODULE...]      Show checkout state, missing software, and unlinked files
  list                    List modules and their commands
  MODULE COMMAND [ARG...] Run a module command
  runtime                 Open an isolated zsh with this checkout's dotfiles
  wizard                  Choose what to set up on this machine

--dry-run shows what would change without changing anything. Root changes need an
authorized sudo session (run sudo -v first); jsh never prompts for a password.
"""


def main(argv):  # pylint: disable=too-many-return-statements
    if not argv or argv[0] in ("-h", "--help", "help"):
        if sys.stdout.isatty():
            Display().header("jsh " + (argv[0] if argv else "--help"), "")
        sys.stdout.write(USAGE)
        return 0
    command, rest = argv[0], argv[1:]
    try:
        found = catalog.discover()
        if command == "wizard" and not rest:
            from jsh import wizard  # pylint: disable=import-outside-toplevel

            return wizard.start(found)
        if command in PHASES:
            return phase(command, rest, found)
        if command == "list" and not rest:
            if sys.stdout.isatty():
                Display().header("jsh list", describe(system.Facts(), False))
            return show(found, system.Facts())
        module = next((module for module in found if module.name == command), None)
        if module is None:
            raise ValueError(f"Unknown command: {command} (see: jsh --help)")
        if sys.stdout.isatty():
            label = "jsh " + " ".join([command, *rest[:1]])
            Display().header(label, describe(system.Facts(), False))
        return invoke(module, rest)
    except (ManifestError, ValueError, RuntimeError, OSError) as error:
        paint = "\033[31m{}\033[0m" if styled(sys.stderr) else "{}"
        print(paint.format(f"✗ {error}"), file=sys.stderr)
        return 2
    except (EOFError, KeyboardInterrupt):
        print("\nSetup cancelled.", file=sys.stderr)
        return 130


def phase(command, rest, found):
    """Run a phase command on the named modules, or on the wizard's saved selection."""
    options = [argument for argument in rest if argument.startswith("-")]
    if set(options) - {"--dry-run"}:
        raise ValueError(f"Unknown option: {(set(options) - {'--dry-run'}).pop()}")
    names = [argument for argument in rest if not argument.startswith("-")]
    if names:
        selected, explicit = catalog.select(found, names), names
    else:
        from jsh import wizard  # pylint: disable=import-outside-toplevel

        saved = wizard.load()
        selected = catalog.select(found, saved["modules"]) if saved is not None else found
        explicit = saved["optional"] if saved is not None else []
    dry_run = "--dry-run" in options
    result = run(command, selected, explicit, dry_run)
    if command == "setup" and not dry_run and result == 0 and sys.stdin.isatty():
        enter_runtime()
    return result


def enter_runtime():
    """Replace the setup process with the isolated interactive shell."""
    sys.stdout.flush()
    launcher = str(system.ROOT / "bin/jsh")
    os.execv(launcher, [launcher])


def run(command, selected, explicit, dry_run, user_only=False):
    status = command == "status"
    dry_run = dry_run or status
    facts = system.Facts()
    tasks = runner.plan(selected, PHASES[command], facts, explicit)
    display = Display(dry_run=dry_run)
    detail = describe(facts, dry_run and not status)
    if explicit:
        detail += " · " + ", ".join(explicit)
    display.header(f"jsh {command}", detail)
    if status:
        checkout(display)
    for module in selected:
        if module.name in explicit and not facts.matches(module.when):
            display.notice(module.name, "does not apply to this machine")
    interrupted = False
    try:
        ok = runner.execute(tasks, display, facts, dry_run, user_only=user_only)
    except KeyboardInterrupt:
        ok, interrupted = False, True
    display.summary(interrupted)
    if interrupted:
        return 130
    return 0 if ok else 1


def describe(facts, preview):
    """Header detail: the checkout's commit, platform, desktop, and whether it is a preview."""
    commit = system.query(["git", "-C", str(system.ROOT), "rev-parse", "--short", "HEAD"])
    desktop = facts.desktop if facts.family == "linux" else ""
    detail = ", ".join(filter(None, [facts.platform, desktop, "dry run" if preview else ""]))
    return f"{commit} ({detail})".strip()


def checkout(display):
    """Report when this checkout is dirty, has no upstream, or differs from it."""
    root = str(system.ROOT)
    try:
        subprocess.run(
            ["git", "-C", root, "fetch", "--quiet"],
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
            capture_output=True,
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired:
        display.notice("checkout", "fetch timed out; comparing with the last fetched upstream")
    upstream = system.query(["git", "-C", root, "rev-parse", "--abbrev-ref", "@{upstream}"])
    parts = [] if upstream else ["no upstream"]
    range_ = "@{upstream}...HEAD"
    counts = system.query(["git", "-C", root, "rev-list", "--left-right", "--count", range_])
    if upstream and counts:
        behind, ahead = (int(value) for value in counts.split())
        parts += [f"{ahead} ahead of {upstream}"] if ahead else []
        parts += [f"{behind} behind {upstream}"] if behind else []
    changed = len(system.query(["git", "-C", root, "status", "--porcelain"]).splitlines())
    parts += [f"{changed} changed"] if changed else []
    if parts:
        display.notice("checkout", ", ".join(parts))


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
