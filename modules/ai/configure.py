"""Merge managed OpenCode and Codex settings, keeping every other setting, and let Codex's
browser extension reach its native host from Helium."""

import json
import os
import re
from pathlib import Path

from jsh import apps, files

CODEX = {"check_for_update_on_startup": "true"}
CODEX_DESKTOP = {
    "open-link-in-target-preference": '"external-browser"',
    "open-local-url-in-target-preference": '"external-browser"',
}


def opencode(ctx):
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    directory = config / "opencode"
    if apps.present("opencode", directory):
        desired = {"$schema": "https://opencode.ai/config.json", "autoupdate": True}
        files.update_json(ctx, directory / "opencode.json", desired)


def toml_keys(text, keys, table=None):
    """Set TOML keys at the top level or in one table, placing new ones after its last key."""
    lines = text.splitlines()
    start = 0
    if table is not None:
        header = f"[{table}]"
        start = next((i + 1 for i, line in enumerate(lines) if line.strip() == header), None)
        if start is None:
            while lines and not lines[-1].strip():
                lines.pop()
            lines += ["", header] if lines else [header]
            start = len(lines)
    end = next(
        (i for i in range(start, len(lines)) if lines[i].lstrip().startswith("[")), len(lines)
    )
    while end > start and not lines[end - 1].strip():
        end -= 1
    for key, value in keys.items():
        pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
        match = next((i for i in range(start, end) if pattern.match(lines[i])), None)
        if match is None:
            lines.insert(end, f"{key} = {value}")
            end += 1
        else:
            lines[match] = f"{key} = {value}"
    return "\n".join(lines) + "\n"


def codex(ctx):
    path = Path.home() / ".codex/config.toml"
    if not apps.present("codex", path):
        return
    current = path.read_text() if path.exists() else ""
    text = toml_keys(toml_keys(current, CODEX), CODEX_DESKTOP, "desktop")
    files.write(ctx, path, text)


def helium_host(ctx):
    """Register Codex's browser extension host with Helium, mirroring the one it gives Chrome."""
    helium = Path.home() / "Library/Application Support/net.imput.helium"
    registry = Path.home() / ".codex/chrome-native-hosts-v2.json"
    if not apps.MACOS or not helium.is_dir() or not registry.is_file():
        return
    entries = json.loads(registry.read_text()).get("entries", [])
    if not entries:
        return
    entry = max(entries, key=lambda item: item.get("updatedAt", ""))
    for name in entry.get("nativeHostNames", []):
        manifest = {
            "allowed_origins": [f"chrome-extension://{i}/" for i in entry["extensionIds"]],
            "description": "ChatGPT browser native messaging host",
            "name": name,
            "path": entry["paths"]["extensionHostPath"],
            "type": "stdio",
        }
        path = helium / "NativeMessagingHosts" / f"{name}.json"
        files.write(ctx, path, json.dumps(manifest, indent=2) + "\n", mode=0o644)


def configure(ctx):
    opencode(ctx)
    codex(ctx)
    helium_host(ctx)
