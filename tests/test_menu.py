"""Exercise terminal navigation and restoration using a pseudo-terminal."""

import os
import pty
import select
import subprocess
import sys
import termios
import time
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
from jsh import menu  # pylint: disable=wrong-import-position


class MenuTests(unittest.TestCase):
    def test_rows_align_breadcrumbs_and_fit_width(self):
        first = menu.item_line(
            ("core", "Essentials / core", "Core tools"), True, True, True, 20, 60, False
        )
        second = menu.item_line(
            ("dock", "Desktop / dock", "Favorites"), False, False, True, 20, 60, False
        )
        self.assertEqual(first.index("Core tools"), second.index("Favorites"))
        self.assertLessEqual(len(first), 60)
        self.assertNotIn("\033[", first)

    def test_preset_and_selection_colors_are_independent(self):
        line = menu.item_line(("minimal", "Minimal", "Core"), True, False, False, 12, 60, True)
        self.assertIn("\033[33m>\033[0m", line)
        self.assertIn("\033[1mMinimal\033[0m", line)
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
            stream = mock.Mock()
            stream.isatty.return_value = True
            self.assertFalse(menu.styled(stream))

    def test_arrow_selection_restores_terminal_mode(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        original = termios.tcgetattr(slave)
        code = (
            "from jsh.menu import choose; "
            "print('RESULT=' + str(choose('Pick', [('a','A',''),('b','B','')])))"
        )
        env = {**os.environ, "PYTHONPATH": str(ROOT / "lib"), "TERM": "xterm", "NO_COLOR": "1"}
        process = subprocess.Popen(  # pylint: disable=consider-using-with
            [sys.executable, "-c", code], stdin=slave, stdout=slave, stderr=slave, env=env
        )
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        output = b""
        while b"Pick" not in output:
            self.assertTrue(select.select([master], [], [], 5)[0], "menu did not appear")
            output += os.read(master, 4096)
        self.assertIn(b"Pick\n\n", output.replace(b"\r", b""))
        os.write(master, b"\x1b[B\r")
        # TCSADRAIN blocks the child until its pending output is read.
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 4096)
        self.assertEqual(process.wait(timeout=1), 0)
        while select.select([master], [], [], 0)[0]:
            output += os.read(master, 4096)
        self.assertIn(b"RESULT=b", output)
        # The kernel sets and clears PENDIN on its own, so it is not a restored setting.
        restored = termios.tcgetattr(slave)
        for attrs in (original, restored):
            attrs[3] &= ~getattr(termios, "PENDIN", 0)
        self.assertEqual(restored, original)


if __name__ == "__main__":
    unittest.main()
