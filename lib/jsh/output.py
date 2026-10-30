"""Terminal output in the style of bun: one transient progress line, then a short summary."""

import itertools
import os
import re
import shutil
import sys
import threading
import time
from collections import Counter, deque
from pathlib import Path

FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
MARKS = {"+": "32", "~": "33", "-": "31"}
PENDING = {
    "installed": "to install",
    "linked": "to link",
    "configured": "to configure",
    "updated": "to update",
    "removed": "to remove",
}


def styled(stream):
    return stream.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"


def duration(seconds):
    return f"{seconds * 1000:.0f}ms" if seconds < 1 else f"{seconds:.2f}s"


def tilde(path):
    home, text = str(Path.home()), str(path)
    return "~" + text[len(home) :] if text == home or text.startswith(home + os.sep) else text


class Display:  # pylint: disable=too-many-instance-attributes
    """Owns the terminal for one run: the spinner line, notices, and the closing summary."""

    def __init__(self, stream=None, dry_run=False):
        self.stream = stream or sys.stdout
        self.color = styled(self.stream)
        self.dry_run = dry_run
        self.changes = []
        self.counts = Counter()
        self.checked = 0
        self.failed = 0
        self.total = 0
        self.done = 0
        self.label = ""
        self.detail = ""
        self.started = time.monotonic()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None

    def paint(self, text, code):
        return f"\033[{code}m{text}\033[0m" if self.color else text

    def change_text(self, text, group):
        """Color version transitions while keeping repository dates subdued."""
        if group not in ("Packages", "Repositories"):
            return text
        match = re.fullmatch(
            r"(\S+) (\S+)( \(\d{4}-\d{2}-\d{2}\))? → (\S+)( \(\d{4}-\d{2}-\d{2}\))?",
            text,
        )
        if not match:
            match = re.fullmatch(r"(\S+) → (\S+)", text)
            if match:
                return f"{match[1]} → {self.paint(match[2], '32')}"
            return text
        name, old, old_date, new, new_date = match.groups()
        old_date = self.paint(old_date, "2") if old_date else ""
        new_date = self.paint(new_date, "2") if new_date else ""
        return f"{name} {self.paint(old, '31')}{old_date} → {self.paint(new, '32')}{new_date}"

    def detail_lines(self, detail):
        """Render before and after values as a readable terminal diff."""
        label, separator, values = detail.partition(": ")
        old, arrow, new = values.partition(" → ")
        if not separator or not arrow:
            return [f"  {detail}"]
        return [
            f"  {label}:",
            f"    {self.paint('- ' + old, '31')}",
            f"    {self.paint('+ ' + new, '32')}",
        ]

    def header(self, command, detail):
        if self.stream.isatty():
            source = (Path(__file__).resolve().parents[2] / "lib/output.sh").read_text()
            banner = source.split("<<'BANNER'\n", 1)[1].split("\nBANNER", 1)[0]
            lines = banner.splitlines()
            title = command.removeprefix("jsh ")
            lines[-1] = f" =   :-=-:{title:^26}-:"
            self._write(self.paint("\n".join(lines), "1;36") + "\n")
            self._write(f"{self.paint(detail, '2')}\n")
        else:
            self._write(f"{self.paint(command, '1')} {self.paint(detail, '2')}\n")

    def begin(self, total):
        self.total = total
        if self.color and self._thread is None:
            self.stream.write("\033[?25l")
            self._stop.clear()
            self._thread = threading.Thread(target=self._spin, daemon=True)
            self._thread.start()

    def end(self):
        if self._thread:
            self._stop.set()
            self._thread.join()
            self._thread = None
            self.stream.write("\r\033[K\033[?25h")
            self.stream.flush()

    def task(self, label):
        with self._lock:
            self.label, self.detail = label, ""

    def progress(self, text):
        with self._lock:
            self.detail = text

    def reach(self, units):
        with self._lock:
            self.done = max(self.done, min(units, self.total))

    def change(self, mark, text, verb, group, source=None, *, details=()):
        with self._lock:
            self.changes.append((mark, text, group, source, tuple(details)))
            self.counts[verb] += 1
            self.checked += 1

    def current(self):
        with self._lock:
            self.checked += 1

    def notice(self, label, text):
        self._write(f"{self.paint('!', '33')} {self.paint(label + ':', '1')} {text}\n")

    def failure(self, label, message, log=None):
        with self._lock:
            self.failed += 1
        head = f"{self.paint('✗', '31')} {self.paint(label + ':', '1')}"
        lines = [f"{head} {self.paint(message, '31')}"]
        if log and Path(log).exists():
            with open(log, encoding="utf-8", errors="replace") as stream:
                lines += [self.paint(f"  │ {text.rstrip()}", "2") for text in deque(stream, 12)]
            lines.append(self.paint(f"  log: {tilde(log)}", "2"))
        self._write("\n".join(lines) + "\n")

    def summary(self, interrupted=False):
        self.end()
        out = []
        if self.changes:
            for group in ("Packages", "Repositories", "Links", "Configuration", "Other changes"):
                entries = [change for change in self.changes if change[2] == group]
                if not entries:
                    continue
                out += ["", self.paint(group, "1")]
                for mark, text, _, source, details in entries:
                    redundant = (
                        group != "Packages"
                        and source
                        and re.search(rf"\b{re.escape(source)}\b", text, re.IGNORECASE)
                    )
                    if group == "Packages" and source:
                        label = " " + self.paint(source, "2")
                    else:
                        label = f" [{source}]" if source and not redundant else ""
                    out.append(
                        f"{self.paint(mark, MARKS[mark])} "
                        f"{self.change_text(text, group)}{label}"
                    )
                    for detail in details:
                        out.extend(self.detail_lines(detail))
        elapsed = self.paint(f"[{duration(time.monotonic() - self.started)}]", "2")
        if self.counts:
            parts = [
                f"{count} {PENDING.get(verb, verb) if self.dry_run else verb}"
                for verb, count in self.counts.items()
            ]
        else:
            parts = [f"Checked {self.checked} items (no changes)"]
        if self.failed:
            parts.append(self.paint(f"{self.failed} failed", "31"))
        if interrupted:
            parts.append(self.paint("interrupted", "33"))
        out += ["", f"{', '.join(parts)} {elapsed}"]
        self._write("\n".join(out) + "\n")

    def _write(self, text):
        with self._lock:
            if self._thread:
                self.stream.write("\r\033[K")
            self.stream.write(text)
            self.stream.flush()

    def _spin(self):
        for frame in itertools.cycle(FRAMES):
            with self._lock:
                counter = f"[{self.done}/{self.total}]"
                head = f"{self.paint(frame, '36')} {self.label} {self.paint(counter, '2')}"
                room = shutil.get_terminal_size().columns - len(self.label) - len(counter) - 4
                detail = self.detail
                if len(detail) > room:
                    detail = detail[: max(room - 1, 0)] + "…"
                line = f"{head} {self.paint(detail, '2')}" if detail and room > 0 else head
                self.stream.write(f"\r\033[K{line}")
                self.stream.flush()
            if self._stop.wait(0.08):
                return
