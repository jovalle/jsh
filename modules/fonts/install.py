"""Install the JetBrains Mono Nerd Font files on Linux from the latest verified release."""

import json
import os
import re
import shutil
import tarfile
import tempfile
from pathlib import Path

from jsh import system, web

HERE = Path(__file__).resolve().parent


def spec():
    data = json.loads((HERE / "fonts.json").read_text())
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", data.get("repository", "")):
        raise ValueError("fonts.json: invalid repository")
    if not re.fullmatch(r"[^/]+[.]tar[.]xz", data.get("asset", "")):
        raise ValueError("fonts.json: invalid asset")
    if not data.get("files") or any(not re.fullmatch(r"[^/]+[.]ttf", n) for n in data["files"]):
        raise ValueError("fonts.json: invalid files")
    return data


def destination():
    data = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    return data / "fonts/jsh"


def install(ctx, refresh=False):  # pylint: disable=too-many-locals
    data = spec()
    target = destination()
    if not refresh and all((target / name).is_file() for name in data["files"]):
        ctx.current()
        return
    ctx.progress(f"downloading {data['asset']}")
    if ctx.dry_run:
        (ctx.changed if refresh else ctx.added)(data["id"])
        return
    release = web.metadata(f"https://api.github.com/repos/{data['repository']}/releases/latest")
    assets = [item for item in release.get("assets", []) if item.get("name") == data["asset"]]
    if len(assets) != 1:
        raise ValueError(f"could not find {data['asset']} in the latest release")
    digest = (assets[0].get("digest") or "").removeprefix("sha256:")
    target.mkdir(parents=True, exist_ok=True)
    (system.ROOT / "tmp").mkdir(exist_ok=True)
    changed = []
    with tempfile.TemporaryDirectory(prefix="fonts.", dir=system.ROOT / "tmp") as directory:
        archive = Path(directory) / data["asset"]
        web.download(assets[0]["browser_download_url"], archive, digest)
        with tarfile.open(archive, "r:xz") as bundle:
            for name in data["files"]:
                source = bundle.extractfile(name)
                if source is None:
                    raise ValueError(f"the font archive lacks {name}")
                content = source.read()
                if (target / name).is_file() and (target / name).read_bytes() == content:
                    continue
                with tempfile.NamedTemporaryFile(dir=target, delete=False) as stream:
                    staged = Path(stream.name)
                    stream.write(content)
                staged.chmod(0o644)
                staged.replace(target / name)
                changed.append(name)
    if changed and shutil.which("fc-cache"):
        ctx.run(["fc-cache", target])
    if changed:
        (ctx.changed if refresh else ctx.added)(f"{data['id']} ({len(changed)} files)")
    else:
        ctx.current()


def update(ctx):
    install(ctx, refresh=True)
