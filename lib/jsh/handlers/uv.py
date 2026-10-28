"""Python command-line tools from PyPI: `uv: {command: package, ...}`.

Installs with `uv tool install` (pip --user without uv) when the command is missing;
`jsh update` runs `uv tool upgrade` for declared packages that uv manages.
"""

import re
import shutil
import sys

from jsh import system
from jsh.handlers import _native

BATCH = True
PRIORITY = 50
units = _native.units
tools = _native.mapping


def check(args):
    if not isinstance(args, dict) or not all(isinstance(value, str) for value in args.values()):
        raise ValueError("uv expects command: package pairs")


def install(ctx, steps):
    failed = []
    for command, package in tools(steps).items():
        if shutil.which(command):
            ctx.current()
            continue
        ctx.progress(package)
        if shutil.which("uv"):
            arguments = ["uv", "tool", "install", package]
        else:
            arguments = [sys.executable, "-m", "pip", "install", "--user", package]
        try:
            ctx.run(arguments)
        except RuntimeError:
            failed.append(package)
            continue
        ctx.added(command)
    if failed:
        raise RuntimeError(f"could not install {', '.join(failed)}")


def versions():
    found = {}
    for line in system.query(["uv", "tool", "list"]).splitlines():
        match = re.match(r"^(\S+) v(\S+)", line)
        if match:
            found[match[1]] = match[2]
    return found


def update(ctx, steps):
    declared = tools(steps)
    if not shutil.which("uv"):
        ctx.current(len(declared))
        return
    before = versions()
    managed = [package for package in declared.values() if package in before]
    ctx.current(len(declared) - len(managed))
    for package in managed:
        ctx.progress(package)
        ctx.run(["uv", "tool", "upgrade", package])
    after = versions()
    for package in managed:
        if after.get(package, before[package]) != before[package]:
            ctx.changed(f"{package} {before[package]} → {after[package]}")
        else:
            ctx.current()
