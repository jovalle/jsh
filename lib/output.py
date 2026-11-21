#!/usr/bin/env python3
"""Render jsh output events."""

import argparse
from contextlib import contextmanager
import locale
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import threading
from typing import Dict, Iterator, List, Optional, TextIO, Tuple

MARKER = "\x1e"
SYMBOLS = {
    "ok": ("✓", "32"),
    "drift": ("!", "33"),
    "added": ("+", "32"),
    "changed": ("~", "33"),
    "removed": ("-", "31"),
    "fail": ("✕", "31"),
    "notice": ("!", "33"),
}
CHANGE_KINDS = ("added", "changed", "removed")
PLANNED_ACTIONS = {"added": "add", "changed": "change", "removed": "remove"}
BRAILLE_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
ASCII_FRAMES = "|/-\\"
CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(r"\x1b\](?:[^\x07\x1b]|\x1b(?!\\))*(?:\x07|\x1b\\)")
C0 = re.compile(r"[\x00-\x09\x0b-\x1f\x7f]")


def verbs() -> Dict[str, Tuple[str, str]]:
    """Return the supported step verbs and their present and past forms."""
    table = {}
    path = Path(__file__).with_name("verbs.tsv")
    try:
        with path.open(encoding="utf-8") as rows:
            for number, row in enumerate(rows, 1):
                row = row.rstrip("\n")
                if not row or row.startswith("#"):
                    continue
                fields = row.split("\t")
                if len(fields) != 3 or not all(fields):
                    raise ValueError(f"{path}:{number}: expected verb, ing, and past")
                table[fields[0]] = (fields[1], fields[2])
    except OSError:
        return {}
    return table


def _display_verbs() -> Dict[str, Tuple[str, str]]:
    try:
        return verbs()
    except ValueError:
        return {}


def _paint(text: str, code: str, color: bool) -> str:
    if not color:
        return text
    return f"\x1b[{code}m{text}\x1b[0m"


def _code_spans(text: str, color: bool) -> List[Tuple[str, int]]:
    """Split text into words and `code` spans as (display, width) tokens."""
    tokens = []
    for part in re.split(r"(`[^`]+`)", text):
        if len(part) > 2 and part.startswith("`") and part.endswith("`"):
            shown = part[1:-1] if color else part
            tokens.append((_paint(shown, "36", color), len(shown)))
        else:
            tokens.extend((word, len(word)) for word in part.split())
    return tokens


def format_notice(text: str, width: int = 0, color: bool = False) -> List[str]:
    """Format one Action needed entry as a bullet with a hanging indent."""
    bullet = "  " + _paint("•", "1;33", color) + " "
    indent = "    "
    lines: List[str] = []
    line, used = "", 0
    limit = max(width - len(indent), 20) if width else 0
    for shown, size in _code_spans(_display_path(_sanitize(text)), color):
        if line and limit and used + 1 + size > limit:
            lines.append(line)
            line, used = "", 0
        if line:
            line += " "
            used += 1
        line += shown
        used += size
    lines.append(line)
    return [(bullet if index == 0 else indent) + line for index, line in enumerate(lines)]


def _sanitize(text: str) -> str:
    text = CSI.sub("", text)
    text = OSC.sub("", text)
    return C0.sub("", text)


def _display_path(text: str) -> str:
    if text.startswith("$HOME/"):
        return "~/" + text[len("$HOME/") :]
    home = os.environ.get("HOME", "").rstrip("/")
    if home and text.startswith(home + "/"):
        return "~/" + text[len(home) + 1 :]
    return text


