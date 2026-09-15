"""Behavioral regressions for discovery, file convergence, and artifact verification."""

import contextlib
import hashlib
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import application_config
import apps
import desktop_defaults


class FileTests(unittest.TestCase):
    def test_second_apply_does_not_replace_file_or_create_another_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings"
            state = Path(directory) / "state"
            with patch.dict(os.environ, {"XDG_STATE_HOME": str(state)}):
                application_config.ensure_file(path, b"before")
                application_config.ensure_file(path, b"after")
                inode, modified = path.stat().st_ino, path.stat().st_mtime_ns
                backups = list(state.rglob("settings"))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_bytes(), b"before")
                self.assertFalse(application_config.ensure_file(path, b"after"))
                self.assertEqual((path.stat().st_ino, path.stat().st_mtime_ns), (inode, modified))
                self.assertEqual(list(state.rglob("settings")), backups)

    def test_mode_drift_is_repaired(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings"
            with patch.dict(os.environ, {"XDG_STATE_HOME": directory}):
                path.write_bytes(b"same")
                path.chmod(0o600)
                self.assertTrue(application_config.ensure_file(path, b"same", 0o644))
                self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_preview_creates_no_directories_or_backups(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "absent/settings"
            self.assertTrue(application_config.ensure_file(path, b"new", dry_run=True))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_user_symlink_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "owned"
            target.write_bytes(b"mine")
            link = Path(directory) / "settings"
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                application_config.ensure_file(link, b"new")
            self.assertEqual(target.read_bytes(), b"mine")


class DesktopDefaultsTests(unittest.TestCase):
    @unittest.skipUnless(
        shutil.which("xdg-mime") and shutil.which("xdg-settings"), "requires xdg-utils"
    )
    def test_xfce_browser_drift_and_second_apply_with_real_xdg_utils(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(
                HOME=directory,
                XDG_CONFIG_HOME=str(root / "config"),
                XDG_DATA_HOME=str(root / "data"),
                XDG_STATE_HOME=str(root / "state"),
                XDG_CONFIG_DIRS=str(root / "etc"),
                XDG_DATA_DIRS=str(root / "share"),
                XDG_CURRENT_DESKTOP="XFCE",
                DE="xfce",
            )
            launcher = root / "data/applications/waterfox.desktop"
            launcher.parent.mkdir(parents=True)
            launcher.write_text(
                "[Desktop Entry]\nType=Application\nName=Waterfox\nExec=/bin/true %u\n"
            )
            registry = root / "config/xfce4/helpers.rc"
            registry.parent.mkdir(parents=True)
            registry.write_text("WebBrowser=firefox\nTerminalEmulator=custom-terminal\n")
            with patch.dict(os.environ, env):
                desktop_defaults.configure_browser()
                self.assertIn("TerminalEmulator=custom-terminal", registry.read_text())
                self.assertEqual(
                    desktop_defaults.query("xdg-settings", "get", "default-web-browser"),
                    "waterfox.desktop",
                )
                files = [
                    registry,
                    root / "config/mimeapps.list",
                    root / "data/xfce4/helpers/waterfox.desktop",
                ]
                before = [(p.read_bytes(), p.stat().st_mtime_ns) for p in files]
                desktop_defaults.configure_browser()
                self.assertEqual(before, [(p.read_bytes(), p.stat().st_mtime_ns) for p in files])

    def test_code_shell_preserves_settings_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / "settings.json"
            settings.write_text(
                json.dumps(
                    {
                        "editor.fontSize": 15,
                        "terminal.integrated.defaultProfile.linux": "bash",
                        "terminal.integrated.profiles.linux": {"bash": {"path": "/bin/bash"}},
                    }
                )
            )
            with patch.dict(os.environ, {"XDG_STATE_HOME": str(root / "state")}), patch.object(
                application_config.sys, "platform", "linux"
            ), patch.object(application_config.shutil, "which", return_value="/usr/bin/zsh"):
                application_config.configure_code_shell(root)
                result = json.loads(settings.read_text())
                self.assertEqual(result["editor.fontSize"], 15)
                self.assertEqual(result["terminal.integrated.defaultProfile.linux"], "zsh")
                self.assertEqual(
                    result["terminal.integrated.profiles.linux"]["bash"], {"path": "/bin/bash"}
                )
                before = settings.stat().st_mtime_ns
                application_config.configure_code_shell(root)
                self.assertEqual(settings.stat().st_mtime_ns, before)

    def test_helium_launcher_uses_managed_profile_command(self):
        with tempfile.TemporaryDirectory() as directory:
            desktop = Path(directory)
            launcher = Path("/home/test/.jsh/bin/helium")

            application_config.configure_helium_launcher(desktop, launcher)

            content = (desktop / "helium.desktop").read_text()
            self.assertIn("Exec=/home/test/.jsh/bin/helium launch -- %U\n", content)
            self.assertIn("StartupWMClass=Helium\n", content)


class DesktopTests(unittest.TestCase):
    @unittest.skipUnless(
        sys.platform == "linux" and shutil.which("xdg-mime"), "Linux xdg-utils required"
    )
    def test_generated_exec_is_resolved_by_xdg_mime(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            applications = home / "data/applications"
            applications.mkdir(parents=True)
            config = home / "config"
            config.mkdir()
            (applications / "jsh-test.desktop").write_text(
                "[Desktop Entry]\nType=Application\nName=Test\nExec="
                + application_config.desktop_executable(Path("/bin/true"))
                + " %f\n"
            )
            (config / "mimeapps.list").write_text(
                "[Default Applications]\napplication/x-jsh-test=jsh-test.desktop\n"
            )
            env = dict(
                os.environ,
                HOME=directory,
                XDG_CONFIG_HOME=str(config),
                XDG_DATA_HOME=str(home / "data"),
                XDG_DATA_DIRS=str(home / "data"),
                XDG_CONFIG_DIRS=str(config),
                XDG_CURRENT_DESKTOP="X-Generic",
                DE="generic",
            )
            result = subprocess.run(
                ["xdg-mime", "query", "default", "application/x-jsh-test"],
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(result.stdout.strip(), "jsh-test.desktop")


class DesktopPreferenceTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux" and shutil.which("zsh"), "Linux/Zsh required")
    def test_prompt_uses_debian_logo_and_linux_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "os-release"
            for distro, expected in [("debian", "\uf306"), ("unknown", "\uf17c")]:
                release.write_text('ID="' + distro + '"\n')
                env = dict(os.environ, JSH_OS_RELEASE=str(release), JSH_PROMPT_MODE="nerdfont-v3")
                result = subprocess.run(
                    [
                        "zsh",
                        "-fc",
                        'source "$1"; print -rn -- "${_JSH_PROMPT_ICON[linux]}"',
                        "test",
                        str(ROOT / "lib/zsh/prompt.zsh"),
                    ],
                    env=env,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.stdout, expected)

    def test_font_install_does_not_download_when_files_match(self):
        import fonts

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "conf").mkdir()
            target = root / "data/fonts/jsh/font.ttf"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"font")
            spec = {"files": {"font.ttf": hashlib.sha256(b"font").hexdigest()}}
            (root / "conf/fonts.json").write_text(json.dumps(spec))
            before = target.stat()
            with patch.object(fonts, "ROOT", root), patch.dict(
                os.environ, {"XDG_DATA_HOME": str(root / "data")}
            ), patch.object(fonts, "download") as download, patch.object(fonts, "emit"):
                fonts.main()
            download.assert_not_called()
            self.assertEqual(target.stat().st_mtime_ns, before.st_mtime_ns)


class WaterfoxLifecycleTests(unittest.TestCase):
    def test_unchanged_browser_stays_open_and_edits_require_shutdown(self):
        script = r"""source "$1"
require_command() { :; }
validate_manifest() { :; }
validate_waterfox_config() { :; }
waterfox_binary() { printf /bin/true; }
waterfox_root() { printf '%s' "$TEST_PROFILE"; }
selected_profile() { printf '%s' "$TEST_PROFILE"; }
validate_configured_addons() { :; }
prepare_waterfox_review() { echo review >> "$TEST_EVENTS"; }
show_waterfox_review() { WATERFOX_SETTINGS_DIFFER=0; }
stage_betterfox() { :; }
prepare_policy() { POLICY_CHANGED=$TEST_DRIFT; }
compose_preferences() { printf managed > "$2"; }
confirm_waterfox_review() { return 0; }
profile_is_locked() { return 0; }
close_waterfox() { echo close >> "$TEST_EVENTS"; }
reconcile_addon_state() { echo edit >> "$TEST_EVENTS"; }
reconcile_addon_permissions() { :; }
install_preferences() { :; }
install_policy() { :; }
configure_associations() { :; }
apply_configuration
"""
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            (profile / "user.js").write_text("managed")
            events = profile / "events"
            for drift, expected in [(0, ["review"]), (1, ["review", "close", "edit"])]:
                events.unlink(missing_ok=True)
                env = dict(
                    os.environ,
                    TEST_PROFILE=directory,
                    TEST_EVENTS=str(events),
                    TEST_DRIFT=str(drift),
                    JSH_ASSUME_YES="1",
                )
                subprocess.run(
                    [
                        "bash",
                        "-c",
                        script,
                        "test",
                        str(ROOT / "scripts/unix/configure/waterfox.sh"),
                    ],
                    env=env,
                    capture_output=True,
                    check=True,
                )
                self.assertEqual(events.read_text().splitlines(), expected)

    def test_current_package_scopes_do_not_insert_blank_lines(self):
        script = 'source "$1"; brew() { return 0; }; install_scope core; install_scope common'
        result = subprocess.run(
            [
                "bash",
                "-c",
                script,
                "test",
                str(ROOT / "scripts/unix/install/packages.sh"),
            ],
            env=dict(os.environ, JSH_PLAIN_OUTPUT="1"),
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.stdout.splitlines(),
            ["core packages are current.", "common packages are current."],
        )


class DeployTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("zsh"), "Zsh is required for dotfile deployment")
    def test_redeploy_preserves_files_under_stow_directory_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            home = Path(directory) / "home"
            (home / ".config").mkdir(parents=True)
            for relative in ("scripts/unix/deploy/dotfiles.zsh", "bin/jstow", "lib/output.sh"):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            source = root / "dotfiles/.config/example/settings.json"
            source.parent.mkdir(parents=True)
            source.write_text('{"personal": true}\n')
            env = dict(
                os.environ,
                HOME=str(home),
                XDG_STATE_HOME=str(home / "state"),
                JSH_ASSUME_YES="1",
                JSH_PLAIN_OUTPUT="1",
            )
            command = ["zsh", str(root / "scripts/unix/deploy/dotfiles.zsh")]
            subprocess.run(command, env=env, capture_output=True, check=True)
            self.assertTrue((home / ".config/example").is_symlink())
            original = source.stat()
            subprocess.run(command, env=env, capture_output=True, check=True)
            self.assertEqual(source.read_text(), '{"personal": true}\n')
            self.assertEqual(source.stat().st_ino, original.st_ino)
            self.assertEqual(source.stat().st_mtime_ns, original.st_mtime_ns)
            self.assertTrue((home / ".config/example/settings.json").samefile(source))
            self.assertFalse((home / "state/jsh/backups").exists())


class MakeOrchestrationTests(unittest.TestCase):
    def prepare_root(self, directory):
        root = Path(directory)
        (root / "lib").mkdir()
        shutil.copy2(ROOT / "lib/output.sh", root / "lib/output.sh")
        return root

    def add_script(self, root, relative, label, exit_code=0, executable=True):
        script = root / relative
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' '{label}' >> \"$JSH_TEST_LOG\"\n"
            f"exit {exit_code}\n"
        )
        script.chmod(0o755 if executable else 0o644)

    def run_make(self, root, target, platform="linux", **environment):
        log = root / "events"
        env = dict(os.environ, JSH_PLAIN_OUTPUT="1", JSH_TEST_LOG=str(log), **environment)
        result = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "-f",
                str(ROOT / "Makefile"),
                target,
                f"JSH_ROOT={root}",
                f"PLATFORM={platform}",
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        events = log.read_text().splitlines() if log.exists() else []
        return result, events

    def test_setup_discovers_scripts_in_deterministic_phase_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare_root(directory)
            scripts = [
                ("scripts/linux/install/20-applications.sh", "linux-applications", True),
                ("scripts/linux/install/10-packages.sh", "linux-packages", True),
                ("scripts/unix/install/30-tools.sh", "unix-tools", True),
                ("scripts/unix/deploy/10-dotfiles.sh", "unix-dotfiles", True),
                ("scripts/unix/configure/20-zed.sh", "unix-zed", True),
                ("scripts/unix/configure/10-spotify.sh", "unix-spotify", True),
                ("scripts/linux/configure/10-desktop.sh", "linux-desktop", True),
                ("scripts/linux/patch/10-patch.sh", "linux-patch", True),
                ("scripts/development/hooks.sh", "hooks", True),
                ("scripts/unix/configure/00-non-executable.sh", "ignored", False),
            ]
            for relative, label, executable in scripts:
                self.add_script(root, relative, label, executable=executable)

            result, events = self.run_make(root, "setup")

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                events,
                [
                    "linux-packages",
                    "linux-applications",
                    "unix-tools",
                    "unix-dotfiles",
                    "unix-spotify",
                    "unix-zed",
                    "linux-desktop",
                ],
            )

    def test_configure_filters_scripts_for_each_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare_root(directory)
            for platform in ("unix", "linux", "darwin", "windows"):
                self.add_script(
                    root,
                    f"scripts/{platform}/configure/10-{platform}.sh",
                    platform,
                )

            for platform, expected in [
                ("linux", ["unix", "linux"]),
                ("darwin", ["unix", "darwin"]),
                ("wsl", ["unix", "linux", "windows"]),
            ]:
                (root / "events").unlink(missing_ok=True)
                with self.subTest(platform=platform):
                    result, events = self.run_make(root, "configure", platform)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(events, expected)

    def test_failure_mode_is_fail_fast_or_continue_on_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.prepare_root(directory)
            self.add_script(root, "scripts/unix/configure/10-fail.sh", "fail", exit_code=7)
            self.add_script(root, "scripts/unix/configure/20-after.sh", "after")

            result, events = self.run_make(root, "configure")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, ["fail"])

            (root / "events").unlink()
            result, events = self.run_make(root, "configure", JSH_CONTINUE_ON_ERROR="1")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(events, ["fail", "after"])


