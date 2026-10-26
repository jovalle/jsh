"""Step output stays readable without a terminal and keeps logs only for failures."""

import contextlib
import importlib.util
import io
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jsh_output", ROOT / "lib/output.py")
OUTPUT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OUTPUT)


class OutputTests(unittest.TestCase):
    def capture(self, body):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            body()
        return stream.getvalue()

    def test_plain_result_lists_changes_before_current_and_items_after(self):
        def body():
            with OUTPUT.Step("tools"):
                OUTPUT.count("current", 5)
                OUTPUT.count("installed", 2)
                OUTPUT.item("jq")

        lines = self.capture(body).splitlines()
        self.assertRegex(lines[0], r"^✓ tools     2 installed · 5 current {4}\[\d+ms\]$")
        self.assertEqual(lines[1], "  + jq")
        self.assertNotIn("\033", "".join(lines))

    def test_timings_share_a_column_across_summaries(self):
        def body():
            with OUTPUT.Step("core"):
                OUTPUT.count("current", 5)
            with OUTPUT.Step("runtime"):
                OUTPUT.count("installed", 12)
                OUTPUT.count("current", 3)

        lines = self.capture(body).splitlines()
        self.assertEqual(lines[0].index("["), 39)
        self.assertEqual(lines[1].index("["), 39)

    def test_current_children_are_listed_under_a_blank_summary(self):
        def body():
            with OUTPUT.Step("core"):
                OUTPUT.current("bash")
                OUTPUT.current("git")

        lines = self.capture(body).splitlines()
        self.assertRegex(lines[0], r"^✓ core {33}\[\d+ms\]$")
        self.assertEqual(lines[1:], ["  ✓ bash", "  ✓ git"])

    def test_skip_replaces_the_summary_with_the_reason(self):
        def body():
            with OUTPUT.Step("helium"):
                OUTPUT.skip("close the browser")

        self.assertEqual(self.capture(body), "○ helium    close the browser\n")

    def test_successful_command_output_is_hidden_and_log_removed(self):
        logs = []

        def body():
            with OUTPUT.Step("core") as step:
                OUTPUT.run(["sh", "-c", "echo noisy"])
                logs.append(step.log)

        self.assertNotIn("noisy", self.capture(body))
        self.assertFalse(os.path.exists(logs[0]))

    def test_failed_command_shows_log_tail_and_keeps_log(self):
        logs = []

        def body():
            with self.assertRaises(subprocess.CalledProcessError):
                with OUTPUT.Step("core") as step:
                    logs.append(step)
                    OUTPUT.run(["sh", "-c", "echo boom; exit 3"])

        text = self.capture(body)
        self.addCleanup(os.unlink, logs[0].log)
        self.assertRegex(text.splitlines()[0], r"^✗ core {33}\[\d+ms\]$")
        self.assertIn("  │ boom", text)
        self.assertIn("log: ", text)


if __name__ == "__main__":
    unittest.main()
