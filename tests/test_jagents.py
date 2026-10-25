"""Behavior of bin/jagents against a temporary home and config."""

import json
import os
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODEX = """model = "gpt"

[mcp_servers.notion]
url = "https://mcp.notion.com/mcp"

[mcp_servers.extra]
command = "/bin/extra"
args = ["serve"]

[mcp_servers.extra.env]
API_TOKEN = "secret-value"
MODE = "fast"

[mcp_servers.extra.tools.run]
approval_mode = "approve"

[plugins."tool@market"]
enabled = true

[tui]
theme = "dark"
"""


class JagentsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.source = self.home / "source/skills"
        for name, flag in (("handoff", "disable-model-invocation: true\n"), ("research", "")):
            (self.source / name).mkdir(parents=True)
            (self.source / name / "SKILL.md").write_text(
                f"---\nname: {name}\ndescription: test\n{flag}---\nBody\n", encoding="utf-8"
            )
        (self.home / ".codex").mkdir()
        (self.home / ".codex/config.toml").write_text(CODEX, encoding="utf-8")
        (self.home / ".config/opencode/skills/local-skill").mkdir(parents=True)
        (self.home / ".config/opencode/skills/local-skill/SKILL.md").write_text(
            "---\nname: local-skill\ndescription: test\n---\n", encoding="utf-8"
        )
        (self.home / ".config/opencode/opencode.json").write_text(
            json.dumps({"mcp": {"gsd": {"type": "local", "command": ["gsd"]}}}), encoding="utf-8"
        )
        self.config = self.home / "agents.json"
        self.config.write_text(
            json.dumps(
                {
                    "schema": 2,
                    "mcp": {"notion": {"url": "https://mcp.notion.com/mcp"}},
                    "skills": {"path": "~/.agents/skills", "source": str(self.source)},
                    "agents": [
                        {
                            "id": "codex",
                            "name": "Codex",
                            "inventory": {
                                "mcp": [{"format": "codex", "path": "~/.codex/config.toml"}],
                                "plugins": [{"format": "codex", "path": "~/.codex/config.toml"}],
                            },
                        },
                        {
                            "id": "opencode",
                            "name": "OpenCode",
                            "inventory": {
                                "mcp": [
                                    {
                                        "format": "opencode",
                                        "path": "~/.config/opencode/opencode.json",
                                    }
                                ],
                                "skills": ["~/.config/opencode/skills"],
                                "skill_commands": "~/.config/opencode/commands",
                            },
                            "keep": {"mcp": ["gsd"]},
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )

    def run_jagents(self, *arguments):
        environment = dict(
            os.environ,
            HOME=str(self.home),
            JSH_AGENTS_CONFIG=str(self.config),
            XDG_STATE_HOME=str(self.home / ".local/state"),
        )
        return subprocess.run(
            [str(ROOT / "bin/jagents"), *arguments],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def extras(self):
        result = self.run_jagents("extras", "--tsv")
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.split("\t")[0] for line in result.stdout.splitlines()]

    def test_lists_undeclared_items_and_skips_shared_and_kept(self):
        self.assertEqual(
            self.extras(),
            ["codex:mcp:extra", "codex:plugins:tool@market", "opencode:skills:local-skill"],
        )

    def test_apply_adds_shared_servers_and_user_only_skill_commands(self):
        dry = self.run_jagents("apply", "--dry-run")
        self.assertIn("OpenCode: would add MCP server notion", dry.stdout)
        self.assertNotIn("notion", (self.home / ".config/opencode/opencode.json").read_text())

        result = self.run_jagents("apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.home / ".config/opencode/opencode.json").read_text())
        self.assertEqual(
            data["mcp"]["notion"],
            {"type": "remote", "url": "https://mcp.notion.com/mcp", "enabled": True},
        )
        self.assertIn("gsd", data["mcp"])
        command = self.home / ".config/opencode/commands/handoff.md"
        self.assertIn("handoff/SKILL.md", command.read_text())
        self.assertFalse((self.home / ".config/opencode/commands/research.md").exists())
        self.assertEqual(self.run_jagents("apply").stdout, "")

    def test_remove_deletes_codex_tables_without_touching_others(self):
        result = self.run_jagents("remove", "codex:mcp:extra", "codex:plugins:tool@market")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = tomllib.loads((self.home / ".codex/config.toml").read_text())
        self.assertEqual(list(data["mcp_servers"]), ["notion"])
        self.assertNotIn("plugins", data)
        self.assertEqual(data["tui"], {"theme": "dark"})
        self.assertEqual(data["model"], "gpt")

    def test_remove_moves_directories_to_a_backup(self):
        result = self.run_jagents("remove", "opencode:skills:local-skill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / ".config/opencode/skills/local-skill").exists())
        self.assertIn("moved", result.stdout)
        backup = Path(result.stdout.strip().rsplit(" ", 1)[1])
        self.assertTrue(backup.is_relative_to(self.home))
        self.assertTrue((backup / "SKILL.md").is_file())

    def test_adopt_shares_server_with_secrets_as_env_references(self):
        result = self.run_jagents("adopt", "codex:mcp:extra")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("export API_TOKEN", result.stdout)
        config = json.loads(self.config.read_text())
        self.assertEqual(
            config["mcp"]["extra"],
            {
                "command": ["/bin/extra", "serve"],
                "env": {"API_TOKEN": "${env:API_TOKEN}", "MODE": "fast"},
            },
        )
        self.assertNotIn("secret-value", self.config.read_text())

        self.run_jagents("apply")
        entry = json.loads((self.home / ".config/opencode/opencode.json").read_text())["mcp"]
        self.assertEqual(entry["extra"]["environment"]["API_TOKEN"], "{env:API_TOKEN}")
        self.assertNotIn("codex:mcp:extra", self.extras())

    def test_keep_declares_item_for_that_agent_only(self):
        result = self.run_jagents("keep", "codex:plugins:tool@market")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.config.read_text())
        self.assertEqual(config["agents"][0]["keep"], {"plugins": ["tool@market"]})
        self.assertNotIn("codex:plugins:tool@market", self.extras())

    def test_unknown_id_fails(self):
        result = self.run_jagents("remove", "codex:mcp:missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not an extra", result.stderr)


if __name__ == "__main__":
    unittest.main()
