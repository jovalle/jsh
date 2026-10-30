"""File helpers for handlers and module scripts: backed-up writes and JSON settings merges."""

import copy
import json
import os
import re
import stat
import tempfile
import time
from pathlib import Path

from jsh import system
from jsh.output import tilde

STAMP = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"


def backups():
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    return state / "jsh/backups" / STAMP


def write(ctx, path, text, mode=None):
    """Replace a user file atomically after backing it up; report it as current or changed."""
    path = Path(path)
    data = text.encode() if isinstance(text, str) else text
    if path.is_file() and path.read_bytes() == data:
        ctx.current()
        return False
    existed = path.exists() or path.is_symlink()
    if not ctx.dry_run:
        home = Path.home()
        for parent in path.parents:
            if parent == home:
                break
            if parent.is_symlink():
                raise ValueError(f"symlinked directory needs manual review: {tilde(parent)}")
        if mode is None:
            mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        if existed:
            inside = home in path.parents
            backup = backups() / (path.relative_to(home) if inside else path.name)
            backup.parent.mkdir(parents=True, exist_ok=True)
            if path.is_symlink():
                backup.symlink_to(os.readlink(path))
            else:
                backup.write_bytes(path.read_bytes())
            ctx.write_log(f"backup {tilde(path)} -> {tilde(backup)}")
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        try:
            temporary.chmod(mode)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    (ctx.changed if existed else ctx.added)(tilde(path))
    return True


def jsonc(text):
    """Parse JSON that may contain comments and trailing commas."""
    tokens = r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*[\s\S]*?\*/'
    plain = re.sub(tokens, lambda match: match[0] if match[0].startswith('"') else " ", text)
    plain = re.sub(r'("(?:[^"\\]|\\.)*")|,\s*(?=[}\]])', lambda match: match[1] or "", plain)
    return json.loads(plain)


def merge(current, desired):
    if not isinstance(current, dict) or not isinstance(desired, dict):
        raise ValueError("settings must be JSON objects")
    result = copy.deepcopy(current)
    for key, value in desired.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def update_json(ctx, path, desired):
    """Merge desired keys into a JSON(C) settings file, keeping every other setting."""
    path = Path(path)
    current = jsonc(path.read_text()) if path.exists() else {}
    updated = merge(current, desired)
    if path.exists() and current == updated:
        ctx.current()
        return False
    return write(ctx, path, json.dumps(updated, indent=2, ensure_ascii=False) + "\n")


def local(module, name):
    """Return the text of an optional machine-local overlay at local/MODULE/NAME, or ""."""
    path = system.ROOT / "local" / module / name
    return path.read_text() if path.is_file() else ""


def local_json(module, name, desired):
    """Deep-merge an optional local/MODULE/NAME JSON overlay into desired."""
    text = local(module, name)
    return merge(desired, jsonc(text)) if text.strip() else desired
