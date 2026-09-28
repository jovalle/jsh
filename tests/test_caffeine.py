import contextlib
import importlib.machinery
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("caffeine", str(ROOT / "bin/cafe"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
CAFFEINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CAFFEINE
LOADER.exec_module(CAFFEINE)
SCRIPT = str((ROOT / "bin/cafe").resolve())


def which_only(*names: str):
    return lambda name: f"/usr/bin/{name}" if name in names else None


class MacOSCaffeineTests(unittest.TestCase):
    def run_child(self, parent_command: str):
        completed = subprocess.CompletedProcess([], 0, stdout=parent_command, stderr="")
        with (
            patch.object(CAFFEINE.sys, "argv", ["cafe", "--macos-inhibited"]),
            patch.object(CAFFEINE.os, "getppid", return_value=4321),
            patch.object(CAFFEINE.subprocess, "run", return_value=completed) as run,
            patch.object(CAFFEINE, "wait_until_stopped") as wait_until_stopped,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            CAFFEINE.run_macos()
        return run, wait_until_stopped

    def test_child_accepts_caffeinate_parent(self):
        run, wait_until_stopped = self.run_child("/usr/bin/caffeinate\n")

        run.assert_called_once_with(
            ["ps", "-p", "4321", "-o", "comm="],
            check=True,
            capture_output=True,
            text=True,
        )
        wait_until_stopped.assert_called_once()

    def test_child_rejects_other_parent(self):
        with self.assertRaisesRegex(RuntimeError, "caffeinate assertion owner was not started"):
            self.run_child("/bin/zsh\n")


class LinuxCaffeineTests(unittest.TestCase):
    def exec_command(self, *available: str):
        with (
            patch.object(CAFFEINE.sys, "argv", ["cafe"]),
            patch.object(CAFFEINE.shutil, "which", side_effect=which_only(*available)),
            patch.object(CAFFEINE.os, "execv") as execv,
        ):
            CAFFEINE.run_linux()
        return execv.call_args.args

    def test_prefers_gnome_session_inhibit(self):
        executable, command = self.exec_command("gnome-session-inhibit", "systemd-inhibit")

        self.assertEqual(executable, "/usr/bin/gnome-session-inhibit")
        self.assertEqual(
            command,
            [
                "/usr/bin/gnome-session-inhibit",
                "--app-id",
                "caffeine",
                "--reason",
                "Keep the screen active",
                "--inhibit",
                "idle:suspend",
                sys.executable,
                SCRIPT,
                "--linux-inhibited",
            ],
        )

    def test_falls_back_to_systemd_inhibit(self):
        executable, command = self.exec_command("systemd-inhibit")

        self.assertEqual(executable, "/usr/bin/systemd-inhibit")
        self.assertEqual(
            command,
            [
                "/usr/bin/systemd-inhibit",
                "--who=caffeine",
                "--why=Keep the screen active",
                "--what=idle:sleep",
                "--mode=block",
                sys.executable,
                SCRIPT,
                "--linux-inhibited",
            ],
        )

    def test_requires_an_inhibitor(self):
        with self.assertRaisesRegex(
            RuntimeError, "gnome-session-inhibit or systemd-inhibit is required on Linux"
        ):
            self.exec_command()

    def run_systemd_child(self, listing: str):
        completed = subprocess.CompletedProcess([], 0, stdout=listing, stderr="")
        with (
            patch.object(CAFFEINE.sys, "argv", ["cafe", "--linux-inhibited"]),
            patch.object(CAFFEINE.shutil, "which", side_effect=which_only("systemd-inhibit")),
            patch.object(CAFFEINE.subprocess, "run", return_value=completed),
            patch.object(CAFFEINE, "wait_until_stopped") as wait_until_stopped,
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            CAFFEINE.run_linux()
        return wait_until_stopped, output.getvalue()

    def test_systemd_child_accepts_registered_inhibitor(self):
        wait_until_stopped, output = self.run_systemd_child(
            "caffeine 1000 jay 99 python3 idle:sleep Keep the screen active block\n"
        )

        wait_until_stopped.assert_called_once()
        self.assertIn("Validation: PASS - systemd idle and suspend inhibitor registered", output)
        self.assertIn("Inspect: systemd-inhibit --list", output)

    def test_systemd_child_rejects_missing_inhibitor(self):
        with self.assertRaisesRegex(
            RuntimeError, "systemd idle and suspend inhibitor was not registered"
        ):
            self.run_systemd_child("UPower 0 root 1986 upowerd sleep Pause device polling delay\n")


class XfceCaffeineTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.pid_file = Path(directory.name) / "cafe.test.pid"
        pid_patch = patch.object(CAFFEINE, "PID_FILE", self.pid_file)
        pid_patch.start()
        self.addCleanup(pid_patch.stop)

    def test_status_clears_stale_pid_file_and_shows_inactive_icon(self):
        self.pid_file.write_text("999999999")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            CAFFEINE.show_xfce_status()

        self.assertFalse(self.pid_file.exists())
        self.assertIn(f"<img>{ROOT.resolve()}/assets/icons/cafe-off.svg</img>", output.getvalue())
        self.assertIn(f"<click>{SCRIPT} --xfce-toggle</click>", output.getvalue())

    def test_toggle_without_inhibitor_leaves_sleep_settings_alone(self):
        with (
            patch.object(CAFFEINE.sys, "argv", ["cafe", "--xfce-toggle"]),
            patch.object(CAFFEINE.shutil, "which", return_value=None),
            patch.object(CAFFEINE.subprocess, "Popen") as popen,
            patch.object(CAFFEINE, "run_quietly") as run_quietly,
            contextlib.redirect_stderr(io.StringIO()) as errors,
        ):
            exit_code = CAFFEINE.main()

        self.assertEqual(exit_code, 1)
        self.assertIn("gnome-session-inhibit or systemd-inhibit is required", errors.getvalue())
        popen.assert_not_called()
        run_quietly.assert_not_called()
        self.assertFalse(self.pid_file.exists())


if __name__ == "__main__":
    unittest.main()
