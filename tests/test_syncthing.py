"""Syncthing protections preserve existing rules and apply to every folder."""

import importlib.util
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
from jsh.output import Display
from jsh.runner import Context

SPEC = importlib.util.spec_from_file_location("jsh_syncthing", ROOT / "modules/tools/syncthing.py")
SYNCTHING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNCTHING)


class SyncthingTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        scratch = tempfile.TemporaryDirectory(dir=ROOT / "tmp")  # pylint: disable=R1732
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        self.root = self.home / ".jsh"
        self.projects = self.home / "Projects"
        self.root.mkdir()
        self.projects.mkdir()
        (self.root / ".stignore").write_text("(?d).cache\n/local/vendor/\n")
        (self.projects / ".stignore").write_text("!.git/config\nnode_modules\n")
        self.defaults = ["node_modules"]
        self.environment = mock.patch.dict(
            os.environ, {"HOME": str(self.home), "XDG_STATE_HOME": str(self.home / "state")}
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.facts = system.Facts(platform="debian", desktop="", host="test")

    def context(self, dry_run=False):
        ctx = Context(Display(io.StringIO(), dry_run), self.facts, "configure", "tools",
                      self.home / "logs", dry_run)
        ctx.root = self.root
        ctx.run = self.run_command
        return ctx

    def query(self, _ctx, *args):
        if args == ("config", "folders", "list"):
            return "jsh\nprojects"
        if args == ("config", "defaults", "ignores", "dump-json"):
            return json.dumps({"lines": self.defaults})
        if args[-2:] == ("path", "get"):
            return str(self.root if args[2] == "jsh" else self.projects)
        raise AssertionError(args)

    def run_command(self, args):
        self.defaults = Path(args[-1]).read_text().splitlines()

    def test_all_folders_and_defaults_are_protected_idempotently(self):
        with mock.patch.object(SYNCTHING.shutil, "which", return_value="syncthing"), \
             mock.patch.object(SYNCTHING, "query", side_effect=self.query):
            ctx = self.context()
            SYNCTHING.configure(ctx)
            self.assertEqual(self.defaults, [".git", "node_modules"])
            self.assertTrue((self.root / ".stignore").read_text().startswith(
                ".git\nnode_modules\n/local/\n/tmp/\n(?d).cache\n"
            ))
            self.assertEqual((self.projects / ".stignore").read_text(),
                             ".git\nnode_modules\n!.git/config\nnode_modules\n")
            SYNCTHING.configure(ctx)
            self.assertEqual(len(ctx.display.changes), 3)

    def test_dry_run_changes_no_files_or_defaults(self):
        before = (self.projects / ".stignore").read_text()
        with mock.patch.object(SYNCTHING.shutil, "which", return_value="syncthing"), \
             mock.patch.object(SYNCTHING, "query", side_effect=self.query):
            SYNCTHING.configure(self.context(dry_run=True))
        self.assertEqual((self.projects / ".stignore").read_text(), before)
        self.assertEqual(self.defaults, ["node_modules"])

    def test_unavailable_service_is_reported(self):
        with mock.patch.object(SYNCTHING.shutil, "which", return_value="syncthing"), \
             mock.patch.object(SYNCTHING, "query", side_effect=RuntimeError):
            ctx = self.context()
            SYNCTHING.configure(ctx)
        self.assertTrue(ctx.noticed)
