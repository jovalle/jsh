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
ORIGINAL_ARM64 = bytes.fromhex("09 15 40 39 4a 00 80 52 3f 01 00 71 e9 13 8a 1a")
PATCHED_ARM64 = bytes.fromhex("29 00 80 52 09 15 00 39 e9 03 1f 2a 1f 20 03 d5")
UPDATE_X86 = bytes.fromhex(
    "55 48 89 e5 41 57 41 56 41 55 41 54 53 48 81 ec "
    "18 02 00 00 49 89 ff 48 8b 05 9e b6 3c 00 48 8b"
)
UPDATE_ARM64 = bytes.fromhex(
    "e1 03 1e aa 20 71 08 94 fe 03 01 aa fd 7b 05 a9 fd 43 01 91 ff c3 07 d1"
)
DISABLED_X86 = b"\xc3" + UPDATE_X86[1:]
DISABLED_ARM64 = bytes.fromhex("c0 03 5f d6") + UPDATE_ARM64[4:]
UPDATE_LINUX = bytes.fromhex(
    "55 41 57 41 56 41 55 41 54 53 48 81 ec 08 02 00 00 "
    "49 89 ff 4c 8b 77 10 48 8b af e8 01 00 00 48"
)
DISABLED_LINUX = b"\xc3" + UPDATE_LINUX[1:]
ELF_HEADER = b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\x00" + bytes(44)


class SublimeLinuxTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.binary = self.directory / "sublime_text"
        self.binary.write_bytes(ELF_HEADER + ORIGINAL + UPDATE_LINUX + b"unchanged trailer")
        self.binary.chmod(0o755)

    def command(self, *arguments, running=False, platform="Linux"):
        # Emulate the host and build query; exercise real patching and file operations.
        return subprocess.run(
            [
                "bash",
                "-c",
                "\n".join(
                    [
                        'uname() { printf "%s\\n" "$SUBLIME_TEST_PLATFORM"; }',
                        "export -f uname",
                        "export JSH_SUBLIME_SOURCE_ONLY=1",
                        'source "$1"; shift',
                        'app_build_version() { printf "4200\\n"; }',
                        "sublime_is_running() { return " + ("0" if running else "1") + "; }",
                        "codesign() { [[ $SUBLIME_TEST_PLATFORM == Darwin ]] || exit 99; }",
                        "xattr() { [[ $SUBLIME_TEST_PLATFORM == Darwin ]] || exit 99; }",
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
                "SUBLIME_APP_PATH": str(self.directory),
                "SUBLIME_TEST_PLATFORM": platform,
                "JSH_ROOT": str(ROOT),
                "JSH_INTERACTIVE": "0",
                "HOME": str(self.directory / "home"),
                "XDG_CONFIG_HOME": str(self.directory / "config"),
            },
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_apply_is_repeatable_and_restore_recovers_original(self):
        original = self.binary.read_bytes()
        result = self.command("apply", "--yes")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.binary.read_bytes(), ELF_HEADER + PATCHED + DISABLED_LINUX + b"unchanged trailer"
        )
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
            (ELF_HEADER + ORIGINAL * 2 + UPDATE_LINUX, "ambiguous patch signature"),
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

    def test_macos_upgrades_old_patch_and_restores_its_backup(self):
        self.binary = self.directory / "Contents/MacOS/sublime_text"
        self.binary.parent.mkdir(parents=True)
        # The old patch is already installed; automatic checks must still be patched.
        before = PATCHED + UPDATE_X86 + PATCHED_ARM64 + UPDATE_ARM64
        self.binary.write_bytes(before)
        self.assertEqual(self.command("status", platform="Darwin").returncode, 1)
        for _ in range(2):
            result = self.command("apply", "--yes", platform="Darwin")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                self.binary.read_bytes(),
                PATCHED + DISABLED_X86 + PATCHED_ARM64 + DISABLED_ARM64,
            )
            self.assertEqual(self.command("status", platform="Darwin").returncode, 0)
        backups = list(self.binary.parent.glob("sublime_text.backup_*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)
        result = self.command("restore", "--yes", platform="Darwin")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), before)

    def test_macos_requires_unique_update_signatures(self):
        self.binary = self.directory / "Contents/MacOS/sublime_text"
        self.binary.parent.mkdir(parents=True)
        for license_bytes, update in ((ORIGINAL, UPDATE_X86), (ORIGINAL_ARM64, UPDATE_ARM64)):
            for suffix in (b"unknown", update * 2):
                with self.subTest(license_bytes=license_bytes, suffix=suffix):
                    before = license_bytes + suffix
                    self.binary.write_bytes(before)
                    result = self.command("apply", "--yes", "--force", platform="Darwin")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(self.binary.read_bytes(), before)
                    self.assertEqual(list(self.binary.parent.glob("sublime_text.backup_*")), [])

    def test_linux_repatches_replaced_executable(self):
        before = ELF_HEADER + PATCHED + UPDATE_LINUX
        for _ in range(2):
            self.binary.write_bytes(before)  # A vendor update replaces the executable.
            self.assertEqual(self.command("status").returncode, 1)
            result = self.command("apply", "--yes")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.binary.read_bytes(), ELF_HEADER + PATCHED + DISABLED_LINUX)
            self.assertEqual(self.command("status").returncode, 0)
            result = self.command("apply", "--yes")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backups = list(self.directory.glob("sublime_text.backup_*"))
        self.assertEqual(len(backups), 2)
        self.assertTrue(all(p.read_bytes() == before for p in backups))
        self.assertEqual(self.command("restore", "--yes").returncode, 0)
        self.assertEqual(self.binary.read_bytes(), before)

    def test_linux_rejects_unknown_or_ambiguous_update_code(self):
        for suffix in (b"unknown", UPDATE_LINUX * 2, UPDATE_LINUX + DISABLED_LINUX):
            with self.subTest(suffix=suffix):
                before = ELF_HEADER + PATCHED + suffix
                self.binary.write_bytes(before)
                result = self.command("apply", "--yes", "--force")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(self.binary.read_bytes(), before)
                self.assertEqual(list(self.directory.glob("sublime_text.backup_*")), [])


