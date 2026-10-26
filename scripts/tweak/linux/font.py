#!/usr/bin/env python3
"""Install verified JetBrains Mono Nerd Font files on Linux."""

import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DRY_RUN = os.environ.get("JSH_DRY_RUN") == "1"
sys.path.insert(0, str(ROOT / "lib"))
import output  # pylint: disable=import-error,wrong-import-position


def metadata(url):
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "jsh"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url, target, digest):
    if not url.startswith("https://"):
        raise ValueError("Downloads require HTTPS")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("A SHA-256 digest is required for the font download")
    request = urllib.request.Request(url, headers={"User-Agent": "jsh"})
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as stream:
        shutil.copyfileobj(response, stream, length=1024 * 1024)
    checksum = hashlib.sha256()
    with target.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    if checksum.hexdigest() != digest:
        raise ValueError("Font download checksum mismatch")


def manifest():
    path = Path(os.environ.get("JSH_FONT_MANIFEST", ROOT / "conf/fonts.json"))
    spec = json.loads(path.read_text(encoding="utf-8"))
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", spec.get("repository", "")):
        raise ValueError(f"Invalid font manifest: {path}")
    if not re.fullmatch(r"[^/]+[.]tar[.]xz", spec.get("asset", "")):
        raise ValueError(f"Invalid font manifest: {path}")
    files = spec.get("files", [])
    if not files or any(not re.fullmatch(r"[^/]+[.]ttf", name) for name in files):
        raise ValueError(f"Invalid font manifest: {path}")
    return spec


def latest_asset(spec, destination):
    try:
        release = metadata(f"https://api.github.com/repos/{spec['repository']}/releases/latest")
    except (OSError, urllib.error.URLError):
        if all((destination / name).is_file() for name in spec["files"]):
            output.warn(
                f"Could not check {spec['repository']} for updates; keeping installed fonts."
            )
            return None
        raise
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == spec["asset"]]
    if len(assets) != 1:
        raise ValueError(f"Could not resolve {spec['asset']} in the latest release")
    return assets[0]


def publish_font(bundle, destination, name):
    source = bundle.extractfile(name)
    if source is None:
        raise ValueError(f"Font archive does not contain {name}")
    content = source.read()
    target = destination / name
    if target.is_file() and target.read_bytes() == content:
        output.current(name)
        return False
    with tempfile.NamedTemporaryFile(dir=destination, delete=False) as stream:
        staged = Path(stream.name)
        stream.write(content)
    try:
        staged.chmod(0o644)
        staged.replace(target)
    finally:
        staged.unlink(missing_ok=True)
    output.item(name)
    return True


def install_fonts():
    spec = manifest()
    destination = Path(
        os.environ.get(
            "JSH_FONT_DIR",
            Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "fonts/jsh",
        )
    )
    if DRY_RUN:
        output.note(
            f"would install the latest {spec['asset']} from {spec['repository']}: "
            + " ".join(spec["files"])
        )
        output.count("to update", len(spec["files"]))
        return

    asset = latest_asset(spec, destination)
    if asset is None:
        return
    digest = (asset.get("digest") or "").removeprefix("sha256:")
    destination.mkdir(parents=True, exist_ok=True)
    (ROOT / "tmp").mkdir(exist_ok=True)
    changed = []
    with tempfile.TemporaryDirectory(prefix="fonts.", dir=ROOT / "tmp") as directory:
        archive = Path(directory) / spec["asset"]
        download(asset.get("browser_download_url", ""), archive, digest)
        with tarfile.open(archive, "r:xz") as bundle:
            for name in spec["files"]:
                if publish_font(bundle, destination, name):
                    changed.append(name)
    if changed:
        if shutil.which("fc-cache"):
            output.run(["fc-cache", str(destination)])
        output.count("updated", len(changed))


if __name__ == "__main__":
    try:
        with output.Step("fonts"):
            install_fonts()
    except (KeyError, OSError, ValueError, json.JSONDecodeError, tarfile.TarError) as error:
        output.error(str(error))
        sys.exit(1)
