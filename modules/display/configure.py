"""Pick desktop-density resolutions on macOS; bind the ultrawide split toggle on Linux X11."""

import os
import shutil
from pathlib import Path

from jsh import desktop, system
from jsh.system import query

HERE = Path(__file__).resolve().parent


def mac(ctx):
    if not shutil.which("displayplacer") or not query(["xcrun", "--find", "swift"]):
        return
    profile = query(["xcrun", "swift", str(HERE / "resolution.swift")])
    arguments = []
    for line in profile.splitlines():
        fields = line.split("\t")
        if len(fields) != 11:
            raise ValueError("unexpected display resolution profile")
        if fields[3:6] == fields[7:10]:
            ctx.current()
            continue
        arguments.append(fields[0])
        ctx.write_log(f"{fields[1]} ({fields[2]}): {fields[3]} -> {fields[7]} logical")
    if arguments:
        desktop.apply(ctx, "display resolutions", ["displayplacer", *arguments])


def configure(ctx):
    if ctx.facts.desktop == "darwin":
        mac(ctx)
        return
    if os.environ.get("XDG_SESSION_TYPE", "x11") == "wayland" or not shutil.which("xrandr"):
        return
    command = f"bash {system.ROOT}/modules/display/toggle.sh toggle"
    keys = ("<Control><Alt><Super>m", "<Primary><Alt><Super>m")
    desktop.shortcut(ctx, "Jsh display layout", *keys, command)
