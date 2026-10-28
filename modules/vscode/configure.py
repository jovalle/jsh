"""Merge managed VS Code settings, pointing the integrated terminal at zsh when it is installed."""

import json
import os
import shutil
from pathlib import Path

from jsh import apps, files

HERE = Path(__file__).resolve().parent


def configure(ctx):
    if apps.MACOS:
        directory = Path.home() / "Library/Application Support/Code/User"
    else:
        config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
        directory = config / "Code/User"
    if not apps.present("code", directory):
        return
    desired = json.loads((HERE / "settings.json").read_text())
    shell = shutil.which("zsh")
    if shell:
        key = "osx" if apps.MACOS else "linux"
        desired[f"terminal.integrated.profiles.{key}"] = {"zsh": {"path": shell}}
        desired[f"terminal.integrated.defaultProfile.{key}"] = "zsh"
    files.update_json(ctx, directory / "settings.json", desired)
