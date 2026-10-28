"""GNOME Shell extensions: install pinned builds for the running shell, then enable them."""

import json
import os
import shutil
import tempfile
from pathlib import Path

from jsh import desktop, system, web

HERE = Path(__file__).resolve().parent


def data():
    return json.loads((HERE / "extensions.json").read_text())


def roots():
    base = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    return base / "gnome-shell/extensions", Path("/usr/share/gnome-shell/extensions")


def present(uuid):
    return any((root / uuid).is_dir() for root in roots())


def install(ctx):
    if not shutil.which("gnome-extensions"):
        return
    shell = system.query(["gnome-shell", "--version"]).split()[-1].split(".")[0]
    for uuid, builds in data()["install"].items():
        if present(uuid):
            ctx.current()
            continue
        build = next((build for build in builds if shell in build["shells"]), None)
        if build is None:
            ctx.notice(f"{uuid}: no pinned build for GNOME Shell {shell}")
            continue
        ctx.progress(f"downloading {uuid}")
        if not ctx.dry_run:
            (system.ROOT / "tmp").mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="jsh-", dir=system.ROOT / "tmp") as directory:
                archive = Path(directory) / "extension.zip"
                web.download(build["url"], archive, build["sha256"])
                ctx.run(["gnome-extensions", "install", "--force", archive])
        ctx.added(uuid)
        ctx.notice("log out and back in so GNOME Shell loads new extensions")


def configure(ctx):
    spec = data()
    enabled = desktop.gnome_list("org.gnome.shell", "enabled-extensions")
    wanted = list(enabled)
    for uuid in spec["enable"]:
        if not present(uuid):
            ctx.notice(f"{uuid} is not installed; run: jsh install desktop")
        elif uuid not in wanted:
            wanted.append(uuid)
    if wanted == enabled:
        ctx.current()
    else:
        label = "GNOME extensions"
        desktop.gsetting(ctx, "org.gnome.shell", "enabled-extensions", str(wanted), label)
    desktop.gsetting(ctx, "org.gnome.shell", "disable-user-extensions", "false")
    schemas = roots()[0] / "Vitals@CoreCoding.com/schemas"
    if schemas.is_dir():
        vitals = "org.gnome.shell.extensions.vitals"
        desktop.gsetting(ctx, vitals, "hot-sensors", spec["vitals"], "Vitals sensors", schemas)
