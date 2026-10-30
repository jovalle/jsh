"""Homebrew: `brew: {taps: [...], formulae: [...], casks: [...]}`.

Installs what is missing without upgrading anything; `jsh update` upgrades declared packages
that brew reports outdated. Casks are macOS-only; on Linux, formulae need Homebrew installed.
"""

import json
import os
import shutil

from jsh import system

BATCH = True
PRIORITY = 20
KINDS = ("taps", "formulae", "casks")
ENVIRONMENT = {
    "HOMEBREW_NO_AUTO_UPDATE": "1",
    "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    "HOMEBREW_NO_INSTALL_UPGRADE": "1",
    "HOMEBREW_NO_ENV_HINTS": "1",
    # Fail instead of hiding a password prompt behind the progress line.
    "SUDO_ASKPASS": "/usr/bin/false",
}


def check(args):
    if not isinstance(args, dict) or set(args) - set(KINDS):
        raise ValueError(f"brew accepts {', '.join(KINDS)}")
    for kind in KINDS:
        if not isinstance(args.get(kind, []), list):
            raise ValueError(f"brew {kind} must be a list")


def units(step):
    return sum(len(step.args.get(kind, [])) for kind in KINDS)


def wanted(ctx, steps):
    merged = {kind: [] for kind in KINDS}
    for step in steps:
        for kind in KINDS:
            merged[kind] += [name for name in step.args.get(kind, []) if name not in merged[kind]]
    if ctx.facts.platform != "darwin":
        merged["casks"] = []
    return merged


def ready(ctx, merged):
    if shutil.which("brew"):
        os.environ.update(ENVIRONMENT)
        return True
    if ctx.facts.platform == "darwin":
        raise RuntimeError("Install Homebrew first: https://brew.sh")
    if merged["formulae"] or merged["taps"]:
        ctx.notice("install Homebrew from https://brew.sh to add the shared tools")
    return False


def flag(kind):
    return "--formula" if kind == "formulae" else "--cask"


def missing(kind, names):
    current = set(system.query(["brew", "list", flag(kind), "-1"]).splitlines())
    if kind == "casks" and os.path.isdir("/Applications/Sublime Text.app"):
        current.add("sublime-text")
    absent = [name for name in names if name not in current]
    if not absent:
        return []
    # brew list omits aliases and renames, such as python for python@3.13.
    info = system.query(["brew", "info", "--json=v2", flag(kind), *absent])
    if not info:
        # Formulae from taps that a dry run has not added yet are unknown to brew.
        return absent
    for entry in json.loads(info)[kind]:
        if entry.get("installed"):
            current.update(entry.get("aliases", []) + entry.get("oldnames", []))
            current.update(entry.get("old_tokens", []))
            current.update(entry[key] for key in ("full_name", "full_token") if key in entry)
    return [name for name in absent if name not in current]


def install(ctx, steps):
    merged = wanted(ctx, steps)
    if not ready(ctx, merged):
        return
    taps = set(system.query(["brew", "tap"]).splitlines())
    for tap in merged["taps"]:
        if tap in taps:
            ctx.current()
        else:
            ctx.progress(f"tapping {tap}")
            ctx.run(["brew", "tap", tap])
            ctx.added(tap)
    failed = []
    for kind in ("formulae", "casks"):
        absent = missing(kind, merged[kind])
        ctx.current(len(merged[kind]) - len(absent))
        if absent:
            failed += add(ctx, kind, absent)
    if failed:
        raise RuntimeError(f"could not install {', '.join(failed)}")


def add(ctx, kind, names):
    """Install names in one brew call, retrying one by one to isolate failures."""
    ctx.progress(", ".join(names))
    try:
        ctx.run(["brew", "install", flag(kind), *names])
    except RuntimeError:
        failed = []
        for name in names:
            ctx.progress(name)
            try:
                ctx.run(["brew", "install", flag(kind), name])
            except RuntimeError:
                failed.append(name)
                continue
            ctx.added(name)
        return failed
    for name in names:
        ctx.added(name)
    return []


def update(ctx, steps):
    merged = wanted(ctx, steps)
    if not ready(ctx, merged):
        return
    ctx.progress("brew update")
    ctx.run(["brew", "update", "--quiet"])
    report = system.query(["brew", "outdated", "--json=v2"])
    outdated = json.loads(report) if report else {"formulae": [], "casks": []}
    for kind in ("formulae", "casks"):
        declared = set(merged[kind])
        stale = {}
        for entry in outdated.get(kind, []):
            names = {entry["name"], entry["name"].rsplit("/", 1)[-1]}
            if kind == "casks" and "sublime-text" in names:
                continue  # Preserve the patched application.
            match = next(iter(names & declared), None)
            if match:
                old = entry.get("installed_versions")
                old = old[-1] if isinstance(old, list) and old else old
                stale[match] = f"{match} {old} → {entry.get('current_version')}"
        ctx.current(len(declared) - len(stale))
        if stale:
            ctx.progress(", ".join(stale))
            ctx.run(["brew", "upgrade", flag(kind), *stale])
            for text in stale.values():
                ctx.changed(text)