def format_item(
    kind: str, text: str, was: str = "", preview: bool = False, color: bool = False
) -> List[str]:
    """Format one item event as one or more display lines."""
    text = _display_path(_sanitize(text))
    was = _display_path(_sanitize(was))
    if kind in CHANGE_KINDS:
        if preview:
            fact = was or text
            suffix = _paint(f"  would {PLANNED_ACTIONS[kind]}", "2", color)
            return ["{} {}{}".format(_paint("!", "33", color), fact, suffix)]
        lines = []
        if was:
            lines.append("{} {}".format(_paint("!", "33", color), was))
        symbol, code = SYMBOLS[kind]
        lines.append(f"{_paint(symbol, code, color)} {text}")
        return lines
    if kind == "output":
        return [_paint(f"    {text}", "2", color)]
    if kind in ("info", "skip"):
        return [_paint(text, "2", color)]
    if kind not in SYMBOLS:
        return [_paint(f"    {text}", "2", color)]
    symbol, code = SYMBOLS[kind]
    if kind == "notice" and color:
        text = re.sub(r"`([^`]+)`", lambda match: _paint(match[1], "36", color), text)
    return [f"{_paint(symbol, code, color)} {text}"]


class Renderer:
    """Consume event lines and render the jsh output layout."""

    def __init__(
        self, out: TextIO, *, tty: bool, color: bool, preview: bool, report: Optional[Path]
    ):
        self.out = out
        self.tty = tty
        self.color = color
        self.preview = preview
        self.report = report
        self._verbs = _display_verbs()
        self._step: Optional[Tuple[str, str]] = None
        self._group: Optional[Tuple[str, str]] = None
        self._group_items = 0
        self._group_skips = 0
        self._group_failed = False
        self._progress = ""
        self._task: Optional[Tuple[str, Optional[Path]]] = None
        self._ended = False
        self._closed = False
        self._frame = 0
        self._displayed_lines = 0
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        if tty:
            self._thread = threading.Thread(target=self._spin, daemon=True)
            self._thread.start()

    def _write(self, line: str = "") -> None:
        with self._lock:
            if self.tty:
                self._clear_spinner()
            self.out.write(line + "\n")
            if self.tty:
                spinner = self._spinner_line(self._task, "")
                if spinner is not None:
                    self._draw_spinner(spinner)
            self.out.flush()

    def _clear_spinner(self) -> None:
        for index in range(self._displayed_lines):
            self.out.write("\r\x1b[K")
            if index + 1 < self._displayed_lines:
                self.out.write("\x1b[1A")
        self._displayed_lines = 0

    def _draw_spinner(self, line: str) -> None:
        self.out.write(line)
        self._displayed_lines = line.count("\n") + 1

    @staticmethod
    def _frames() -> str:
        lc_ctype = os.environ.get("LC_CTYPE", "").lower()
        lang = os.environ.get("LANG")
        coerced = lc_ctype in ("c.utf-8", "c.utf8", "utf-8")
        if (
            not os.environ.get("LC_ALL")
            and coerced
            and (lang is None or lang.upper() in ("C", "POSIX"))
        ):
            return ASCII_FRAMES
        try:
            locale.setlocale(locale.LC_CTYPE, "")
            encoding = locale.nl_langinfo(locale.CODESET)
        except (AttributeError, locale.Error):
            encoding = locale.getpreferredencoding(False)
        if encoding.lower().replace("-", "").replace("_", "") == "utf8":
            return BRAILLE_FRAMES
        return ASCII_FRAMES

    def _width(self) -> int:
        try:
            width = os.get_terminal_size(self.out.fileno()).columns
        except (AttributeError, OSError):
            width = shutil.get_terminal_size(fallback=(80, 24)).columns
        return width if width > 1 else 80

    @staticmethod
    def _log_lines(path: Path) -> List[str]:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            return []
        lines = []
        for raw in text.split("\n"):
            raw = raw.removesuffix("\r")
            line = _sanitize(raw.rsplit("\r", 1)[-1])
            if line:
                lines.append(line)
        return lines

    @staticmethod
    def _last_log_line(path: Path) -> str:
        try:
            with path.open("rb") as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 8192))
                text = log.read().decode("utf-8", errors="replace")
        except (OSError, ValueError):
            return ""
        for raw in reversed(text.split("\n")):
            raw = raw.removesuffix("\r")
            line = _sanitize(raw.rsplit("\r", 1)[-1])
            if line:
                return line
        return ""

    def _spinner_line(
        self, task: Optional[Tuple[str, Optional[Path]]], latest: str
    ) -> Optional[str]:
        if self._step is None:
            return None
        verb, obj = self._step
        ing = self._verbs.get(verb, (verb, verb))[0]
        progress = self._progress
        if self._task is not None:
            label, _ = self._task
            progress = label
            if self._task == task and latest:
                progress += f"  {latest}"
        frames = self._frames()
        frame = frames[self._frame % len(frames)]
        self._frame += 1
        base = f"{frame} {ing} {obj}..."
        limit = self._width() - 1
        shown_base = base[:limit]
        shown_suffix = f"  {progress}"[:limit] if progress else ""
        line = _paint(shown_base, "1", self.color)
        if shown_suffix:
            line = _paint(shown_suffix, "2", self.color) + "\n" + line
        return line

    def _spin(self) -> None:
        while not self._stop.wait(0.1):
            with self._lock:
                task = self._task
            latest = self._last_log_line(task[1]) if task and task[1] else ""
            with self._lock:
                line = self._spinner_line(task, latest)
                if line is not None:
                    try:
                        self._clear_spinner()
                        self._draw_spinner(line)
                        self.out.flush()
                    except OSError:
                        self._stop.set()
                        return

    def _stop_spinner(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
        if self.tty:
            with self._lock:
                try:
                    self._clear_spinner()
                    self.out.flush()
                except OSError:
                    pass

    def _finish_step(self, stopped: bool = False) -> None:
        with self._lock:
            if self._step is None:
                return
            if self.tty:
                self._clear_spinner()
            verb, obj = self._step
            ing = self._verbs.get(verb, (verb, verb))[0]
            self._step = None
            self._progress = ""
            self._task = None
            if stopped and self._group is not None:
                self._group_failed = True
        if stopped:
            symbol = _paint("✕", "31", self.color)
            self._write(f"{symbol} Stopped {ing.lower()} {obj}")

    def _close_group(self) -> None:
        with self._lock:
            if self._group is None:
                return
            self._group = None
            self._group_items = 0
            self._group_skips = 0
            self._group_failed = False

    def _item(self, kind: str, text: str, was: str = "") -> None:
        lines = format_item(kind, text, was, self.preview, self.color)
        with self._lock:
            if self._group is not None:
                self._group_items += 1
                if kind == "skip":
                    self._group_skips += 1
                elif kind == "fail":
                    self._group_failed = True
        for line in lines:
            self._write(line)

    def _report_lines(self, name: str) -> List[str]:
        if self.report is None:
            return []
        try:
            return [
                _sanitize(line)
                for line in (self.report / name).read_text(encoding="utf-8").splitlines()
                if line
            ]
        except FileNotFoundError:
            return []

    def _summary(self, elapsed: str, status: Optional[str] = None) -> None:
        events = self._report_lines("events")
        failures = self._report_lines("failures")
        notices = self._report_lines("notices")
        counts = {kind: events.count(kind) for kind in CHANGE_KINDS}
        self._write()
        if failures or (status is not None and status != "0"):
            summary = _paint("Finished with errors", "1;31", self.color)
        elif self.preview:
            summary = "Preview complete"
        else:
            summary = _paint("Ready", "1;32", self.color)
        total = sum(counts.values())
        if self.preview:
            summary += f"  {total} would change" if total else "  No changes identified"
        elif total:
            for kind in CHANGE_KINDS:
                if counts[kind]:
                    summary += f"  {counts[kind]} {kind}"
        elif notices:
            summary += "  No changes made"
        else:
            summary += "  Everything is current"
        if failures:
            summary += f"  {len(failures)} failed"
        try:
            seconds = max(0, int(float(elapsed)))
        except (OverflowError, ValueError):
            seconds = 0
        summary += f"  {seconds // 60}m {seconds % 60:02d}s"
        self._write(summary)
        if self.preview:
            self._write("No settings changed")
        if failures:
            self._write()
            self._write(_paint("Failed", "1;31", self.color))
            for failure in failures:
                self._write("  {} {}".format(_paint("✕", "31", self.color), failure))
        if notices:
            self._write()
            self._write(_paint("Action needed", "1;33", self.color))
            width = self._width() if self.tty else 0
            for notice in notices:
                for line in format_notice(notice, width, self.color):
                    self._write(line)

    def feed(self, line: str) -> bool:
        """Consume one wire line and return false once an end event is seen."""
        if self._ended:
            return False
        line = line.removesuffix("\n").removesuffix("\r")
        if not line.startswith(MARKER):
            self._item("output", line)
            return True
        fields = line[len(MARKER) :].split("\t")
        event = fields[0]
        values = fields[1:]
        if event == "group":
            self._finish_step()
            self._close_group()
            name = _sanitize(values[0]) if values else ""
            purpose = _sanitize(values[1]) if len(values) > 1 else ""
            with self._lock:
                self._group = (name, purpose)
            self._write()
            heading = _paint(f"› {name}", "1;36", self.color)
            if purpose:
                heading += "  " + _paint(purpose, "2", self.color)
            self._write(heading)
        elif event == "step":
            self._finish_step()
            verb = _sanitize(values[0]) if values else ""
            obj = _sanitize(values[1]) if len(values) > 1 else ""
            with self._lock:
                self._step = (verb, obj)
                self._progress = ""
                self._task = None
            if not self.tty:
                ing = self._verbs.get(verb, (verb, verb))[0]
                self._write(_paint(f"{ing} {obj}...", "2", self.color))
        elif event == "stepclose":
            self._finish_step()
        elif event == "item":
            kind = values[0] if values else ""
            text = values[1] if len(values) > 1 else ""
            was = values[2] if len(values) > 2 else ""
            self._item(kind, text, was)
        elif event == "progress":
            with self._lock:
                self._progress = _sanitize(values[0]) if values else ""
        elif event == "task":
            label = _sanitize(values[0]) if values else ""
            log = Path(values[1]) if len(values) > 1 and values[1] else None
            with self._lock:
                self._progress = label
                self._task = (label, log)
        elif event == "taskend":
            status = values[0] if values else ""
            saved_text = values[1] if len(values) > 1 else ""
            with self._lock:
                task = self._task
                label = task[0] if task is not None else ""
            if status == "0" and self.tty and task is not None and task[1] is not None:
                latest = self._last_log_line(task[1])
                with self._lock:
                    line = self._spinner_line(task, latest)
                    if line is not None:
                        self._clear_spinner()
                        self._draw_spinner(line)
                        self.out.flush()
            with self._lock:
                self._task = None
                self._progress = ""
            if status != "0":
                self._item("fail", f"{label} failed ({_sanitize(status)})")
                tail = self._log_lines(Path(saved_text))[-10:]
                indent = min(
                    (len(line) - len(line.lstrip(" ")) for line in tail if line.strip()), default=0
                )
                for output in tail:
                    self._item("output", output[indent:])
                self._item("output", f"Log: {_sanitize(saved_text)}")
        elif event == "end":
            status = values[1] if len(values) > 1 else None
            self._finish_step(stopped=status in ("130", "143"))
            self._close_group()
            with self._lock:
                self._progress = ""
                self._task = None
            if self.report is not None:
                self._summary(values[0] if values else "0", status)
            self._ended = True
            return False
        else:
            self._item("output", line[len(MARKER) :])
        return True

    def close(self) -> None:
        """Flush an interrupted step and restore the terminal line."""
        if not self._ended:
            self._finish_step(stopped=True)
            self._close_group()
            self._ended = True
        self._stop_spinner()


def _color_enabled(stream: TextIO) -> bool:
    if "NO_COLOR" in os.environ or os.environ.get("TERM") == "dumb":
        return False
    setting = os.environ.get("JSH_COLOR", "auto")
    if setting == "never":
        return False
    if setting == "always":
        return True
    try:
        return stream.isatty()
    except (AttributeError, OSError):
        return False


_active_renderer: Optional[Renderer] = None


def _wire_field(value: str) -> str:
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ").replace(MARKER, "")


def _event(event: str, *values: str) -> bool:
    if _active_renderer is None:
        return False
    fields = "\t".join(_wire_field(value) for value in values)
    line = MARKER + event
    if fields:
        line += "\t" + fields
    _active_renderer.feed(line + "\n")
    return True


def _write_lines(stream: TextIO, lines: List[str]) -> None:
    for line in lines:
        stream.write(line + "\n")
    stream.flush()


def _print_item(kind: str, text: str, was: str = "") -> None:
    if _event("item", kind, text, was):
        return
    stream = sys.stderr if kind in ("drift", "fail", "notice") else sys.stdout
    _write_lines(
        stream,
        format_item(
            kind,
            text,
            was,
            preview=os.environ.get("JSH_DRY_RUN") == "1",
            color=_color_enabled(stream),
        ),
    )


def group(name: str, purpose: str = "") -> None:
    if _event("group", name, purpose):
        return
    stream = sys.stdout
    color = _color_enabled(stream)
    name = _sanitize(name)
    purpose = _sanitize(purpose)
    heading = _paint(f"› {name}", "1;36", color)
    if purpose:
        heading += "  " + _paint(purpose, "2", color)
    _write_lines(stream, ["", heading])


def step(verb: str, obj: str) -> None:
    if _event("step", verb, obj):
        return
    stream = sys.stdout
    verb = _sanitize(verb)
    obj = _sanitize(obj)
    ing = _display_verbs().get(verb, (verb, verb))[0]
    _write_lines(stream, [_paint(f"{ing} {obj}...", "2", _color_enabled(stream))])


def ok(text: str) -> None:
    _print_item("ok", text)


def drift(text: str) -> None:
    _print_item("drift", text)


def added(text: str, was: str = "") -> None:
    _print_item("added", text, was)


def changed(text: str, was: str = "") -> None:
    _print_item("changed", text, was)


def removed(text: str, was: str = "") -> None:
    _print_item("removed", text, was)


def fail(text: str) -> None:
    _print_item("fail", text)


def info(text: str) -> None:
    _print_item("info", text)


def notice(text: str) -> None:
    _print_item("notice", text)


def skipped(text: str) -> None:
    _print_item("skip", f"Skipping {text}")


@contextmanager
def session() -> Iterator[Renderer]:
    global _active_renderer
    if _active_renderer is not None:
        yield _active_renderer
        return

    stream = sys.stdout
    renderer = Renderer(
        stream,
        tty=stream.isatty(),
        color=_color_enabled(stream),
        preview=os.environ.get("JSH_DRY_RUN") == "1",
        report=None,
    )
    _active_renderer = renderer
    try:
        yield renderer
    except BaseException:
        renderer.close()
        raise
    else:
        renderer.feed(MARKER + "end\t0\n")
    finally:
        _active_renderer = None
        renderer.close()


def _render(args: argparse.Namespace) -> int:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    tty = sys.stdout.isatty()
    color = _color_enabled(sys.stdout)
    renderer = Renderer(sys.stdout, tty=tty, color=color, preview=args.preview, report=args.report)
    for line in sys.stdin:
        if not renderer.feed(line):
            break
    renderer.close()
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    render = commands.add_parser("render")
    render.add_argument("--preview", action="store_true")
    render.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    if args.command == "render":
        return _render(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
