"""Install the official VS Code .deb or .rpm on Linux, verified by its published SHA-256."""

import platform
import shutil
import tempfile
from pathlib import Path

from jsh import apps, system, web

METADATA = "https://update.code.visualstudio.com/api/update/linux-{channel}-{arch}/stable/latest"


def install(ctx):
    manager = "apt" if ctx.facts.platform == "debian" else "dnf"
    query = ["dpkg-query", "-W", "code"] if manager == "apt" else ["rpm", "-q", "code"]
    if shutil.which("code") or system.query(query):
        ctx.current()
        return
    arch = {"x86_64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    if not arch:
        raise RuntimeError("VS Code requires x86_64 or aarch64")
    if apps.defer(ctx):
        return
    if not ctx.dry_run and not ctx.admin():
        ctx.notice("needs sudo to install the VS Code package; run sudo -v first, then rerun")
        return
    channel = "deb" if manager == "apt" else "rpm"
    ctx.progress("downloading vscode")
    if not ctx.dry_run:
        release = web.metadata(METADATA.format(channel=channel, arch=arch))
        (system.ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="vscode-", dir=system.ROOT / "tmp") as directory:
            package = Path(directory) / f"vscode.{channel}"
            web.download(release["url"], package, release["sha256hash"])
            ctx.progress("installing vscode")
            if manager == "apt":
                ctx.run(["apt-get", "install", "--no-upgrade", "-y", package], root=True)
            else:
                ctx.run(["dnf", "install", "-y", package], root=True)
    ctx.added("vscode")
