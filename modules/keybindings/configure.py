"""Apply keyboard settings and custom shortcuts from keybindings.json for the active desktop."""

import json
import plistlib
import shutil
from pathlib import Path

from jsh import desktop
from jsh.system import query

HERE = Path(__file__).resolve().parent
KEYS = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"


def mac(ctx, config):
    for key, value in config["keyboard"].items():
        if query(["defaults", "read", "NSGlobalDomain", key]) == str(value):
            ctx.current()
        else:
            command = ["defaults", "write", "NSGlobalDomain", key, "-int", str(value)]
            desktop.apply(ctx, key, command)
    if not config["shortcuts"]:
        return
    exported = query(["defaults", "export", "NSGlobalDomain", "-"])
    current = plistlib.loads(exported.encode()).get("NSUserKeyEquivalents", {}) if exported else {}
    for menu, binding in config["shortcuts"].items():
        if current.get(menu) == binding:
            ctx.current()
        else:
            arguments = ["defaults", "write", "NSGlobalDomain", "NSUserKeyEquivalents"]
            desktop.apply(ctx, menu, [*arguments, "-dict-add", menu, binding])


def configure(ctx):
    name = ctx.facts.desktop
    config = json.loads((HERE / "keybindings.json").read_text())[name]
    if name == "darwin":
        mac(ctx, config)
        return
    paths = desktop.gnome_list(desktop.MEDIA_KEYS, "custom-keybindings") if name == "gnome" else []
    original = list(paths)
    for binding in config:
        if not shutil.which(binding["command"].split()[0]):
            ctx.current()
            continue
        if name == "xfce":
            key = "/commands/custom/" + binding["binding"]
            channel = "xfce4-keyboard-shortcuts"
            desktop.xfsetting(ctx, channel, key, binding["command"], binding["name"])
            continue
        path = f"{KEYS}jsh-{binding['name'].lower()}/"
        schema = f"{desktop.MEDIA_KEYS}.custom-keybinding:{path}"
        for key in ("name", "binding", "command"):
            value = "'" + binding[key].replace("'", "\\'") + "'"
            desktop.gsetting(ctx, schema, key, value, f"{binding['name']} {key}")
        if path not in paths:
            paths.append(path)
    # Compare lists, not text: gsettings prints an empty list as "@as []".
    if name == "gnome" and paths != original:
        key = "custom-keybindings"
        desktop.gsetting(ctx, desktop.MEDIA_KEYS, key, str(paths), "custom keybindings")
