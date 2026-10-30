"""AppImages from a GitHub release: `appimage: {name: NAME, release: API_URL, architectures: {}}`.

Installs into ~/.local/bin with a desktop entry, verified by the release asset's SHA-256 digest.
The installed digest is recorded so `jsh update` can replace only launchers jsh installed.
"""

import json
import os
import platform
import shutil
import tempfile
from pathlib import Path

from jsh import system, web
from jsh.output import tilde

BATCH = True
PRIORITY = 40
PLATFORMS = ("linux",)


def check(args):
    if (
        not isinstance(args, dict)
        or not isinstance(args.get("name"), str)
        or not isinstance(args.get("release"), str)
    ):
        raise ValueError("appimage needs name: and release:")


def state(name):
    base = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    return base / "jsh/appimage" / f"{name}.json"


def asset(args):
    machine = {"AMD64": "x86_64", "arm64": "aarch64"}.get(platform.machine(), platform.machine())
    if machine not in ("x86_64", "aarch64"):
        raise RuntimeError(f"{args['name']}: no AppImage for {machine}")
    wanted = args.get("architectures", {}).get(machine, machine)
    release = web.metadata(args["release"])
    found = [
        item for item in release["assets"] if item["name"].lower().endswith(f"-{wanted}.appimage")
    ]
    if len(found) != 1:
        raise RuntimeError(f"{args['name']}: expected one {wanted} AppImage in the release")
    return found[0]


def place(args, item):
    name = args["name"]
    destination = Path.home() / ".local/bin" / name
    digest = (item.get("digest") or "").removeprefix("sha256:")
    destination.parent.mkdir(parents=True, exist_ok=True)
    (system.ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jsh-", dir=system.ROOT / "tmp") as directory:
        temporary = Path(directory) / name
        web.download(item["browser_download_url"], temporary, digest)
        temporary.chmod(0o755)
        # Copy beside the destination, then publish atomically.
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
            staged = Path(stream.name)
        try:
            shutil.copy2(temporary, staged)
            staged.replace(destination)
        finally:
            staged.unlink(missing_ok=True)
    record = state(name)
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({"asset": item["name"], "digest": digest}) + "\n")
    data = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    entry = data / "applications" / f"jsh-{name}.desktop"
    entry.parent.mkdir(parents=True, exist_ok=True)
    executable = str(destination).replace("\\", "\\\\").replace('"', '\\"')
    executable = executable.replace("`", "\\`").replace("$", "\\$").replace("%", "%%")
    entry.write_text(
        f"[Desktop Entry]\nType=Application\nName={name.title()}\n"
        f'Exec="{executable}" %U\nTerminal=false\n'
    )


def install(ctx, steps):
    for step in steps:
        name = step.args["name"]
        if shutil.which(name):
            ctx.current()
            continue
        destination = Path.home() / ".local/bin" / name
        if destination.exists() or destination.is_symlink():
            raise RuntimeError(f"refusing to replace {tilde(destination)}")
        ctx.progress(f"downloading {name}")
        if not ctx.dry_run:
            place(step.args, asset(step.args))
        ctx.added(name)


def update(ctx, steps):
    for step in steps:
        name = step.args["name"]
        record = state(name)
        if not record.is_file():
            ctx.current()
            continue
        ctx.progress(f"checking {name}")
        item = asset(step.args)
        digest = (item.get("digest") or "").removeprefix("sha256:")
        if digest == json.loads(record.read_text())["digest"]:
            ctx.current()
            continue
        if not ctx.dry_run:
            place(step.args, item)
        ctx.changed(f"{name} → {item['name']}")
