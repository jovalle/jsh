#!/usr/bin/env python3
"""Manage Citrix launchers and the explicitly selected WFClient preference."""

import os
from pathlib import Path
import re
import subprocess
import sys

from application_config import desktop_executable, ensure_file


def main():
    citrix = Path(sys.argv[1])
    home = Path.home()
    applications = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")) / "applications"
    changed = False
    for filename, name, executable, argument, mime in [
        ("jsh-citrix-ica.desktop", "Citrix Workspace ICA Launcher", "wfica.sh", "%f", "application/x-ica"),
        ("jsh-citrix-receiver.desktop", "Citrix Workspace Receiver Launcher", "util/ctxwebhelper", "%u", "x-scheme-handler/receiver"),
    ]:
        content = ("[Desktop Entry]\nType=Application\nName=" + name + "\nNoDisplay=true\n"
                   "TryExec=" + str(citrix / executable) + "\nExec=" + desktop_executable(citrix / executable)
                   + " " + argument + "\nIcon=" + str(citrix / "icons/receiver.png")
                   + "\nMimeType=" + mime + ";\n")
        changed = ensure_file(applications / filename, content.encode()) or changed
        current = subprocess.run(["xdg-mime", "query", "default", mime],
                                 check=True, capture_output=True, text=True).stdout.strip()
        if current != filename:
            subprocess.run(["xdg-mime", "default", filename, mime], check=True)
            actual = subprocess.run(["xdg-mime", "query", "default", mime],
                                    check=True, capture_output=True, text=True).stdout.strip()
            if actual != filename:
                raise ValueError(f"MIME association did not take effect: {mime} -> {actual}")
    if changed:
        subprocess.run(["update-desktop-database", str(applications)], check=True)
    settings = home / ".ICAClient/wfclient.ini"
    original = settings.read_text() if settings.exists() else "[WFClient]\nVersion = 2\n"
    lines = original.splitlines(keepends=True)
    output = []
    inside = False
    found_section = False
    found_key = False
    for line in lines:
        if re.match(r"^\s*\[", line):
            if inside and not found_key:
                output.append("MouseSendsControlV=False\n")
                found_key = True
            inside = line.strip().lower() == "[wfclient]"
            found_section = found_section or inside
        if inside and re.match(r"^\s*MouseSendsControlV\s*=", line, re.IGNORECASE):
            if not found_key:
                output.append("MouseSendsControlV=False\n")
                found_key = True
        else:
            output.append(line)
    if output and not output[-1].endswith("\n"):
        output[-1] += "\n"
    if not found_section:
        output.append("\n[WFClient]\n")
    if not found_key:
        output.append("MouseSendsControlV=False\n")
    ensure_file(settings, "".join(output).encode(), 0o600)


if __name__ == "__main__":
    main()
