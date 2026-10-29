"""Apply the macOS Waterfox policy, then write managed prefs into the default profile's user.js."""

import configparser
import json
import re
from pathlib import Path

from jsh import apps, files

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
    if defaults:
        return list(dict.fromkeys((directory / path).resolve() for path in defaults))
    sections = [parser[section] for section in parser.sections() if section.startswith("Profile")]
    selected = [section for section in sections if section.get("Default") == "1"]
    if not selected and len(sections) == 1:
        selected = sections
    return [
        (
            Path(item["Path"]) if item.get("IsRelative", "1") != "1" else directory / item["Path"]
        ).resolve()
        for item in selected
    ]


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


def configure(ctx):
    flatpak = Path("/var/lib/flatpak/app/net.waterfox.waterfox")
    if not apps.present("waterfox", *directories(), flatpak, "/Applications/Waterfox.app"):
        return
    if apps.MACOS:
        desired = json.loads((HERE / "policies.json").read_text())
        desired["EnterprisePoliciesEnabled"] = True
        apps.apply_policy(ctx, POLICY, desired, keep_unmanaged=True)
    for directory in directories():
        if not (directory / "profiles.ini").exists():
            continue
        profiles = default_profiles(directory)
        if len(profiles) != 1 or not profiles[0].is_dir():
            ctx.notice("select one default profile in Waterfox first")
            return
        target = profiles[0] / "user.js"
        current = target.read_text() if target.exists() else ""
        text = user_js(current, (HERE / "user.js").read_text().strip())
        if text != current and apps.running("waterfox", "waterfox-bin", "Waterfox"):
            ctx.notice("close Waterfox, then rerun: jsh configure waterfox")
            return
        files.write(ctx, target, text)
        return
    ctx.notice("open Waterfox once to create a profile, then rerun: jsh configure waterfox")
