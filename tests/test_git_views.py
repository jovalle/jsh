"""Tests for project lookup and commit history."""

from tests.test_git import BASE_DATE, GitTestCase, real_git


class GetTests(GitTestCase):
    def setUp(self):
        super().setUp()
        self.env["GIT_BASE"] = str(self.tmp)
        fake = self.tmp / "fakebin/git"
        fake.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = ls-remote ]; then\n'
            '  printf "%s\\n" "$2" >> "$GET_PROBES"\n'
            '  case "$2" in *github.com*) exit "${GITHUB_RESULT:-0}";;\n'
            '  *) exit "${GITLAB_RESULT:-1}";; esac\n'
            "fi\n"
            'if [ "$1" = clone ]; then\n'
            '  printf "%s\\n" "$2" > "$GET_URL"\n'
            '  mkdir "$3"\n'
            "  exit\n"
            "fi\n"
            'exec "$REAL_GIT" "$@"\n'
        )
        fake.chmod(0o755)
        self.env["REAL_GIT"] = real_git()
        self.env["GET_URL"] = str(self.tmp / "url")
        self.env["GET_PROBES"] = str(self.tmp / "probes")

    def test_get_resolves_and_clones_to_projects(self):
        self.run_git("get", "owner/project", cwd=self.tmp)
        self.assertTrue((self.tmp / "project").is_dir())
        self.assertEqual(
            (self.tmp / "url").read_text().strip(), "https://github.com/owner/project.git"
        )

    def test_get_refuses_existing_destination(self):
        (self.tmp / "project").mkdir()
        result = self.run_git("get", "owner/project", cwd=self.tmp, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.tmp / "url").exists())

    def test_get_stops_after_github_succeeds(self):
        self.run_git("get", "owner/project", cwd=self.tmp, env={"GITLAB_RESULT": "0"})
        self.assertEqual(
            (self.tmp / "probes").read_text().splitlines(), ["https://github.com/owner/project.git"]
        )

    def test_get_tries_gitlab_when_github_is_unavailable(self):
        self.run_git(
            "get", "owner/project", cwd=self.tmp, env={"GITHUB_RESULT": "1", "GITLAB_RESULT": "0"}
        )
        self.assertEqual(
            (self.tmp / "url").read_text().strip(), "https://gitlab.com/owner/project.git"
        )

    def test_get_accepts_a_url_to_select_the_host(self):
        self.run_git("get", "https://gitlab.com/owner/project.git", cwd=self.tmp)
        self.assertEqual(
            (self.tmp / "url").read_text().strip(), "https://gitlab.com/owner/project.git"
        )


class CommitViewTests(GitTestCase):
    def test_commits_prints_history_without_a_terminal(self):
        repo = self.repo()
        result = self.run_git("commits", cwd=repo)
        self.assertIn("base", result.stdout)
        self.assertIn("Test", result.stdout)
        self.assertIn(self.out("rev-parse", "--short", "HEAD", cwd=repo), result.stdout)

    def test_history_does_not_pretruncate_subjects(self):
        repo = self.repo()
        subject = ("A long commit message " + "with plenty of useful detail " * 4).strip()
        self.run_git("commit", "--quiet", "--allow-empty", "-m", subject, cwd=repo)
        self.assertIn(subject, self.run_git("commits", cwd=repo).stdout)

    def test_preview_omits_duplicate_committer_and_date(self):
        repo = self.repo()
        commit = self.out("rev-parse", "HEAD", cwd=repo)
        result = self.run_git("commits", "--preview", commit, cwd=repo)
        self.assertIn("Author:", result.stdout)
        self.assertNotIn("Committer:", result.stdout)
        self.assertNotIn("CommitDate:", result.stdout)

    def test_preview_shows_distinct_committer_and_date(self):
        repo = self.repo()
        self.run_git(
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "different",
            cwd=repo,
            env={"GIT_COMMITTER_NAME": "Another", "GIT_AUTHOR_DATE": BASE_DATE},
        )
        commit = self.out("rev-parse", "HEAD", cwd=repo)
        result = self.run_git("commits", "--preview", commit, cwd=repo)
        self.assertIn("Committer: Another", result.stdout)
        self.assertIn("CommitDate:", result.stdout)
