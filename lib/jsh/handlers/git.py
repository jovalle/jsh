"""Shallow clones under local/vendor: `git: {path: url, ...}`.

`jsh update` fast-forwards each clone to its remote HEAD; vendored clones are never edited.
"""

import os

from jsh import system
from jsh.handlers import _native

BATCH = True
PRIORITY = 60
units = _native.units
repositories = _native.mapping


def check(args):
    if not isinstance(args, dict) or not all(isinstance(url, str) for url in args.values()):
        raise ValueError("git expects path: url pairs")
    for path in args:
        if path.startswith("/") or ".." in path.split("/"):
            raise ValueError(f"git path must stay under local/vendor: {path}")


def install(ctx, steps):
    for path, url in repositories(steps).items():
        target = system.ROOT / "local/vendor" / path
        if (target / ".git").exists():
            ctx.current()
            continue
        ctx.progress(f"cloning {path}")
        ctx.run(["git", "clone", "--quiet", "--depth", "1", "--", url, target])
        ctx.added(path)


def update(ctx, steps):
    os.environ["GIT_TERMINAL_PROMPT"] = "0"
    for path in repositories(steps):
        target = system.ROOT / "local/vendor" / path
        if not (target / ".git").exists():
            ctx.current()
            continue
        ctx.progress(path)
        local = system.query(["git", "-C", str(target), "rev-parse", "HEAD"])
        remote = system.query(["git", "-C", str(target), "ls-remote", "origin", "HEAD"])
        remote = remote.split("\t")[0]
        if not remote or remote == local:
            ctx.current()
            continue
        ctx.run(["git", "-C", target, "fetch", "--quiet", "--depth", "1", "origin", "HEAD"])
        ctx.run(["git", "-C", target, "reset", "--quiet", "--hard", "FETCH_HEAD"])
        ctx.changed(f"{path} {local[:7]} → {remote[:7]}")
