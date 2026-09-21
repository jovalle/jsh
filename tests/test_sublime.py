import os
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
            env={**os.environ, "SUBLIME_BINARY": str(self.binary), "JSH_ROOT": str(ROOT)},
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


if __name__ == "__main__":
    unittest.main()
