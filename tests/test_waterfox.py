import importlib.machinery
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import call, patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("waterfox", str(ROOT / "bin/waterfox"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
WATERFOX = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = WATERFOX
LOADER.exec_module(WATERFOX)


def customization_preference(state):
    serialized = json.dumps(state, separators=(",", ":"))
    return f'user_pref("browser.uiCustomization.state", {json.dumps(serialized)});\n'


def read_customization_state(path):
    line = path.read_text(encoding="utf-8").strip()
    encoded = line.removeprefix('user_pref("browser.uiCustomization.state", ').removesuffix(");")
    return json.loads(json.loads(encoded))


class WaterfoxPreferenceTests(unittest.TestCase):
    def test_removes_import_button_from_profile_preferences(self):
        state = {
            "placements": {"PersonalToolbar": ["import-button", "personal-bookmarks"]},
            "seen": ["import-button"],
            "dirtyAreaCache": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            preference = customization_preference(state)
            (profile / "prefs.js").write_text(preference, encoding="utf-8")
            (profile / "user.js").write_bytes(preference.replace("\n", "\r\n").encode())

            updates = WATERFOX.plan_import_button_removal(profile)
            backups = WATERFOX.apply_preference_updates(updates)

            self.assertEqual(set(updates), {profile / "prefs.js", profile / "user.js"})
            self.assertEqual(len(backups), 2)
            for name in ("prefs.js", "user.js"):
                updated = read_customization_state(profile / name)
                self.assertEqual(updated["placements"]["PersonalToolbar"], ["personal-bookmarks"])
                self.assertNotIn("import-button", updated["seen"])
                self.assertIn("PersonalToolbar", updated["dirtyAreaCache"])
            self.assertTrue((profile / "user.js").read_bytes().endswith(b"\r\n"))
            self.assertEqual(WATERFOX.plan_import_button_removal(profile), {})


class WaterfoxShutdownTests(unittest.TestCase):

    def test_warns_closes_waterfox_and_continues(self):
        stderr = io.StringIO()
        with (
            patch.object(WATERFOX.sys, "platform", "linux"),
            patch.object(WATERFOX.sys.stdin, "isatty", return_value=True),
            patch.object(WATERFOX, "waterfox_is_running", side_effect=[True, False, False]),
            patch("builtins.input", return_value="") as prompt,
            patch.object(WATERFOX.subprocess, "run") as run,
            redirect_stderr(stderr),
        ):
            WATERFOX.ensure_waterfox_closed()

        self.assertIn("profile database is locked", stderr.getvalue())
        prompt.assert_called_once_with("Close Waterfox and try again? [Y/n] ")
        self.assertEqual(
            run.call_args_list,
            [
                call(
                    ["pkill", "-TERM", "-x", "waterfox"],
                    stdout=WATERFOX.subprocess.DEVNULL,
                    stderr=WATERFOX.subprocess.DEVNULL,
                    check=False,
                ),
                call(
                    ["pkill", "-TERM", "-x", "waterfox-bin"],
                    stdout=WATERFOX.subprocess.DEVNULL,
                    stderr=WATERFOX.subprocess.DEVNULL,
                    check=False,
                ),
            ],
        )

    def test_yes_closes_waterfox_without_prompt_or_tty(self):
        with (
            patch.object(WATERFOX.sys, "platform", "linux"),
            patch.object(WATERFOX.sys.stdin, "isatty", return_value=False),
            patch.object(WATERFOX, "waterfox_is_running", side_effect=[True, False, False]),
            patch("builtins.input") as prompt,
            patch.object(WATERFOX.subprocess, "run") as run,
            redirect_stderr(io.StringIO()),
        ):
            WATERFOX.ensure_waterfox_closed(assume_yes=True)

        prompt.assert_not_called()
        self.assertEqual(run.call_count, 2)

    def test_leaves_waterfox_open_when_close_is_declined(self):
        with (
            patch.object(WATERFOX.sys.stdin, "isatty", return_value=True),
            patch.object(WATERFOX, "waterfox_is_running", return_value=True),
            patch("builtins.input", return_value="n"),
            patch.object(WATERFOX.subprocess, "run") as run,
            redirect_stderr(io.StringIO()),
            self.assertRaisesRegex(RuntimeError, "Cancelled; Waterfox remains open"),
        ):
            WATERFOX.ensure_waterfox_closed()

        run.assert_not_called()


class WaterfoxLifecycleTests(unittest.TestCase):

    def test_dispatches_open_stop_and_restart(self):
        events = []
        with (
            patch.object(
                WATERFOX,
                "open_waterfox",
                side_effect=lambda args=(): events.append(("open", list(args))),
            ),
            patch.object(
                WATERFOX, "stop_waterfox", side_effect=lambda: events.append(("stop", []))
            ),
        ):
            self.assertEqual(WATERFOX.main(["open", "--", "https://example.test"]), 0)
            self.assertEqual(WATERFOX.main(["stop"]), 0)
            self.assertEqual(WATERFOX.main(["restart"]), 0)

        self.assertEqual(
            events,
            [
                ("open", ["https://example.test"]),
                ("stop", []),
                ("stop", []),
                ("open", []),
            ],
        )

    def test_native_launch_preserves_managed_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "waterfox-bin"
            binary.touch(mode=0o755)
            (root / "profiles.ini").write_text(
                "[Profile0]\nName=managed\nPath=Profiles/default\n",
                encoding="utf-8",
            )
            (root / "installs.ini").write_text(
                "[Install]\nDefault=Profiles/default\n",
                encoding="utf-8",
            )
            with (
                patch.object(WATERFOX.sys, "platform", "linux"),
                patch.object(WATERFOX, "waterfox_root", return_value=root),
                patch.dict(WATERFOX.os.environ, {"JSH_WATERFOX_BIN": str(binary)}),
            ):
                command = WATERFOX.waterfox_launch_command(["https://example.test"])

        self.assertEqual(command, [str(binary), "-P", "managed", "https://example.test"])


class WaterfoxConfigurationTests(unittest.TestCase):

    def test_runs_waterfox_configuration_with_yes(self):
        with patch.object(WATERFOX.subprocess, "run") as run:
            run.return_value.returncode = 0
            WATERFOX.run_waterfox_configuration(assume_yes=True)

        command = run.call_args.args[0]
        environment = run.call_args.kwargs["env"]
        self.assertEqual(command, [str(WATERFOX.WATERFOX_CONFIGURATOR), "apply"])
        self.assertEqual(environment["JSH_INTERRUPT_REPORT"], "0")
        self.assertEqual(environment["JSH_ASSUME_YES"], "1")
        self.assertEqual(environment["JSH_CONFIGURE_ASSUME_YES"], "1")
        self.assertFalse(run.call_args.kwargs["check"])

    def test_reports_waterfox_configuration_failure(self):
        with (
            patch.object(WATERFOX.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "failed with status 10"),
        ):
            run.return_value.returncode = 10
            WATERFOX.run_waterfox_configuration(assume_yes=False)

    def test_translates_configuration_interrupt(self):
        with patch.object(WATERFOX.subprocess, "run") as run, self.assertRaises(KeyboardInterrupt):
            run.return_value.returncode = 130
            WATERFOX.run_waterfox_configuration(assume_yes=False)

    def test_main_configures_before_resolving_default_profile(self):
        with (
            patch.object(WATERFOX, "run_waterfox_configuration") as configure,
            patch.object(WATERFOX, "resolve_profile", side_effect=RuntimeError("stop")) as resolve,
            redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(WATERFOX.main([]), 2)

        configure.assert_called_once_with(False)
        resolve.assert_called_once_with(None)

    def test_main_skips_configuration_for_dry_run_and_explicit_profile(self):
        invocations = (["--dry-run"], ["--profile", "/tmp/profile"])
        for arguments in invocations:
            with self.subTest(arguments=arguments):
                with (
                    patch.object(WATERFOX, "run_waterfox_configuration") as configure,
                    patch.object(WATERFOX, "resolve_profile", side_effect=RuntimeError("stop")),
                    redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(WATERFOX.main(arguments), 2)
                    configure.assert_not_called()


if __name__ == "__main__":
    unittest.main()
