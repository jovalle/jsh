#!/usr/bin/env python3
"""Shared animated progress display, importable or driven by JSON lines on stdin.

Python: from lib.ui.progress import Progress
Shell: producer | lib/ui/cli.sh progress Checking 100
Events: {"completed": 1, "failed": 0, "endpoint": "example.test HTTPS...",
         "message": "Checked example.test"}
Only messages are printed when stdout is redirected. EOF finishes the display.
"""

from __future__ import annotations

import argparse
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse


@lru_cache(maxsize=1)
def progress_theme():
    """Use the shell UI's semantic colors and canonical spinner frames."""
    cli = Path(__file__).with_name("cli.sh")
    try:
        result = subprocess.run(
            [str(cli), "progress-theme"], check=True, capture_output=True, text=True
        )
    except subprocess.CalledProcessError as error:
        raise RuntimeError("Could not load the shared Jsh UI theme") from error
    values = result.stdout.splitlines()
    if len(values) < 6:
        raise RuntimeError("Incomplete Jsh progress theme")
    return dict(zip(("accent", "success", "error", "muted", "warn"), values[:5])), values[5:]


def interactive_output() -> bool:
    return (
        sys.stdout.isatty()
        and os.environ.get("TERM") != "dumb"
        and os.environ.get("JSH_PLAIN_OUTPUT") != "1"
    )


def print_status(label: str, message: str, state: str = "warn") -> None:
    color = progress_theme()[0][state] if interactive_output() else ""
    reset = "\033[0m" if color else ""
    print(f"{color}{label}: {message}{reset}", flush=True)


def clear_progress() -> None:
    if interactive_output():
        print("\r\033[K", end="", flush=True)


def format_duration(seconds: float) -> str:
    seconds = max(0, round(seconds))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes:02d}m"
    if minutes:
        return f"{minutes}m {seconds:02d}s"
    return f"{seconds}s"


class Progress:
    def __init__(self, label: str, total: int) -> None:
        self.label = label
        self.colors, self.frames = progress_theme()
        self.total = total
        self.completed = 0
        self.failed = 0
        self.endpoint = "Starting..."
        self.started_at = time.monotonic()
        self.visible = False
        self.frame = 0
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.animate, daemon=True)

    def report(self, endpoint: str) -> None:
        with self.lock:
            self.endpoint = endpoint

    def bar_line(self) -> str:
        remaining = self.total - self.completed
        elapsed = time.monotonic() - self.started_at
        eta = elapsed / self.completed * remaining if self.completed else 0
        percent = self.completed / self.total * 100 if self.total else 100
        green, red, muted, accent = (
            self.colors[key] for key in ("success", "error", "muted", "accent")
        )
        reset = "\033[0m" if accent else ""
        counts = (
            f" {percent:5.1f}%  {self.completed}/{self.total}  "
            f"{green}✓ {self.completed - self.failed}{reset}  {red}✗ {self.failed}{reset}  "
            f"{remaining} left  ETA {format_duration(eta)}"
        )
        columns = shutil.get_terminal_size().columns
        plain_counts = re.sub(r"\033\[[0-9;]*m", "", counts)
        width = max(1, min(30, columns - len(plain_counts) - len("Progress ") - 1))
        filled = round(width * percent / 100)
        bar = f"{accent}{'━' * filled}{muted}{'─' * (width - filled)}{reset}"
        status = f"Progress {bar}{counts}"
        available = columns - len("Progress ") - width - len(plain_counts) - 3
        if available >= 12:
            target = self.endpoint.split()[0]
            try:
                hostname = urllib.parse.urlsplit(target).hostname or target
            except ValueError:
                hostname = target
            status += f"  {muted}{hostname[:available]}{reset}"
        return status

    def clear(self) -> None:
        if self.visible:
            # The cursor stays on the bar, one line below the processing spinner.
            print("\r\033[K\033[1A\r\033[K", end="", flush=True)
            self.visible = False

    def render(self) -> None:
        if not interactive_output():
            return
        self.clear()
        columns = shutil.get_terminal_size().columns
        spinner = self.frames[self.frame % len(self.frames)]
        processing = f"{spinner} {self.label} {self.endpoint}"
        print(processing[: max(1, columns - 1)] + "\n" + self.bar_line(), end="", flush=True)
        self.visible = True
        self.frame += 1

    def animate(self) -> None:
        while not self.stopped.wait(0.1):
            with self.lock:
                self.render()

    def __enter__(self):
        if interactive_output():
            self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stopped.set()
        if self.thread.is_alive():
            self.thread.join()
        self.clear()
        if exc[0] is None and self.total and interactive_output():
            print(self.bar_line(), flush=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("total", type=int)
    args = parser.parse_args(argv)
    if args.total < 0:
        parser.error("total cannot be negative")
    try:
        with Progress(args.label, args.total) as progress:
            for line in sys.stdin:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError("progress events must be JSON objects")
                completed = event.get("completed", progress.completed)
                failed = event.get("failed", progress.failed)
                endpoint = event.get("endpoint", progress.endpoint)
                message = event.get("message")
                if (
                    type(completed) is not int
                    or type(failed) is not int
                    or not 0 <= failed <= completed <= args.total
                    or not isinstance(endpoint, str)
                    or (message is not None and not isinstance(message, str))
                ):
                    raise ValueError("invalid progress counts or text")
                with progress.lock:
                    progress.clear()
                    progress.completed, progress.failed = completed, failed
                    progress.endpoint = endpoint
                    if message is not None:
                        print(message, flush=True)
                    progress.render()
        return 0
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Progress: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
