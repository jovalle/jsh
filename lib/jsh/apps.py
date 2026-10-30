"""Helpers for app modules: detect installed or running apps and publish root-owned policies."""

import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from jsh import system

MACOS = sys.platform == "darwin"


def present(command, *paths):
    return bool(shutil.which(command)) or any(Path(path).exists() for path in paths)


def running(*names):
    return any(
        subprocess.run(["pgrep", "-x", name], check=False, capture_output=True).returncode == 0
        for name in names
    )


def install_root(path, data):
    """Publish a root-owned file; sudo -n fails instead of prompting."""
    (system.ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=system.ROOT / "tmp", delete=False) as stream:
        staged = Path(stream.name)
        stream.write(data)
    group = "wheel" if MACOS else "root"
    if MACOS and path.parent == Path("/Library/Preferences"):
        # cfprefsd caches this domain, so import through defaults instead of copying the file.
        commands = [["defaults", "import", str(path.with_suffix("")), str(staged)]]
    else:
        commands = [
            ["install", "-d", "-o", "root", "-g", group, "-m", "755", str(path.parent)],
            ["install", "-o", "root", "-g", group, "-m", "644", str(staged), str(path)],
        ]
    try:
        for command in commands:
            subprocess.run(system.privileged(command), check=True, capture_output=True)
    finally:
        staged.unlink()
    if MACOS:
        subprocess.run(["killall", "cfprefsd"], check=False, capture_output=True)


def apply_policy(ctx, path, desired, keep_unmanaged=False):
    """Replace managed policy keys; keep_unmanaged preserves keys jsh does not manage."""
    path = Path(path)
    if path.exists():
        current = plistlib.loads(path.read_bytes()) if MACOS else json.loads(path.read_text())
    else:
        current = {}
    updated = {**current, **desired} if keep_unmanaged else desired
    if current == updated:
        ctx.current()
        return
    if getattr(ctx, "user_only", False):
        ctx.defer_system()
        return
    if not ctx.dry_run:
        if not ctx.admin():
            ctx.notice(f"{path} needs sudo; run sudo -v first, then rerun")
            return
        data = plistlib.dumps(updated) if MACOS else (json.dumps(updated, indent=2) + "\n").encode()
        install_root(path, data)
    (ctx.changed if path.exists() else ctx.added)(str(path))
