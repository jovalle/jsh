#!/usr/bin/env python3
"""Reconcile browser entry points independently of the browser process."""
import argparse
import os
from pathlib import Path
import re
import subprocess

from application_config import ensure_file

BROWSER_MIMES = (
    "x-scheme-handler/http", "x-scheme-handler/https", "text/html",
    "application/xhtml+xml", "application/x-extension-htm",
    "application/x-extension-html", "application/x-extension-shtml",
    "application/x-extension-xhtml", "application/x-extension-xht",
)


def query(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout.strip()


def set_helper_key(text, key, value):
    line = key + "=" + value
    pattern = r"^" + re.escape(key) + r"=.*$"
    if re.search(pattern, text, re.MULTILINE):
        return re.sub(pattern, lambda _: line, text, flags=re.MULTILINE)
    return text + ("\n" if text and not text.endswith("\n") else "") + line + "\n"


def configure_browser(browser="waterfox.desktop", dry_run=False):
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    roots = [data, *(Path(p) for p in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"))]
    desktop = next((root / "applications" / browser for root in roots
                    if (root / "applications" / browser).is_file()), data / "applications" / browser)
    if not desktop.is_file():
        raise ValueError("Browser launcher is missing: " + str(desktop))
    environment = os.environ.get("XDG_CURRENT_DESKTOP", os.environ.get("DESKTOP_SESSION", "")).lower()
    if "xfce" in environment:
        # Exo uses a separate helper registry; MIME defaults alone are insufficient.
        text = desktop.read_text()
        match = re.search(r"^Exec=(.+)$", text, re.MULTILINE)
        if match is None:
            raise ValueError("Browser launcher has no Exec command")
        command = match.group(1)
        bare = re.sub(r"\s+%[fFuU]", "", command)
        with_url = re.sub(r"%[fFuU]", '"%s"', command)
        helper = ("[Desktop Entry]\nType=X-XFCE-Helper\nName=Waterfox\nIcon=waterfox\n"
                  "X-XFCE-Category=WebBrowser\nX-XFCE-Commands=" + bare + ";\n"
                  "X-XFCE-CommandsWithParameter=" + with_url + ";\n")
        ensure_file(data / "xfce4/helpers" / browser, helper.encode(), dry_run=dry_run)
        registry = config / "xfce4/helpers.rc"
        previous = registry.read_text() if registry.exists() else ""
        desired = set_helper_key(previous, "WebBrowser", browser.removesuffix(".desktop"))
        ensure_file(registry, desired.encode(), dry_run=dry_run)
    elif query("xdg-settings", "get", "default-web-browser") != browser:
        if not dry_run:
            subprocess.run(["xdg-settings", "set", "default-web-browser", browser], check=True)
    for mime in BROWSER_MIMES:
        if query("xdg-mime", "query", "default", mime) != browser and not dry_run:
            subprocess.run(["xdg-mime", "default", browser, mime], check=True)
    if not dry_run:
        if query("xdg-settings", "get", "default-web-browser") != browser:
            raise ValueError("Desktop preferred browser did not change to " + browser)
        for mime in BROWSER_MIMES:
            if query("xdg-mime", "query", "default", mime) != browser:
                raise ValueError("Browser association did not take effect: " + mime)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", default="waterfox.desktop")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    configure_browser(args.browser, args.dry_run)
