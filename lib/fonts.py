#!/usr/bin/env python3
"""Install the pinned JetBrains Mono Nerd Font without rewriting matching files."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
from application_config import ensure_file
from apps import download
from jsh_output import emit

ROOT = Path(__file__).resolve().parents[1]


def main():
    spec = json.loads((ROOT / "conf/fonts.json").read_text())
    destination = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "fonts/jsh"
    missing = [
        name
        for name, digest in spec["files"].items()
        if not (destination / name).is_file()
        or hashlib.sha256((destination / name).read_bytes()).hexdigest() != digest
    ]
    if not missing:
        emit("note", "JetBrains Mono Nerd Font is current.")
        return
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "jsh/fonts"
    cache.mkdir(parents=True, exist_ok=True)
    archive = download(spec, cache)
    with tarfile.open(archive) as tar:
        for name in missing:
            content = tar.extractfile(name).read()
            if hashlib.sha256(content).hexdigest() != spec["files"][name]:
                raise ValueError("Font checksum mismatch: " + name)
            ensure_file(destination / name, content)
    subprocess.run(["fc-cache", str(destination)], check=True)
    emit("success", "JetBrains Mono Nerd Font installed.")


if __name__ == "__main__":
    main()
