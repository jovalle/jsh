"""Package handlers install only what is missing, isolate failures, and upgrade on update."""

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
# pylint: disable=wrong-import-position
from jsh import system
from jsh.handlers import _native, apt, brew, git, uv
from jsh.modules import Step
from jsh.output import Display
from jsh.runner import Context


class Module:  # pylint: disable=too-few-public-methods
    name = "demo"
    path = ROOT


def steps(*args):
    return [Step(Module, "install", "test", value) for value in args]


class HandlerTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        scratch = tempfile.TemporaryDirectory(dir=ROOT / "tmp")  # pylint: disable=R1732
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name)
        self.stream = io.StringIO()
        self.display = Display(self.stream)
        self.display.begin(100)
        self.facts = system.Facts(platform="darwin", desktop="darwin", host="test")

    def context(self, phase="install", dry_run=False, facts=None):
        ctx = Context(self.display, facts or self.facts, phase, "test", self.base / "logs", dry_run)
        ctx.run = mock.Mock(return_value=0)
        return ctx

    def changes(self):
        return self.display.changes

    def test_brew_installs_only_missing_formulae_including_aliases(self):
        listed = {"--formula": "git\npython@3.13\n", "--cask": ""}
        info = json.dumps(
            {"formulae": [{"installed": True, "aliases": ["python"], "full_name": "python@3.13"}]}
        )

        def query(arguments):
            if arguments[:2] == ["brew", "list"]:
                return listed[arguments[2]]
            if arguments[:2] == ["brew", "info"]:
                return info if "python" in arguments else ""
            return ""

        ctx = self.context()
        with mock.patch.object(brew.shutil, "which", return_value="/brew"), mock.patch.object(
            brew.system, "query", side_effect=query
        ):
            brew.install(ctx, steps({"formulae": ["git", "python", "ripgrep"]}))
        ctx.run.assert_called_once_with(["brew", "install", "--formula", "ripgrep"])
        self.assertEqual(self.changes(), [("+", "ripgrep")])

    def test_brew_batch_failure_is_isolated_to_the_failing_package(self):
        ctx = self.context()
        ctx.run.side_effect = [RuntimeError("batch"), 0, RuntimeError("bad")]
        self.assertEqual(brew.add(ctx, "formulae", ["good", "bad"]), ["bad"])
        self.assertEqual(self.changes(), [("+", "good")])

    def test_brew_update_upgrades_only_declared_outdated_packages(self):
        outdated = {
            "formulae": [
                {"name": "jq", "installed_versions": ["1.6"], "current_version": "1.7"},
                {"name": "other", "installed_versions": ["1"], "current_version": "2"},
            ],
            "casks": [],
        }
        ctx = self.context("update")
        with mock.patch.object(brew.shutil, "which", return_value="/brew"), mock.patch.object(
            brew.system, "query", return_value=json.dumps(outdated)
        ):
            brew.update(ctx, steps({"formulae": ["jq", "git"]}))
        ctx.run.assert_any_call(["brew", "upgrade", "--formula", "jq"])
        self.assertEqual(self.changes(), [("~", "jq 1.6 → 1.7")])

    def test_brew_is_required_on_macos_but_optional_on_linux(self):
        with mock.patch.object(brew.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "Install Homebrew"):
                brew.install(self.context(), steps({"formulae": ["jq"]}))
            linux = system.Facts(platform="debian", desktop="", host="test")
            brew.install(self.context(facts=linux), steps({"formulae": ["jq"], "casks": ["x"]}))
        self.assertIn("install Homebrew from https://brew.sh", self.stream.getvalue())

    def test_apt_without_sudo_reports_missing_packages_instead_of_installing(self):
        ctx = self.context()
        installed = mock.patch.object(_native.Apt, "installed", side_effect=[True, False])
        with installed, mock.patch.object(system, "admin", return_value=False):
            apt.install(ctx, steps(["git", "ripgrep"]))
        ctx.run.assert_not_called()
        self.assertIn("missing ripgrep; run sudo -v first", self.stream.getvalue())

    def test_apt_installs_missing_without_upgrading(self):
        ctx = self.context()
        installed = mock.patch.object(_native.Apt, "installed", side_effect=[True, False])
        with installed, mock.patch.object(system, "admin", return_value=True):
            apt.install(ctx, steps(["git"], ["ripgrep"]))
        ctx.run.assert_called_with(
            ["apt-get", "install", "--no-upgrade", "-y", "--", "ripgrep"],
            root=True,
            env={"DEBIAN_FRONTEND": "noninteractive"},
        )
        self.assertEqual(self.changes(), [("+", "ripgrep")])

    def test_uv_failure_does_not_stop_the_next_tool(self):
        ctx = self.context()
        ctx.run.side_effect = [RuntimeError("no"), 0]
        with mock.patch.object(uv.shutil, "which", side_effect=lambda name: name == "uv" or None):
            with self.assertRaisesRegex(RuntimeError, "could not install tmail-cli"):
                uv.install(ctx, steps({"tmail": "tmail-cli", "just": "rust-just"}))
        self.assertEqual(ctx.run.call_args.args[0], ["uv", "tool", "install", "rust-just"])
        self.assertEqual(self.changes(), [("+", "just")])

    def test_git_update_resets_only_clones_behind_their_remote(self):
        for name in ("fresh", "stale"):
            (self.base / "local/vendor" / name / ".git").mkdir(parents=True)
        answers = {"fresh": ("aaa", "aaa\tHEAD"), "stale": ("bbb1234", "ccc5678\tHEAD")}

        def query(arguments):
            local, remote = answers[Path(arguments[2]).name]
            return local if "rev-parse" in arguments else remote

        ctx = self.context("update")
        with mock.patch.object(git.system, "ROOT", self.base), mock.patch.object(
            git.system, "query", side_effect=query
        ), mock.patch.dict(os.environ):
            git.update(ctx, steps({"fresh": "u", "stale": "u"}))
        self.assertEqual(self.changes(), [("~", "stale bbb1234 → ccc5678")])
        self.assertEqual(ctx.run.call_count, 2)


if __name__ == "__main__":
    unittest.main()
