"""Select packages for the platform being configured."""

from __future__ import annotations

MANAGERS = ("taps", "brew", "casks", "mas", "apt", "dnf", "flatpak", "uv", "appimage")
ONLY = {"casks": "darwin", "mas": "darwin", "apt": "debian", "dnf": "rhel"}
SELECTORS = ("all", "linux", "darwin", "debian", "rhel", "xfce", "gnome")


def _merge(sources: list[dict], platform: str, desktop: str) -> dict:
    """Merge each source's all, linux, platform, then desktop entries by manager.

    Lists append in that order without duplicates. Managers that only exist on another
    platform (casks and mas on macOS, apt on Debian, dnf on RHEL) are dropped.
    """
    keys = ["all"]
    if platform != "darwin":
        keys.append("linux")
    for key in (platform, desktop):
        if key and key not in keys:
            keys.append(key)
    selected: dict = {}
    for source in sources:
        for key in source or {}:
            if key not in SELECTORS:
                raise ValueError(f"unknown package selector: {key}")
        for key in keys:
            for manager, entries in ((source or {}).get(key) or {}).items():
                if manager not in MANAGERS:
                    raise ValueError(f"unknown package manager: {manager}")
                merged = selected.setdefault(manager, [])
                for entry in entries or []:
                    if entry not in merged:
                        merged.append(entry)
    return {manager: entries for manager, entries in selected.items()
            if entries and ONLY.get(manager, platform) == platform}


def packages(spec: dict, platform: str, extra: dict | None = None, desktop: str = "") -> dict:
    """Merge spec, then extra, for the platform and desktop."""
    return _merge([spec, extra or {}], platform, desktop)


def packages_selection(platform: str, desktop: str, tags: list, common: dict, roles: dict,
                       extra: dict | None = None, roles_extra: dict | None = None) -> dict:
    """Select every package for a full run, or only the packages of the roles in tags.

    A run that selects all tags or the packages tag installs common, every role's packages,
    then the host's extra and per-role extras. Otherwise only the tagged roles' packages and
    their per-role extras are installed.
    """
    roles = roles or {}
    roles_extra = roles_extra or {}
    for name in roles_extra:
        if name not in roles:
            raise ValueError(f"unknown package role: {name}")
    everything = bool({"all", "packages"} & set(tags or []))
    owners = list(roles) if everything else [name for name in roles if name in (tags or [])]
    sources = [common or {}] if everything else []
    sources += [roles[name] for name in owners]
    sources += [extra or {}] if everything else []
    sources += [roles_extra[name] for name in owners if name in roles_extra]
    return _merge(sources, platform, desktop)


class FilterModule:
    def filters(self):
        return {"packages": packages, "packages_selection": packages_selection}
