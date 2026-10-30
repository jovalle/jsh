"""Link module files into place: home/ mirrors into $HOME, and link entries add others.

home/ is linked file by file; a link entry links its path as is, even a directory.
An existing file is moved to ~/.local/state/jsh/backups first; a stale link into this checkout
is replaced without a backup. Targets under a symlinked parent directory are left for review.
"""

import os
import shutil
import time
from pathlib import Path

from jsh import system
from jsh.output import tilde

BATCH = True
PRIORITY = 10
IGNORED = (".DS_Store",)


def check(args):
    if not isinstance(args, dict) or not all(isinstance(args.get(k), str) for k in ("from", "to")):
        raise ValueError("link needs from and to paths")
    if set(args) - {"from", "to", "tree"}:
        raise ValueError("link accepts from and to")


def units(step):
    return sum(1 for _ in pairs(step))


def pairs(step):
    source = Path(os.path.normpath(step.module.path / os.path.expanduser(step.args["from"])))
    target = Path(os.path.expanduser(step.args["to"]))
    if not step.args.get("tree") or not source.is_dir() or source.is_symlink():
        yield source, target
        return
    found = []
    for directory, folders, files in os.walk(source):
        here = Path(directory)
        for name in [name for name in folders if (here / name).is_symlink()] + files:
            if name not in IGNORED and not name.startswith(".zcompdump"):
                found.append(here / name)
    for path in sorted(found):
        yield path, target / path.relative_to(source)


def linked_parent(target):
    home = Path.home()
    for parent in target.parents:
        if parent in (home, Path("/")):
            return None
        if parent.is_symlink():
            return parent
    return None


def link(ctx, steps):
    backups = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    backups = backups / "jsh/backups" / f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    for step in steps:
        for source, target in pairs(step):
            place(ctx, source, target, backups)


def place(ctx, source, target, backups):
    label = tilde(target)
    if (target.is_symlink() and os.readlink(target) == str(source)) or (
        target.exists() and source.exists() and target.samefile(source)
    ):
        ctx.current()
        return
    if not source.exists():
        ctx.notice(f"{label}: {tilde(source)} is missing; run jsh install first")
        ctx.current()
        return
    parent = linked_parent(target)
    if parent:
        ctx.notice(f"{label} is under linked {tilde(parent)}; review it by hand")
        ctx.current()
        return
    stale = target.is_symlink() and str(system.ROOT) in os.readlink(target)
    if not ctx.dry_run:
        if stale:
            target.unlink()
        elif target.exists() or target.is_symlink():
            inside = Path.home() in target.parents
            backup = backups / (target.relative_to(Path.home()) if inside else target.name)
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(backup))
            ctx.write_log(f"backup {label} -> {tilde(backup)}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(source)
    if stale:
        ctx.changed(label)
    else:
        ctx.added(label)