class EntrypointTests(unittest.TestCase):
    def test_yes_mode_handles_a_tty_device_without_a_controlling_terminal(self):
        entrypoint = (ROOT / "j.sh").read_text()
        terminal_setup = entrypoint.split("if [[ -r /proc/self/status ]]", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, JSH_DIR=directory, JSH_TTY="/dev/tty")
            result = subprocess.run(
                ["bash", "-c", terminal_setup + '\nprintf "%s" "$TTY"', "j.sh", "install", "--yes"],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                start_new_session=True,
                check=True,
            )
            self.assertEqual(result.stdout, "/dev/null")

    def test_output_uses_shared_plain_and_color_contract(self):
        for environment, expected in [
            ({"JSH_PLAIN_OUTPUT": "1"}, "✓ Ready\n".encode()),
            ({"JSH_COLOR": "always", "TERM": "xterm"}, "\x1b[32m✓ Ready\x1b[0m\n".encode()),
        ]:
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("NO_COLOR", "JSH_PLAIN_OUTPUT", "JSH_COLOR")
            }
            env.update(environment)
            code = (
                "import sys; sys.path.insert(0, sys.argv[1]); "
                "import jsh_output; jsh_output.emit('success', 'Ready')"
            )
            result = subprocess.run(
                [sys.executable, "-c", code, str(ROOT / "lib")],
                env=env,
                capture_output=True,
                check=True,
            )
            self.assertEqual(result.stdout, expected)


