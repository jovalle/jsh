"""The jsh launcher runs under POSIX sh and delegates commands or starts zsh."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LauncherTests(unittest.TestCase):
    def test_command_and_runtime_through_symlink(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as scratch:
            base = Path(scratch)
            checkout = base / "checkout"
            (checkout / "bin").mkdir(parents=True)
            (checkout / "local/vendor/zsh-autosuggestions").mkdir(parents=True)
            shutil.copy(ROOT / "bin/jsh", checkout / "bin/jsh")
            for path, label in ((checkout / "j.sh", "command"), (base / "zsh", "zsh")):
                path.write_text(f'#!/bin/sh\nprintf "{label}:%s\\n" "$*"\n')
                path.chmod(0o755)
            launcher = base / "jsh"
            launcher.symlink_to(checkout / "bin/jsh")
            env = {**os.environ, "HOME": str(base), "PATH": f"{base}:/usr/bin:/bin"}
            for args, expected in (
                (["update"], "command:update"),
                ([], "zsh:-d -i"),
                (["-c", "true"], "zsh:-d -c true"),
            ):
                result = subprocess.run(
                    [str(launcher), *args], env=env, text=True, capture_output=True, check=True
                )
                self.assertEqual(result.stdout.strip(), expected)
                self.assertEqual(result.stderr, "")