class SublimePreferencesTests(unittest.TestCase):
    def test_macos_editor_defaults_preserve_mpv_and_only_repair_changed_types(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "Applications/Sublime Text.app").mkdir(parents=True)
            state = home / "associations"
            state.mkdir()
            # duti resolves these extensions to shared video UTIs, not TypeScript.
            for kind in ("public.mpeg-2-transport-stream", "public.avchd-mpeg-2-transport-stream"):
                (state / kind).write_text("io.mpv\n")
            changes = home / "changes"
            shell = r"""
uname() { printf 'Darwin\n'; }
duti() {
  local kind handler
  if [[ $1 == -s ]]; then kind=$3; else kind=$2; fi
  kind=${kind#.}
  case ${kind} in
    ts) kind=public.mpeg-2-transport-stream ;;
    mts|m2ts) kind=public.avchd-mpeg-2-transport-stream ;;
  esac
  if [[ $1 == -s ]]; then
    printf '%s\n' "$*" >> "$HOME/changes"
    printf '%s\n' "$2" > "$HOME/associations/$kind"
  else
    handler=other.app
    [[ ! -f $HOME/associations/$kind ]] || handler=$(< "$HOME/associations/$kind")
    printf '%s\n' "$handler"
  fi
}
source "$1"
"""

            def configure():
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        shell,
                        "_",
                        str(ROOT / "scripts/unix/configure/sublime-text.sh"),
                    ],
                    env={**os.environ, "HOME": temporary},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            configure()
            first = changes.read_text().splitlines()
            assigned = {line.split()[2] for line in first}
            self.assertTrue({"public.source-code", ".py", ".tsx", ".cts", ".toml"} <= assigned)
            self.assertTrue(assigned.isdisjoint({".ts", ".mts", ".m2ts"}))
            self.assertEqual((state / "public.mpeg-2-transport-stream").read_text(), "io.mpv\n")
            self.assertEqual(
                (state / "public.avchd-mpeg-2-transport-stream").read_text(), "io.mpv\n"
            )
            configure()
            self.assertEqual(changes.read_text().splitlines(), first)
            # An extension outside the old spot checks must also be repaired alone.
            (state / "tsx").write_text("other.app\n")
            configure()
            self.assertEqual(
                changes.read_text().splitlines(), first + ["-s com.sublimetext.4 .tsx all"]
            )

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
