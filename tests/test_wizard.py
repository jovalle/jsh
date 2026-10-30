"""The guided setup previews and saves choices without touching the real machine."""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
from jsh import cli, modules, runner, system, wizard  # pylint: disable=wrong-import-position
from jsh.output import Display  # pylint: disable=wrong-import-position


class WizardTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        scratch = tempfile.TemporaryDirectory(dir=ROOT / "tmp")  # pylint: disable=R1732
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name)
        env = mock.patch.dict(
            os.environ, {"HOME": str(self.base), "XDG_STATE_HOME": str(self.base)}
        )
        env.start()
        self.addCleanup(env.stop)
        self.facts = system.Facts(platform="debian", desktop="xfce", host="test")
        self.found = [
            modules.Module("core", self.base / "core", {"description": "Core"}),
            modules.Module("shell", self.base / "shell", {"description": "Shell"}),
            modules.Module("extra", self.base / "extra", {"description": "Extra"}),
        ]
        self.found[2].steps["install"] = [
            modules.Step(self.found[2], "install", "apt", ["extra"], optional=True)
        ]

    def wizard(self, answers):
        with (
            mock.patch.object(sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input", side_effect=answers),
            mock.patch.object(system, "Facts", return_value=self.facts),
            mock.patch.object(cli, "run", return_value=0) as run,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            result = wizard.start(self.found)
        return result, run.call_args_list

    def test_preview_then_apply_and_save_optional_selection(self):
        result, calls = self.wizard(["all", "extra", "link", "yes"])
        self.assertEqual(result, 0)
        self.assertEqual(
            [(c.args[0], c.args[2], c.args[3]) for c in calls],
            [("link", ["extra"], True), ("link", ["extra"], False)],
        )
        self.assertEqual(
            wizard.load(), {"modules": ["core", "shell", "extra"], "optional": ["extra"]}
        )

    def test_cancel_does_not_save_or_apply(self):
        _, calls = self.wizard(["", "", "n"])
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].args[3])
        self.assertFalse(wizard.path().exists())

    def test_saved_selection_scopes_unnamed_commands_but_not_explicit_ones(self):
        wizard.path().parent.mkdir(parents=True)
        wizard.path().write_text(json.dumps({"modules": ["core"], "optional": []}))
        with (
            mock.patch.object(cli.catalog, "discover", return_value=self.found),
            mock.patch.object(cli, "run", return_value=0) as run,
        ):
            cli.main(["update"])
            self.assertEqual([m.name for m in run.call_args.args[1]], ["core"])
            cli.main(["install", "extra"])
            self.assertEqual([m.name for m in run.call_args.args[1]], ["extra"])
            self.assertEqual(run.call_args.args[2], ["extra"])

    def test_invalid_or_empty_selection_is_not_treated_as_every_module(self):
        wizard.path().parent.mkdir(parents=True)
        wizard.path().write_text('{"modules": [], "optional": []}')
        with self.assertRaisesRegex(ValueError, "Invalid selection"):
            wizard.load()

    def test_user_only_execution_defers_system_tasks_even_when_admin_is_available(self):
        self.found[0].steps["install"] = [
            modules.Step(self.found[0], "install", "apt", ["example"])
        ]
        tasks = runner.plan(self.found[:1], ("install",), self.facts)
        stream = io.StringIO()
        with (
            mock.patch.object(system, "ROOT", self.base),
            mock.patch.object(system, "admin", return_value=True),
            mock.patch.object(tasks[0].handler, "install") as install,
        ):
            runner.execute(tasks, Display(stream), self.facts, False, user_only=True)
        install.assert_not_called()
        self.assertIn("use `jsh setup core`", stream.getvalue())

    def test_skipped_system_steps_are_reported_once_with_modules(self):
        self.found[0].steps["install"] = [
            modules.Step(self.found[0], "install", "apt", ["example"])
        ]
        self.found[1].steps["configure"] = [
            modules.Step(self.found[1], "configure", "script", "first.py", root=True),
            modules.Step(self.found[1], "configure", "script", "second.py", root=True),
        ]
        tasks = runner.plan(self.found[:2], ("install", "configure"), self.facts)
        stream = io.StringIO()
        with mock.patch.object(system, "ROOT", self.base):
            runner.execute(tasks, Display(stream), self.facts, True, user_only=True)
        self.assertEqual(stream.getvalue().count("System changes skipped"), 1)
        self.assertIn("jsh setup core shell", stream.getvalue())

    def test_interactive_preview_precedes_user_only_apply(self):
        with (
            mock.patch.object(wizard.menu, "choose", side_effect=["minimal", ["core"]]),
            mock.patch.object(wizard.menu, "view", return_value="apply") as view,
            mock.patch.object(cli, "run", return_value=0) as run,
            mock.patch.object(cli, "enter_runtime") as runtime,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            self.assertEqual(wizard.interactive(self.found, self.facts, None), 0)
        self.assertEqual([call.args[3] for call in run.call_args_list], [True, False])
        self.assertTrue(all(call.kwargs["user_only"] for call in run.call_args_list))
        view.assert_called_once()
        self.assertTrue(view.call_args.kwargs["actions"])
        runtime.assert_called_once()
        self.assertEqual(wizard.load()["modules"], ["core"])

    def test_runtime_is_not_opened_after_failed_setup_or_other_phase(self):
        with (
            mock.patch.object(cli, "run", side_effect=[1, 0]),
            mock.patch.object(cli, "enter_runtime") as runtime,
        ):
            self.assertEqual(wizard.apply("setup", self.found, []), 1)
            self.assertEqual(wizard.apply("link", self.found, []), 0)
        runtime.assert_not_called()

    def test_direct_setup_opens_runtime_only_after_successful_interactive_run(self):
        with (
            mock.patch.object(cli.catalog, "discover", return_value=self.found),
            mock.patch.object(cli, "run", side_effect=[0, 0, 1]),
            mock.patch.object(sys.stdin, "isatty", return_value=True),
            mock.patch.object(cli, "enter_runtime") as runtime,
        ):
            cli.main(["setup", "core"])
            cli.main(["setup", "core", "--dry-run"])
            cli.main(["setup", "core"])
        runtime.assert_called_once()

    def test_escape_from_modules_returns_to_preset_menu(self):
        with mock.patch.object(wizard.menu, "choose", side_effect=["minimal", None, None]) as pick:
            self.assertEqual(wizard.interactive(self.found, self.facts, None), 0)
        self.assertEqual(pick.call_count, 3)
        self.assertTrue(pick.call_args.args[0].startswith("\n"))
        self.assertNotIn("Your workstation", pick.call_args.args[0])

    def test_change_from_preview_returns_to_modules(self):
        with (
            mock.patch.object(
                wizard.menu, "choose", side_effect=["minimal", ["core"], None, None]
            ) as pick,
            mock.patch.object(wizard.menu, "view", return_value="change"),
            mock.patch.object(cli, "run", return_value=0),
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            self.assertEqual(wizard.interactive(self.found, self.facts, None), 0)
        self.assertEqual(pick.call_args_list[2].args[0], "Setup · Choose modules")


if __name__ == "__main__":
    unittest.main()
