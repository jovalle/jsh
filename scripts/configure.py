#!/usr/bin/env python3
"""Apply managed preferences while preserving unrelated application settings."""

import configparser
import copy
import getpass
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", str(HOME / ".config")))
DRY_RUN = os.environ.get("JSH_DRY_RUN") == "1"
MACOS = sys.platform == "darwin"
BACKUP = Path(os.environ.get("XDG_STATE_HOME", str(HOME / ".local/state")))
BACKUP = BACKUP / "jsh/backups" / f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
sys.path.insert(0, str(ROOT / "lib"))
import output  # pylint: disable=import-error,wrong-import-position


def write(path, text):
    if path.exists() and path.read_text() == text:
        output.current(output.tilde(path))
        return
    if DRY_RUN:
        output.count("to update")
        output.item(output.tilde(path))
        return
    for parent in path.parents:
        if parent == HOME:
            break
        if parent.is_symlink():
            raise ValueError(f"Symlinked app directory requires manual review: {parent}")
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    if path.exists() or path.is_symlink():
        relative = path.relative_to(HOME)
        backup = BACKUP / relative
        backup.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink():
            backup.symlink_to(os.readlink(path))
        else:
            shutil.copy2(path, backup)
        output.note(f"backup {output.tilde(backup)}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(text)
    try:
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    output.item(output.tilde(path))
    output.count("updated")


def jsonc(text):
    # Preserve strings while stripping JSONC comments, then trailing commas.
    tokens = r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/'
    plain = re.sub(tokens, lambda match: match[0] if match[0].startswith('"') else " ", text)
    plain = re.sub(r'("(?:[^"\\]|\\.)*")|,\s*(?=[}\]])', lambda match: match[1] or "", plain)
    return json.loads(plain)


def merge(current, desired):
    if not isinstance(current, dict) or not isinstance(desired, dict):
        raise ValueError("Application settings must be JSON objects")
    result = copy.deepcopy(current)
    for key, value in desired.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def update_json(path, desired):
    current = jsonc(path.read_text()) if path.exists() else {}
    updated = merge(current, desired)
    if path.exists() and current == updated:
        output.current(output.tilde(path))
        return
    write(path, json.dumps(updated, indent=2, ensure_ascii=False) + "\n")


def policy_path(app):
    if app == "waterfox":
        return Path("/Library/Preferences/net.waterfox.waterfox.plist")
    if MACOS:
        return Path("/Library/Managed Preferences") / getpass.getuser() / "net.imput.helium.plist"
    return Path("/etc/chromium/policies/managed/jsh-helium.json")


def install_root(path, data):
    """Publish a root-owned policy file; sudo -n fails instead of prompting."""
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=ROOT / "tmp", delete=False) as stream:
        staged = Path(stream.name)
        stream.write(data)
    sudo = [] if os.geteuid() == 0 else ["sudo", "-n", "--"]
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
            subprocess.run([*sudo, *command], check=True, capture_output=True)
    finally:
        staged.unlink()
    if MACOS:
        subprocess.run(["killall", "cfprefsd"], check=False, capture_output=True)


def apply_policy(path, desired, keep_unmanaged=False):
    """Replace managed policy keys; keep_unmanaged preserves keys jsh does not manage."""
    if path.exists():
        current = plistlib.loads(path.read_bytes()) if MACOS else json.loads(path.read_text())
    else:
        current = {}
    updated = {**current, **desired} if keep_unmanaged else desired
    if current == updated:
        output.current(str(path))
        return
    if DRY_RUN:
        output.count("to update")
        output.item(str(path))
        return
    data = plistlib.dumps(updated) if MACOS else (json.dumps(updated, indent=2) + "\n").encode()
    try:
        install_root(path, data)
    except subprocess.CalledProcessError:
        output.attention(f"{path} needs sudo; run sudo -v, then rerun just configure")
        output.count("issues")
        return
    output.item(str(path))
    output.count("updated")


