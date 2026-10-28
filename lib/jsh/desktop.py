"""Desktop settings helpers for module scripts: gsettings, xfconf, macOS defaults, and shortcuts."""

import ast

from jsh.system import query


def apply(ctx, label, arguments):
    ctx.run(arguments)
    ctx.changed(label)


def gsetting(ctx, schema, key, value, label=None, schemadir=None):  # pylint: disable=R0917
    command = ["gsettings", *(["--schemadir", str(schemadir)] if schemadir else [])]
    if query([*command, "get", schema, key]) == value:
        ctx.current()
    else:
        apply(ctx, label or f"{schema} {key}", [*command, "set", schema, key, value])


def xfsetting(ctx, channel, key, value, label=None):
    current = query(["xfconf-query", "-c", channel, "-p", key])
    if current == value:
        ctx.current()
        return
    arguments = ["xfconf-query", "-c", channel, "-p", key, "-s", value]
    if not current:
        arguments += ["--create", "--type", "string"]
    apply(ctx, label or f"{channel} {key}", arguments)


def gnome_list(schema, key):
    raw = query(["gsettings", "get", schema, key])
    return ast.literal_eval(raw.removeprefix("@as ")) if raw else []


MEDIA_KEYS = "org.gnome.settings-daemon.plugins.media-keys"


def shortcut(ctx, name, gnome_binding, xfce_binding, command):
    """Bind a key to a command in the running GNOME or XFCE session."""
    if ctx.facts.desktop == "xfce":
        key = "/commands/custom/" + xfce_binding
        xfsetting(ctx, "xfce4-keyboard-shortcuts", key, command, name)
        return
    paths = gnome_list(MEDIA_KEYS, "custom-keybindings")
    slug = "".join(character if character.isalnum() else "-" for character in name.lower())
    path = f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/{slug}/"
    schema = f"{MEDIA_KEYS}.custom-keybinding:{path}"
    for key, value in (("name", name), ("binding", gnome_binding), ("command", command)):
        gsetting(ctx, schema, key, "'" + value.replace("'", "\\'") + "'", f"{name} {key}")
    if path not in paths:
        gsetting(ctx, MEDIA_KEYS, "custom-keybindings", str([*paths, path]))
