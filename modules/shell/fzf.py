"""Install the fzf binary that matches the vendored fzf checkout's pinned version."""

import re

from jsh import system


def install(ctx):
    directory = system.ROOT / "local/vendor/fzf"
    script = directory / "install"
    if not script.exists():
        ctx.current()
        return
    pinned = re.search(r"^version=(\S+)", script.read_text(), re.MULTILINE)
    binary = directory / "bin/fzf"
    current = system.query([str(binary), "--version"]) if binary.exists() else ""
    if pinned and current.split(" ")[0] == pinned.group(1):
        ctx.current()
        return
    ctx.progress("fzf binary")
    ctx.run([script, "--bin"])
    if current:
        ctx.changed(f"fzf {current.split(' ')[0]} → {pinned.group(1) if pinned else 'latest'}")
    else:
        ctx.added("fzf")


update = install
