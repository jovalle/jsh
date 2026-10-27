"""App configuration must preserve user data and be safe to repeat."""

import importlib.util
import io
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jsh_apps", ROOT / "scripts/configure.py")
APPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPS)


class AppTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(dir=ROOT / "tmp"))
        self.addCleanup(shutil.rmtree, self.home)
        stdout = patch("sys.stdout", new_callable=io.StringIO)
        stdout.start()
        self.addCleanup(stdout.stop)
        for name, value in {
            "HOME": self.home,
            "CONFIG": self.home / ".config",
            "BACKUP": self.home / "backups",
            "DRY_RUN": False,
            "MACOS": False,
        }.items():
            patcher = patch.object(APPS, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(APPS, "running", return_value=False)
        self.running = patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(APPS, "present", return_value=True)
        self.present = patcher.start()
        self.addCleanup(patcher.stop)
        self.policies = self.home / "policies"
        patcher = patch.object(APPS, "policy_path", lambda app: self.policies / app)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(APPS, "install_root", side_effect=self.fake_install)
        self.install_root = patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def fake_install(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def seed(self, relative, text):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_jsonc_preserves_comment_like_strings(self):
        parsed = APPS.jsonc('{// comment\n"url":"https://example.com/*x*/", "x": [1,],}')
        self.assertEqual(parsed, {"url": "https://example.com/*x*/", "x": [1]})

    def test_json_merge_preserves_nested_preferences_and_original_backup(self):
        path = self.seed("settings.json", '{"profile":{"keep":1,"change":false}}')
        original = path.read_text()
        APPS.update_json(path, {"profile": {"change": True}})
        self.assertEqual(json.loads(path.read_text()), {"profile": {"keep": 1, "change": True}})
        self.assertEqual((self.home / "backups/settings.json").read_text(), original)

    def test_json_update_is_noop_when_values_match(self):
        path = self.seed("settings.json", '{/* keep comment */"x":1}')
        APPS.update_json(path, {"x": 1})
        self.assertEqual(path.read_text(), '{/* keep comment */"x":1}')
        self.assertFalse((self.home / "backups").exists())

    def test_invalid_json_is_not_replaced(self):
        path = self.seed("settings.json", "broken")
        with self.assertRaises(ValueError):
            APPS.update_json(path, {"x": 1})
        self.assertEqual(path.read_text(), "broken")

    def test_symlink_update_does_not_modify_source(self):
        source = self.seed("source.json", '{"x":1}')
        target = self.home / "settings.json"
        target.symlink_to(source)
        APPS.update_json(target, {"x": 2})
        self.assertFalse(target.is_symlink())
        self.assertEqual(source.read_text(), '{"x":1}')
        self.assertTrue((self.home / "backups/settings.json").is_symlink())

    def test_dry_run_leaves_existing_and_missing_files_untouched(self):
        path = self.seed("settings.json", '{"x":1}')
        with patch.object(APPS, "DRY_RUN", True):
            APPS.update_json(path, {"x": 2})
            APPS.write(self.home / "missing/file", "content")
        self.assertEqual(path.read_text(), '{"x":1}')
        self.assertFalse((self.home / "missing").exists())
        self.assertFalse((self.home / "backups").exists())

    def test_helium_uses_default_profile_and_preserves_other_profiles(self):
        default = self.seed(".config/helium/Default/Preferences", '{"unmanaged":42}')
        other = self.seed(".config/helium/Profile 1/Preferences", '{"unmanaged":43}')
        APPS.helium()
        self.assertEqual(json.loads(default.read_text())["unmanaged"], 42)
        self.assertFalse(json.loads(default.read_text())["credentials_enable_service"])
        self.assertEqual(other.read_text(), '{"unmanaged":43}')

    def test_running_browser_is_skipped_without_writes(self):
        path = self.seed(".config/helium/Default/Preferences", "{}")
        self.running.return_value = True
        APPS.helium()
        self.assertEqual(path.read_text(), "{}")
        self.assertFalse((self.home / "backups").exists())

    def test_waterfox_uses_default_profile_and_is_repeatable(self):
        self.seed(
            ".waterfox/profiles.ini",
            "[Profile0]\nPath=main\nDefault=1\n[Profile1]\nPath=other\n",
        )
        target = self.seed(".waterfox/main/user.js", 'user_pref("my.preference", 42);\n')
        other = self.seed(".waterfox/other/user.js", "unmanaged")
        APPS.waterfox()
        first = target.read_text()
        APPS.waterfox()
        self.assertEqual(first, target.read_text())
        self.assertIn('user_pref("my.preference", 42);', first)
        self.assertEqual(other.read_text(), "unmanaged")

    def test_waterfox_ambiguous_profiles_are_not_changed(self):
        self.seed(".waterfox/profiles.ini", "[Profile0]\nPath=one\n[Profile1]\nPath=two\n")
        target = self.seed(".waterfox/one/user.js", "unmanaged")
        APPS.waterfox()
        self.assertEqual(target.read_text(), "unmanaged")
        self.assertFalse((self.home / "backups").exists())

    def test_macos_vscode_destination_leaves_keybindings_to_dotfiles(self):
        path = self.seed("Library/Application Support/Code/User/settings.json", '{"custom":true}')
        bindings = self.seed(
            "Library/Application Support/Code/User/keybindings.json",
            '[{"key":"ctrl+alt+9","command":"my.command"}]',
        )
        with patch.object(APPS, "MACOS", True), patch.object(
            APPS.shutil, "which", return_value=None
        ):
            APPS.vscode()
        self.assertTrue(json.loads(path.read_text())["custom"])
        self.assertEqual(bindings.read_text(), '[{"key":"ctrl+alt+9","command":"my.command"}]')

    def test_helium_policy_replaces_stale_extension_settings(self):
        stale = {"ExtensionSettings": {"nngceckbapebfimnlniiiahkandclblb": {}}, "Old": 1}
        self.seed("policies/helium", json.dumps(stale))
        APPS.helium()
        written = json.loads((self.policies / "helium").read_text())
        self.assertNotIn("Old", written)
        self.assertNotIn("nngceckbapebfimnlniiiahkandclblb", written["ExtensionSettings"])
        self.assertIn("aeblfdkhhhdcdjpifhhbdiojplfjncoa", written["ExtensionInstallForcelist"])
        self.assertEqual(
            written["ExtensionSettings"]["blockjmkbacgjkknlgpkjjiijinjdanf"],
            {"toolbar_pin": "force_pinned"},
        )

    def test_uninstalled_apps_are_skipped_without_policy_or_settings(self):
        self.present.return_value = False
        for app in (APPS.helium, APPS.waterfox, APPS.vscode, APPS.sublime):
            app()
        self.install_root.assert_not_called()
        self.assertEqual(list(self.home.iterdir()), [])

    def test_current_policy_is_not_rewritten(self):
        self.seed("policies/helium", (ROOT / "conf/helium/policy.json").read_text())
        APPS.helium()
        self.install_root.assert_not_called()

    def test_policy_dry_run_does_not_install(self):
        with patch.object(APPS, "DRY_RUN", True):
            APPS.helium()
        self.install_root.assert_not_called()
        self.assertFalse((self.policies / "helium").exists())

    def test_policy_without_sudo_is_reported_not_raised(self):
        self.install_root.side_effect = subprocess.CalledProcessError(1, ["sudo"])
        APPS.helium()
        self.assertFalse((self.policies / "helium").exists())

    def test_macos_waterfox_policy_keeps_unmanaged_keys_and_drops_stale_addons(self):
        current = {
            "DisableAppUpdate": True,
            "ExtensionSettings": {"{446900e4-71c2-419f-a6a7-df9c091e268b}": {}},
        }
        path = self.policies / "waterfox"
        path.parent.mkdir(parents=True)
        path.write_bytes(plistlib.dumps(current))
        with patch.object(APPS, "MACOS", True):
            APPS.waterfox()
        written = plistlib.loads(path.read_bytes())
        self.assertTrue(written["DisableAppUpdate"])
        self.assertTrue(written["EnterprisePoliciesEnabled"])
        self.assertNotIn("{446900e4-71c2-419f-a6a7-df9c091e268b}", written["ExtensionSettings"])
        self.assertEqual(
            written["ExtensionSettings"]["{d634138d-c276-4fc8-924b-40a0ea21d284}"]["default_area"],
            "navbar",
        )
        self.assertEqual(written["SearchEngines"]["Default"], "Startpage")

    def test_linux_waterfox_policy_is_not_managed(self):
        APPS.waterfox()
        self.install_root.assert_not_called()

    def test_sublime_merges_preferences_into_flatpak_profile(self):
        path = self.seed(
            ".var/app/com.sublimetext.three/config/sublime-text/Packages/User/"
            "Preferences.sublime-settings",
            '{"theme": "custom", "tab_size": 4,}',
        )
        self.seed(".config/sublime-text/Packages/User/Preferences.sublime-settings", "{}")
        APPS.sublime()
        written = json.loads(path.read_text())
        self.assertEqual(written["theme"], "custom")
        self.assertEqual(written["tab_size"], 2)
        self.assertFalse(written["update_check"])
        native = self.home / ".config/sublime-text/Packages/User/Preferences.sublime-settings"
        self.assertEqual(native.read_text(), "{}")

    def test_sublime_without_profile_is_skipped(self):
        APPS.sublime()
        self.assertFalse((self.home / ".config/sublime-text").exists())


if __name__ == "__main__":
    unittest.main()
