"""App modules preserve user data, respect running apps and sudo, and are safe to repeat."""

import importlib.util
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
# pylint: disable=wrong-import-position
from jsh import apps, files, system
from jsh.output import Display
from jsh.runner import Context


def script(module):
    path = ROOT / "modules" / module / "configure.py"
    spec = importlib.util.spec_from_file_location(f"test_{module}", path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


HELIUM, WATERFOX, SUBLIME, VSCODE = (
    script(name) for name in ("helium", "waterfox", "sublime", "vscode")
)


class AppTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        scratch = tempfile.TemporaryDirectory(dir=ROOT / "tmp")  # pylint: disable=R1732
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        self.backups = self.home / "state/jsh/backups"
        self.policies = self.home / "policies"
        environment = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / "state"),
        }
        self.running = mock.Mock(return_value=False)
        self.present = mock.Mock(return_value=True)
        self.install_root = mock.Mock(side_effect=self.fake_install)
        self.admin = mock.Mock(return_value=True)
        for patcher in (
            mock.patch.dict(os.environ, environment),
            mock.patch.object(apps, "MACOS", False),
            mock.patch.object(apps, "running", self.running),
            mock.patch.object(apps, "present", self.present),
            mock.patch.object(apps, "install_root", self.install_root),
            mock.patch.object(system, "admin", self.admin),
            mock.patch.object(HELIUM, "policy_path", lambda: self.policies / "helium"),
            mock.patch.object(WATERFOX, "POLICY", self.policies / "waterfox"),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.stream = io.StringIO()

    def context(self, dry_run=False):
        display = Display(self.stream, dry_run)
        facts = system.Facts(platform="debian", desktop="", host="test")
        return Context(display, facts, "configure", "test", self.home / "logs", dry_run)

    @staticmethod
    def fake_install(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def seed(self, relative, text):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def backup(self, name):
        found = list(self.backups.glob(f"*/{name}"))
        return found[0] if found else None

    def test_jsonc_preserves_comment_like_strings(self):
        parsed = files.jsonc('{// comment\n"url":"https://example.com/*x*/", "x": [1,],}')
        self.assertEqual(parsed, {"url": "https://example.com/*x*/", "x": [1]})

    def test_json_merge_preserves_nested_preferences_and_original_backup(self):
        original = '{"profile":{"keep":1,"change":false}}'
        path = self.seed("settings.json", original)
        files.update_json(self.context(), path, {"profile": {"change": True}})
        self.assertEqual(json.loads(path.read_text()), {"profile": {"keep": 1, "change": True}})
        self.assertEqual(self.backup("settings.json").read_text(), original)

    def test_json_update_is_noop_when_values_match(self):
        path = self.seed("settings.json", '{/* keep comment */"x":1}')
        files.update_json(self.context(), path, {"x": 1})
        self.assertEqual(path.read_text(), '{/* keep comment */"x":1}')
        self.assertFalse(self.backups.exists())

    def test_invalid_json_is_not_replaced(self):
        path = self.seed("settings.json", "broken")
        with self.assertRaises(ValueError):
            files.update_json(self.context(), path, {"x": 1})
        self.assertEqual(path.read_text(), "broken")

    def test_symlink_update_does_not_modify_source(self):
        source = self.seed("source.json", '{"x":1}')
        target = self.home / "settings.json"
        target.symlink_to(source)
        files.update_json(self.context(), target, {"x": 2})
        self.assertFalse(target.is_symlink())
        self.assertEqual(source.read_text(), '{"x":1}')
        self.assertTrue(self.backup("settings.json").is_symlink())

    def test_dry_run_leaves_existing_and_missing_files_untouched(self):
        path = self.seed("settings.json", '{"x":1}')
        ctx = self.context(dry_run=True)
        files.update_json(ctx, path, {"x": 2})
        files.write(ctx, self.home / "missing/file", "content")
        self.assertEqual(path.read_text(), '{"x":1}')
        self.assertFalse((self.home / "missing").exists())
        self.assertFalse(self.backups.exists())

    def test_helium_uses_default_profile_and_preserves_other_profiles(self):
        default = self.seed(".config/helium/Default/Preferences", '{"unmanaged":42}')
        other = self.seed(".config/helium/Profile 1/Preferences", '{"unmanaged":43}')
        HELIUM.configure(self.context())
        self.assertEqual(json.loads(default.read_text())["unmanaged"], 42)
        self.assertFalse(json.loads(default.read_text())["credentials_enable_service"])
        self.assertEqual(other.read_text(), '{"unmanaged":43}')

    def test_running_browser_gets_a_notice_and_no_writes(self):
        path = self.seed(".config/helium/Default/Preferences", "{}")
        self.running.return_value = True
        HELIUM.configure(self.context())
        self.assertEqual(path.read_text(), "{}")
        self.assertIn("close Helium, then rerun: jsh configure helium", self.stream.getvalue())

    def test_helium_policy_replaces_stale_extension_settings(self):
        stale = {"ExtensionSettings": {"nngceckbapebfimnlniiiahkandclblb": {}}, "Old": 1}
        self.seed("policies/helium", json.dumps(stale))
        HELIUM.configure(self.context())
        written = json.loads((self.policies / "helium").read_text())
        self.assertNotIn("Old", written)
        self.assertNotIn("nngceckbapebfimnlniiiahkandclblb", written["ExtensionSettings"])
        self.assertIn("aeblfdkhhhdcdjpifhhbdiojplfjncoa", written["ExtensionInstallForcelist"])

    def test_current_policy_is_not_rewritten(self):
        self.seed("policies/helium", (ROOT / "modules/helium/policy.json").read_text())
        HELIUM.configure(self.context())
        self.install_root.assert_not_called()

    def test_policy_dry_run_does_not_install(self):
        HELIUM.configure(self.context(dry_run=True))
        self.install_root.assert_not_called()
        self.assertFalse((self.policies / "helium").exists())

    def test_policy_without_sudo_is_reported_not_raised(self):
        self.admin.return_value = False
        HELIUM.configure(self.context())
        self.install_root.assert_not_called()
        self.assertIn("needs sudo; run sudo -v first", self.stream.getvalue())

    def test_uninstalled_apps_are_left_alone(self):
        self.present.return_value = False
        for app in (HELIUM, WATERFOX, VSCODE, SUBLIME):
            app.configure(self.context())
        self.install_root.assert_not_called()
        self.assertEqual(sorted(path.name for path in self.home.iterdir()), [])

    def test_waterfox_uses_default_profile_and_is_repeatable(self):
        profiles = "[Profile0]\nPath=main\nDefault=1\n[Profile1]\nPath=other\n"
        self.seed(".waterfox/profiles.ini", profiles)
        target = self.seed(".waterfox/main/user.js", 'user_pref("my.preference", 42);\n')
        other = self.seed(".waterfox/other/user.js", "unmanaged")
        WATERFOX.configure(self.context())
        first = target.read_text()
        WATERFOX.configure(self.context())
        self.assertEqual(first, target.read_text())
        self.assertIn('user_pref("my.preference", 42);', first)
        self.assertIn(WATERFOX.BEGIN, first)
        self.assertEqual(other.read_text(), "unmanaged")

    def test_waterfox_ambiguous_profiles_are_not_changed(self):
        self.seed(".waterfox/profiles.ini", "[Profile0]\nPath=one\n[Profile1]\nPath=two\n")
        target = self.seed(".waterfox/one/user.js", "unmanaged")
        WATERFOX.configure(self.context())
        self.assertEqual(target.read_text(), "unmanaged")
        self.assertIn("select one default profile", self.stream.getvalue())

    def test_macos_waterfox_policy_keeps_unmanaged_keys_and_drops_stale_addons(self):
        current = {
            "DisableAppUpdate": True,
            "ExtensionSettings": {"{446900e4-71c2-419f-a6a7-df9c091e268b}": {}},
        }
        path = self.policies / "waterfox"
        path.parent.mkdir(parents=True)
        path.write_bytes(plistlib.dumps(current))
        with mock.patch.object(apps, "MACOS", True):
            WATERFOX.configure(self.context())
        written = plistlib.loads(path.read_bytes())
        self.assertTrue(written["DisableAppUpdate"])
        self.assertTrue(written["EnterprisePoliciesEnabled"])
        self.assertNotIn("{446900e4-71c2-419f-a6a7-df9c091e268b}", written["ExtensionSettings"])
        self.assertEqual(written["SearchEngines"]["Default"], "Startpage")

    def test_linux_waterfox_policy_is_not_managed(self):
        WATERFOX.configure(self.context())
        self.install_root.assert_not_called()

    def test_sublime_merges_preferences_into_flatpak_profile(self):
        path = self.seed(
            ".var/app/com.sublimetext.three/config/sublime-text/Packages/User/"
            "Preferences.sublime-settings",
            '{"theme": "custom", "tab_size": 4,}',
        )
        native = self.seed(".config/sublime-text/Packages/User/Preferences.sublime-settings", "{}")
        SUBLIME.configure(self.context())
        written = json.loads(path.read_text())
        self.assertEqual(written["theme"], "custom")
        self.assertEqual(written["tab_size"], 2)
        self.assertFalse(written["update_check"])
        self.assertEqual(native.read_text(), "{}")

    def test_sublime_without_profile_gets_a_notice(self):
        SUBLIME.configure(self.context())
        self.assertFalse((self.home / ".config/sublime-text").exists())
        self.assertIn("open Sublime Text once", self.stream.getvalue())


if __name__ == "__main__":
    unittest.main()
