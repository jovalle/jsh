#!/usr/bin/env python3
"""Apply desktop, dock, audio, display, wallpaper, and keyboard settings."""

import ast
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRY_RUN = os.environ.get("JSH_DRY_RUN") == "1"
sys.path.insert(0, str(ROOT / "lib"))
import output  # pylint: disable=import-error,wrong-import-position


def query(*arguments):
    result = subprocess.run(arguments, check=False, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def apply(label, *arguments):
    if DRY_RUN:
        output.note("would run " + " ".join(arguments))
        output.count("to update")
    else:
        output.run(list(arguments))
        output.count("updated")
    output.item(label)


def gsetting(schema, key, value, label=None):
    if query("gsettings", "get", schema, key) != value:
        apply(label or key, "gsettings", "set", schema, key, value)
    else:
        output.current(label or key)


def xfsetting(channel, key, value):
    current = query("xfconf-query", "-c", channel, "-p", key)
    if current == value:
        output.current(key)
        return
    args = ["xfconf-query", "-c", channel, "-p", key, "-s", value]
    if not current:
        args += ["--create", "--type", "string"]
    apply(key, *args)


def write_file(path, content, mode=0o644):
    if path.is_file() and path.read_bytes() == content:
        output.current(output.tilde(path))
        return False
    if DRY_RUN:
        output.note(f"would write {output.tilde(path)}")
        output.count("to update")
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(content)
    try:
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    output.item(output.tilde(path))
    output.count("updated")
    return True


def shortcut(desktop, name, gnome_binding, xfce_binding, command):
    if desktop == "xfce":
        xfsetting(
            "xfce4-keyboard-shortcuts",
            "/commands/custom/" + xfce_binding,
            command,
        )
        return
    raw = query(
        "gsettings", "get", "org.gnome.settings-daemon.plugins.media-keys", "custom-keybindings"
    )
    paths = ast.literal_eval(raw.removeprefix("@as ")) if raw else []
    slug = "".join(character if character.isalnum() else "-" for character in name.lower())
    path = f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/{slug}/"
    schema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:" + path
    for key, value in (("name", name), ("binding", gnome_binding), ("command", command)):
        gsetting(schema, key, "'" + value.replace("'", "\\'") + "'", f"{name} {key}")
    if path not in paths:
        paths.append(path)
        gsetting("org.gnome.settings-daemon.plugins.media-keys", "custom-keybindings", str(paths))


def wallpaper(desktop):
    name = os.environ.get("JSH_WALLPAPER")
    if not name:
        output.skip("set JSH_WALLPAPER to an image path")
        return
    image = Path(name).expanduser().resolve(strict=True)
    if not image.is_file():
        raise ValueError("Wallpaper must be a file")
    if desktop == "darwin":
        script = (
            'on run argv\ntell application "System Events"\n'
            "repeat with itemDesktop in desktops\n"
            "if picture of itemDesktop is not item 1 of argv then\n"
            "set picture of itemDesktop to item 1 of argv\n"
            "end if\nend repeat\nend tell\nend run"
        )
        apply(output.tilde(image), "osascript", "-e", script, str(image))
    elif desktop == "gnome":
        for key in ("picture-uri", "picture-uri-dark"):
            keys = query("gsettings", "list-keys", "org.gnome.desktop.background").splitlines()
            if key in keys:
                gsetting("org.gnome.desktop.background", key, f"'{image.as_uri()}'")
        gsetting("org.gnome.desktop.background", "picture-options", "'zoom'")
    else:
        properties = query("xfconf-query", "-c", "xfce4-desktop", "-l").splitlines()
        targets = [prop for prop in properties if prop.endswith("/last-image")]
        if not targets:
            output.skip("XFCE has no initialized backdrop properties")
        for prop in targets:
            xfsetting("xfce4-desktop", prop, str(image))


def mac_keybindings(config):
    for key, value in config["keyboard"].items():
        if query("defaults", "read", "NSGlobalDomain", key) != str(value):
            apply(key, "defaults", "write", "NSGlobalDomain", key, "-int", str(value))
        else:
            output.current(key)
    if config["shortcuts"]:
        exported = query("defaults", "export", "NSGlobalDomain", "-")
        current = plistlib.loads(exported.encode()).get("NSUserKeyEquivalents", {})
        for menu, binding in config["shortcuts"].items():
            if current.get(menu) != binding:
                apply(
                    menu,
                    "defaults",
                    "write",
                    "NSGlobalDomain",
                    "NSUserKeyEquivalents",
                    "-dict-add",
                    menu,
                    binding,
                )
            else:
                output.current(menu)


def keybindings(desktop):
    config = json.loads((ROOT / "conf/keybindings.json").read_text())[desktop]
    if desktop == "darwin":
        mac_keybindings(config)
        return
    paths = []
    if desktop == "gnome":
        raw = query(
            "gsettings", "get", "org.gnome.settings-daemon.plugins.media-keys", "custom-keybindings"
        )
        paths = ast.literal_eval(raw.removeprefix("@as ")) if raw else []
    for binding in config:
        if not shutil.which(binding["command"].split()[0]):
            output.note(f"skipped unavailable command: {binding['command']}")
            continue
        if desktop == "xfce":
            xfsetting(
                "xfce4-keyboard-shortcuts",
                "/commands/custom/" + binding["binding"],
                binding["command"],
            )
        else:
            path = (
                "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"
                f"jsh-{binding['name'].lower()}/"
            )
            schema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:" + path
            for key in ("name", "binding", "command"):
                gsetting(
                    schema,
                    key,
                    "'" + binding[key].replace("'", "\\'") + "'",
                    f"{binding['name']} {key}",
                )
            if path not in paths:
                paths.append(path)
    if desktop == "gnome":
        gsetting("org.gnome.settings-daemon.plugins.media-keys", "custom-keybindings", str(paths))


def run_linux_script(name, desktop):
    if desktop == "darwin":
        output.skip("Linux only")
        return
    script = ROOT / f"scripts/customize/{name}.sh"
    arguments = ["env", f"JSH_DESKTOP={desktop}", "bash", str(script)]
    if DRY_RUN:
        subprocess.run(arguments, check=True)
    else:
        output.run(arguments)


def desktop_settings(desktop):
    run_linux_script("desktop", desktop)


def dock(desktop):
    run_linux_script("dock", desktop)


def audio(desktop):
    if desktop == "darwin":
        output.skip("Linux only")
        return
    policy = Path.home() / ".config/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf"
    source_name = os.environ.get("JSH_AUDIO_POLICY")
    if not source_name and os.uname().nodename.split(".", maxsplit=1)[0] == "colossus":
        source_name = str(ROOT / "conf/audio.conf")
    changed = False
    if source_name and Path(source_name).is_file():
        changed = write_file(policy, Path(source_name).read_bytes())
    else:
        output.note("no audio device policy for this host; keeping existing devices")
    command = f"bash {ROOT}/scripts/customize/audio.sh cycle"
    shortcut(
        desktop,
        "Jsh audio output",
        "<Control><Alt><Super>a",
        "<Primary><Alt><Super>a",
        command,
    )
    if changed and shutil.which("systemctl"):
        apply("WirePlumber", "systemctl", "--user", "restart", "wireplumber.service")


def mac_display():
    selector = ROOT / "scripts/customize/resolution.swift"
    if not shutil.which("displayplacer"):
        output.skip("displayplacer is unavailable")
        return
    if not shutil.which("xcrun") or not query("xcrun", "--find", "swift"):
        output.skip("the Swift toolchain is unavailable")
        return
    profile = query("xcrun", "swift", str(selector))
    if not profile:
        output.skip("no configurable displays found")
        return
    arguments = []
    for line in profile.splitlines():
        fields = line.split("\t")
        if len(fields) != 11:
            raise ValueError("Unexpected display resolution profile")
        if fields[3:6] == fields[7:10]:
            continue
        arguments.append(fields[0])
        output.note(f"{fields[1]} ({fields[2]})")
        output.note(
            f"current: {fields[3]} logical, {fields[4]} backing, "
            f"scaling:{fields[5]}, {fields[6]} effective PPI"
        )
        output.note(
            f"proposed: {fields[7]} logical, {fields[8]} backing, "
            f"scaling:{fields[9]}, {fields[10]} effective PPI"
        )
    if arguments:
        apply("macOS display resolutions", "displayplacer", *arguments)
    else:
        output.current("macOS display resolutions")


def display(desktop):
    if desktop == "darwin":
        mac_display()
        return
    if os.environ.get("XDG_SESSION_TYPE", "x11") == "wayland":
        output.skip("logical monitor splitting requires X11")
        return
    if not shutil.which("xrandr"):
        output.skip("xrandr is unavailable")
        return
    command = f"bash {ROOT}/scripts/customize/display.sh toggle"
    shortcut(
        desktop,
        "Jsh display layout",
        "<Control><Alt><Super>m",
        "<Primary><Alt><Super>m",
        command,
    )


def main(component):
    if os.environ["JSH_PLATFORM"] == "darwin":
        desktop = "darwin"
    else:
        if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
            output.skip("Skipping desktop customization: no graphical session.")
            return
        session = (
            os.environ.get("XDG_CURRENT_DESKTOP", "") + ":" + os.environ.get("DESKTOP_SESSION", "")
        ).lower()
        desktop = next((name for name in ("gnome", "xfce") if name in session), "")
        tool = {"gnome": "gsettings", "xfce": "xfconf-query"}.get(desktop)
        if not tool or not shutil.which(tool) or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            output.skip("Skipping desktop customization: needs an active GNOME or XFCE session.")
            return
    tasks = (
        ("wallpaper", wallpaper),
        ("keybindings", keybindings),
        ("desktop", desktop_settings),
        ("dock", dock),
        ("audio", audio),
        ("display", display),
    )
    for name, task in tasks:
        if component in (name, "all"):
            with output.Step(name):
                task(desktop)


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        output.error(str(error))
        sys.exit(1)
