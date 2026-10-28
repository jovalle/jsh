"""Apply Helium's managed policy, then merge preferences into its single default profile."""

import getpass
import json
import os
from pathlib import Path

from jsh import apps, files

HERE = Path(__file__).resolve().parent


def directory():
    if apps.MACOS:
        return Path.home() / "Library/Application Support/net.imput.helium"
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "helium"


def policy_path():
    if apps.MACOS:
        return Path("/Library/Managed Preferences") / getpass.getuser() / "net.imput.helium.plist"
    return Path("/etc/chromium/policies/managed/jsh-helium.json")


def configure(ctx):
    profile_root = directory()
    if not apps.present("helium", profile_root, "/Applications/Helium.app"):
        return
    apps.apply_policy(ctx, policy_path(), json.loads((HERE / "policy.json").read_text()))
    if apps.running("helium", "Helium", "helium-bin"):
        ctx.notice("close Helium, then rerun: jsh configure helium")
        return
    profiles = sorted(profile_root.glob("*/Preferences"))
    if not profiles:
        ctx.notice("open Helium once to create a profile, then rerun: jsh configure helium")
        return
    default = profile_root / "Default/Preferences"
    profiles = [default] if default in profiles else profiles
    if len(profiles) != 1:
        ctx.notice("several profiles and no Default profile; choose one by hand")
        return
    files.update_json(ctx, profiles[0], json.loads((HERE / "preferences.json").read_text()))
    state = json.loads((HERE / "state.json").read_text())
    files.update_json(ctx, profile_root / "Local State", state)
