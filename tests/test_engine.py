"""The engine plans module steps into tasks, runs them, and reports through the display."""

import io
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
# pylint: disable=wrong-import-position
from jsh import modules, runner, system
from jsh.output import Display


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text))
    path.chmod(mode)


class EngineTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        scratch = tempfile.TemporaryDirectory(dir=ROOT / "tmp")  # pylint: disable=R1732
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name)
        self.home = self.base / "home"
        self.home.mkdir()
        environment = {"HOME": str(self.home), "XDG_STATE_HOME": str(self.base / "state")}
        for patcher in (
            mock.patch.dict(os.environ, environment),
            mock.patch.object(system, "ROOT", self.base),
            mock.patch.object(runner.system, "ROOT", self.base),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.facts = system.Facts(platform="darwin", desktop="darwin", host="archon")

    def module(self, name, manifest, files=None):
        write(self.base / "modules" / name / "module.toml", manifest)
        for relative, text in (files or {}).items():
            write(self.base / "modules" / name / relative, text)

    def run_phases(self, phases, names=(), dry_run=False):
        found = modules.select(modules.discover(self.base), list(names))
        stream = io.StringIO()
        display = Display(stream, dry_run)
        ok = runner.execute(runner.plan(found, phases, self.facts), display, self.facts, dry_run)
        display.summary()
        return ok, stream.getvalue()

    def test_when_filters_modules_and_steps(self):
        mac = 'description = "Mac"\nwhen = { platform = "darwin" }\n'
        mac += '[[configure]]\nscript = "a.py"\n'
        self.module("mac", mac)
        self.module("tux", mac.replace("Mac", "Tux").replace("darwin", "linux"))
        self.module(
            "both",
            """\
            description = "Both"

            [[configure]]
            script = "a.py"
            when = { host = "other" }

            [[configure]]
            script = "a.py"
            when = { platform = ["linux", "darwin"], host = "archon" }
            """,
        )
        tasks = runner.plan(modules.discover(self.base), ("configure",), self.facts)
        labels = [(task.label, len(task.steps)) for task in tasks]
        self.assertEqual(labels, [("both", 1), ("mac", 1)])

    def test_script_events_become_changes_and_notices(self):
        self.module(
            "demo",
            "description = \"Demo\"\n[[configure]]\nscript = \"apply.sh 'two words'\"\n",
            {
                "apply.sh": """\
                . "${JSH_ROOT}/lib/core.sh"
                [[ $1 == 'two words' && ${JSH_PHASE} == configure ]] || exit 9
                jsh::changed "demo setting"
                jsh::current 2
                jsh::notice "close the app first"
                """
            },
        )
        write(self.base / "lib/core.sh", (ROOT / "lib/core.sh").read_text())
        write(self.base / "lib/output.sh", (ROOT / "lib/output.sh").read_text())
        ok, out = self.run_phases(("configure",))
        self.assertTrue(ok)
        self.assertIn("! demo: close the app first\n", out)
        self.assertIn("\n~ demo setting\n\n1 configured [", out)

    def test_failed_task_is_reported_and_later_tasks_still_run(self):
        bad = 'description = "Bad"\n[[configure]]\nscript = "fail.sh"\n'
        self.module("abad", bad, {"fail.sh": "echo boom\nexit 3\n"})
        self.module(
            "good",
            'description = "Good"\n[[configure]]\nscript = "ok.py"\n',
            {"ok.py": "def configure(ctx):\n    ctx.added('good thing')\n"},
        )
        ok, out = self.run_phases(("configure",))
        self.assertFalse(ok)
        self.assertIn("✗ abad: fail.sh exited with 3\n  │ $ bash fail.sh\n  │ boom\n", out)
        self.assertIn("+ good thing", out)
        self.assertIn("1 configured, 1 failed [", out)

    def test_root_step_without_sudo_is_skipped_with_a_notice(self):
        self.module(
            "sys",
            'description = "System"\n[[configure]]\nscript = "ok.py"\nroot = true\n',
            {"ok.py": "def configure(ctx):\n    ctx.added('should not run')\n"},
        )
        with mock.patch.object(system, "admin", return_value=False):
            ok, out = self.run_phases(("configure",))
        self.assertTrue(ok)
        self.assertIn("! sys: needs sudo; run sudo -v first, then rerun", out)
        self.assertNotIn("should not run", out)

    def test_update_reuses_install_steps_of_updatable_handlers(self):
        self.module(
            "tool",
            """\
            description = "Tool"

            [[install]]
            git = { a = "https://example.test/a.git" }

            [[install]]
            script = "a.py"

            [[install]]
            link = { from = "a", to = "b" }

            [[update]]
            script = "b.py"
            """,
        )
        tasks = runner.plan(modules.discover(self.base), ("update",), self.facts)
        self.assertEqual(
            [(task.label, [step.args for step in task.steps]) for task in tasks],
            [("git", [{"a": "https://example.test/a.git"}]), ("tool", ["b.py"])],
        )

    def test_link_places_backs_up_and_reports_current(self):
        files = {"home/.zshrc": "zsh\n", "home/.config/a/b": "b\n"}
        self.module("shell", 'description = "Shell"\n', files)
        write(self.home / ".zshrc", "mine\n")
        ok, out = self.run_phases(("link",))
        self.assertTrue(ok)
        source = self.base / "modules/shell/home/.zshrc"
        self.assertEqual(os.readlink(self.home / ".zshrc"), str(source))
        backups = list((self.base / "state/jsh/backups").glob("*/.zshrc"))
        self.assertEqual([path.read_text() for path in backups], ["mine\n"])
        self.assertIn("+ ~/.config/a/b\n+ ~/.zshrc\n\n2 linked [", out)
        ok, out = self.run_phases(("link",))
        self.assertIn("Checked 2 items (no changes)", out)

    def test_stale_link_into_the_checkout_is_replaced_without_backup(self):
        self.module("shell", 'description = "Shell"\n', {"home/.zshrc": "zsh\n"})
        (self.home / ".zshrc").symlink_to(self.base / "dotfiles/.zshrc")
        _, out = self.run_phases(("link",))
        self.assertIn("~ ~/.zshrc", out)
        self.assertFalse((self.base / "state").exists())

    def test_dry_run_reports_without_changing_anything(self):
        self.module("shell", 'description = "Shell"\n', {"home/.zshrc": "zsh\n"})
        _, out = self.run_phases(("link",), dry_run=True)
        self.assertIn("1 to link [", out)
        self.assertFalse((self.home / ".zshrc").exists())

    def test_unknown_handler_is_rejected(self):
        self.module("odd", 'description = "Odd"\n[[configure]]\nnope = 1\n')
        with self.assertRaisesRegex(ValueError, "Unknown handler: nope"):
            runner.plan(modules.discover(self.base), ("configure",), self.facts)

    def test_malformed_manifests_name_the_file_and_problem(self):
        cases = {
            'description = "A"\n[[install]\n': "module.toml: Expected ']]'",
            'description = "A"\nextra = 1\n': "module.toml: unknown keys extra",
            "[[install]]\nbrew = {}\n": "module.toml: description is required",
            'description = "A"\n[[install]]\nbrew = {}\napt = []\n': "names exactly one handler",
            'description = "A"\nwhen = { os = "x" }\n': "when accepts desktop, host, platform",
            'description = "A"\n[commands.go]\nabout = "x"\n': "[commands.go] needs run",
        }
        for text, message in cases.items():
            with self.subTest(message=message):
                self.module("odd", text)
                with self.assertRaises(modules.ManifestError) as caught:
                    modules.discover(self.base)
                self.assertIn(message, str(caught.exception))


if __name__ == "__main__":
    unittest.main()
