"""Small keyboard-driven terminal menus with a plain numbered fallback."""

import os
import select
import shutil
import sys
import termios
import textwrap
import tty

from jsh.output import styled


def paint(text, color, enabled):
    return f"\033[{color}m{text}\033[0m" if enabled and text else text


def item_line(  # pylint: disable=too-many-positional-arguments,too-many-locals
    item, active, marked, multiple, label_width, width, color
):
    """Align labels before adding color, and fit the visible text to the terminal."""
    _, label, detail = item
    prefix = " " + paint(">" if active else " ", "33", color) + " "
    if multiple:
        prefix += paint("[x]" if marked else "[ ]", "32" if marked else "90", color) + " "
    else:
        prefix += "    "
    room = max(0, width - 8)
    column = min(label_width, max(0, room - 3))
    label = label[:column]
    if " / " in label:
        group, leaf = label.split(" / ", 1)
        colored = paint(group, "36", color) + " / " + paint(leaf, "1", color)
    else:
        colored = paint(label, "1", color)
    remaining = max(0, room - column - 2)
    return prefix + colored + " " * (column - len(label)) + "  " + detail[:remaining]


def available():
    return sys.stdin.isatty() and sys.stdout.isatty() and os.environ.get("TERM") != "dumb"


def key(stream):
    fd = stream.fileno()
    char = os.read(fd, 1).decode("latin-1")
    if not char:
        return "\x04"
    if char != "\x1b":
        return char
    if not select.select([fd], [], [], 0.05)[0]:
        return "escape"
    tail = os.read(fd, 1).decode("latin-1")
    if tail == "[" and select.select([fd], [], [], 0.05)[0]:
        return {"A": "up", "B": "down"}.get(os.read(fd, 1).decode("latin-1"), "")
    return "escape"


# pylint: disable=too-many-locals,too-many-branches,too-many-nested-blocks,too-many-statements
def choose(title, items, selected=(), multiple=False, title_color=None):
    """Return selected keys, or None on Escape. Each item is (key, label, description)."""
    marked = set(selected)
    cursor = 0
    query = ""
    searching = False
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?25l")
        while True:
            filtered = [
                item for item in items if query.lower() in (item[1] + " " + item[2]).lower()
            ]
            cursor = min(cursor, max(0, len(filtered) - 1))
            rows = max(1, shutil.get_terminal_size((80, 24)).lines - len(title.splitlines()) - 6)
            start = max(0, cursor - rows + 1)
            width = shutil.get_terminal_size((80, 24)).columns
            color = styled(sys.stdout)
            lines = [paint(title, title_color or "1;36", color)]
            if searching or query:
                lines.append(f"Search: {query}")
            lines.append("")
            label_width = max((len(item[1]) for item in items), default=0)
            for index, (name, label, detail) in enumerate(filtered[start:start + rows], start):
                lines.append(item_line((name, label, detail), index == cursor, name in marked,
                                       multiple, label_width, width, color))
            controls = "↑↓ move | space select | " + ("a toggle all | " if multiple else "")
            lines += ["", (f"{len(marked)} selected | " if multiple else "") + controls +
                      "/ search | enter continue | esc back"]
            sys.stdout.write("\033[H\033[2J" + "\r\n".join(lines))
            sys.stdout.flush()
            pressed = key(sys.stdin)
            if pressed in ("\x03", "\x04"):
                raise KeyboardInterrupt
            if pressed == "escape":
                return None
            if pressed in ("\r", "\n"):
                if searching:
                    searching = False
                    continue
                if multiple:
                    return [item[0] for item in items if item[0] in marked]
                if filtered:
                    return filtered[cursor][0]
            elif pressed == "up":
                cursor = max(0, cursor - 1)
            elif pressed == "down":
                cursor = min(len(filtered) - 1, cursor + 1) if filtered else 0
            elif searching and pressed in ("\x7f", "\b"):
                query, cursor = query[:-1], 0
            elif searching and pressed.isprintable():
                query, cursor = query + pressed, 0
            elif pressed == "/":
                searching = True
            elif multiple and pressed == " " and filtered:
                name = filtered[cursor][0]
                marked.symmetric_difference_update({name})
            elif multiple and pressed == "a" and filtered:
                visible = {item[0] for item in filtered}
                if visible <= marked:
                    marked.difference_update(visible)
                else:
                    marked.update(visible)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)
        sys.stdout.write("\033[?25h\033[H\033[2J")
        sys.stdout.flush()


# pylint: enable=too-many-locals,too-many-branches,too-many-nested-blocks,too-many-statements
def view(title, text, actions=False):  # pylint: disable=too-many-locals
    """Show a scrollable detail without losing content on narrow terminals."""
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    offset = 0
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\033[?25l")
        while True:
            width, height = shutil.get_terminal_size((80, 24))
            lines = [
                part
                for line in text.splitlines()
                for part in (
                    textwrap.wrap(line, max(1, width - 1), replace_whitespace=False) or [""]
                )
            ]
            count = max(1, height - 4)
            offset = min(offset, max(0, len(lines) - count))
            color = styled(sys.stdout)
            visible = []
            for line in lines[offset : offset + count]:
                if line.startswith(("+ ", "~ ", "- ", "! ", "✗ ")):
                    code = {"+": "32", "~": "33", "-": "31", "!": "33", "✗": "31"}[line[0]]
                    line = paint(line[0], code, color) + line[1:]
                elif line in (
                    "Packages",
                    "Repositories",
                    "Links",
                    "Configuration",
                    "Other changes",
                ):
                    line = paint(line, "1", color)
                visible.append(line)
            controls = (
                "↑↓ scroll | a apply | d details | c change | esc cancel"
                if actions
                else "↑↓ scroll | enter or esc back"
            )
            screen = [paint(title[: max(width - 1, 1)], "1;36", color), "", *visible, "", controls]
            sys.stdout.write("\033[H\033[2J" + "\r\n".join(screen))
            sys.stdout.flush()
            pressed = key(sys.stdin)
            if pressed in ("\x03", "\x04"):
                raise KeyboardInterrupt
            if actions and pressed in ("a", "d", "c"):
                return {"a": "apply", "d": "details", "c": "change"}[pressed]
            if pressed == "escape":
                return None
            if not actions and pressed in ("\r", "\n"):
                return None
            if pressed == "up":
                offset = max(0, offset - 1)
            elif pressed == "down":
                offset = min(max(0, len(lines) - count), offset + 1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)
        sys.stdout.write("\033[?25h\033[H\033[2J")
        sys.stdout.flush()
