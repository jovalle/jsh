"""Build a separate XFCE audio plugin with the Wave:3 indicator in its button."""

import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from jsh import apps, system, web

HERE = Path(__file__).resolve().parent / "audio"
VERSION = "0.4.9"
ARCHIVE = f"xfce4-pulseaudio-plugin_{VERSION}.orig.tar.bz2"
URL = f"https://deb.debian.org/debian/pool/main/x/xfce4-pulseaudio-plugin/{ARCHIVE}"
SHA256 = "a0807615fb2848d0361b7e4568a44f26d189fda48011c7ba074986c8bfddc99a"
DESKTOP = Path("/usr/share/xfce4/panel/plugins/jsh-pulseaudio.desktop")
STOCK_DESKTOP = Path("/usr/share/xfce4/panel/plugins/pulseaudio.desktop")


def configure(ctx):
    if ctx.facts.host != "colossus" or ctx.facts.platform != "debian":
        ctx.current()
        return
    if not shutil.which("pkg-config") or not STOCK_DESKTOP.is_file():
        ctx.notice("XFCE audio plugin build prerequisites are missing; run jsh install desktop")
        return
    libdir = subprocess.run(
        ["pkg-config", "--variable=libdir", "libxfce4panel-2.0"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    if not libdir:
        ctx.notice("XFCE audio plugin build prerequisites are missing; run jsh install desktop")
        return
    library = Path(libdir) / "xfce4/panel/plugins/libjsh-pulseaudio.so"
    patch = (HERE / "pulseaudio.patch").read_bytes()
    fingerprint = hashlib.sha256(patch + SHA256.encode()).hexdigest()
    stock = STOCK_DESKTOP.read_text()
    descriptor = stock.replace("X-XFCE-Module=pulseaudio-plugin", "X-XFCE-Module=jsh-pulseaudio")
    if descriptor == stock:
        raise ValueError("unrecognized XFCE audio plugin descriptor")
    descriptor += f"\nX-Jsh-Fingerprint={fingerprint}\n"
    if library.is_file() and DESKTOP.is_file() and DESKTOP.read_text() == descriptor:
        ctx.current()
        return
    if apps.defer(ctx):
        return
    existed = library.exists() or DESKTOP.exists()
    if not ctx.dry_run:
        if not ctx.admin():
            ctx.notice("XFCE audio plugin needs sudo; run sudo -v first, then rerun")
            return
        scratch = system.ROOT / "tmp"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            directory = Path(directory)
            archive = directory / ARCHIVE
            web.download(URL, archive, SHA256)
            # The archive is pinned by digest; tar extracts only this known upstream release.
            with tarfile.open(archive, "r:bz2") as source:
                source.extractall(directory)
            root = directory / f"xfce4-pulseaudio-plugin-{VERSION}"
            ctx.run(["patch", "-p1", "-i", HERE / "pulseaudio.patch"], cwd=root)
            ctx.run(["./configure", "--prefix=/usr", f"--libdir={libdir}"], cwd=root)
            ctx.run(["make", "-j2"], cwd=root)
            built = root / "panel-plugin/.libs/libpulseaudio-plugin.so"
            staged = library.with_name(f".{library.name}.{os.getpid()}.tmp")
            apps.install_root(staged, built.read_bytes())
            ctx.run(["mv", "-f", str(staged), str(library)], root=True)
            apps.install_root(DESKTOP, descriptor.encode())
        if existed and shutil.which("xfce4-panel") and system.query(["pgrep", "-x", "xfce4-panel"]):
            ctx.run(["xfce4-panel", "-r"], check=False)
    (ctx.changed if existed else ctx.added)("XFCE Wave:3 audio plugin")
