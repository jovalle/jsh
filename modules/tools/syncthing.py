"""Keep Git metadata, dependencies, and machine-local jsh data out of Syncthing."""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from jsh import files


def query(ctx, *arguments):
    command = ["syncthing", "cli", *arguments]
    try:
        result = subprocess.run(
            command, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False,
            timeout=15,
        )
    except subprocess.TimeoutExpired as error:
        ctx.write_log(f"{' '.join(command)} timed out")
        raise RuntimeError("could not read Syncthing configuration") from error
    if result.returncode:
        ctx.write_log(f"{' '.join(command)}: {result.stderr.strip()}")
        raise RuntimeError("could not read Syncthing configuration")
    return result.stdout.strip()


def configure(ctx):
    if not shutil.which("syncthing"):
        ctx.current()
        return
    try:
        folders = query(ctx, "config", "folders", "list").splitlines()
        defaults = json.loads(query(ctx, "config", "defaults", "ignores", "dump-json"))["lines"]
        paths = [query(ctx, "config", "folders", folder, "path", "get") for folder in folders]
    except RuntimeError:
        ctx.notice("start Syncthing and run jsh configure tools to protect synced folders")
        return

    common = [".git", "node_modules"]
    desired = common + [line for line in defaults if line not in common]
    if defaults == desired:
        ctx.current()
    else:
        if not ctx.dry_run:
            scratch = ctx.root / "tmp"
            scratch.mkdir(exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", dir=scratch, encoding="utf-8") as stream:
                stream.write("\n".join(desired) + "\n")
                stream.flush()
                ctx.run(["syncthing", "cli", "operations", "default-ignores", stream.name])
        ctx.changed("Syncthing default ignores")

    for raw in paths:
        folder = Path(raw).expanduser()
        if not folder.is_dir():
            ctx.notice(f"Syncthing folder is unavailable: {folder}")
            continue
        ignore = folder / ".stignore"
        text = ignore.read_text(encoding="utf-8") if ignore.exists() else ""
        rules = common.copy()
        if folder.resolve() == ctx.root.resolve():
            rules += ["/local/", "/tmp/"]
        lines = text.splitlines()
        if lines[: len(rules)] != rules:
            text = "\n".join(rules) + "\n" + text
        files.write(ctx, ignore, text)
