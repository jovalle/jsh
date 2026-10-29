"""Condenses `git status` output: one line per change type, sibling paths folded into braces.

Reads Git's long format (no color, no hints) on stdin; argv[1] is "true" for color.
"""

import re
import shutil
import sys

ENTRY = re.compile(r"\t([a-z ]+):\s+(.*)$")
INDENT = "  "


def brace(values):
    """Folds values into {a,b}, keeping a shared extension outside: {a,b}.py."""
    dots = [value.rfind(".") for value in values]
    extensions = {value[dot:] for value, dot in zip(values, dots) if dot > 0}
    if len(extensions) == 1 and all(dot > 0 for dot in dots):
        extension = extensions.pop()
        return "{" + ",".join(value[: -len(extension)] for value in values) + "}" + extension
    return "{" + ",".join(values) + "}"


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
    """Returns whole brace expressions for one group, values spread evenly across lines."""

    def token(chunk):
        return "/".join(head + (brace(chunk) if len(chunk) > 1 else chunk[0],) + tail)

    tokens, chunk = [], []
    for value in values:
        if chunk and len(token(chunk + [value])) > room:
            tokens.append(token(chunk))
            chunk = []
        chunk.append(value)
    tokens.append(token(chunk))
    size = -(-len(values) // len(tokens))
    even = [token(values[start : start + size]) for start in range(0, len(values), size)]
    return even if len(even) == len(tokens) and max(map(len, even)) <= room else tokens


def render(first, paths, width, paint):
    """Prints one change type, wrapping only between paths so each stays whole for copying."""
    indent = len(first)
    room = width - len(INDENT) - indent
    lines, line = [], ""
    for head, values, tail in group(paths):
        for token in fold(head, values, tail, room):
            if " " in token:
                lines += [line, token] if line else [token]
                line = ""
            elif line and len(line) + 2 + len(token) > room:
                lines.append(line)
                line = token
            else:
                line = f"{line}  {token}" if line else token
    lines += [line] if line else []
    for number, text in enumerate(lines):
        print(INDENT + (first if number == 0 else " " * indent) + paint(text))


def main():
    color = sys.argv[1:] == ["true"]
    width = shutil.get_terminal_size().columns
    sgr, header, entries = "31", None, {}

    def paint(text):
        return f"\033[{sgr}m{text}\033[0m" if color else text

    def flush():
        nonlocal header
        if header:
            print(f"{header[:-1]} ({len(entries.get('', []))}):")
            header = None
        labels = {label: f"{label} ({len(paths)}):" for label, paths in entries.items() if label}
        pad = max(map(len, labels.values()), default=0) + 1
        for label, paths in entries.items():
            render(labels[label].ljust(pad) if label else "", paths, width, paint)
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
        if line in ("Untracked files:", "Ignored files:"):
            header = line
        else:
            print(line)
        if line.endswith(":") and not line.startswith(("\t", " ")):
            sgr = "32" if line == "Changes to be committed:" else "31"
    flush()


if __name__ == "__main__":
    main()