class ArtifactTests(unittest.TestCase):
    def test_unsafe_archive_members_are_rejected_before_extraction(self):
        cases = [
            ("../escape", None, None),
            ("waterfox/link", tarfile.SYMTYPE, "../../escape"),
            ("waterfox/link", tarfile.LNKTYPE, "../../escape"),
        ]
        for name, member_type, linkname in cases:
            with self.subTest(
                name=name, member_type=member_type
            ), tempfile.TemporaryDirectory() as directory:
                artifact = Path(directory) / "waterfox.tar.bz2"
                with tarfile.open(artifact, "w:bz2") as archive:
                    member = tarfile.TarInfo(name)
                    if member_type is None:
                        archive.addfile(member, io.BytesIO())
                    else:
                        member.type = member_type
                        member.linkname = linkname
                        archive.addfile(member)
                app = {"id": "waterfox", "kind": "tar", "version": "unsafe-test"}
                with patch.object(apps, "command") as command, patch.object(apps, "root") as root:
                    with self.assertRaises(ValueError):
                        apps.install(app, artifact)
                command.assert_not_called()
                root.assert_not_called()

    def test_checksum_failure_never_activates_download(self):
        with tempfile.TemporaryDirectory() as directory:
            app = dict(
                id="zoom",
                kind="deb",
                url="https://example.invalid/zoom.deb",
                sha256=hashlib.sha256(b"trusted").hexdigest(),
            )

            def fetch(arguments):
                Path(arguments[arguments.index("--output") + 1]).write_bytes(b"tampered")

            with patch.object(apps, "command", side_effect=fetch):
                with self.assertRaises(RuntimeError):
                    apps.download(app, Path(directory))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_newer_native_version_is_preserved(self):
        app = dict(id="zoom", kind="deb", package="zoom", version="1.0")
        responses = [
            subprocess.CompletedProcess([], 0, "installed\t2.0", ""),
            subprocess.CompletedProcess([], 0),
        ]
        with patch.object(apps.subprocess, "run", side_effect=responses):
            self.assertEqual(apps.inspect(app), ("unchanged", "2.0"))

    def test_catalog_has_distinct_ids_and_valid_pins(self):
        catalog = apps.load_catalog(apps.ROOT / "conf/apps/debian.json")
        self.assertEqual(
            {a["id"] for a in catalog},
            {"citrix", "zoom", "vscode", "waterfox", "ghostty", "helium"},
        )


if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
