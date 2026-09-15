#!/usr/bin/env python3
"""Inspect and install the pinned native Debian desktop application catalog."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

from jsh_output import emit

ROOT = Path(__file__).resolve().parents[1]


def command(args, **kwargs):
    """Run an argv without a shell; propagate errors including failed probes."""
    return subprocess.run(args, text=True, check=True, **kwargs)


def root(args, **kwargs):
    return command(([] if os.geteuid() == 0 else ["sudo", "--"]) + args, **kwargs)


def load_catalog(path):
    data = json.loads(path.read_text())
    if data.get("schema") != 1 or not isinstance(data.get("apps"), list):
        raise ValueError("Invalid application catalog")
    seen = set()
    for app in data["apps"]:
        if app["id"] in seen or not re.fullmatch(r"[a-z][a-z0-9-]*", app["id"]):
            raise ValueError("Invalid or duplicate application ID")
        seen.add(app["id"])
        if app["kind"] not in ("deb", "tar") or app["arch"] != "amd64":
            raise ValueError("Unsupported artifact type or architecture")
        if not re.fullmatch(r"[a-f0-9]{64}", app["sha256"]):
            raise ValueError("Missing artifact checksum")
        if not app["url"].startswith("https://"):
            raise ValueError("Artifacts require HTTPS")
        if not re.fullmatch(r"[0-9][a-zA-Z0-9.+:~-]*", app["version"]):
            raise ValueError("Invalid application version")
    return data["apps"]


def inspect(app):
    """Package versions are minimums: preserve newer security updates."""
    if app["kind"] == "deb":
        result = subprocess.run(
            ["dpkg-query", "-W", "-f=${db:Status-Status}\t${Version}", app["package"]],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr)
        fields = result.stdout.split("\t")
        if result.returncode or not fields or fields[0] != "installed":
            return "install", "missing"
        installed = fields[1]
        satisfied = subprocess.run(
            ["dpkg", "--compare-versions", installed, "ge", app["version"]],
            check=False,
        ).returncode
        if satisfied not in (0, 1):
            raise RuntimeError("Could not compare package versions")
        return ("unchanged" if satisfied == 0 else "upgrade"), installed
    destination = Path("/opt/jsh") / ("waterfox-" + app["version"])
    launcher = Path("/usr/local/bin/waterfox")
    if not (destination / "waterfox").is_file():
        return "install", "missing"
    result = command([str(destination / "waterfox"), "--version"], capture_output=True, timeout=20)
    if result.stdout.strip() != "BrowserWorks Waterfox " + app["version"]:
        return "repair", "version mismatch"
    if launcher.resolve() != destination / "waterfox":
        return "repair", "launcher mismatch"
    return "unchanged", app["version"]


def download(app, cache):
    suffix = ".deb" if app["kind"] == "deb" else ".tar.bz2"
    target = cache / (app["sha256"] + suffix)
    if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == app["sha256"]:
        return target
    cache.mkdir(parents=True, exist_ok=True)
    url = app["url"]
    if app["id"] == "citrix":
        # Citrix attaches expiring download tokens. Resolve only the pinned filename.
        page = (
            urllib.request.urlopen(
                "https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html",
                timeout=30,
            )
            .read()
            .decode()
        )
        match = re.search(
            r'rel="(//downloads[.]citrix[.]com/[^"?]*'
            + re.escape(url.rsplit("/", 1)[1])
            + r'[^\"]*)"',
            page,
        )
        if not match:
            raise RuntimeError("Pinned Citrix artifact is no longer published; refresh the catalog")
        url = "https:" + match.group(1)
    temporary = target.with_suffix(target.suffix + ".partial")
    try:
        command(
            [
                "curl",
                "--fail",
                "--location",
                "--retry",
                "2",
                "--connect-timeout",
                "20",
                "--max-time",
                "600",
                "--output",
                str(temporary),
                url,
            ]
        )
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != app["sha256"]:
            raise RuntimeError("Checksum mismatch for " + app["id"])
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def install(app, artifact):
    if app["kind"] == "deb":
        for field, expected in [
            ("Package", app["package"]),
            ("Architecture", app["arch"]),
            ("Version", app["version"]),
        ]:
            actual = command(
                ["dpkg-deb", "-f", str(artifact), field], capture_output=True
            ).stdout.strip()
            if actual != expected:
                raise RuntimeError("Unexpected package " + field)
        if app["id"] == "citrix":
            root(
                ["debconf-set-selections"],
                input="icaclient app_protection/install_app_protection select no\n",
            )
        root(["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", str(artifact)])
        return
    destination = Path("/opt/jsh") / ("waterfox-" + app["version"])
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix="jsh-waterfox-") as directory:
            with tarfile.open(artifact) as archive:
                # Validate even authenticated archives before delegating extraction.
                for member in archive.getmembers():
                    path = Path(member.name)
                    if path.is_absolute() or ".." in path.parts or path.parts[0] != "waterfox":
                        raise ValueError("Unsafe archive path")
                    if member.issym() or member.islnk():
                        link = Path(member.linkname)
                        if link.is_absolute() or ".." in link.parts:
                            raise ValueError("Unsafe archive link")
                command(["tar", "-xjf", str(artifact), "-C", directory])
            root(["install", "-d", "-m", "0755", "/opt/jsh"])
            staging = str(destination) + ".stage-" + str(os.getpid())
            try:
                root(["cp", "-a", str(Path(directory) / "waterfox"), staging])
                root(["chown", "-R", "root:root", staging])
                root(["mv", staging, str(destination)])
            finally:
                if Path(staging).exists():
                    root(["rm", "-rf", "--", staging])
    launcher = Path("/usr/local/bin/waterfox")
    if launcher.exists() and not launcher.is_symlink():
        raise RuntimeError("Unmanaged Waterfox launcher exists: " + str(launcher))
    if launcher.resolve() != destination / "waterfox":
        root(["install", "-d", "-m", "0755", "/usr/local/bin"])
        root(["ln", "-sfn", str(destination / "waterfox"), str(launcher)])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "apply", "check"))
    parser.add_argument("--only", help="Comma-separated application IDs")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if sys.platform != "linux" or not shutil.which("dpkg-query"):
        parser.error("This catalog currently supports Debian-family Linux")
    arch = command(["dpkg", "--print-architecture"], capture_output=True).stdout.strip()
    apps = load_catalog(ROOT / "conf/apps/debian.json")
    selected = set(args.only.split(",")) if args.only else {a["id"] for a in apps}
    unknown = selected - {a["id"] for a in apps}
    if unknown:
        parser.error("Unknown application(s): " + ", ".join(sorted(unknown)))
    apps = [a for a in apps if a["id"] in selected]
    if any(a["arch"] != arch for a in apps):
        parser.error("No native application artifacts defined for " + arch)
    rows = []
    for app in apps:
        action, current = inspect(app)
        rows.append(dict(id=app["id"], action=action, installed=current, desired=app["version"]))
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for row in rows:
            emit(
                "note" if row["action"] == "unchanged" else "info",
                f"{row['action']:10} {row['id']:12} {row['installed']} -> {row['desired']}",
            )
    if args.action != "apply":
        return int(args.action == "check" and any(r["action"] != "unchanged" for r in rows))
    pending = [a for a, r in zip(apps, rows) if r["action"] != "unchanged"]
    if not pending:
        return 0
    if not args.yes and os.environ.get("JSH_ASSUME_YES") != "1":
        if not sys.stdin.isatty():
            parser.error("Noninteractive apply requires --yes")
        if input("Apply these application changes? [y/N] ").lower() not in ("y", "yes"):
            return 0
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "jsh"
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "jsh/apps"
    state.mkdir(parents=True, exist_ok=True)
    with (state / "apps.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Authenticate before downloading or modifying the machine.
        if os.geteuid() != 0:
            command(
                ["sudo", "-v" if sys.stdin.isatty() else "-n", "true"]
                if not sys.stdin.isatty()
                else ["sudo", "-v"]
            )
        artifacts = {a["id"]: download(a, cache) for a in pending}
        with (state / "apps.jsonl").open("a") as journal:
            for app in pending:
                event = dict(id=app["id"], time=time.time(), version=app["version"])
                try:
                    # Another run may have converged while our plan was displayed.
                    if inspect(app)[0] != "unchanged":
                        install(app, artifacts[app["id"]])
                    if inspect(app)[0] != "unchanged":
                        raise RuntimeError("Application verification failed: " + app["id"])
                    event["status"] = "verified"
                except Exception:
                    event["status"] = "failed"
                    raise
                finally:
                    journal.write(json.dumps(event) + "\n")
                    journal.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("jsh applications: " + str(error), file=sys.stderr)
        sys.exit(1)
