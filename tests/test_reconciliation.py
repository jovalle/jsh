"""Behavioral regressions for discovery, file convergence, and artifact verification."""

import contextlib
import io
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DesktopPreferenceTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux" and shutil.which("zsh"), "Linux/Zsh required")
    def test_prompt_uses_debian_logo_and_linux_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "os-release"
            for distro, expected in [("debian", "\uf306"), ("unknown", "\uf17c")]:
                release.write_text('ID="' + distro + '"\n')
                env = dict(
                    os.environ,
                    JSH_OS_RELEASE=str(release),
                    JSH_PROMPT_MODE="nerdfont-v3",
                    LC_ALL="C.UTF-8",
                )
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

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("zsh"), "Linux/Zsh required")
    def test_prompt_uses_ascii_icons_in_c_locale(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "os-release"
            release.write_text("ID=testlinux\n")
            env = dict(
                os.environ,
                JSH_OS_RELEASE=str(release),
                JSH_PROMPT_MODE="nerdfont-v3",
                LC_ALL="C",
            )
            result = subprocess.run(
                [
                    "zsh",
                    "-fc",
                    'source "$1"; print -rn -- "${_JSH_PROMPT_MODE}:${_JSH_PROMPT_ICON[linux]}:${_JSH_PROMPT_ICON[prompt]}"',
                    "test",
                    str(ROOT / "lib/zsh/prompt.zsh"),
                ],
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout, "ascii:testlinux:>")
            self.assertEqual(result.stderr, "")


class WaterfoxLifecycleTests(unittest.TestCase):
    def test_symlinked_waterfox_policy_is_rejected(self):
        script = r"""source "$1"
TEMP_DIR="$2"
prepare_policy
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy"
            policy.symlink_to(root / "real-policy")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "test",
                    str(ROOT / "scripts/unix/configure/waterfox.sh"),
                    directory,
                ],
                env=dict(
                    os.environ,
                    JSH_PLAIN_OUTPUT="1",
                    JSH_WATERFOX_POLICY_FILE=str(policy),
                ),
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to replace symlinked Waterfox policy", result.stderr)

    def test_current_macos_content_handler_is_not_rewritten(self):
        script = r"""source "$1"
macos_content_handler() { printf '%s\n' net.waterfox.waterfox; }
duti() { printf '%s\n' "$*" >> "$TEST_EVENTS"; }
set_macos_content_handler net.waterfox.waterfox public.html
"""
        with tempfile.TemporaryDirectory() as directory:
            events = Path(directory) / "events"
            subprocess.run(
                ["bash", "-c", script, "test", str(ROOT / "lib/unix/waterfox.sh")],
                env=dict(os.environ, TEST_EVENTS=str(events)),
                capture_output=True,
                check=True,
            )
            self.assertFalse(events.exists())

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


class DeployTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("zsh"), "Zsh is required for dotfile deployment")
    def test_deploy_failure_restores_conflicts_and_command_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            home = Path(directory) / "home"
            home.mkdir()
            for relative in ("scripts/unix/deploy/dotfiles.zsh", "lib/output.sh"):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            jstow = root / "bin/jstow"
            jstow.parent.mkdir(parents=True)
            jstow.write_text("#!/bin/sh\nexit 1\n")
            jstow.chmod(0o755)
            source = root / "dotfiles/.config/example/settings.json"
            source.parent.mkdir(parents=True)
            source.write_text("managed\n")
            conflict = home / ".config/example/settings.json"
            conflict.parent.mkdir(parents=True)
            conflict.write_text("original\n")
            env = dict(
                os.environ,
                HOME=str(home),
                XDG_STATE_HOME=str(home / "state"),
                JSH_ASSUME_YES="1",
                JSH_PLAIN_OUTPUT="1",
            )

            result = subprocess.run(
                ["zsh", str(root / "scripts/unix/deploy/dotfiles.zsh")],
                env=env,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(conflict.read_text(), "original\n")
            self.assertFalse((home / ".bin").exists())
            backups = home / "state/jsh/backups"
            self.assertFalse(backups.exists() and any(backups.iterdir()))

    @unittest.skipUnless(shutil.which("zsh"), "Zsh is required for dotfile deployment")
    def test_deploy_ignores_generated_zsh_completion_dumps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            home = Path(directory) / "home"
            home.mkdir()
            for relative in ("scripts/unix/deploy/dotfiles.zsh", "bin/jstow", "lib/output.sh"):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            (root / "dotfiles").mkdir()
            (root / "dotfiles/.zcompdump").write_text("repository cache\n")
            home_cache = home / ".zcompdump"
            home_cache.write_text("home cache\n")
            env = dict(
                os.environ,
                HOME=str(home),
                XDG_STATE_HOME=str(home / "state"),
                JSH_ASSUME_YES="1",
                JSH_PLAIN_OUTPUT="1",
            )
            command = ["zsh", str(root / "scripts/unix/deploy/dotfiles.zsh")]

            subprocess.run(command, env=env, capture_output=True, check=True)
            subprocess.run(command, env=env, capture_output=True, check=True)

            self.assertEqual(home_cache.read_text(), "home cache\n")
            self.assertFalse(home_cache.is_symlink())
            self.assertFalse((home / "state/jsh/backups").exists())

    @unittest.skipUnless(shutil.which("zsh"), "Zsh is required for dotfile deployment")
    def test_deploy_tolerates_restricted_home_subtrees(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            home = Path(directory) / "home"
            shim_dir = Path(directory) / "bin"
            home.mkdir()
            shim_dir.mkdir()
            for relative in ("scripts/unix/deploy/dotfiles.zsh", "bin/jstow", "lib/output.sh"):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            source = root / "dotfiles/.config/example/settings.json"
            source.parent.mkdir(parents=True)
            source.write_text('{"personal": true}\n')
            find_shim = shim_dir / "find"
            find_shim.write_text('#!/bin/sh\n"$REAL_FIND" "$@"\n' '[ "$1" != "$HOME" ]\n')
            find_shim.chmod(0o755)
            env = dict(
                os.environ,
                HOME=str(home),
                JSH_ASSUME_YES="1",
                JSH_PLAIN_OUTPUT="1",
                PATH=f"{shim_dir}:{os.environ['PATH']}",
                REAL_FIND=shutil.which("find"),
            )

            subprocess.run(
                ["zsh", str(root / "scripts/unix/deploy/dotfiles.zsh")],
                env=env,
                capture_output=True,
                check=True,
            )

            self.assertTrue((home / ".config/example/settings.json").samefile(source))

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

    @unittest.skipUnless(shutil.which("zsh"), "Zsh is required for dotfile deployment")
    def test_deploy_leaves_gitignored_dotfile_state_unmanaged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            home = Path(directory) / "home"
            home.mkdir()
            for relative in ("scripts/unix/deploy/dotfiles.zsh", "bin/jstow", "lib/output.sh"):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            ignored_source = root / "dotfiles/.config/example/runtime.json"
            ignored_source.parent.mkdir(parents=True)
            ignored_source.write_text("repository runtime\n")
            (root / ".gitignore").write_text("dotfiles/.config/example/\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            live_state = home / ".config/example/runtime.json"
            live_state.parent.mkdir(parents=True)
            live_state.write_text("live runtime\n")
            env = dict(
                os.environ,
                HOME=str(home),
                XDG_STATE_HOME=str(home / "state"),
                JSH_ASSUME_YES="1",
                JSH_PLAIN_OUTPUT="1",
            )

            subprocess.run(
                ["zsh", str(root / "scripts/unix/deploy/dotfiles.zsh")],
                env=env,
                capture_output=True,
                check=True,
            )

            self.assertEqual(live_state.read_text(), "live runtime\n")
            self.assertFalse(live_state.is_symlink())
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
            "#!/bin/sh\n" f"printf '%s\\n' '{label}' >> \"$JSH_TEST_LOG\"\n" f"exit {exit_code}\n"
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


if __name__ == "__main__":
    with contextlib.redirect_stdout(io.StringIO()):
        unittest.main()
