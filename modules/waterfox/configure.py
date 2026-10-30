"""Apply the macOS Waterfox policy, then write managed prefs into the default profile's user.js."""

import configparser
import json
import os
import re
from pathlib import Path

from jsh import apps, files, menu
from jsh.output import tilde

HERE = Path(__file__).resolve().parent
POLICY = Path("/Library/Preferences/net.waterfox.waterfox.plist")
BEGIN = "// BEGIN jsh preferences"
END = "// END jsh preferences"


def directories():
    home = Path.home()
    if apps.MACOS:
        return [home / "Library/Application Support/Waterfox"]
    return [home / ".waterfox", home / ".var/app/net.waterfox.waterfox/.waterfox"]


def default_profiles(directory):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(directory / "profiles.ini")
    defaults = [
        parser[section].get("Default")
        for section in parser.sections()
        if section.startswith("Install") and parser[section].get("Default")
    ]
    sections = [parser[section] for section in parser.sections() if section.startswith("Profile")]
    selected = [section for section in sections if section.get("Default") == "1"]
    if not selected and len(sections) == 1:
        selected = sections
    profile_defaults = [
        (
            Path(item["Path"]) if item.get("IsRelative", "1") != "1" else directory / item["Path"]
        ).resolve()
        for item in selected
    ]
    if defaults:
        install_defaults = list(dict.fromkeys((directory / path).resolve() for path in defaults))
        if len(install_defaults) > 1 and len(profile_defaults) == 1:
            if profile_defaults[0] in install_defaults:
                return profile_defaults
        return install_defaults
    return profile_defaults


def registered_profiles(directory):
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(directory / "profiles.ini")
    return [
        (
            section.get("Name", section.name),
            (
                (directory / section["Path"]).resolve()
                if section.get("IsRelative", "1") == "1"
                else Path(section["Path"]).resolve()
            ),
        )
        for section in (parser[key] for key in parser.sections() if key.startswith("Profile"))
        if section.get("Path")
    ]


def choose_profile(ctx):
    """Ask only on an interactive terminal; leave the spinner paused while reading."""
    choices = [
        (directory, name, path)
        for directory in directories()
        for name, path in registered_profiles(directory)
        if path.is_dir()
    ]
    if ctx.dry_run or not menu.available() or not ctx.display.stream.isatty() or not choices:
        ctx.notice("choose a profile from Waterfox about:profiles; rerun with "
                   "JSH_WATERFOX_PROFILE='name' jsh configure waterfox")
        return None
    display = ctx.display
    display.end()
    try:
        items = [(index, name, tilde(path)) for index, (_, name, path) in enumerate(choices)]
        display.stream.write("\033[?1049h")
        display.stream.flush()
        selected = menu.choose("Waterfox · Choose profile", items)
    finally:
        display.stream.write("\033[?1049l")
        display.stream.flush()
        display.begin(display.total)
    if selected is None:
        ctx.notice("profile selection skipped; Waterfox preferences were not changed")
        return None
    directory, _, path = choices[selected]
    return directory, path


def user_js(current, desired):
    """Replace the managed block and drop loose lines that set the same preferences."""
    keys = set(re.findall(r"^user_pref\(['\"]([^'\"]+)", desired, re.MULTILINE))
    current = re.sub(re.escape(BEGIN) + r"[\s\S]*?" + re.escape(END), "", current)
    keep = []
    for line in current.splitlines():
        match = re.match(r"user_pref\(['\"]([^'\"]+)", line)
        if not match or match[1] not in keys:
            keep.append(line)
    prefix = "\n".join(keep).rstrip()
    block = BEGIN + "\n" + desired + "\n" + END + "\n"
    return (prefix + "\n\n" if prefix else "") + block


def managed_prefs():
    """Managed user.js preferences followed by any local/waterfox/user.js additions."""
    managed = (HERE / "user.js").read_text().strip()
    extra = files.local("waterfox", "user.js").strip()
    return managed + ("\n" + extra if extra else "")


def configure(ctx):  # pylint: disable=too-many-branches
    flatpak = Path("/var/lib/flatpak/app/net.waterfox.waterfox")
    if not apps.present("waterfox", *directories(), flatpak, "/Applications/Waterfox.app"):
        return
    if apps.MACOS:
        desired = json.loads((HERE / "policies.json").read_text())
        desired = files.local_json("waterfox", "policies.json", desired)
        desired["EnterprisePoliciesEnabled"] = True
        apps.apply_policy(ctx, POLICY, desired, keep_unmanaged=True)
    requested = os.environ.get("JSH_WATERFOX_PROFILE")
    if requested:
        matches = [(directory, profile) for directory in directories()
                   for name, profile in registered_profiles(directory) if name == requested]
        if len(matches) != 1:
            ctx.notice("profile name must match exactly one profile in Waterfox about:profiles")
            return
    for directory in directories():
        if not (directory / "profiles.ini").exists():
            continue
        if requested and matches[0][0] != directory:
            continue
        profiles = [matches[0][1]] if requested else default_profiles(directory)
        if len(profiles) != 1 or not profiles[0].is_dir():
            choice = choose_profile(ctx)
            if choice is None:
                return
            directory, profile = choice
            profiles = [profile]
        target = profiles[0] / "user.js"
        current = target.read_text() if target.exists() else ""
        text = user_js(current, managed_prefs())
        if text == current:
            ctx.current()
            return
        if apps.MACOS:
            launch = ["open", "-a", "Waterfox"]
        elif ".var/app/net.waterfox.waterfox" in str(directory):
            launch = ["flatpak", "run", "net.waterfox.waterfox"]
        else:
            launch = ["waterfox"]
        with apps.closed_for_changes(
            ctx, "Waterfox", ("waterfox", "waterfox-bin", "Waterfox"), launch
        ) as ready:
            if ready:
                files.write(ctx, target, text)
        return
    ctx.notice("open Waterfox once to create a profile, then rerun: jsh configure waterfox")
