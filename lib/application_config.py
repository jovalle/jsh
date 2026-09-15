#!/usr/bin/env python3
"""Reconcile application configuration without replacing personal settings."""

import configparser
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import stat
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def desktop_executable(path):
    """Avoid unnecessary quotes: xdg-utils cannot resolve a quoted first word."""
    value = str(path)
    if re.fullmatch(r"[/A-Za-z0-9_.+-]+", value):
        return value
    return '"' + "".join("\\" + c if c in '\\"`$' else c for c in value) + '"'


def ensure_file(path, content, mode=0o644, dry_run=False):
    """Compare bytes and mode; backup then atomically replace only changed files."""
    if path.is_symlink():
        if path.read_bytes() == content:
            return False
        raise ValueError("Refusing to replace an unmanaged symlink: " + str(path))
    if path.exists() and path.read_bytes() == content and stat.S_IMODE(path.stat().st_mode) == mode:
        return False
    print(("Would write " if dry_run else "Writing ") + str(path))
    if dry_run:
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = (
            Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "jsh/backups"
        )
        backup = backup / str(time.time_ns()) / path.relative_to(path.anchor)
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copy2(path, backup)
        backup.chmod(0o600)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".jsh-")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


def configure_code_shell(destination, dry_run=False):
    shell = shutil.which("zsh")
    if not shell:
        return
    settings = destination / "settings.json"
    current = json.loads(settings.read_text()) if settings.exists() else {}
    desired = json.loads(json.dumps(current))
    platform_name = "osx" if sys.platform == "darwin" else "linux"
    profiles = desired.setdefault("terminal.integrated.profiles." + platform_name, {})
    profile = profiles.setdefault("zsh", {})
    if profile is None:
        profile = profiles["zsh"] = {}
    if profile.get("path") not in ("zsh", shell):
        profile["path"] = shell
    desired["terminal.integrated.defaultProfile." + platform_name] = "zsh"
    if desired != current:
        ensure_file(settings, (json.dumps(desired, indent=2) + "\n").encode(), dry_run=dry_run)


def configure_helium_launcher(desktop, launcher=ROOT / "bin/helium", dry_run=False):
    ensure_file(
        desktop / "helium.desktop",
        (
            "[Desktop Entry]\nType=Application\nName=Helium\n"
            "Exec=" + desktop_executable(launcher) + " launch -- %U\n"
            "Icon=helium\nCategories=Network;WebBrowser;\n"
            "MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;\n"
            "StartupNotify=true\nStartupWMClass=Helium\n"
        ).encode(),
        dry_run=dry_run,
    )


def main():
    dry = os.environ.get("JSH_CONFIGURE_DRY_RUN") == "1" or "--dry-run" in sys.argv
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    desktop = data / "applications"
    if sys.platform == "linux" and Path("/usr/bin/helium").is_file():
        configure_helium_launcher(desktop, dry_run=dry)
    if sys.platform == "linux" and shutil.which("waterfox"):
        system_launcher = Path("/usr/local/bin/waterfox")
        binary = (
            system_launcher.resolve()
            if system_launcher.exists()
            else Path(shutil.which("waterfox")).resolve()
        )
        if not (home / ".waterfox").exists():
            source = home / ".var/app/net.waterfox.waterfox/.waterfox"
            if source.exists():
                print("Copying existing Flatpak Waterfox profile to native location")
                if not dry:
                    shutil.copytree(
                        source,
                        home / ".waterfox",
                        ignore=shutil.ignore_patterns("lock", ".parentlock", "parent.lock"),
                    )
        launcher = binary
        registry = configparser.ConfigParser()
        registry.read(home / ".waterfox/profiles.ini")
        installs = configparser.ConfigParser()
        installs.read(home / ".waterfox/installs.ini")
        preferred = next(
            (installs[s].get("Default") for s in installs.sections() if installs[s].get("Default")),
            None,
        )
        profile_name = next(
            (
                registry[s].get("Name")
                for s in registry.sections()
                if s.startswith("Profile") and registry[s].get("Path") == preferred
            ),
            None,
        )
        if profile_name:
            launcher = home / ".local/bin/waterfox"
            script = (
                "#!/bin/sh\n# Keep the migrated, managed profile across native application upgrades.\n"
                'for argument in "$@"; do\n'
                '  case "$argument" in -P|-profile|--profile|-ProfileManager|--ProfileManager)\n'
                "    exec " + shlex.quote(str(binary)) + ' "$@" ;;\n  esac\ndone\n'
                "exec " + shlex.quote(str(binary)) + " -P " + shlex.quote(profile_name) + ' "$@"\n'
            )
            ensure_file(launcher, script.encode(), 0o755, dry_run=dry)
        ensure_file(
            desktop / "waterfox.desktop",
            (
                "[Desktop Entry]\nType=Application\nName=Waterfox\n"
                "Exec=" + desktop_executable(launcher) + " %u\n"
                "Icon=" + str(binary.parent / "browser/chrome/icons/default/default128.png") + "\n"
                "Categories=Network;WebBrowser;\nMimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;\n"
                "StartupNotify=true\n"
            ).encode(),
            dry_run=dry,
        )
    if shutil.which("code"):
        destination = (
            config / "Code/User"
            if sys.platform == "linux"
            else home / "Library/Application Support/Code/User"
        )
        source = home / ".var/app/com.visualstudio.code/config/Code/User"
        for filename in ("settings.json",):
            if (source / filename).exists() and not (destination / filename).exists():
                ensure_file(destination / filename, (source / filename).read_bytes(), dry_run=dry)
        configure_code_shell(destination, dry_run=dry)
        bindings = destination / "keybindings.json"
        desired = json.loads((ROOT / "dotfiles/.config/Code/User/keybindings.json").read_text())
        try:
            current = json.loads(bindings.read_text()) if bindings.exists() else []
        except json.JSONDecodeError as error:
            raise ValueError(
                "Existing VS Code keybindings use JSONC; merge the managed binding manually: "
                + str(bindings)
            ) from error
        if not isinstance(current, list):
            raise ValueError("Expected a keybindings array: " + str(bindings))
        # Preserve bindings outside the managed key/when pair.
        merged = [
            b
            for b in current
            if not any(
                b.get("key") == d.get("key") and b.get("when") == d.get("when") for d in desired
            )
        ] + desired
        if merged != current:
            ensure_file(bindings, (json.dumps(merged, indent=2) + "\n").encode(), dry_run=dry)
    if sys.platform == "linux":
        for name, native_name in [("fd", "fdfind"), ("bat", "batcat")]:
            executable = shutil.which(native_name)
            if executable and not shutil.which(name):
                ensure_file(
                    home / ".local/bin" / name,
                    ('#!/bin/sh\nexec "' + executable + '" "$@"\n').encode(),
                    0o755,
                    dry_run=dry,
                )
        for app_id, native in [
            ("net.waterfox.waterfox", "waterfox"),
            ("com.visualstudio.code", "code"),
        ]:
            if shutil.which(native):
                # Hide duplicate menus; retain the original installation and its data.
                ensure_file(
                    desktop / (app_id + ".desktop"),
                    b"[Desktop Entry]\nType=Application\nHidden=true\n",
                    dry_run=dry,
                )
        if shutil.which("flatpak"):
            ensure_file(
                home / ".local/bin/spotify",
                b'#!/bin/sh\nexec flatpak run com.spotify.Client "$@"\n',
                0o755,
                dry_run=dry,
            )
    if sys.platform == "linux" and (desktop / "waterfox.desktop").is_file():
        from desktop_defaults import configure_browser

        configure_browser(dry_run=dry)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
