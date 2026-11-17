"""Turn named entries into the {src, dest} items the link role takes."""

from __future__ import annotations


def links(entries: list, source_root: str, destination_root: str) -> list:
    """Each entry is NAME, [SOURCE, NAME], or {source, name}; SOURCE defaults to NAME.

    The result links source_root/SOURCE to destination_root/NAME.
    """
    items = []
    for entry in entries or []:
        if isinstance(entry, dict):
            source, name = entry["source"], entry["name"]
        elif isinstance(entry, (list, tuple)):
            source, name = entry[0], entry[1]
        else:
            source = name = entry
        items.append({"src": f"{source_root}/{source}", "dest": f"{destination_root}/{name}"})
    return items


class FilterModule:
    def filters(self):
        return {"links": links}
