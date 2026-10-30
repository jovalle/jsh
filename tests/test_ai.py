"""AI skill updates select a compatible Node without changing the user's PATH."""

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


class AiTests(unittest.TestCase):
    def test_update_uses_compatible_node_for_rea_and_npm(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as scratch:
            base = Path(scratch)
            old = base / "bin"
            new = base / "brew/opt/node/bin"
            old.mkdir()
            new.mkdir(parents=True)
            log = base / "calls"

            def executable(path, text):
                path.write_text("#!/bin/sh\n" + text + "\n", encoding="utf-8")
                path.chmod(0o755)

            executable(old / "node", "exit 1")
            executable(old / "brew", "exit 0")
            executable(new / "node", "exit 0")
            executable(
                old / "rea",
                'printf "rea %s %s\\n" "$(command -v node)" "$*" >> "$CALLS"\n'
                'if [ "$1" = --version ]; then echo 1.0; '
                'elif [ "$2" = --dry-run ]; then echo \'{"plannedActions": []}\'; fi',
            )
            executable(old / "npm", 'printf "npm %s\\n" "$(command -v node)" >> "$CALLS"')
            executable(old / "graphify", 'if [ "$1" = --version ]; then echo "graphify 1"; fi')
            executable(old / "opencode", "exit 0")
            executable(old / "agy", "exit 0")
            skill = base / ".agents/skills/graphify"
            skill.mkdir(parents=True)
            (skill / ".graphify_version").write_text("1", encoding="utf-8")
            env = {
                **os.environ,
                "HOME": str(base),
                "PATH": f"{old}:/usr/bin:/bin",
                "HOMEBREW_PREFIX": str(base / "brew"),
                "CALLS": str(log),
                "JSH_PHASE": "update",
            }
            result = subprocess.run(
                ["bash", str(ROOT / "modules/ai/skills.sh")],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertIn(f"npm {new}/node", calls)
            self.assertIn(f"rea {new}/node setup --dry-run", calls)
            self.assertIn("--client opencode", calls)
            self.assertIn("--client antigravity", calls)
            self.assertNotIn(f"rea {old}/node", calls)


class AiConfigureTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "ai_configure", ROOT / "modules/ai/configure.py"
        )
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.home = Path(tempfile.mkdtemp(dir=ROOT / "tmp"))
        self.addCleanup(shutil.rmtree, self.home)
        env = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".state"),
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.ctx = mock.Mock(dry_run=False)

    def test_toml_keys_sets_top_level_before_tables(self):
        text = 'model = "x"\n\n[projects."/a"]\ncheck_for_update_on_startup = false\n'
        result = self.module.toml_keys(text, self.module.CODEX)
        self.assertEqual(
            result,
            'model = "x"\ncheck_for_update_on_startup = true\n\n'
            '[projects."/a"]\ncheck_for_update_on_startup = false\n',
        )
        self.assertEqual(self.module.toml_keys(result, self.module.CODEX), result)

    def test_configure_enables_auto_update_and_keeps_other_settings(self):
        opencode = self.home / ".config/opencode/opencode.json"
        codex = self.home / ".codex/config.toml"
        for path, text in (
            (opencode, '{"mcp": {"rea": {}}, "autoupdate": false}'),
            (codex, "check_for_update_on_startup = false\n"),
        ):
            path.parent.mkdir(parents=True)
            path.write_text(text, encoding="utf-8")
        self.module.configure(self.ctx)
        self.assertEqual(json.loads(opencode.read_text())["mcp"], {"rea": {}})
        self.assertIs(json.loads(opencode.read_text())["autoupdate"], True)
        self.assertEqual(
            codex.read_text(),
            "check_for_update_on_startup = true\n\n[desktop]\n"
            'open-link-in-target-preference = "external-browser"\n'
            'open-local-url-in-target-preference = "external-browser"\n',
        )

    def test_toml_keys_updates_existing_table(self):
        text = (
            '[desktop]\nopen-link-in-target-preference = "in-app-browser"\nx = 1\n\n'
            "[tui]\ny = 2\n"
        )
        result = self.module.toml_keys(text, self.module.CODEX_DESKTOP, "desktop")
        self.assertEqual(
            result,
            '[desktop]\nopen-link-in-target-preference = "external-browser"\nx = 1\n'
            'open-local-url-in-target-preference = "external-browser"\n\n[tui]\ny = 2\n',
        )
        again = self.module.toml_keys(result, self.module.CODEX_DESKTOP, "desktop")
        self.assertEqual(again, result)

    def test_helium_host_mirrors_codex_registry(self):
        helium = self.home / "Library/Application Support/net.imput.helium"
        helium.mkdir(parents=True)
        registry = self.home / ".codex/chrome-native-hosts-v2.json"
        registry.parent.mkdir()
        entry = {
            "extensionIds": ["abc"],
            "nativeHostNames": ["com.openai.codexextension"],
            "paths": {"extensionHostPath": "/host"},
            "updatedAt": "2026",
        }
        registry.write_text(json.dumps({"entries": [entry]}), encoding="utf-8")
        with mock.patch.object(self.module.apps, "MACOS", True):
            self.module.helium_host(self.ctx)
        manifest = json.loads(
            (helium / "NativeMessagingHosts/com.openai.codexextension.json").read_text()
        )
        self.assertEqual(manifest["allowed_origins"], ["chrome-extension://abc/"])
        self.assertEqual(manifest["path"], "/host")


if __name__ == "__main__":
    unittest.main()
