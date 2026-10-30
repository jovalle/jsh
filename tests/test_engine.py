"""The engine plans module steps into tasks, runs them, and reports through the display."""

import io
import json
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
    def test_terminal_header_embeds_command_in_banner(self):
        stream = io.StringIO()
        stream.isatty = lambda: True
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
            Display(stream).header("jsh setup", "commit (debian, xfce)")
        lines = stream.getvalue().splitlines()
        self.assertIn("setup", lines[-2])
        self.assertNotIn("jsh", lines[-2])
        self.assertTrue(lines[-2].startswith(" =   :-=-:"))
        self.assertEqual(lines[-1], "commit (debian, xfce)")

    def test_terminal_header_keeps_long_command(self):
        stream = io.StringIO()
        stream.isatty = lambda: True
        command = "jsh module a-long-command-name"
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
            Display(stream).header(command, "details")
        self.assertIn("module a-long-command-name", stream.getvalue().splitlines()[-2])

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
        text = manifest if isinstance(manifest, str) else json.dumps(manifest)
        write(self.base / "modules" / name / "module.json", text)
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
        mac = {
            "description": "Mac",
            "when": {"platform": "darwin"},
            "configure": [{"script": "a.py"}],
        }
        self.module("mac", mac)
        self.module("tux", {**mac, "description": "Tux", "when": {"platform": "linux"}})
        self.module(
            "both",
            {
                "description": "Both",
                "configure": [
                    {"script": "a.py", "when": {"host": "other"}},
                    {"script": "a.py", "when": {"platform": ["linux", "darwin"], "host": "archon"}},
                ],
            },
        )
        tasks = runner.plan(modules.discover(self.base), ("configure",), self.facts)
        labels = [(task.label, len(task.steps)) for task in tasks]
        self.assertEqual(labels, [("both", 1), ("mac", 1)])

    def test_script_events_become_changes_and_notices(self):
        self.module(
            "demo",
            {"description": "Demo", "configure": [{"script": "apply.sh 'two words'"}]},
            {"apply.sh": """\
                . "${JSH_ROOT}/lib/core.sh"
                [[ $1 == 'two words' && ${JSH_PHASE} == configure ]] || exit 9
                jsh::detail "theme: light → dark"
                jsh::detail "font: old → new"
                jsh::changed "demo setting"
                jsh::current 2
                jsh::notice "close the app first"
                """},
        )
        write(self.base / "lib/core.sh", (ROOT / "lib/core.sh").read_text())
        write(self.base / "lib/output.sh", (ROOT / "lib/output.sh").read_text())
        ok, out = self.run_phases(("configure",))
        self.assertTrue(ok)
        self.assertIn("! demo: close the app first\n", out)
        self.assertIn("\nConfiguration\n~ demo setting\n  theme:\n    - light\n    + dark\n"
                      "  font:\n    - old\n    + new\n\n1 configured [", out)

    def test_failed_task_is_reported_and_later_tasks_still_run(self):
        bad = {"description": "Bad", "configure": [{"script": "fail.sh"}]}
        self.module("abad", bad, {"fail.sh": "echo boom\nexit 3\n"})
        self.module(
            "good",
            {"description": "Good", "configure": [{"script": "ok.py"}]},
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
            {"description": "System", "configure": [{"script": "ok.py", "root": True}]},
            {"ok.py": "def configure(ctx):\n    ctx.added('should not run')\n"},
        )
        with mock.patch.object(system, "admin", return_value=False):
            ok, out = self.run_phases(("configure",))
        self.assertTrue(ok)
        self.assertIn("! sys: needs sudo; run sudo -v first, then rerun", out)
        self.assertNotIn("should not run", out)

    def test_missing_script_key_has_a_descriptive_failure(self):
        self.module(
            "bad",
            {"description": "Bad", "configure": [{"script": "bad.py"}]},
            {"bad.py": "def configure(ctx):\n    return {}['name']\n"},
        )
        ok, out = self.run_phases(("configure",))
        self.assertFalse(ok)
        self.assertIn("✗ bad: missing required key 'name'", out)

    def test_summary_groups_changes_by_kind_and_avoids_redundant_sources(self):
        stream = io.StringIO()
        display = Display(stream, dry_run=True)
        display.begin(10)
        for phase, label, handler, mark, text in (
            ("configure", "audio", "script", "changed", "Jsh audio output"),
            ("configure", "desktop", "script", "changed", "XFCE desktop (17 settings)"),
            ("configure", "vscode", "script", "changed", "~/.config/Code/User/settings.json"),
            ("install", "brew", "brew", "added", "fzf"),
            ("install", "flatpak", "flatpak", "added", "com.example.App"),
            ("install", "git", "git", "added", "skills/example"),
            ("link", "link", "link", "added", "~/.zshrc"),
            ("update", "ai", "script", "removed", "old skill"),
        ):
            ctx = runner.Context(display, self.facts, phase, label, self.base, True)
            ctx.handler = handler
            getattr(ctx, mark)(text)
        display.summary()
        out = stream.getvalue()
        self.assertIn("Packages\n+ fzf Homebrew\n+ com.example.App Flatpak", out)
        self.assertIn("Repositories\n+ skills/example", out)
        self.assertIn("Links\n+ ~/.zshrc", out)
        self.assertIn("~ Jsh audio output\n~ XFCE desktop (17 settings)\n", out)
        self.assertIn("~ ~/.config/Code/User/settings.json [vscode]", out)
        self.assertIn("Other changes\n- old skill [ai]", out)
        self.assertIn("3 to configure", out)
        self.assertIn("1 to remove", out)

    def test_summary_colors_versions_dates_and_package_sources(self):
        stream = io.StringIO()
        display = Display(stream)
        display.color = True
        display.change("~", "atuin 18.24.2 → 18.24.3", "updated", "Packages", "Homebrew")
        display.change("~", "jq → 1.7", "updated", "Packages", "dnf")
        display.change(
            "~", "skills/example dbd4588 (2026-10-09) → ca45fc4 (2026-10-28)",
            "updated", "Repositories",
        )
        display.summary()
        out = stream.getvalue()
        self.assertIn("atuin \033[31m18.24.2\033[0m → \033[32m18.24.3\033[0m "
                      "\033[2mHomebrew\033[0m", out)
        self.assertIn("jq → \033[32m1.7\033[0m \033[2mdnf\033[0m", out)
        self.assertIn("skills/example \033[31mdbd4588\033[0m\033[2m (2026-10-09)\033[0m"
                      " → \033[32mca45fc4\033[0m\033[2m (2026-10-28)\033[0m", out)
        display.color = False
        self.assertEqual(display.change_text("example v1 → v2", "Repositories"),
                         "example v1 → v2")

    def test_configuration_details_show_colored_before_and_after(self):
        display = Display(io.StringIO())
        display.color = True
        self.assertEqual(display.detail_lines("pins: /old/app.desktop → /new/app.desktop"), [
            "  pins:", "    \033[31m- /old/app.desktop\033[0m",
            "    \033[32m+ /new/app.desktop\033[0m",
        ])
        display.color = False
        self.assertEqual(display.detail_lines("setting: old → new"),
                         ["  setting:", "    - old", "    + new"])

    def test_update_reuses_install_steps_of_updatable_handlers(self):
        self.module(
            "tool",
            {
                "description": "Tool",
                "install": [
                    {"git": {"a": "https://example.test/a.git"}},
                    {"script": "a.py"},
                    {"link": {"from": "a", "to": "b"}},
                ],
                "update": [{"script": "b.py"}],
            },
        )
        tasks = runner.plan(modules.discover(self.base), ("update",), self.facts)
        self.assertEqual(
            [(task.label, [step.args for step in task.steps]) for task in tasks],
            [("git", [{"a": "https://example.test/a.git"}]), ("tool", ["b.py"])],
        )
        self.assertEqual(
            [task.describe() for task in tasks],
            ["updating Git repositories", "updating tool module"],
        )

    def test_link_places_backs_up_and_reports_current(self):
        files = {"home/.zshrc": "zsh\n", "home/.config/a/b": "b\n"}
        self.module("shell", {"description": "Shell"}, files)
        write(self.home / ".zshrc", "mine\n")
        ok, out = self.run_phases(("link",))
        self.assertTrue(ok)
        source = self.base / "modules/shell/home/.zshrc"
        self.assertEqual(os.readlink(self.home / ".zshrc"), str(source))
        backups = list((self.base / "state/jsh/backups").glob("*/.zshrc"))
        self.assertEqual([path.read_text() for path in backups], ["mine\n"])
        self.assertIn("Links\n+ ~/.config/a/b\n+ ~/.zshrc\n\n2 linked [", out)
        ok, out = self.run_phases(("link",))
        self.assertIn("Checked 2 items (no changes)", out)

    def test_link_entry_links_a_directory_whole_and_flags_missing_sources(self):
        manifest = {
            "description": "Skills",
            "link": [
                {"from": "kit", "to": "~/.agents/skills/kit"},
                {"from": "../../local/vendor/absent", "to": "~/.agents/skills/absent"},
            ],
        }
        self.module("skills", manifest, {"kit/SKILL.md": "kit\n", "kit/refs/a.md": "a\n"})
        _, out = self.run_phases(("link",))
        target = self.home / ".agents/skills/kit"
        self.assertEqual(os.readlink(target), str(self.base / "modules/skills/kit"))
        self.assertIn("! link: ~/.agents/skills/absent: ", out)
        self.assertIn("is missing; run jsh install first", out)
        self.assertFalse((self.home / ".agents/skills/absent").is_symlink())

    def test_stale_link_into_the_checkout_is_replaced_without_backup(self):
        self.module("shell", {"description": "Shell"}, {"home/.zshrc": "zsh\n"})
        (self.home / ".zshrc").symlink_to(self.base / "dotfiles/.zshrc")
        _, out = self.run_phases(("link",))
        self.assertIn("~ ~/.zshrc", out)
        self.assertFalse((self.base / "state").exists())

    def test_dry_run_reports_without_changing_anything(self):
        self.module("shell", {"description": "Shell"}, {"home/.zshrc": "zsh\n"})
        _, out = self.run_phases(("link",), dry_run=True)
        self.assertIn("1 to link [", out)
        self.assertFalse((self.home / ".zshrc").exists())

    def test_unknown_handler_is_rejected(self):
        self.module("odd", {"description": "Odd", "configure": [{"nope": 1}]})
        with self.assertRaisesRegex(ValueError, "Unknown handler: nope"):
            runner.plan(modules.discover(self.base), ("configure",), self.facts)

    def test_malformed_manifests_name_the_file_and_problem(self):
        cases = {
            '{"description": "A",': "module.json: Expecting property name",
            '["description"]': "module.json: the manifest must be an object",
            '{"description": "A", "extra": 1}': "module.json: unknown keys extra",
            '{"install": [{"brew": {}}]}': "module.json: description is required",
            '{"description": "A", "install": ["brew"]}': "install must be a list of step objects",
            '{"description": "A", "install": [{"brew": {}, "apt": []}]}': "names exactly one",
            '{"description": "A", "when": {"os": "x"}}': "when accepts desktop, host, platform",
            '{"description": "A", "commands": ["go"]}': "commands must be an object",
            '{"description": "A", "commands": {"go": {"about": "x"}}}': "commands.go needs run",
        }
        for text, message in cases.items():
            with self.subTest(message=message):
                self.module("odd", text)
                with self.assertRaises(modules.ManifestError) as caught:
                    modules.discover(self.base)
                self.assertIn(message, str(caught.exception))


if __name__ == "__main__":
    unittest.main()
