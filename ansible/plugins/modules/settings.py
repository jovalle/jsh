#!/usr/bin/python
"""Merge managed keys into an app-owned JSON, JSONC, or plist settings file."""

from __future__ import annotations

DOCUMENTATION = r"""
module: settings
short_description: Merge managed keys into an app-owned settings file
description:
  - Reads the current file (JSON with comments and trailing commas allowed, or a plist),
    merges the desired values over it, and writes formatted JSON or an XML plist only when the
    result differs. An unreadable file fails without being written.
  - Plists under /Library/Preferences are written with C(defaults import) and cfprefsd is
    restarted, so cached preferences do not overwrite them.
options:
  path: {description: Settings file to update., type: path, required: true}
  source: {description: JSON or JSONC file with the desired values., type: path}
  values: {description: Desired values., type: dict}
  overlays:
    description: Optional JSON or JSONC files merged over the desired values in order; missing files are ignored.
    type: list
    elements: path
    default: []
  format: {description: Format of I(path)., type: str, choices: [json, plist], default: json}
  merge:
    description: C(deep) merges objects recursively like jq C(*), C(shallow) replaces top-level keys like jq C(+), C(replace) writes only the desired values.
    type: str
    choices: [deep, shallow, replace]
    default: deep
  mode: {description: Mode for a new file; an existing file keeps its mode., type: str, default: "0644"}
  backup: {description: Keep a backup of the previous file., type: bool, default: false}
"""

import json
import os
import plistlib
import re
import subprocess
import tempfile

from ansible.module_utils.basic import AnsibleModule

STRING = r'"(?:[^"\\]|\\.)*"'
COMMENTS = re.compile(rf"({STRING})|//[^\n]*|/\*[\s\S]*?\*/")
TRAILING_COMMAS = re.compile(rf"({STRING})|,(?=\s*[}}\]])")


def parse_jsonc(text: str) -> dict:
    """Parse JSON, falling back to JSONC; the result must be an object."""
    try:
        value = json.loads(text)
    except ValueError:
        text = COMMENTS.sub(lambda match: match.group(1) or " ", text)
        text = TRAILING_COMMAS.sub(lambda match: match.group(1) or "", text)
        value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("settings must be an object")
    return value


def deep_merge(current: dict, desired: dict) -> dict:
    merged = dict(current)
    for key, value in desired.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def canonical(value: dict) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False, default=str)


def main() -> None:
    module = AnsibleModule(
        argument_spec=dict(
            path=dict(type="path", required=True),
            source=dict(type="path"),
            values=dict(type="dict"),
            overlays=dict(type="list", elements="path", default=[]),
            format=dict(type="str", choices=["json", "plist"], default="json"),
            merge=dict(type="str", choices=["deep", "shallow", "replace"], default="deep"),
            mode=dict(type="str", default="0644"),
            backup=dict(type="bool", default=False),
        ),
        mutually_exclusive=[("source", "values")],
        required_one_of=[("source", "values")],
        supports_check_mode=True,
    )
    params = module.params
    path = params["path"]

    try:
        if params["source"]:
            with open(params["source"], encoding="utf-8") as handle:
                desired = parse_jsonc(handle.read())
        else:
            desired = params["values"]
        for overlay in params["overlays"]:
            if os.path.isfile(overlay):
                with open(overlay, encoding="utf-8") as handle:
                    desired = deep_merge(desired, parse_jsonc(handle.read()))
    except (OSError, ValueError) as error:
        module.fail_json(msg=f"desired settings are unreadable: {error}")

    exists = os.path.isfile(path)
    current = {}
    if exists:
        try:
            if params["format"] == "plist":
                with open(path, "rb") as handle:
                    current = plistlib.load(handle)
            else:
                with open(path, encoding="utf-8") as handle:
                    current = parse_jsonc(handle.read())
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            module.fail_json(msg=f"{path} is unreadable and was left unchanged: {error}")

    if params["merge"] == "deep":
        merged = deep_merge(current, desired)
    elif params["merge"] == "shallow":
        merged = {**current, **desired}
    else:
        merged = desired

    before, after = canonical(current), canonical(merged)
    changed = not exists or before != after
    result = dict(changed=changed, path=path)
    if changed and module._diff:
        result["diff"] = dict(before="" if not exists else before + "\n", after=after + "\n",
                              before_header=path, after_header=path)
    if not changed or module.check_mode:
        module.exit_json(**result)

    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o755, exist_ok=True)
    if params["backup"] and exists:
        result["backup_file"] = module.backup_local(path)
    if params["format"] == "plist":
        content = plistlib.dumps(merged, fmt=plistlib.FMT_XML)
    else:
        content = (json.dumps(merged, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    descriptor, staged = tempfile.mkstemp(dir=directory, prefix=".settings.")
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(content)
    mode = os.stat(path).st_mode & 0o7777 if exists else int(params["mode"], 8)
    os.chmod(staged, mode)

    if params["format"] == "plist" and directory == "/Library/Preferences":
        domain = path[: -len(".plist")] if path.endswith(".plist") else path
        imported = subprocess.run(["defaults", "import", domain, staged],
                                  capture_output=True, text=True, check=False)
        os.unlink(staged)
        if imported.returncode != 0:
            module.fail_json(msg=f"defaults import failed: {imported.stderr.strip()}", **result)
        subprocess.run(["killall", "cfprefsd"], capture_output=True, check=False)
    else:
        module.atomic_move(staged, path)
        if params["format"] == "plist":
            subprocess.run(["killall", "cfprefsd"], capture_output=True, check=False)
    module.exit_json(**result)


if __name__ == "__main__":
    main()
