"""Apply Helium's managed policy, merge preferences into its single default profile, and keep
any local/helium/unpacked.json extension directories loaded with developer mode on."""

import fcntl
import getpass
import hashlib
import hmac
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from jsh import apps, files, system
from jsh.output import tilde

HERE = Path(__file__).resolve().parent
BINARY = "/Applications/Helium.app/Contents/MacOS/Helium"
F_GETPATH = 50
UNPACKED = 4


def directory():
    if apps.MACOS:
        return Path.home() / "Library/Application Support/net.imput.helium"
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "helium"


def policy_path():
    if apps.MACOS:
        return Path("/Library/Managed Preferences") / getpass.getuser() / "net.imput.helium.plist"
    return Path("/etc/chromium/policies/managed/jsh-helium.json")


def unpacked_directories():
    text = files.local("helium", "unpacked.json")
    paths = [Path(os.path.expanduser(item)) for item in (files.jsonc(text) if text.strip() else [])]
    return [canonical(path) for path in paths if (path / "manifest.json").is_file()]


def canonical(path):
    """The on-disk spelling of a directory, which Chromium hashes into an unpacked extension ID."""
    descriptor = os.open(path, os.O_RDONLY)
    try:
        return fcntl.fcntl(descriptor, F_GETPATH, b"\0" * 1024).split(b"\0")[0].decode()
    finally:
        os.close(descriptor)


def extension_id(path):
    digest = hashlib.sha256(path.encode()).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def device_id():
    output = system.query(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
    match = re.search(r'"IOPlatformUUID" = "([^"]+)"', output)
    return match[1] if match else ""


def prune(value):
    if isinstance(value, dict):
        items = {key: prune(item) for key, item in value.items()}
        return {key: item for key, item in items.items() if item not in ({}, [])}
    if isinstance(value, list):
        return [prune(item) for item in value]
    return value


def mac(device, path, value):
    """Chromium's tracked-preference MAC: HMAC-SHA256 keyed by the (empty) seed."""
    text = json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
    message = device + path + text.replace("<", "\\u003C")
    return hmac.new(b"", message.encode(), hashlib.sha256).hexdigest().upper()


def unpacked_pending(secure, paths):
    data = json.loads(secure.read_text()) if secure.exists() else {}
    extensions = data.get("extensions", {})
    if paths and not extensions.get("ui", {}).get("developer_mode"):
        return True
    settings = extensions.get("settings", {})
    return any(
        settings.get(extension_id(path), {}).get("location") != UNPACKED
        or settings[extension_id(path)].get("path") != path
        for path in paths
    )


def unpacked_entries(paths):
    """Let a throwaway headless Helium load the directories and record their settings."""
    (system.ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=system.ROOT / "tmp") as scratch:
        subprocess.run(
            [
                BINARY,
                f"--user-data-dir={scratch}",
                "--no-first-run",
                "--headless=new",
                "--load-extension=" + ",".join(paths),
                "--dump-dom",
                "about:blank",
            ],
            check=False,
            capture_output=True,
            timeout=60,
        )
        secure = Path(scratch) / "Default/Secure Preferences"
        data = json.loads(secure.read_text()) if secure.exists() else {}
    settings = data.get("extensions", {}).get("settings", {})
    return {extension_id(path): settings.get(extension_id(path)) for path in paths}


def load_unpacked(ctx, secure, paths):
    entries = unpacked_entries(paths)
    broken = [path for path in paths if not entries[extension_id(path)]]
    for path in broken:
        ctx.notice(f"Helium could not load the unpacked extension in {path}")
    device = device_id()
    if not device or len(broken) == len(paths):
        return
    data = json.loads(secure.read_text()) if secure.exists() else {}
    extensions = data.setdefault("extensions", {})
    macs = data.setdefault("protection", {}).setdefault("macs", {}).setdefault("extensions", {})
    for key, entry in entries.items():
        if entry:
            entry = {**entry, "location": UNPACKED, "disable_reasons": []}
            extensions.setdefault("settings", {})[key] = entry
            macs.setdefault("settings", {})[key] = mac(
                device, f"extensions.settings.{key}", prune(entry)
            )
    extensions.setdefault("ui", {})["developer_mode"] = True
    macs.setdefault("ui", {})["developer_mode"] = mac(device, "extensions.ui.developer_mode", True)
    # Helium re-creates these OS-encrypted hashes from the MACs on its next start.
    macs.pop("settings_encrypted_hash", None)
    macs["ui"].pop("developer_mode_encrypted_hash", None)
    protection = data["protection"]
    protection.pop("super_encrypted_hash", None)
    protection["super_mac"] = mac(device, "", protection["macs"])
    files.write(ctx, secure, json.dumps(data, separators=(",", ":"), ensure_ascii=False))


def configure(ctx):  # pylint: disable=too-many-locals
    profile_root = directory()
    if not apps.present("helium", profile_root, "/Applications/Helium.app"):
        return
    policy = json.loads((HERE / "policy.json").read_text())
    policy = files.local_json("helium", "policy.json", policy)
    apps.apply_policy(ctx, policy_path(), policy)
    profiles = sorted(profile_root.glob("*/Preferences"))
    if not profiles:
        ctx.notice("open Helium once to create a profile, then rerun: jsh configure helium")
        return
    default = profile_root / "Default/Preferences"
    profiles = [default] if default in profiles else profiles
    if len(profiles) != 1:
        ctx.notice("several profiles and no Default profile; choose one by hand")
        return
    preferences = json.loads((HERE / "preferences.json").read_text())
    state = json.loads((HERE / "state.json").read_text())
    targets = [(profiles[0], preferences), (profile_root / "Local State", state)]
    pending = any(
        not path.exists()
        or files.merge(files.jsonc(path.read_text()), desired) != files.jsonc(path.read_text())
        for path, desired in targets
    )
    paths = unpacked_directories() if apps.MACOS else []
    secure = profiles[0].parent / "Secure Preferences"
    unpacked = bool(paths) and unpacked_pending(secure, paths)
    if not pending and not unpacked:
        ctx.current(2 + bool(paths))
        return
    launch = ["open", "-a", "Helium"] if apps.MACOS else ["helium"]
    with apps.closed_for_changes(
        ctx, "Helium", ("helium", "Helium", "helium-bin"), launch
    ) as ready:
        if ready:
            for path, desired in targets:
                files.update_json(ctx, path, desired)
            if unpacked and ctx.dry_run:
                ctx.changed(tilde(secure))
            elif unpacked:
                load_unpacked(ctx, secure, paths)
