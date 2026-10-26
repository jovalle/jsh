"""Agent client reconciliation must apply shared config and only report undeclared items."""

import importlib.util
import io
import json
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
SPEC = importlib.util.spec_from_file_location("jsh_agents", ROOT / "scripts/configure/agents.py")
AGENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AGENTS)

CODEX = """model = "gpt"

[mcp_servers.extra]
command = "/bin/extra"
args = ["serve"]

[plugins."tool@market"]
enabled = true
"""


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(dir=ROOT / "tmp"))
        self.addCleanup(shutil.rmtree, self.home)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        stdout = patch("sys.stdout", new_callable=io.StringIO)
        self.stdout = stdout.start()
        self.addCleanup(stdout.stop)
        patcher = patch.object(AGENTS.shutil, "which", self.which)
        patcher.start()
        self.addCleanup(patcher.stop)
        source = self.home / "source/skills"
        for name, flag in (("handoff", "disable-model-invocation: true\n"), ("research", "")):
            self.seed(f"source/skills/{name}/SKILL.md", f"---\nname: {name}\n{flag}---\nBody\n")
        self.seed(".codex/config.toml", CODEX)
        self.seed(".config/opencode/skills/local-skill/SKILL.md", "---\nname: local\n---\n")
        self.seed(
            ".config/opencode/opencode.json",
            json.dumps({"mcp": {"gsd": {"type": "local", "command": ["gsd"]}}}),
        )
        self.config = {
            "mcp": {"notion": {"url": "https://mcp.notion.com/mcp"}},
            "skills": {"path": "~/.agents/skills", "source": str(source)},
            "agents": [
                {
                    "id": "codex",
                    "name": "Codex",
                    "command": "codex",
                    "inventory": {
                        "mcp": [{"format": "codex", "path": "~/.codex/config.toml"}],
                        "plugins": [{"format": "codex", "path": "~/.codex/config.toml"}],
                    },
                },
                {
                    "id": "opencode",
                    "name": "OpenCode",
                    "command": "opencode",
                    "check": [str(self.bin / "opencode"), "--version"],
                    "links": ["~/.config/opencode/agents"],
                    "plugins": "~/.config/opencode/opencode.json",
                    "inventory": {
                        "mcp": [{"format": "opencode", "path": "~/.config/opencode/opencode.json"}],
                        "skills": ["~/.config/opencode/skills"],
                        "skill_commands": "~/.config/opencode/commands",
                    },
                    "keep": {"mcp": ["gsd"]},
                },
            ],
        }
        self.stub("codex", "echo codex 1.0")
        self.stub("opencode", "echo 9.9.9")

    def which(self, name):
        path = self.bin / name
        return str(path) if path.exists() else None

    def seed(self, relative, text):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def stub(self, name, body):
        path = self.seed(f"bin/{name}", f"#!/bin/sh\n{body}\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def reconcile(self, dry_run=False):
        path = self.seed("agents.json", json.dumps(self.config))
        AGENTS.reconcile(self.home, dry_run, path, {})
        return self.stdout.getvalue()

    def opencode(self):
        return json.loads((self.home / ".config/opencode/opencode.json").read_text())

    def test_reports_undeclared_items_and_skips_shared_and_kept(self):
        text = self.reconcile(dry_run=True)
        self.assertIn("undeclared codex:mcp:extra", text)
        self.assertIn("undeclared codex:plugins:tool@market", text)
        self.assertIn("undeclared opencode:skills:local-skill", text)
        self.assertNotIn("opencode:mcp:gsd", text)

    def test_dry_run_changes_nothing(self):
        before = (self.home / ".codex/config.toml").read_text()
        text = self.reconcile(dry_run=True)
        self.assertIn("would add MCP server notion to OpenCode", text)
        self.assertNotIn("notion", self.opencode()["mcp"])
        self.assertEqual((self.home / ".codex/config.toml").read_text(), before)
        self.assertFalse((self.home / ".config/opencode/commands").exists())

    def test_apply_adds_shared_servers_and_user_only_skill_commands(self):
        self.reconcile()
        self.assertEqual(
            self.opencode()["mcp"]["notion"],
            {"type": "remote", "url": "https://mcp.notion.com/mcp", "enabled": True},
        )
        self.assertIn("gsd", self.opencode()["mcp"])
        codex = (self.home / ".codex/config.toml").read_text()
        self.assertIn('[mcp_servers.notion]\nurl = "https://mcp.notion.com/mcp"', codex)
        self.assertIn("[mcp_servers.extra]", codex)
        command = self.home / ".config/opencode/commands/handoff.md"
        self.assertIn("handoff/SKILL.md", command.read_text())
        self.assertFalse((self.home / ".config/opencode/commands/research.md").exists())

    def test_second_run_makes_no_changes(self):
        self.reconcile()
        codex = (self.home / ".codex/config.toml").read_text()
        self.stdout.truncate(0)
        self.stdout.seek(0)
        text = self.reconcile()
        self.assertNotIn("add ", text)
        self.assertEqual((self.home / ".codex/config.toml").read_text(), codex)

    def test_unmanaged_command_is_not_overwritten(self):
        target = self.seed(".config/opencode/commands/handoff.md", "mine")
        text = self.reconcile()
        self.assertEqual(target.read_text(), "mine")
        self.assertIn("is not managed", text)

    def test_broken_links_and_missing_local_plugins_are_removed(self):
        agents = self.home / ".config/opencode/agents"
        agents.mkdir(parents=True)
        (agents / "gone.md").symlink_to(self.home / "removed.md")
        present = self.seed(".config/opencode/agents/present.md", "")
        (agents / "kept.md").symlink_to(present)
        self.seed(".config/opencode/present.js", "")
        data = self.opencode()
        data["plugin"] = ["file:///removed/gsd.js", "./present.js", "opencode-wakatime"]
        self.seed(".config/opencode/opencode.json", json.dumps(data))
        self.reconcile()
        self.assertFalse((agents / "gone.md").is_symlink())
        self.assertTrue((agents / "kept.md").is_symlink())
        self.assertEqual(self.opencode()["plugin"], ["./present.js", "opencode-wakatime"])

    def test_missing_client_is_reported_and_left_alone(self):
        (self.bin / "codex").unlink()
        before = (self.home / ".codex/config.toml").read_text()
        text = self.reconcile()
        self.assertIn("Codex: `codex` is not installed", text)
        self.assertIn("OpenCode: 9.9.9", text)
        # Shared config still applies to installed config files.
        self.assertNotEqual((self.home / ".codex/config.toml").read_text(), before)

    def test_failed_check_is_reported(self):
        self.stub("opencode", "echo signed out >&2; exit 1")
        text = self.reconcile(dry_run=True)
        self.assertIn("failed: signed out", text)


if __name__ == "__main__":
    unittest.main()
