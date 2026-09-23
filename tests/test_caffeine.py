import importlib.machinery
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("caffeine", str(ROOT / "bin/caffeine"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
CAFFEINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CAFFEINE
LOADER.exec_module(CAFFEINE)


class MacOSCaffeineTests(unittest.TestCase):
    def run_child(self, assertion_output: str, returncode: int = 0):
        completed = subprocess.CompletedProcess(
            ["pmset", "-g", "assertions"],
            returncode,
            stdout=assertion_output,
            stderr="",
        )
        with (
            patch.object(CAFFEINE.sys, "argv", ["caffeine", CAFFEINE.MACOS_CHILD_ARGUMENT]),
            patch.object(CAFFEINE.os, "getpid", return_value=1234),
            patch.object(CAFFEINE.subprocess, "run", return_value=completed) as run,
            patch.object(CAFFEINE, "wait_until_stopped") as wait_until_stopped,
        ):
            CAFFEINE.run_macos()
        return run, wait_until_stopped

    def test_child_accepts_caffeinate_assertion_for_its_pid(self):
        run, wait_until_stopped = self.run_child(
            "Details: caffeinate asserting on behalf of '/usr/bin/python3' (pid 1234)\n"
        )

        run.assert_called_once_with(
            ["pmset", "-g", "assertions"],
            check=False,
            capture_output=True,
            text=True,
        )
        wait_until_stopped.assert_called_once()

    def test_child_rejects_assertion_for_another_pid(self):
        with self.assertRaisesRegex(RuntimeError, "assertions were not registered"):
            self.run_child("Details: caffeinate asserting on behalf of python3 (pid 5678)\n")

    def test_child_reports_assertion_inspection_failure(self):
        with self.assertRaisesRegex(RuntimeError, "could not inspect"):
            self.run_child("", returncode=1)


if __name__ == "__main__":
    unittest.main()
