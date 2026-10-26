"""Colored, symbol-led terminal output with spinner steps for jsh Python scripts."""

import itertools
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
# Summaries are padded to this width so step timings share a column.
SUMMARY_WIDTH = 26


def styled(stream=None):
    stream = stream or sys.stdout
    return stream.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"


def paint(text, code, stream=None):
    return f"\033[{code}m{text}\033[0m" if styled(stream) else text


def duration(seconds):
    return f"{seconds * 1000:.0f}ms" if seconds < 1 else f"{seconds:.2f}s"


def tilde(path):
    home, text = str(Path.home()), str(path)
    return "~" + text[len(home) :] if text == home or text.startswith(home + os.sep) else text


def warn(text):
    print(f"{paint('!', '33', sys.stderr)} {paint(text, '33', sys.stderr)}", file=sys.stderr)


def error(text):
    print(f"{paint('✗', '31', sys.stderr)} {paint(text, '31', sys.stderr)}", file=sys.stderr)


def _emit(text):
    if Step.active:
        Step.active.lines.append(text)
    else:
        print(text, flush=True)


def item(text):
    _emit(f"  {paint('+', '32')} {text}")


def current(text):
    _emit(f"  {paint('✓', '32')} {paint(text, '2')}")


def note(text):
    _emit(paint(f"  › {text}", "2"))


def attention(text):
    _emit(f"  {paint('!', '33')} {paint(text, '33')}")


def count(label, amount=1):
    if Step.active:
        Step.active.counts[label] = Step.active.counts.get(label, 0) + amount


def progress(text):
    if Step.active:
        Step.active.detail = text


def skip(reason):
    if Step.active:
        Step.active.skipped = reason
    else:
        print(f"{paint('○', '33')} {paint(reason, '33')}", flush=True)


def run(arguments):
    """Run a command, keeping its output in the active step's log instead of the terminal."""
    step = Step.active
    if step is None:
        subprocess.run(arguments, check=True)
        return
    if step.log is None:
        (ROOT / "tmp").mkdir(exist_ok=True)
        descriptor, step.log = tempfile.mkstemp(
            prefix=f"jsh-{step.label}-", suffix=".log", dir=ROOT / "tmp"
        )
        os.close(descriptor)
    with open(step.log, "a", encoding="utf-8") as stream:
        stream.write(f"$ {shlex.join(arguments)}\n")
        stream.flush()
        subprocess.run(
            arguments,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=stream,
            stderr=subprocess.STDOUT,
        )


class Step:
    """One labelled unit of work: a spinner while running, then a single result line."""

    active = None

    def __init__(self, label):
        self.label = label
        self.detail = ""
        self.counts = {}
        self.lines = []
        self.skipped = None
        self.log = None
        self.started = time.monotonic()
        self._done = threading.Event()
        self._spinner = None

    def __enter__(self):
        Step.active = self
        if styled():
            sys.stdout.write("\033[?25l")
            self._spinner = threading.Thread(target=self._spin, daemon=True)
            self._spinner.start()
        return self

    def _spin(self):
        for frame in itertools.cycle(FRAMES):
            room = shutil.get_terminal_size().columns - len(self.label) - 6
            detail = self.detail
            if len(detail) > room:
                detail = detail[: max(room - 1, 0)] + "…"
            suffix = "  " + paint(detail, "2") if detail and room > 0 else ""
            sys.stdout.write(f"\r\033[K{paint(frame, '36')} {self.label}{suffix}")
            sys.stdout.flush()
            if self._done.wait(0.08):
                return

    def summary(self):
        counts = [(label, number) for label, number in self.counts.items() if number]
        if not counts:
            return ""
        counts.sort(key=lambda entry: entry[0] == "current")
        return " · ".join(f"{number} {label}" for label, number in counts)

    def __exit__(self, kind, value, trace):
        Step.active = None
        if self._spinner:
            self._done.set()
            self._spinner.join()
            sys.stdout.write("\r\033[K\033[?25h")
        elapsed = paint(f"[{duration(time.monotonic() - self.started)}]", "2")
        if kind is not None:
            parts = [paint("✗", "31"), f"{self.label:<9}", " " * SUMMARY_WIDTH, elapsed]
        elif self.skipped:
            parts = [paint("○", "33"), f"{self.label:<9}", paint(self.skipped, "33")]
        else:
            summary = f"{self.summary():<{SUMMARY_WIDTH}}"
            parts = [paint("✓", "32"), f"{self.label:<9}", paint(summary, "2"), elapsed]
        print(" ".join(parts), flush=True)
        for text in self.lines:
            print(text, flush=True)
        if self.log and kind is not None:
            with open(self.log, encoding="utf-8", errors="replace") as stream:
                for text in deque(stream, maxlen=20):
                    print(paint(f"  │ {text.rstrip()}", "2"))
            print(paint(f"  log: {tilde(self.log)}", "2"), flush=True)
        elif self.log:
            os.unlink(self.log)
        return False
