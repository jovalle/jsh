"""Select one role's packages for the platform being configured."""

from __future__ import annotations

MANAGERS = ("taps", "brew", "casks", "mas", "apt", "dnf", "flatpak", "uv", "appimage")
ONLY = {"casks": "darwin", "mas": "darwin", "apt": "debian", "dnf": "rhel"}


def packages(spec: dict, platform: str, extra: dict | None = None) -> dict:
    """Merge the all, linux, and platform entries of spec, then of extra, by manager.

    Lists append in that order without duplicates. Managers that only exist on another
    platform (casks and mas on macOS, apt on Debian, dnf on RHEL) are dropped.
    """
    keys = ["all"]
    if platform != "darwin":
        keys.append("linux")
    if platform not in keys:
        keys.append(platform)
    selected: dict = {}
    for source in (spec or {}, extra or {}):
        for key in keys:
            for manager, entries in (source.get(key) or {}).items():
                if manager not in MANAGERS:
                    raise ValueError(f"unknown package manager: {manager}")
                merged = selected.setdefault(manager, [])
                for entry in entries or []:
                    if entry not in merged:
                        merged.append(entry)
    return {manager: entries for manager, entries in selected.items()
            if entries and ONLY.get(manager, platform) == platform}


class FilterModule:
    def filters(self):
        return {"packages": packages}
