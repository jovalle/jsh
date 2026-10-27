"""Installation is scoped, repeatable, and avoids system upgrades."""

import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("jsh_packages", ROOT / "scripts/install.py")
PACKAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGES)


class PackageTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def setUp(self):
        patcher = patch.object(PACKAGES, "DRY_RUN", False)
        patcher.start()
        self.addCleanup(patcher.stop)
        stdout = patch("sys.stdout", new_callable=io.StringIO)
        stdout.start()
        self.addCleanup(stdout.stop)
        for target, name in ((PACKAGES, "admin"), (PACKAGES.output, "confirm")):
            patcher = patch.object(target, name, return_value=True)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_apt_only_installs_missing_packages_without_upgrade(self):
        with patch.object(PACKAGES, "native_installed", side_effect=[True, False]), patch.object(
            PACKAGES, "run"
        ) as run:
            PACKAGES.native_packages("apt", ["git", "jq"])
        self.assertEqual(
            run.call_args_list[1].args[0], ["apt-get", "install", "--no-upgrade", "-y", "--", "jq"]
        )
        self.assertTrue(all("upgrade" not in call.args[0] for call in run.call_args_list))

    def test_dnf_does_not_run_upgrades(self):
        with patch.object(PACKAGES, "native_installed", return_value=False), patch.object(
            PACKAGES, "run"
        ) as run:
            PACKAGES.native_packages("dnf", ["git"])
        run.assert_called_once_with(["dnf", "install", "-y", "--", "git"], root=True)

    def test_missing_packages_without_sudo_are_reported_not_installed(self):
        with patch.object(PACKAGES, "native_installed", return_value=False), patch.object(
            PACKAGES, "admin", return_value=False
        ), patch.object(PACKAGES, "run") as run, patch.object(
            PACKAGES.output, "problem"
        ) as problem:
            PACKAGES.native_packages("dnf", ["ripgrep"])
        run.assert_not_called()
        problem.assert_called_once_with("sudo needs a password; install these packages manually")

    def test_failed_python_tool_does_not_stop_the_next_one(self):
        failure = subprocess.CalledProcessError(1, ["uv"])
        installed = [False, True, False, True]
        with patch.object(PACKAGES, "installed", side_effect=installed), patch.object(
            PACKAGES, "run", side_effect=[failure, ""]
        ) as run, patch.object(PACKAGES.output, "problem") as problem:
            PACKAGES.python_tools({"tmail": "tmail-cli", "just": "rust-just"})
        problem.assert_called_once_with("could not install tmail-cli")
        self.assertEqual(run.call_args_list[1].args[0], ["uv", "tool", "install", "rust-just"])

    def test_existing_packages_require_no_mutations(self):
        with patch.object(PACKAGES, "native_installed", return_value=True), patch.object(
            PACKAGES, "run"
        ) as run, patch.object(PACKAGES.output, "current") as current:
            PACKAGES.native_packages("apt", ["git", "jq"])
        run.assert_not_called()
        self.assertEqual([call.args[0] for call in current.call_args_list], ["git", "jq"])

    def test_brew_formulae_and_casks_are_separate(self):
        absent = '{"formulae": [], "casks": []}'
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "run", side_effect=["git", absent, "", "spotify", absent, ""]
        ) as run, patch.dict(os.environ):
            PACKAGES.brew_packages({"formulae": ["git", "jq"], "casks": ["spotify", "ghostty"]})
        self.assertEqual(run.call_args_list[2].args[0], ["brew", "install", "--formula", "jq"])
        self.assertEqual(run.call_args_list[5].args[0], ["brew", "install", "--cask", "ghostty"])

    def test_brew_alias_of_installed_formula_is_not_reinstalled(self):
        info = (
            '{"formulae": [{"name": "python@3.15", "full_name": "python@3.15",'
            ' "aliases": ["python", "python3"], "oldnames": [], "installed": [{}]}], "casks": []}'
        )
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "run", side_effect=["python@3.15", info, ""]
        ) as run, patch.dict(os.environ):
            PACKAGES.brew_packages({"formulae": ["python"]})
        self.assertNotIn("install", [call.args[0][1] for call in run.call_args_list])

    def test_brew_renamed_cask_that_is_installed_is_not_reinstalled(self):
        info = (
            '{"formulae": [], "casks": [{"token": "ghostty", "full_token": "ghostty",'
            ' "old_tokens": ["ghostty-old"], "installed": "1.2.0"}]}'
        )
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "run", side_effect=["", "ghostty", info]
        ) as run, patch.dict(os.environ):
            PACKAGES.brew_packages({"casks": ["ghostty-old"]})
        self.assertNotIn("install", [call.args[0][1] for call in run.call_args_list])

    def test_dry_run_appimage_does_not_query_network_or_write(self):
        with patch.object(PACKAGES, "DRY_RUN", True), patch.object(
            PACKAGES, "installed", return_value=False
        ), patch.object(PACKAGES.platform, "machine", return_value="x86_64"), patch.object(
            PACKAGES, "metadata"
        ) as metadata:
            PACKAGES.appimage("helium", {"release": "https://example.com/release"})
        metadata.assert_not_called()

    def test_existing_appimage_is_not_replaced(self):
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "metadata"
        ) as metadata:
            PACKAGES.appimage("helium", {})
        metadata.assert_not_called()

    def test_vscode_dry_run_does_not_download(self):
        with patch.object(PACKAGES, "DRY_RUN", True), patch.object(
            PACKAGES, "installed", return_value=False
        ), patch.object(PACKAGES, "native_installed", return_value=False), patch.object(
            PACKAGES.platform, "machine", return_value="aarch64"
        ), patch.object(
            PACKAGES, "metadata"
        ) as metadata:
            PACKAGES.vscode(
                {"package": "code", "metadata": "https://example.com/{channel}/{arch}"}, "dnf"
            )
        metadata.assert_not_called()

    def test_flatpak_system_install_is_not_duplicated(self):
        results = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0)]
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES.subprocess, "run", side_effect=results
        ), patch.object(PACKAGES, "run") as run:
            PACKAGES.flatpak({"id": "com.spotify.Client"}, "apt", ["flatpak"])
        run.assert_not_called()

    def test_download_requires_https_and_digest_before_network(self):
        with patch.object(PACKAGES.urllib.request, "urlopen") as urlopen:
            for url, digest in [("http://example.com", "a" * 64), ("https://example.com", "")]:
                with self.assertRaises(ValueError):
                    PACKAGES.download(url, Path("unused"), digest)
        urlopen.assert_not_called()

    def test_checksum_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory, patch.object(
            PACKAGES.urllib.request, "urlopen"
        ) as urlopen:
            urlopen.return_value.__enter__.return_value = io.BytesIO(b"wrong content")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                PACKAGES.download("https://example.com", Path(directory) / "download", "0" * 64)

    def test_dry_run_never_executes_sudo_or_install(self):
        with patch.object(PACKAGES, "DRY_RUN", True), patch.object(
            PACKAGES.os, "geteuid", return_value=1000
        ), patch.object(PACKAGES.subprocess, "run") as run:
            PACKAGES.run(["dnf", "install", "git"], root=True)
        run.assert_not_called()

    def test_mac_app_selection_does_not_install_other_groups(self):
        with patch.dict(os.environ, {"JSH_PLATFORM": "darwin"}), patch.object(
            PACKAGES, "DRY_RUN", True
        ), patch.object(PACKAGES, "brew_packages") as brew:
            PACKAGES.main(["ghostty"])
        brew.assert_called_once_with({"casks": ["ghostty"]})

    def test_missing_brew_tap_is_added_before_formulae(self):
        absent = '{"formulae": [], "casks": []}'
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "run", side_effect=["homebrew/core", "", "", absent, "", ""]
        ) as run, patch.dict(os.environ):
            PACKAGES.brew_packages({"taps": ["xguot/difi"], "formulae": ["xguot/difi/difi"]})
        self.assertEqual(run.call_args_list[1].args[0], ["brew", "tap", "xguot/difi"])
        self.assertEqual(
            run.call_args_list[4].args[0], ["brew", "install", "--formula", "xguot/difi/difi"]
        )

    def test_mac_apps_add_casks_for_the_current_host_only(self):
        config = {
            "platforms": {
                "darwin": {
                    "apps": {"casks": ["spotify"]},
                    "hosts": {"archon": {"casks": ["mounty"]}, "other": {"casks": ["zoom"]}},
                }
            }
        }
        with patch.dict(os.environ, {"JSH_PLATFORM": "darwin", "JSH_HOST": "archon"}), patch.object(
            PACKAGES, "brew_packages"
        ) as brew:
            PACKAGES.install_group(config, config["platforms"]["darwin"], "darwin", "apps")
        brew.assert_called_once_with({"casks": ["spotify", "mounty"]})

    def test_linux_tools_add_xfce_packages_and_skip_brew_when_missing(self):
        config = {"brew": {"formulae": ["eza"]}, "python": {}, "npm": {}}
        spec = {"manager": "apt", "tools": ["jq"], "desktops": {"xfce": ["xfce4-terminal"]}}
        with patch.dict(os.environ, {"JSH_DESKTOP": "XFCE"}), patch.object(
            PACKAGES, "native_packages"
        ) as native, patch.object(PACKAGES, "installed", return_value=False), patch.object(
            PACKAGES, "brew_packages"
        ) as brew:
            PACKAGES.install_group(config, spec, "debian", "tools")
        native.assert_called_once_with("apt", ["jq", "xfce4-terminal"])
        brew.assert_not_called()

    def test_npm_installs_only_missing_global_packages(self):
        results = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1)]
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES.subprocess, "run", side_effect=results
        ), patch.object(PACKAGES, "run") as run:
            PACKAGES.npm_packages({"present": "*", "rea-agents": "*"})
        run.assert_called_once_with(["npm", "install", "--global", "rea-agents@*"])

    def test_python_tool_installs_with_uv_when_available(self):
        with patch.object(PACKAGES, "installed", side_effect=[False, True]), patch.object(
            PACKAGES, "run"
        ) as run:
            PACKAGES.python_tools({"just": "rust-just"})
        run.assert_called_once_with(["uv", "tool", "install", "rust-just"])

    def test_python_tool_falls_back_to_user_pip_without_uv(self):
        with patch.object(PACKAGES, "installed", side_effect=[False, False]), patch.object(
            PACKAGES, "run"
        ) as run:
            PACKAGES.python_tools({"just": "rust-just"})
        run.assert_called_once_with(
            [PACKAGES.sys.executable, "-m", "pip", "install", "--user", "rust-just"]
        )

    def test_installed_python_tool_is_left_alone(self):
        with patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "run"
        ) as run:
            PACKAGES.python_tools({"just": "rust-just"})
        run.assert_not_called()

    def test_runtime_clones_only_missing_vendor_repositories(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory, patch.object(
            PACKAGES, "ROOT", Path(directory)
        ), patch.object(PACKAGES, "run") as run:
            (Path(directory) / "local/vendor/fzf/.git").mkdir(parents=True)
            PACKAGES.vendor({"fzf": "https://example.com/fzf.git", "skills/a": "https://a.git"})
        run.assert_called_once_with(
            [
                "git",
                "clone",
                "--quiet",
                "--depth",
                "1",
                "--",
                "https://a.git",
                f"{directory}/local/vendor/skills/a",
            ]
        )

    def test_fzf_binary_matching_pinned_version_is_kept(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory, patch.object(
            PACKAGES, "ROOT", Path(directory)
        ):
            fzf = Path(directory) / "local/vendor/fzf"
            (fzf / "bin").mkdir(parents=True)
            (fzf / "install").write_text("#!/bin/sh\nversion=0.74.5\n")
            (fzf / "bin/fzf").touch()
            with patch.object(PACKAGES, "run", return_value="0.74.5 (abc123)") as run:
                PACKAGES.fzf_binary()
        self.assertEqual(run.call_count, 1)

    def test_outdated_fzf_binary_is_reinstalled_from_vendored_script(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory, patch.object(
            PACKAGES, "ROOT", Path(directory)
        ):
            fzf = Path(directory) / "local/vendor/fzf"
            fzf.mkdir(parents=True)
            (fzf / "install").write_text("#!/bin/sh\nversion=0.74.5\n")
            with patch.object(PACKAGES, "run") as run:
                PACKAGES.fzf_binary()
        run.assert_called_once_with([f"{fzf}/install", "--bin"])

    def test_launcher_never_replaces_a_foreign_jsh_command(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as home, patch.object(
            PACKAGES.Path, "home", return_value=Path(home)
        ):
            (Path(home) / ".local/bin").mkdir(parents=True)
            (Path(home) / ".local/bin/jsh").write_text("other")
            with self.assertRaisesRegex(RuntimeError, "Refusing to replace"):
                PACKAGES.launcher()
            self.assertEqual((Path(home) / ".local/bin/jsh").read_text(), "other")

    def test_launcher_links_jsh_into_local_bin(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as home, patch.object(
            PACKAGES.Path, "home", return_value=Path(home)
        ):
            PACKAGES.launcher()
            link = Path(home) / ".local/bin/jsh"
            self.assertEqual(link.readlink(), ROOT / "bin/jsh")

    def install_extension(self, shell, present=False):
        builds = {
            "Vitals@x": [
                {"shells": ["40"], "url": "https://e.test/40.zip", "sha256": "a" * 64},
                {"shells": ["45"], "url": "https://e.test/45.zip", "sha256": "b" * 64},
            ]
        }
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as data, patch.dict(
            os.environ, XDG_DATA_HOME=data, JSH_DESKTOP="gnome"
        ), patch.object(PACKAGES, "installed", return_value=True), patch.object(
            PACKAGES, "run", return_value=f"GNOME Shell {shell}.3"
        ) as run, patch.object(PACKAGES, "download") as download, patch.object(
            PACKAGES.output, "problem"
        ) as problem:
            if present:
                (Path(data) / "gnome-shell/extensions/Vitals@x").mkdir(parents=True)
            PACKAGES.gnome_extensions(builds)
        return run, download, problem

    def test_extension_build_matches_running_shell(self):
        run, download, problem = self.install_extension("45")
        self.assertEqual(download.call_args.args[0], "https://e.test/45.zip")
        self.assertEqual(download.call_args.args[2], "b" * 64)
        self.assertEqual(run.call_args.args[0][:3], ["gnome-extensions", "install", "--force"])
        problem.assert_not_called()

    def test_installed_extension_is_left_alone(self):
        run, download, _ = self.install_extension("40", present=True)
        download.assert_not_called()
        self.assertEqual(run.call_count, 1)

    def test_extension_without_pinned_build_is_reported(self):
        _, download, problem = self.install_extension("39")
        download.assert_not_called()
        problem.assert_called_once_with("Vitals@x: no pinned build for GNOME Shell 39")


if __name__ == "__main__":
    unittest.main()
