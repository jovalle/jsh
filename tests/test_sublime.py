import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = bytes.fromhex("0f b6 51 05 83 f2 01")
PATCHED = bytes.fromhex("c6 41 05 01 b2 00 90")
ELF_HEADER = b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\x00" + bytes(44)


class SublimeLinuxTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.binary = self.directory / "sublime_text"
        self.binary.write_bytes(ELF_HEADER + ORIGINAL + b"unchanged trailer")
        self.binary.chmod(0o755)

    def command(self, *arguments):
        # Emulate the host and build query; exercise real patching and file operations.
        return subprocess.run(
            [
                "bash",
                "-c",
                "\n".join(
                    [
                        'uname() { printf "Linux\\n"; }',
                        "export -f uname",
                        "export JSH_SUBLIME_SOURCE_ONLY=1",
                        'source "$1"; shift',
                        'app_build_version() { printf "4200\\n"; }',
                        "pgrep() { return 1; }",
                        "codesign() { exit 99; }",
                        "xattr() { exit 99; }",
                        "osascript() { exit 99; }",
                        'main "$@"',
                    ]
                ),
                "_",
                str(ROOT / "bin/sublime"),
                *arguments,
            ],
            env={
                **os.environ,
                "SUBLIME_BINARY": str(self.binary),
                "JSH_ROOT": str(ROOT),
                "HOME": str(self.directory / "home"),
                "XDG_CONFIG_HOME": str(self.directory / "config"),
            },
            capture_output=True,
            text=True,
            check=False,
        )

    def test_apply_is_repeatable_and_restore_recovers_original(self):
        original = self.binary.read_bytes()
        result = self.command("apply", "--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), ELF_HEADER + PATCHED + b"unchanged trailer")
        backups = list(self.directory.glob("sublime_text.backup_*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual(self.command("status").returncode, 0)
        result = self.command("apply", "--force", "--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.directory.glob("sublime_text.backup_*")), backups)
        result = self.command("restore", "--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), original)
        self.assertEqual(self.command("status").returncode, 1)

    def test_apply_disables_updates_even_when_already_patched(self):
        settings = (
            self.directory / "config/sublime-text/Packages/User/Preferences.sublime-settings"
        )
        for _ in range(2):
            settings.parent.mkdir(parents=True, exist_ok=True)
            settings.write_text('{"update_check": true}')
            result = self.command("apply", "--yes")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            preferences = json.loads(re.sub(r",\s*}", "}", settings.read_text()))
            self.assertIs(preferences["update_check"], False)
        self.assertEqual(len(list(self.directory.glob("sublime_text.backup_*"))), 1)

    def test_unknown_duplicate_and_arm64_binaries_are_untouched(self):
        for data, error in (
            (ELF_HEADER + b"unknown", "unrecognized binary structure"),
            (ELF_HEADER + ORIGINAL * 2, "ambiguous patch signature"),
            (
                ELF_HEADER[:18] + b"\xb7\x00" + ELF_HEADER[20:] + ORIGINAL,
                "unsupported Linux binary",
            ),
        ):
            with self.subTest(error=error):
                self.binary.write_bytes(data)
                result = self.command("apply", "--yes", "--force")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(error, result.stdout + result.stderr)
                self.assertEqual(self.binary.read_bytes(), data)
                self.assertEqual(list(self.directory.glob("sublime_text.backup_*")), [])


class SublimePreferencesTests(unittest.TestCase):
    def test_preferences_do_not_require_file_association_tools(self):
        for platform in ("Darwin", "Linux"):
            for preferences_only in (False, True):
                with self.subTest(platform=platform, preferences_only=preferences_only), \
                        tempfile.TemporaryDirectory() as temporary:
                    home = Path(temporary)
                    flatpak = home / ".var/app/com.sublimetext.three"
                    flatpak.mkdir(parents=True)
                    result = subprocess.run(
                        [
                            "bash",
                            "-c",
                            'uname() { printf "%s\\n" "$SUBLIME_TEST_PLATFORM"; }; '
                            'command() { if [[ $1 == -v && ( $2 == duti || $2 == xdg-mime ) ]]; '
                            'then return 1; fi; builtin command "$@"; }; '
                            'script=$1; shift; source "$script" "$@"',
                            "_",
                            str(ROOT / "scripts/unix/configure/sublime-text.sh"),
                            *(["--preferences-only"] if preferences_only else []),
                        ],
                        env={
                            **os.environ,
                            "HOME": temporary,
                            "XDG_CONFIG_HOME": str(home / "xdg"),
                            "SUBLIME_TEST_PLATFORM": platform,
                        },
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    targets = (
                        [home / "Library/Application Support/Sublime Text"]
                        if platform == "Darwin"
                        else [home / "xdg/sublime-text", flatpak / "config/sublime-text"]
                    )
                    for target in targets:
                        settings = target / "Packages/User/Preferences.sublime-settings"
                        preferences = json.loads(re.sub(r",\s*}", "}", settings.read_text()))
                        self.assertIs(preferences["update_check"], False)


if __name__ == "__main__":
    unittest.main()
