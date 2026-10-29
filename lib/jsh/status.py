"""Condenses `git status` output: one line per change type, sibling paths folded into braces.

Reads Git's long format (no color, no hints) on stdin; argv[1] is "true" for color.
"""

import functools
import re
import shutil
import sys

ENTRY = re.compile(r"\t([a-z ]+):\s+(.*)$")
INDENT = "  "
# SGR codes; labels missing here are merge conflicts ("both modified", "added by us", ...).
TYPES = {
    "new file": "32",
    "modified": "33",
    "deleted": "31",
    "renamed": "36",
    "copied": "36",
    "typechange": "35",
}
CONFLICT = "1;31"
SECTIONS = {
    "Changes to be committed:": "1;32",
    "Changes not staged for commit:": "1;31",
    "Unmerged paths:": "1;31",
    "Untracked files:": "2",
    "Ignored files:": "2",
}
LOOSE = {"Untracked files:": "", "Ignored files:": "2"}


def brace(values):
    """Returns (names, extension) for {a,b}.py, keeping a shared extension outside the braces."""
    dots = [value.rfind(".") for value in values]
    extensions = {value[dot:] for value, dot in zip(values, dots) if dot > 0}
    if len(extensions) == 1 and all(dot > 0 for dot in dots):
        extension = extensions.pop()
        return [value[: -len(extension)] for value in values], extension
    return values, ""


def leaf(path, name, dim):
    """Paints a path's last component with name() and its directories with dim()."""
    if " -> " in path:
        return dim(" -> ").join(leaf(side, name, dim) for side in path.split(" -> "))
    stem = path.rstrip("/")
    folder, slash, base = stem.rpartition("/")
    return dim(folder + slash) + name(base) + dim(path[len(stem) :])


def shade(head, chunk, tail, name, dim):
    """Paints the names that vary with name() and the shared structure with dim()."""
    if len(chunk) == 1:
        return leaf("/".join(head + (chunk[0],) + tail), name, dim)
    names, extension = brace(chunk)
    prefix = "".join(part + "/" for part in head) + "{"
    suffix = "}" + extension + "".join("/" + part for part in tail)
    return dim(prefix) + dim(",").join(map(name, names)) + dim(suffix)


def group(paths):
    """Returns (head, values, tail) per group; paths that differ in one component share one."""
    left = list(paths)
    found = []
    while True:
        buckets = {}
        for path in left:
            parts = path.split("/")
            if " " in path or path.startswith('"') or len(parts) < 2:
                continue
            for i in range(len(parts)):
                buckets.setdefault((i, tuple(parts[:i]), tuple(parts[i + 1 :])), []).append(path)
        key, members = max(buckets.items(), key=lambda item: len(item[1]), default=(None, []))
        if len(members) < 2:
            break
        i, head, tail = key
        found.append((paths.index(members[0]), head, [m.split("/")[i] for m in members], tail))
        left = [path for path in left if path not in members]
    found += [(paths.index(path), (), [path], ()) for path in left]
    return [item[1:] for item in sorted(found, key=lambda item: item[0])]


def fold(head, values, tail, room):
    """Returns (text, head, chunk, tail) per brace expression, values spread evenly across lines."""

    def token(chunk):
        if len(chunk) == 1:
            return "/".join(head + (chunk[0],) + tail)
        names, extension = brace(chunk)
        return "/".join(head + ("{" + ",".join(names) + "}" + extension,) + tail)

    chunks, chunk = [], []
    for value in values:
        if chunk and len(token(chunk + [value])) > room:
            chunks.append(chunk)
            chunk = []
        chunk.append(value)
    chunks.append(chunk)
    size = -(-len(values) // len(chunks))
    even = [values[start : start + size] for start in range(0, len(values), size)]
    if len(even) == len(chunks) and max(len(token(part)) for part in even) <= room:
        chunks = even
    return [(token(part), head, part, tail) for part in chunks]


def render(first, indent, paths, name, dim):
    """Prints one change type, wrapping only between paths so each stays whole for copying."""
    room = shutil.get_terminal_size().columns - len(INDENT) - indent
    lines, line, used = [], [], 0
    for spec in group(paths):
        for text, *parts in fold(*spec, room):
            painted = shade(*parts, name, dim)
            if " " in text:
                lines += [line, [painted]] if line else [[painted]]
                line, used = [], 0
            elif line and used + 2 + len(text) > room:
                lines.append(line)
                line, used = [painted], len(text)
            else:
                used += len(text) + (2 if line else 0)
                line.append(painted)
    lines += [line] if line else []
    for number, tokens in enumerate(lines):
        print(INDENT + (first if number == 0 else " " * indent) + "  ".join(tokens))


def main():
    color = sys.argv[1:] == ["true"]
    header, entries = None, {}

    def paint(code, text):
        return f"\033[{code}m{text}\033[0m" if color and code and text else text

    dim = functools.partial(paint, "2")

    def counted(code, text, count):
        return paint(code, f"{text} (") + paint("1", str(count)) + paint(code, "):")

    def flush():
        nonlocal header
        loose = LOOSE.get(header, "")
        if header:
            print(counted(SECTIONS[header], header[:-1], len(entries.get("", []))))
            header = None
        plain = {label: f"{label} ({len(paths)}):" for label, paths in entries.items() if label}
        pad = max(map(len, plain.values()), default=0) + 1
        for label, paths in entries.items():
            code, first, indent = loose, "", 0
            if label:
                code, indent = TYPES.get(label, CONFLICT), pad
                first = counted(code, label, len(paths)) + " " * (pad - len(plain[label]))
            render(first, indent, paths, functools.partial(paint, code), dim)
        entries.clear()

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if line.startswith("\t"):
            match = None if header else ENTRY.match(line)
            if header or match:
                label, path = ("", line[1:]) if header else match.groups()
                entries.setdefault(label, []).append(path)
                continue
        flush()
        if line in LOOSE:
            header = line
        else:
            print(paint(SECTIONS.get(line, ""), line))
    flush()


if __name__ == "__main__":
    main()
