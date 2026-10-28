"""Facts about this machine and command execution for handlers."""

import os
import platform as _platform
import shlex
import shutil
import subprocess
import sys
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class Facts:
    """What `when:` conditions match against."""

    def __init__(self, platform=None, desktop=None, host=None):
        self.platform = platform or detect_platform()
        self.family = "darwin" if self.platform == "darwin" else "linux"
        self.desktop = detect_desktop() if desktop is None else desktop
        self.host = host or os.environ.get("JSH_HOST") or _platform.node().split(".")[0].lower()

    def matches(self, when):
        """True when every key in `when` lists (or equals) this machine's value."""
        for key, wanted in (when or {}).items():
            values = wanted if isinstance(wanted, list) else [wanted]
            values = [str(value) for value in values]
            if key == "platform":
                if self.platform not in values and self.family not in values:
                    return False
            elif key in ("desktop", "host"):
                if getattr(self, key) not in values:
                    return False
            else:
                raise ValueError(f"unknown when: key {key!r}")
        return True


def detect_platform():
    if sys.platform == "darwin":
        return "darwin"
    if not sys.platform.startswith("linux"):
        raise RuntimeError("Supported platforms: macOS, Debian-family Linux, RHEL-family Linux.")
    release = {}
    with open("/etc/os-release", encoding="utf-8") as stream:
        for line in stream:
            key, _, value = line.strip().partition("=")
            release[key] = value.strip("\"'")
    family = f" {release.get('ID', '')} {release.get('ID_LIKE', '')} "
    if " debian " in family or " ubuntu " in family:
        return "debian"
    if any(f" {name} " in family for name in ("rhel", "fedora", "centos", "rocky", "almalinux")):
        return "rhel"
    raise RuntimeError(f"Unsupported Linux distribution: {release.get('ID', 'unknown')}")


def detect_desktop():
    if sys.platform == "darwin":
        return "darwin"
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return ""
    session = os.environ.get("JSH_DESKTOP") or (
        os.environ.get("XDG_CURRENT_DESKTOP", "") + ":" + os.environ.get("DESKTOP_SESSION", "")
    )
    return next((name for name in ("xfce", "gnome") if name in session.lower()), "")


@lru_cache(maxsize=None)
def admin():
    """True when root commands can run without a password prompt."""
    if os.geteuid() == 0:
        return True
    if not shutil.which("sudo"):
        return False
    result = subprocess.run(["sudo", "-n", "true"], check=False, capture_output=True)
    return result.returncode == 0


def privileged(arguments):
    return list(arguments) if os.geteuid() == 0 else ["sudo", "-n", "--", *arguments]


def query(arguments, check=False):
    """Run a read-only command and return its stripped stdout ('' when it fails)."""
    try:
        result = subprocess.run(
            arguments, check=check, text=True, capture_output=True, stdin=subprocess.DEVNULL
        )
    except FileNotFoundError:
        if check:
            raise
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def quoted(arguments):
    return shlex.join(str(argument) for argument in arguments)
