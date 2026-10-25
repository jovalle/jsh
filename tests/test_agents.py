import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "lib/unix/agents.sh"


class AgentValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.home = base / "home"
        self.bin = base / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.config = base / "agents.json"
        self.reload_marker = base / "reloaded"

    def stub(self, name: str, body: str):
        executable = self.bin / name
        executable.write_text(f"#!/bin/sh\n{body}\n")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)

    def write_config(self, agents):
        self.config.write_text(json.dumps({"schema": 1, "agents": agents}))

    def run_script(self, *arguments: str):
        environment = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:/usr/bin:/bin:{os.path.dirname(shutil.which('jq'))}",
            "JSH_AGENTS_CONFIG": str(self.config),
        }
        completed = subprocess.run(
            [str(SCRIPT), str(ROOT), *arguments],
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=True,
        )
        return [tuple(line.split("\t", 1)) for line in completed.stdout.splitlines()]

    def opencode_fixture(self):
        self.stub("opencode", f'[ "$1" = reload ] && : > "{self.reload_marker}"; echo 9.9.9')
        config_dir = self.home / ".config/opencode"
        (config_dir / "agents").mkdir(parents=True)
        (config_dir / "agents/gsd.md").symlink_to(self.home / "removed/gsd.md")
        present = config_dir / "present.js"
        present.write_text("")
        (config_dir / "opencode.json").write_text(
            json.dumps({"plugin": ["file:///removed/gsd.js", "./present.js", "opencode-wakatime"]})
        )
        self.write_config(
            [
                {
                    "name": "OpenCode",
                    "command": "opencode",
                    "check": ["opencode", "--version"],
                    "links": ["~/.config/opencode/agents"],
                    "plugins": "~/.config/opencode/opencode.json",
                    "reload": ["opencode", "reload"],
                }
            ]
        )
        return config_dir

    def test_check_reports_stale_link_and_missing_local_plugin_without_changing_them(self):
        config_dir = self.opencode_fixture()

        records = self.run_script()

        self.assertEqual(
            records,
            [
                ("issue", f"OpenCode: broken link {config_dir}/agents/gsd.md"),
                (
                    "issue",
                    f"OpenCode: missing plugin file:///removed/gsd.js in "
                    f"{config_dir}/opencode.json",
                ),
            ],
        )
        self.assertTrue((config_dir / "agents/gsd.md").is_symlink())
        self.assertFalse(self.reload_marker.exists())

    def test_repair_removes_stale_link_and_plugin_then_reloads(self):
        config_dir = self.opencode_fixture()

        records = self.run_script("--repair")

        self.assertEqual(
            records,
            [
                ("fixed", f"OpenCode: removed broken link {config_dir}/agents/gsd.md"),
                (
                    "fixed",
                    f"OpenCode: removed missing plugin file:///removed/gsd.js from "
                    f"{config_dir}/opencode.json",
                ),
                ("ok", "OpenCode: 9.9.9"),
            ],
        )
        self.assertFalse((config_dir / "agents/gsd.md").is_symlink())
        plugins = json.loads((config_dir / "opencode.json").read_text())["plugin"]
        self.assertEqual(plugins, ["./present.js", "opencode-wakatime"])
        self.assertTrue(self.reload_marker.exists())

    def test_reports_missing_command_and_failed_health_check(self):
        self.stub("codex", 'echo "Not logged in" >&2; exit 1')
        self.write_config(
            [
                {"name": "Copilot", "command": "copilot-missing"},
                {"name": "Codex", "command": "codex", "check": ["codex", "login", "status"]},
            ]
        )

        records = self.run_script()

        self.assertEqual(
            records,
            [
                ("issue", "Copilot: `copilot-missing` is not installed; run `jsh install`."),
                ("issue", "Codex: `codex login status` failed: Not logged in"),
            ],
        )

    def test_skips_agents_for_other_operating_systems(self):
        self.write_config([{"name": "Elsewhere", "os": ["plan9"], "command": "missing"}])

        self.assertEqual(self.run_script(), [])


if __name__ == "__main__":
    unittest.main()