def running(*names):
    for name in names:
        process = subprocess.run(
            ["pgrep", "-x", name], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        if process.returncode == 0:
            return True
    return False


def present(command, *paths):
    return bool(shutil.which(command)) or any(path.exists() for path in paths)


def helium():
    directory = (
        HOME / "Library/Application Support/net.imput.helium" if MACOS else CONFIG / "helium"
    )
    if not present("helium", directory, Path("/Applications/Helium.app")):
        output.skip("not installed")
        return
    apply_policy(policy_path("helium"), json.loads((ROOT / "conf/helium/policy.json").read_text()))
    if running("helium", "Helium", "helium-bin"):
        output.skip("close the browser and rerun just configure helium")
        return
    profiles = sorted(directory.glob("*/Preferences"))
    if not profiles:
        output.skip("open it once to create a profile, then rerun configure")
        return
    desired = json.loads((ROOT / "conf/helium/preferences.json").read_text())
    default = directory / "Default/Preferences"
    profiles = [default] if default in profiles else profiles
    if len(profiles) != 1:
        output.skip("multiple profiles without a Default profile; choose one manually")
        return
    update_json(profiles[0], desired)
    update_json(
        directory / "Local State", json.loads((ROOT / "conf/helium/state.json").read_text())
    )


def default_waterfox_profiles(directory):
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
            directory / item["Path"] if item.get("IsRelative", "1") == "1" else Path(item["Path"])
        ).resolve()
        for item in selected
    ]


def waterfox():
    directories = (
        [HOME / "Library/Application Support/Waterfox"]
        if MACOS
        else [HOME / ".waterfox", HOME / ".var/app/net.waterfox.waterfox/.waterfox"]
    )
    flatpak = Path("/var/lib/flatpak/app/net.waterfox.waterfox")
    if not present("waterfox", *directories, flatpak, Path("/Applications/Waterfox.app")):
        output.skip("not installed")
        return
    if MACOS:
        desired = json.loads((ROOT / "conf/gecko/policies.json").read_text())
        desired["EnterprisePoliciesEnabled"] = True
        apply_policy(policy_path("waterfox"), desired, keep_unmanaged=True)
    if running("waterfox", "waterfox-bin", "Waterfox"):
        output.skip("close the browser and rerun just configure waterfox")
        return
    for directory in directories:
        if not (directory / "profiles.ini").exists():
            continue
        profiles = default_waterfox_profiles(directory)
        if len(profiles) != 1 or not profiles[0].is_dir():
            output.skip("select one default profile in the browser first")
            return
        desired = (ROOT / "conf/gecko/waterfox.js").read_text().strip()
        keys = set(re.findall(r"^user_pref\(['\"]([^'\"]+)", desired, re.MULTILINE))
        target = profiles[0] / "user.js"
        current = target.read_text() if target.exists() else ""
        begin = "// BEGIN jsh preferences"
        end = "// END jsh preferences"
        current = re.sub(re.escape(begin) + r"[\s\S]*?" + re.escape(end), "", current)
        keep = []
        for line in current.splitlines():
            match = re.match(r"user_pref\(['\"]([^'\"]+)", line)
            if not match or match[1] not in keys:
                keep.append(line)
        prefix = "\n".join(keep).rstrip()
        block = begin + "\n" + desired + "\n" + end + "\n"
        write(target, (prefix + "\n\n" if prefix else "") + block)
        return
    output.skip("initialize a default profile, then rerun configure")


def vscode():
    directory = HOME / "Library/Application Support/Code/User" if MACOS else CONFIG / "Code/User"
    if not present("code", directory):
        output.skip("not installed")
        return
    desired = json.loads((ROOT / "conf/vscode/settings.json").read_text())
    shell = shutil.which("zsh")
    if shell:
        key = "osx" if MACOS else "linux"
        desired[f"terminal.integrated.profiles.{key}"] = {"zsh": {"path": shell}}
        desired[f"terminal.integrated.defaultProfile.{key}"] = "zsh"
    update_json(directory / "settings.json", desired)


def sublime():
    if MACOS:
        directory = HOME / "Library/Application Support/Sublime Text"
    else:
        flatpak = HOME / ".var/app/com.sublimetext.three/config/sublime-text"
        directory = flatpak if flatpak.is_dir() else CONFIG / "sublime-text"
    apps = (
        Path("/Applications/Sublime Text.app"),
        Path("/var/lib/flatpak/app/com.sublimetext.three"),
        HOME / ".var/app/com.sublimetext.three",
    )
    if not present("subl", directory, *apps):
        output.skip("not installed")
        return
    if not directory.is_dir():
        output.skip("open Sublime Text once, then rerun configure")
        return
    desired = json.loads((ROOT / "conf/sublime/preferences.json").read_text())
    update_json(directory / "Packages/User/Preferences.sublime-settings", desired)


def main(name):
    apps = {
        "helium": helium,
        "waterfox": waterfox,
        "vscode": vscode,
        "sublime": sublime,
    }
    for label, app in apps.items():
        if name in ("all", label):
            with output.Step(label):
                app()


if __name__ == "__main__":
    try:
        main(sys.argv[1] if len(sys.argv) > 1 else "all")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        output.error(str(error))
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
