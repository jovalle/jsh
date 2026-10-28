"""Merge managed preferences into Sublime Text's user settings once it has run."""

import json
import os
from pathlib import Path

from jsh import apps, files

HERE = Path(__file__).resolve().parent


def configure(ctx):
    home = Path.home()
    if apps.MACOS:
        directory = home / "Library/Application Support/Sublime Text"
    else:
        flatpak = home / ".var/app/com.sublimetext.three/config/sublime-text"
        config = Path(os.environ.get("XDG_CONFIG_HOME", str(home / ".config")))
        directory = flatpak if flatpak.is_dir() else config / "sublime-text"
    installed = (
        "/Applications/Sublime Text.app",
        "/var/lib/flatpak/app/com.sublimetext.three",
        home / ".var/app/com.sublimetext.three",
    )
    if not apps.present("subl", directory, *installed):
        return
    if not directory.is_dir():
        ctx.notice("open Sublime Text once, then rerun: jsh configure sublime")
        return
    desired = json.loads((HERE / "preferences.json").read_text())
    files.update_json(ctx, directory / "Packages/User/Preferences.sublime-settings", desired)
