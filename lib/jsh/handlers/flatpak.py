"""Flathub apps for the current user: `flatpak: [app.id, ...]`.

Needs the flatpak command (install it with an apt or dnf step); `jsh update` updates declared apps.
"""

import shutil
import subprocess

from jsh import system
from jsh.handlers import _native

BATCH = True
PRIORITY = 30
PLATFORMS = ("linux",)
REMOTE = "https://flathub.org/repo/flathub.flatpakrepo"
check = _native.check
units = _native.units


def present(app):
    return any(
        subprocess.run(["flatpak", "info", scope, app], check=False, capture_output=True).returncode
        == 0
        for scope in ("--user", "--system")
    )


def wanted(ctx, steps):
    apps = []
    for step in steps:
        apps += [app for app in step.args if app not in apps]
    if not shutil.which("flatpak"):
        ctx.notice(f"flatpak is missing; skipped {', '.join(apps)}")
        return []
    return apps


def install(ctx, steps):
    apps = wanted(ctx, steps)
    absent = [app for app in apps if not present(app)]
    ctx.current(len(apps) - len(absent))
    if not absent:
        return
    ctx.run(["flatpak", "remote-add", "--user", "--if-not-exists", "flathub", REMOTE])
    for app in absent:
        ctx.progress(app)
        ctx.run(["flatpak", "install", "--user", "--noninteractive", "-y", "flathub", app])
        ctx.added(app)


def update(ctx, steps):
    apps = wanted(ctx, steps)
    listing = system.query(["flatpak", "remote-ls", "--updates", "--columns=application"])
    stale = [app for app in apps if app in listing.splitlines()]
    ctx.current(len(apps) - len(stale))
    if stale:
        ctx.progress(", ".join(stale))
        ctx.run(["flatpak", "update", "--noninteractive", "-y", *stale])
        for app in stale:
            ctx.changed(app)
