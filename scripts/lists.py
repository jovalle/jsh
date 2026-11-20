#!/usr/bin/env python3
"""Rewrite inline YAML lists such as `tags: [a, b]` as block lists, in place."""

import argparse
import json
import sys

import yaml


def plain(node):
    """Return a node tree without presentation details."""
    if isinstance(node, yaml.ScalarNode):
        return (node.tag, node.value)
    if isinstance(node, yaml.SequenceNode):
        return (node.tag, [plain(item) for item in node.value])
    return (node.tag, [(plain(key), plain(value)) for key, value in node.value])


def nodes(stream):
    """Return each document's node tree."""
    return [plain(document) for document in yaml.compose_all(stream, Loader=yaml.SafeLoader)]


def block(item):
    """Return item text that keeps its meaning as a block list entry, or None."""
    if item.startswith("*"):
        return item
    flow = yaml.compose(f"[{item}]", Loader=yaml.SafeLoader).value[0]
    try:
        entry = yaml.compose(f"- {item}", Loader=yaml.SafeLoader)
        if len(entry.value) == 1 and plain(entry.value[0]) == plain(flow):
            return item
    except yaml.YAMLError:
        pass
    # Plain strings such as `-` turn into list syntax outside brackets; quote them instead.
    if isinstance(flow, yaml.ScalarNode) and flow.tag == "tag:yaml.org,2002:str":
        return json.dumps(flow.value, ensure_ascii=False)
    return None


def rewrite(text):
    """Rewrite each outermost non-empty flow sequence; return the text, the count, and kept lines."""
    edits, kept = [], []
    stack = []

    def role():
        if not stack:
            return "root", 0
        frame = stack[-1]
        if frame["flow"]:
            return "flow", 0
        if frame["kind"] == "map":
            if frame["key"]:
                return "key", 0
            return "value", frame["column"]
        return "item", 0

    def finish(start, end):
        if not stack:
            return
        frame = stack[-1]
        frame["items"].append((start, end))
        if frame["kind"] == "map" and not frame["flow"]:
            frame["key"] = not frame["key"]

    def begin(event, kind):
        where, column = role()
        if where == "key" and stack:
            stack[-1]["column"] = event.start_mark.column
        flow = bool(event.flow_style) or bool(stack and stack[-1]["flow"])
        stack.append({"kind": kind, "flow": flow, "key": True, "column": 0, "items": [],
                      "start": event.start_mark, "role": where, "parent": column,
                      "convert": kind == "seq" and event.flow_style and where != "flow"})

    for event in yaml.parse(text, Loader=yaml.SafeLoader):
        if isinstance(event, (yaml.ScalarEvent, yaml.AliasEvent)):
            if stack and stack[-1]["kind"] == "map" and not stack[-1]["flow"] and stack[-1]["key"]:
                stack[-1]["column"] = event.start_mark.column
            finish(event.start_mark.index, event.end_mark.index)
        elif isinstance(event, yaml.SequenceStartEvent):
            begin(event, "seq")
        elif isinstance(event, yaml.MappingStartEvent):
            begin(event, "map")
        elif isinstance(event, (yaml.SequenceEndEvent, yaml.MappingEndEvent)):
            frame = stack.pop()
            end = event.end_mark.index
            if frame["convert"] and frame["items"]:
                edit = convert(text, frame, end)
                if edit:
                    edits.append(edit)
                else:
                    kept.append(frame["start"].line + 1)
            finish(frame["start"].index, end)

    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text, len(edits), kept


def convert(text, frame, end):
    """Return (start, end, replacement) for one flow sequence, or None when it must stay inline."""
    start = frame["start"].index
    bracket = text.index("[", start)
    prefix = text[start:bracket].strip()
    items = [text[a:b] for a, b in frame["items"]]
    gaps = [text[bracket + 1:frame["items"][0][0]]]
    gaps += [text[b:a] for (_, b), (a, _) in zip(frame["items"], frame["items"][1:])]
    gaps.append(text[frame["items"][-1][1]:end - 1])
    if any("#" in gap for gap in gaps) or any("\n" in item for item in items):
        return None
    items = [block(item) for item in items]
    if None in items:
        return None

    if frame["role"] == "value":
        while start > 0 and text[start - 1] in " \t\n":
            start -= 1
        indent = " " * (frame["parent"] + 2)
        head = " " + prefix if prefix else ""
        return start, end, head + "".join(f"\n{indent}- {item}" for item in items)

    indent = " " * frame["start"].column
    lines = [f"- {item}" for item in items]
    if prefix:
        return start, end, prefix + "".join(f"\n{indent}{line}" for line in lines)
    return bracket, end, f"\n{indent}".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", metavar="FILE")
    args = parser.parse_args()
    status = 0
    for path in args.files:
        with open(path, encoding="utf-8", newline="") as handle:
            text = handle.read()
        try:
            # Lists nested in inline lists become block lists one level per pass.
            result, count, kept = rewrite(text)
            changed = count
            while changed:
                result, changed, kept = rewrite(result)
                count += changed
            if count and nodes(result) != nodes(text):
                raise ValueError("rewritten data differs from the original")
        except (yaml.YAMLError, ValueError) as error:
            print(f"{path}: {error}", file=sys.stderr)
            status = 1
            continue
        for line in kept:
            print(f"{path}:{line}: kept inline list with comments or items that need it", file=sys.stderr)
        if count:
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write(result)
            print(f"{path}: {count} inline list{'s' if count > 1 else ''} rewritten")
    return status


if __name__ == "__main__":
    sys.exit(main())
