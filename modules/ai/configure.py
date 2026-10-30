"""Merge managed OpenCode and Codex settings, keeping every other setting."""

import os
import re
from pathlib import Path

from jsh import apps, files

CODEX = {"check_for_update_on_startup": "true"}


def opencode(ctx):
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    directory = config / "opencode"
    if apps.present("opencode", directory):
        desired = {"$schema": "https://opencode.ai/config.json", "autoupdate": True}
        files.update_json(ctx, directory / "opencode.json", desired)


def toml_keys(text, keys):
    """Set top-level TOML keys, placing new ones before the first table."""
    lines = text.splitlines()
    end = next((i for i, line in enumerate(lines) if line.lstrip().startswith("[")), len(lines))
    while end and not lines[end - 1].strip():
        end -= 1
    for key, value in keys.items():
        pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
        match = next((i for i in range(end) if pattern.match(lines[i])), None)
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
    files.write(ctx, path, toml_keys(current, CODEX))


def configure(ctx):
    opencode(ctx)
    codex(ctx)
