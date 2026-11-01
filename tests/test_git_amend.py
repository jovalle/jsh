"""Tests for moving Git commit timestamps."""

import datetime as dt

from tests.test_git import BASE, GitTestCase


class AmendTests(GitTestCase):
    def setUp(self):
        super().setUp()
        self.path = self.repo()
        for index in (1, 2):
            stamp = (BASE + dt.timedelta(hours=index * 6)).strftime("%Y-%m-%d %H:%M:%S +0000")
            self.run_git(
                "commit",
                "--quiet",
                "--allow-empty",
                "-m",
                f"commit {index}",
                cwd=self.path,
                env={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp},
            )

    def history(self):
        return self.out("log", "--reverse", "--format=%s %ct", cwd=self.path).splitlines()

    def test_moves_commit_and_later_commits_by_same_interval(self):
        before = self.history()
        target = self.out("rev-parse", "HEAD~1", cwd=self.path)
        self.run_git("amend", "-t", "-2h0m0s", target, cwd=self.path)
        after = self.history()
        self.assertEqual(after[0], before[0])
        for old, new in zip(before[1:], after[1:]):
            self.assertEqual(int(old.rsplit(" ", 1)[1]) - int(new.rsplit(" ", 1)[1]), 7200)

    def test_single_commit_leaves_later_timestamps_unchanged(self):
        before = self.history()
        self.run_git("amend", "-x", "-t", "+1h0m0s", "HEAD~1", cwd=self.path)
        after = self.history()
        self.assertEqual(after[0], before[0])
        self.assertEqual(after[2], before[2])
        self.assertEqual(int(after[1].split()[-1]) - int(before[1].split()[-1]), 3600)

    def test_refuses_to_move_before_parent_without_changing_head(self):
        before = self.out("rev-parse", "HEAD", cwd=self.path)
        result = self.run_git("amend", "-t", "-7h0m0s", "HEAD~1", cwd=self.path, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.out("rev-parse", "HEAD", cwd=self.path), before)

    def test_single_commit_cannot_move_after_its_successor(self):
        before = self.out("rev-parse", "HEAD", cwd=self.path)
        result = self.run_git("amend", "-x", "-t", "+7h0m0s", "HEAD~1", cwd=self.path, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.out("rev-parse", "HEAD", cwd=self.path), before)

    def test_literal_time_preserves_worktree_and_randomizes_omitted_seconds(self):
        (self.path / "a.txt").write_text("unstaged change\n")
        self.run_git("amend", "-x", "-t", "2026-01-05 17:15", "HEAD~1", cwd=self.path)
        timestamp = int(self.out("show", "-s", "--format=%ct", "HEAD~1", cwd=self.path))
        start = int(dt.datetime(2026, 1, 5, 17, 15, tzinfo=dt.timezone.utc).timestamp())
        self.assertGreaterEqual(timestamp, start)
        self.assertLess(timestamp, start + 60)
        self.assertEqual((self.path / "a.txt").read_text(), "unstaged change\n")

    def test_refuses_to_rewrite_a_merge(self):
        self.run_git("switch", "-c", "side", "HEAD~1", cwd=self.path)
        self.run_git("commit", "--quiet", "--allow-empty", "-m", "side", cwd=self.path)
        self.run_git("switch", "main", cwd=self.path)
        self.run_git("merge", "--quiet", "--no-ff", "-m", "merge", "side", cwd=self.path)
        head = self.out("rev-parse", "HEAD", cwd=self.path)
        result = self.run_git("amend", "-t", "+1h0m0s", "HEAD~1", cwd=self.path, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("merge", result.stderr)
        self.assertEqual(self.out("rev-parse", "HEAD", cwd=self.path), head)
