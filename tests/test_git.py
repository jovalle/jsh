"""bin/git adds save, load, refresh, and commit -t, and passes everything else to the real git."""

import datetime as dt
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "bin/git"
BASE_DATE = "2026-01-05 10:00:17 +0000"
BASE = dt.datetime(2026, 1, 5, 10, 0, 17, tzinfo=dt.timezone.utc)

FAKE_GH = """#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path

store = Path(os.environ["FAKE_GH_DIR"])
args = sys.argv[1:]
gists = sorted((p for p in store.iterdir()), key=lambda p: int(p.name), reverse=True)
if args[:3] == ["api", "--paginate", "gists"]:
    for gist in gists:
        print(gist.name + "\\t" + (gist / ".description").read_text())
elif args[:3] == ["gist", "create", "--desc"]:
    gist = store / str(max((int(p.name) for p in gists), default=0) + 1)
    gist.mkdir()
    (gist / ".description").write_text(args[3])
    for name in args[4:]:
        shutil.copy(name, gist / Path(name).name)
    print("https://gist.github.com/" + gist.name)
elif args[:3] == ["gist", "delete", "--yes"]:
    shutil.rmtree(store / args[3])
elif args[:2] == ["gist", "clone"]:
    shutil.copytree(store / args[2], args[3], ignore=shutil.ignore_patterns(".description"))
else:
    sys.exit("fake gh: unsupported " + " ".join(args))
"""


def real_git():
    for directory in os.environ["PATH"].split(os.pathsep):
        candidate = Path(directory or ".") / "git"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            if not candidate.samefile(SHIM):
                return str(candidate)
    raise RuntimeError("git not found")


class GitTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        fakebin = self.tmp / "fakebin"
        fakebin.mkdir()
        (fakebin / "gh").write_text(FAKE_GH)
        (fakebin / "gh").chmod(0o755)
        (self.tmp / "gists").mkdir()
        (self.tmp / "home").mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(
            HOME=str(self.tmp / "home"),
            XDG_CONFIG_HOME=str(self.tmp / "home/.config"),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Test",
            GIT_AUTHOR_EMAIL="test@example.com",
            GIT_COMMITTER_NAME="Test",
            GIT_COMMITTER_EMAIL="test@example.com",
            FAKE_GH_DIR=str(self.tmp / "gists"),
            PATH=os.pathsep.join([str(ROOT / "bin"), str(fakebin), os.environ["PATH"]]),
            TZ="UTC",
            LC_ALL="C",
            NO_COLOR="1",
        )

    def run_git(self, *args, cwd, check=True, env=None):
        result = subprocess.run(
            [str(SHIM), *args],
            cwd=cwd,
            env={**self.env, **(env or {})},
            capture_output=True,
            text=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(f"git {' '.join(args)} failed:\n{result.stdout}{result.stderr}")
        return result

    def out(self, *args, cwd):
        return self.run_git(*args, cwd=cwd).stdout.strip()

    def commit(self, repo, message, *files):
        for name, text in files:
            (repo / name).write_text(text)
        self.run_git("add", "--all", cwd=repo)
        dated = {"GIT_AUTHOR_DATE": BASE_DATE, "GIT_COMMITTER_DATE": BASE_DATE}
        self.run_git("commit", "--quiet", "-m", message, cwd=repo, env=dated)

    def repo(self, name="repo"):
        path = self.tmp / name
        self.run_git("init", "--quiet", "-b", "main", str(path), cwd=self.tmp)
        self.commit(path, "base", ("a.txt", "one\n"))
        return path


class PassthroughTests(GitTestCase):
    def test_other_commands_reach_the_real_git(self):
        expected = subprocess.run(
            [real_git(), "--version"], capture_output=True, text=True, check=True
        )
        self.assertEqual(self.out("--version", cwd=self.tmp), expected.stdout.strip())

    def test_missing_real_git_fails_instead_of_recursing(self):
        only_bash = self.tmp / "onlybash"
        only_bash.mkdir()
        (only_bash / "bash").symlink_to(shutil.which("bash"))
        path = os.pathsep.join([str(ROOT / "bin"), str(only_bash)])
        result = self.run_git("status", cwd=self.tmp, check=False, env={"PATH": path})
        self.assertEqual(result.returncode, 127)
        self.assertIn("no git found on PATH", result.stderr)


class CommitTimestampTests(GitTestCase):
    def setUp(self):
        super().setUp()
        self.path = self.repo()

    def commit_at(self, spec):
        before = dt.datetime.now(dt.timezone.utc)
        self.run_git("commit", "--quiet", "--allow-empty", "-m", "next", "-t", spec, cwd=self.path)
        after = dt.datetime.now(dt.timezone.utc)
        author, committer = self.out("log", "-1", "--format=%at %ct", cwd=self.path).split()
        self.assertEqual(author, committer)
        stamp = dt.datetime.fromtimestamp(int(committer), dt.timezone.utc)
        return stamp, before, after

    def assert_within(self, stamp, start, seconds):
        self.assertGreaterEqual(stamp, start)
        self.assertLess(stamp, start + dt.timedelta(seconds=seconds))

    def test_offset_from_last_commit_fills_random_seconds(self):
        stamp, _, _ = self.commit_at("+40m")
        self.assert_within(stamp, dt.datetime(2026, 1, 5, 10, 40, tzinfo=dt.timezone.utc), 60)

    def test_offset_with_zero_seconds_is_exact(self):
        stamp, _, _ = self.commit_at("+1h40m0s")
        self.assertEqual(stamp, BASE + dt.timedelta(hours=1, minutes=40))

    def test_negative_offset_moves_before_last_commit(self):
        stamp, _, _ = self.commit_at("-2h")
        self.assert_within(stamp, dt.datetime(2026, 1, 5, 8, tzinfo=dt.timezone.utc), 3600)

    def test_exact_timestamp(self):
        stamp, _, _ = self.commit_at("2026-03-04 05:06:07")
        self.assertEqual(stamp, dt.datetime(2026, 3, 4, 5, 6, 7, tzinfo=dt.timezone.utc))

    def test_missing_seconds_are_filled(self):
        stamp, _, _ = self.commit_at("2026-03-04 05:06")
        self.assert_within(stamp, dt.datetime(2026, 3, 4, 5, 6, tzinfo=dt.timezone.utc), 60)

    def test_missing_time_of_day_is_filled(self):
        stamp, _, _ = self.commit_at("2026-03-04")
        self.assert_within(stamp, dt.datetime(2026, 3, 4, tzinfo=dt.timezone.utc), 86400)

    def test_yesterday_with_time(self):
        stamp, before, after = self.commit_at("yesterday 14:30")
        self.assertIn(
            stamp.date(),
            {before.date() - dt.timedelta(days=1), after.date() - dt.timedelta(days=1)},
        )
        self.assertEqual((stamp.hour, stamp.minute), (14, 30))

    def test_today_never_lands_in_the_future(self):
        stamp, before, after = self.commit_at("today")
        self.assertIn(stamp.date(), {before.date(), after.date()})
        self.assertLessEqual(stamp, after)

    def test_weekdays(self):
        cases = {
            "wednesday 09:15:00": lambda today: today - dt.timedelta((today.isoweekday() - 3) % 7),
            "last wed 9:15:00": lambda today: today
            - dt.timedelta((today.isoweekday() - 4) % 7 + 1),
            "next Wednesday 09:15:00": lambda today: today
            + dt.timedelta((2 - today.isoweekday()) % 7 + 1),
        }
        for spec, expected in cases.items():
            with self.subTest(spec=spec):
                stamp, before, after = self.commit_at(spec)
                self.assertIn(stamp.date(), {expected(before.date()), expected(after.date())})
                self.assertEqual(stamp.isoweekday(), 3)
                self.assertEqual(stamp.time(), dt.time(9, 15))

    def test_impossible_date_is_rejected_without_committing(self):
        result = self.run_git(
            "commit",
            "--allow-empty",
            "-m",
            "x",
            "-t",
            "2026-02-30 10:00",
            cwd=self.path,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid timestamp: 2026-02-30 10:00", result.stderr)
        self.assertEqual(self.out("rev-list", "--count", "HEAD", cwd=self.path), "1")

    def test_message_that_looks_like_the_option_is_left_alone(self):
        self.run_git("commit", "--quiet", "--allow-empty", "-m", "-t", cwd=self.path)
        self.assertEqual(self.out("log", "-1", "--format=%s", cwd=self.path), "-t")


class RefreshTests(GitTestCase):
    def setUp(self):
        super().setUp()
        seed = self.repo("seed")
        self.run_git(
            "clone", "--quiet", "--bare", str(seed), str(self.tmp / "origin.git"), cwd=self.tmp
        )
        self.work = self.clone("work")
        self.other = self.clone("other")

    def clone(self, name):
        self.run_git("clone", "--quiet", str(self.tmp / "origin.git"), name, cwd=self.tmp)
        return self.tmp / name

    def push_upstream(self, *files):
        self.commit(self.other, "upstream", *files)
        self.run_git("push", "--quiet", "origin", "main", cwd=self.other)

    def test_rebases_branch_onto_origin_default_and_keeps_local_edits(self):
        self.push_upstream(("b.txt", "upstream\n"))
        self.run_git("switch", "--quiet", "-c", "feature", cwd=self.work)
        self.commit(self.work, "feature", ("c.txt", "feature\n"))
        (self.work / "a.txt").write_text("dirty\n")

        self.run_git("refresh", cwd=self.work)

        self.assertEqual(
            self.out("log", "--format=%s", cwd=self.work).splitlines(),
            ["feature", "upstream", "base"],
        )
        self.assertEqual((self.work / "a.txt").read_text(), "dirty\n")

    def test_conflict_aborts_and_leaves_branch_unchanged(self):
        self.push_upstream(("a.txt", "upstream\n"))
        self.run_git("switch", "--quiet", "-c", "feature", cwd=self.work)
        self.commit(self.work, "feature", ("a.txt", "feature\n"))
        head = self.out("rev-parse", "HEAD", cwd=self.work)

        result = self.run_git("refresh", cwd=self.work, check=False)

        self.assertEqual(result.returncode, 1)
        self.assertIn("aborted, feature is unchanged", result.stderr)
        self.assertEqual(self.out("rev-parse", "HEAD", cwd=self.work), head)
        self.assertEqual(self.out("status", "--porcelain", cwd=self.work), "")


class SaveLoadTests(GitTestCase):
    def setUp(self):
        super().setUp()
        seed = self.repo("seed")
        self.commit(seed, "ignore logs", (".gitignore", "*.log\n"), ("b.txt", "two\n"))
        self.run_git(
            "clone", "--quiet", "--bare", str(seed), str(self.tmp / "origin.git"), cwd=self.tmp
        )
        self.here = self.clone("here", "https://user:secret@GitHub.com:443/owner/repo.git/")
        self.there = self.clone("there", "git@github.com:owner/repo.git")

    def clone(self, name, url):
        self.run_git("clone", "--quiet", str(self.tmp / "origin.git"), name, cwd=self.tmp)
        self.run_git("remote", "set-url", "origin", url, cwd=self.tmp / name)
        return self.tmp / name

    def gists(self):
        return sorted((self.tmp / "gists").iterdir())

    def snapshot(self, repo):
        return (
            self.out("diff", "--cached", cwd=repo),
            self.out("diff", cwd=repo),
            self.out("ls-files", "--others", "--exclude-standard", cwd=repo),
        )

    def make_changes(self):
        (self.here / "a.txt").write_text("staged\n")
        self.run_git("add", "a.txt", cwd=self.here)
        (self.here / "b.txt").write_text("unstaged\n")
        (self.here / "new.txt").write_text("untracked\n")
        (self.here / "noise.log").write_text("ignored\n")

    def test_round_trip_to_another_clone_keeps_staged_unstaged_and_untracked(self):
        self.make_changes()
        self.run_git("save", cwd=self.here)
        self.run_git("load", cwd=self.there)

        self.assertEqual(self.snapshot(self.there), self.snapshot(self.here))
        self.assertFalse((self.there / "noise.log").exists())

    def test_gist_is_keyed_by_origin_without_credentials(self):
        self.make_changes()
        self.run_git("save", cwd=self.here)
        [gist] = self.gists()
        self.assertEqual((gist / ".description").read_text(), "git save: github.com/owner/repo")
        self.assertNotIn("secret", (gist / "info").read_text())

    def test_saving_again_replaces_the_previous_gist(self):
        self.make_changes()
        self.run_git("save", cwd=self.here)
        (self.here / "new.txt").write_text("newer\n")
        self.run_git("save", cwd=self.here)

        [gist] = self.gists()
        self.assertIn("+newer", (gist / "unstaged.patch").read_text())

    def test_load_refuses_a_dirty_tree(self):
        self.make_changes()
        self.run_git("save", cwd=self.here)
        (self.there / "a.txt").write_text("local\n")

        result = self.run_git("load", cwd=self.there, check=False)

        self.assertEqual(result.returncode, 1)
        self.assertIn("working tree has changes", result.stderr)
        self.assertEqual((self.there / "a.txt").read_text(), "local\n")

    def test_clean_tree_saves_nothing(self):
        result = self.run_git("save", cwd=self.here)
        self.assertIn("Nothing to save", result.stdout)
        self.assertEqual(self.gists(), [])


if __name__ == "__main__":
    unittest.main()
