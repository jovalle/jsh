"""Set every desktop's wallpaper to the image in JSH_WALLPAPER; nothing is chosen implicitly."""

import os
from pathlib import Path

from jsh import desktop
from jsh.output import tilde
from jsh.system import query

APPLESCRIPT = """on run argv
tell application "System Events"
repeat with itemDesktop in desktops
if picture of itemDesktop is not item 1 of argv then
set picture of itemDesktop to item 1 of argv
end if
end repeat
end tell
end run"""


def configure(ctx):
    name = os.environ.get("JSH_WALLPAPER")
    if not name:
        return
    image = Path(name).expanduser().resolve(strict=True)
    if not image.is_file():
        raise ValueError(f"JSH_WALLPAPER is not a file: {name}")
    if ctx.facts.desktop == "darwin":
        script = 'tell application "System Events" to get picture of every desktop'
        if set(query(["osascript", "-e", script]).split(", ")) == {str(image)}:
            ctx.current()
            return
        command = ["osascript", "-e", APPLESCRIPT, str(image)]
        desktop.apply(ctx, f"wallpaper {tilde(image)}", command)
    elif ctx.facts.desktop == "gnome":
        keys = query(["gsettings", "list-keys", "org.gnome.desktop.background"]).splitlines()
        for key in ("picture-uri", "picture-uri-dark"):
            if key in keys:
                desktop.gsetting(ctx, "org.gnome.desktop.background", key, f"'{image.as_uri()}'")
        desktop.gsetting(ctx, "org.gnome.desktop.background", "picture-options", "'zoom'")
    else:
        properties = query(["xfconf-query", "-c", "xfce4-desktop", "-l"]).splitlines()
        targets = [prop for prop in properties if prop.endswith("/last-image")]
        if not targets:
            ctx.notice("XFCE has no backdrop properties yet; log in to XFCE once, then rerun")
        for prop in targets:
            desktop.xfsetting(ctx, "xfce4-desktop", prop, str(image), f"wallpaper {prop}")
