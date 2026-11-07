#!/usr/bin/env python3
"""Exercise interactive shell contracts without reading the user's configuration."""

import os
import json
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SHELLS = list(
    dict.fromkeys(
        str(Path(p).resolve())
        for p in ("/bin/bash", shutil.which("bash"), shutil.which("zsh"))
        if p
    )
)


class ShellChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jsh-shell-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.tools = self.home / "tools"
        self.tools.mkdir()
        # A missing vendor dir makes the rc fall back to the checkout's local/vendor.
        (self.home / "vendor").mkdir()
        self.env = dict(
            HOME=str(self.home),
            PATH=f"{self.tools}:/usr/bin:/bin:/usr/sbin:/sbin",
            TERM="xterm-256color",
            LANG="en_US.UTF-8",
            JSH_ROOT=str(ROOT),
            JSH_LOAD_CONFIG="0",
            JSH_VENDOR=str(self.home / "vendor"),
            JSH_RUNTIME_DIR=str(self.home / "runtime"),
            JSH_PROMPT_ASYNC="0",
            JSH_PROMPT_MODE="ascii",
            J_NO_HOOK="1",
            J_DATA=str(self.home / "j.db"),
            GIT_CONFIG_NOSYSTEM="1",
        )
        # Avoid Homebrew discovery leaking installed tools into these isolated shells.
        self.tool("brew", 'printf "HOMEBREW_PREFIX=/nonexistent\\n"')
        for name in ("atuin", "zoxide", "direnv", "fzf", "docker", "kubectl", "task"):
            self.tool(name, "exit 0")

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def test_helium_policy_reports_restart_and_missing_extension(self):
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq required")
        self.tool("jq", f'exec "{jq}" "$@"')
        self.tool("uname", "echo Darwin")
        self.tool("pgrep", "exit 0")
        self.tool("sudo", 'if [ "$1" = -n ]; then shift; fi; if [ "$1" = -- ]; then shift; fi; "$@"')
        self.tool("killall", "exit 0")
        self.tool("plutil", 'cat "$5"')
        runtime = self.home / "fixture"
        (runtime / "scripts/lib").mkdir(parents=True)
        (runtime / "lib/shell").mkdir(parents=True)
        for name in ("apps.sh", "common.sh"):
            shutil.copy(ROOT / "scripts/lib" / name, runtime / "scripts/lib" / name)
        shutil.copy(ROOT / "lib/shell/output.sh", runtime / "lib/shell/output.sh")
        shutil.copytree(ROOT / "scripts/helium", runtime / "scripts/helium")
        (runtime / "scripts/packages.sh").write_text('#!/bin/bash\nexit 0\n')
        source = (ROOT / "scripts/helium.sh").read_text()
        source = source.replace('policy=/Library/Managed\\ Preferences/$(id -un)/net.imput.helium.plist', 'policy=${HOME}/policy.json')
        source = source.replace('/Applications/Helium.app/Contents/Resources/net.imput.helium.manifest/Contents/Resources/net.imput.helium.manifest', '${HOME}/manifest.json')
        script = runtime / "scripts/helium.sh"
        script.write_text(source)
        profile = self.home / "Library/Application Support/net.imput.helium/Default"
        profile.mkdir(parents=True)
        prefs = json.loads((runtime / "scripts/helium/preferences.json").read_text())
        policy = json.loads((runtime / "scripts/helium/policy.json").read_text())
        prefs.setdefault("extensions", {})["pinned_extensions"] = sorted(policy["ExtensionSettings"])
        (profile / "Preferences").write_text(json.dumps(prefs))
        (profile.parent / "Local State").write_text(json.dumps({**json.loads((runtime / "scripts/helium/state.json").read_text()), "browser": {"enabled_labs_experiments": ["enable-experimental-web-platform-features"]}}))
        (self.home / "manifest.json").write_text('{"pfm_name":"ExtensionForceInstallWithSearchOrNewTabOverridesEnabled"}')
        (profile / "Secure Preferences").write_text('{"extensions":{"settings":{"fgmjlmbojbkmdpofahffgcpkhkngfpef":{"location":7}}}}')
        env = self.env | {"JSH_ROOT": str(runtime), "JSH_KEEP_APPS": "1", "XDG_STATE_HOME": str(self.home / "state"), "XDG_CONFIG_HOME": str(self.home / "config"), "TMPDIR": str(self.home)}
        def run():
            result = subprocess.run(["bash", str(script)], env=env, cwd=self.home, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout + result.stderr
        self.assertIn("restart Helium", run())
        saved_policy = (self.home / "policy.json").read_bytes()
        self.assertNotIn("restart Helium", run())
        self.assertEqual((self.home / "policy.json").read_bytes(), saved_policy)
        (profile / "Secure Preferences").write_text('{}')
        self.assertIn("Startpage extension", run())
        (profile / "Secure Preferences").write_text('{"extensions":{"settings":{"fgmjlmbojbkmdpofahffgcpkhkngfpef":{"disable_reasons":[1]}}}}')
        self.assertIn("Startpage extension", run())
        (self.home / "manifest.json").write_text('{}')
        self.assertIn("temporary", run())
        (self.home / "policy.json").write_text('{}')
        self.tool("sudo", "exit 1")
        output = run()
        self.assertIn("needs sudo", output)
        self.assertNotIn("restart Helium to apply the changed policy", output)
        env["JSH_DRY_RUN"] = "1"
        self.assertIn("restart Helium", run())
        self.assertEqual((self.home / "policy.json").read_text(), '{}')

    def run_shell(self, shell, code, **env):
        runtime = Path(env.get("JSH_ROOT", ROOT))
        if "zsh" in Path(shell).name:
            args = [shell, "-d", "-i", "-c", code]
            env["ZDOTDIR"] = str(runtime / "dotfiles")
        else:
            args = [
                shell,
                "--noprofile",
                "--rcfile",
                str(runtime / "dotfiles/.bashrc"),
                "-ic",
                code,
            ]
        result = subprocess.run(
            args, env=self.env | env, cwd=self.home, capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        errors = "\n".join(
            line
            for line in result.stderr.splitlines()
            if not any(
                noise in line for noise in ("no job control", "cannot set terminal process group")
            )
        )
        self.assertEqual(errors, "", result.stdout + errors)
        return result.stdout

    def each_shell(self, code, **env):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.run_shell(shell, code, **env)

    def run_terminal(self, shell, code, login=False, **env):
        environment = self.env | env
        if "zsh" in Path(shell).name:
            environment["ZDOTDIR"] = str(ROOT / "dotfiles")
            args = [shell, "-d", "-i"]
        else:
            args = [shell, "--noprofile", "--rcfile", str(ROOT / "dotfiles/.bashrc"), "-i"]
            if login:
                args = [shell, "--login", "-i"]
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve(shell, args, environment)
        output = bytearray()
        try:
            os.write(terminal, (code + "\nexit\n").encode())
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(terminal, 65536)
                    except OSError:
                        break  # PTYs return EIO when their slave closes.
                    if not chunk:
                        break
                    output.extend(chunk)
            else:
                self.fail("interactive shell timed out: " + output.decode(errors="replace"))
        finally:
            os.close(terminal)
            # Do not leave a stuck interactive shell behind on assertion failure.
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        return output.decode(errors="replace")

    def list_choices(self, shell, line, **env):
        """Type LINE then ^D into an interactive zsh and return what the listing printed."""
        environment = self.env | env | {"ZDOTDIR": str(ROOT / "dotfiles")}
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve(shell, [shell, "-d", "-i"], environment)

        def settle(limit=25.0, quiet=1.0):
            # Keys sent before zle starts are handled by the tty's cooked mode, so wait for quiet.
            chunks = bytearray()
            end = time.monotonic() + limit
            last = time.monotonic()
            while time.monotonic() < end and time.monotonic() - last < quiet:
                if select.select([terminal], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(terminal, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    chunks.extend(chunk)
                    last = time.monotonic()
            return chunks.decode(errors="replace")

        try:
            settle()
            os.write(terminal, b"PATH=$HOME/tools:$PATH\n")
            settle()
            os.write(terminal, line.encode() + b"\x04")
            return settle()
        finally:
            os.close(terminal)
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)

    def test_commands_and_reload_keep_listing_arguments(self):
        self.tool("eza", 'printf "<%s>\\n" "$@"')
        self.each_shell("""
            for name in l ll la lt lS gs gco; do alias "$name" >/dev/null || exit 1; done
            for name in take up bd ff ffd backup j projects; do type "$name" >/dev/null || exit 1; done
            jsh reload
            output=$(ls -lht -- 'two words')
            [[ $output == *'<--sort=modified>'* && $output == *'<two words>'* ]] || exit 2
            take 'two words/sub' || exit 3
            up || exit 4
            [[ $PWD == "$HOME/two words" ]] || exit 5
            up 0 >/dev/null 2>&1 && exit 6
            printf 'keep me' > original
            backup original >/dev/null || exit 7
            for copy in original.*.bak; do
                [[ $(command cat "$copy") == 'keep me' ]] || exit 8
            done
        """)

    def test_listing_falls_back_when_eza_disappears_on_reload(self):
        self.tool("eza", "exit 99")
        self.each_shell("""
            has() { return 1; }
            . "$JSH/lib/shell/commands.sh"
            output=$(ls "$HOME") || exit 1
            [[ $output == *tools* ]] || exit 2
            [[ $(alias ll) != *eza* && $(alias tree 2>/dev/null) != *eza* ]] || exit 3
        """)

    def test_common_aliases_match_between_shells(self):
        aliases = []
        for shell in SHELLS:
            output = self.run_shell(shell, "alias")
            parsed = {}
            for line in output.splitlines():
                item = shlex.split(line.removeprefix("alias "))[-1]
                name, _, value = item.partition("=")
                if name not in ("show_options", "run-help", "which-command"):
                    parsed[name] = value
            aliases.append(parsed)
        for actual in aliases[1:]:
            self.assertEqual(aliases[0], actual)

    def test_bash_login_shell_loads_the_same_commands(self):
        (self.home / ".bashrc").symlink_to(ROOT / "dotfiles/.bashrc")
        (self.home / ".bash_profile").symlink_to(ROOT / "dotfiles/.bash_profile")
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                output = self.run_terminal(
                    shell,
                    "alias l >/dev/null && type j >/dev/null && printf '\\nLOGIN_OK\\n'",
                    login=True,
                )
                self.assertIn("\r\nLOGIN_OK\r\n", output)

    def test_launcher_falls_back_to_bash_and_noninteractive_rc_is_silent(self):
        for name in ("bash", "mkdir", "readlink"):
            (self.tools / name).symlink_to(shutil.which(name, path="/usr/bin:/bin"))
        result = subprocess.run(
            [
                str(ROOT / "bin/jsh"),
                "-i",
                "-c",
                "[[ -n $BASH_VERSION ]] && alias l >/dev/null && type j >/dev/null && printf FALLBACK_OK",
            ],
            env=self.env | {"PATH": str(self.tools)},
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "FALLBACK_OK")
        (self.home / "runtime").rename(self.home / "old-runtime")
        result = subprocess.run(
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                '. "$JSH_ROOT/dotfiles/.bashrc"; [[ -z ${JSH+x} ]]',
            ],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertFalse((self.home / "runtime").exists())

    def test_navigation_preserves_database_and_prefers_exact_project_names(self):
        (self.home / "Projects/alpha").mkdir(parents=True)
        (self.home / "Projects/alphabet").mkdir()
        (self.home / "Stacks/work/beta").mkdir(parents=True)
        self.each_shell("""
            j alpha || exit 1
            [[ $PWD == "$HOME/Projects/alpha" ]] || exit 2
            j -a >/dev/null || exit 3
            j -a >/dev/null || exit 4
            [[ $(command awk -F'|' '$2 >= 2 { print $1 }' "$J_DATA") == "$PWD" ]] || exit 5
            j beta || exit 6
            [[ $PWD == "$HOME/Stacks/work/beta" ]] || exit 7
            if [[ -n ${BASH_VERSION:-} ]]; then _jsh_bash_prompt; fi
            j - || exit 8
            [[ $PWD == "$HOME/Projects/alpha" ]] || exit 9
            j --remove >/dev/null || exit 10
            [[ ! -s $J_DATA ]] || exit 11
            j definitely-missing >/dev/null 2>&1 && exit 12
            projects >/dev/null || exit 13
        """)

    def test_navigation_keeps_frecency_and_ambiguous_selection(self):
        for path in ("Projects/same", "Stacks/team/same", "elsewhere/older", "elsewhere/newer"):
            (self.home / path).mkdir(parents=True)
        self.each_shell("""
            jsh::choose() { shift; printf '%s\\n' "$@" | command tail -n 1; }
            j same || exit 1
            [[ $PWD == "$HOME/Stacks/team/same" ]] || exit 2
            command mkdir -p "${J_DATA%/*}"
            now=$(($(command date +%s) / 3600))
            printf '%s|%s|%s\\n' "$HOME/elsewhere/older" 100 "$((now - 1000))" \
                "$HOME/elsewhere/newer" 2 "$now" > "$J_DATA"
            j elsewhere || exit 3
            [[ $PWD == "$HOME/elsewhere/newer" ]] || exit 4
            printf '%s|1|0\\n' "$HOME/missing" >> "$J_DATA"
            j --clean >/dev/null || exit 5
            [[ $(command wc -l < "$J_DATA") == *2* ]] || exit 6
        """)

    def test_navigation_jumps_to_a_single_fuzzy_project_without_a_chooser(self):
        (self.home / "Projects/alphabet").mkdir(parents=True)
        self.each_shell("""
            jsh::choose() { return 99; }
            j alph || exit 1
            [[ $PWD == "$HOME/Projects/alphabet" ]] || exit 2
        """)

    def test_navigation_keeps_literal_backslashes_and_rejects_record_separators(self):
        for name in (r"literal\name", "bad|name", "trailing\n"):
            (self.home / name).mkdir()
        self.each_shell(r"""
            cd "$HOME/literal\name" || exit 1
            j -a >/dev/null || exit 2
            j -a >/dev/null || exit 3
            IFS='|' read -r entry visits hour < "$J_DATA"
            [[ $entry == "$PWD" && $visits == 2 ]] || exit 4
            j --remove >/dev/null || exit 5
            [[ ! -s $J_DATA ]] || exit 6
            cd "$HOME/bad|name" || exit 7
            j -a >/dev/null 2>&1 && exit 8
            [[ ! -s $J_DATA ]] || exit 9
            jsh::choose() { shift; printf '%s\n' "$1"; }
            J_PATHS="$HOME"
            j pick literal || exit 10
            j - || exit 11
            [[ $PWD == "$HOME/bad|name" ]] || exit 12
            cd "$HOME/"$'trailing\n' || exit 13
            j -a >/dev/null 2>&1 && exit 14
            [[ ! -s $J_DATA ]] || exit 15
        """)

    def test_navigation_accepts_relative_database_paths(self):
        (self.home / "project").mkdir()
        self.each_shell("""
            J_DATA=relative-visits.db
            _j_add "$HOME/project" || exit 1
            [[ -f $J_DATA ]] || exit 2
            _j_remove "$HOME/project" || exit 3
            [[ ! -s $J_DATA ]] || exit 4
        """)

    def test_navigation_path_resolution_does_not_run_directory_hooks(self):
        (self.home / "project").mkdir()
        (self.home / "project link").symlink_to(self.home / "project")
        self.each_shell("""
            if [[ -n ${ZSH_VERSION:-} ]]; then
                chpwd() { printf 'hook\\n' >> "$HOME/directory-hooks"; }
            fi
            original=$PWD
            resolved=$(_j_abspath "$HOME/project link") || exit 1
            [[ $resolved == "$HOME/project" && $PWD == "$original" ]] || exit 2
            [[ ! -e $HOME/directory-hooks ]] || exit 3
            _j_abspath "$HOME/missing" >/dev/null 2>&1 && exit 4
            cd "$HOME/project link" || exit 5
            if [[ -n ${ZSH_VERSION:-} ]]; then
                [[ -s $HOME/directory-hooks ]] || exit 6
            fi
        """)

    def test_zsh_directory_tracking_records_one_visit(self):
        (self.home / "project").mkdir()
        for shell in SHELLS:
            if "zsh" not in Path(shell).name:
                continue
            self.run_shell(
                shell,
                """
                cd "$HOME/project" || exit 1
                for ((i=0; i<100; i++)); do
                    [[ -s $J_DATA && ! -d $J_DATA.lock ]] && break
                    command sleep 0.02
                done
                IFS='|' read -r entry visits hour < "$J_DATA" || exit 2
                [[ $entry == "$PWD" && $visits == 1 ]] || exit 3
            """,
                J_NO_HOOK="",
            )

    def test_installer_links_follow_the_checkout_location(self):
        checkout = self.home / "checkout with spaces"
        for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
            (checkout / name).mkdir(parents=True)
        for name in ("scripts/lib/common.sh", "lib/shell/output.sh"):
            shutil.copy2(ROOT / name, checkout / name)
        # Keep real link/backup logic; avoid package installation and downloads.
        for name in ("packages.sh", "shell.sh"):
            (checkout / "scripts" / name).write_text("exit 0\n")
        shutil.copy2(ROOT / "install.sh", checkout / "install.sh")
        shutil.copy2(ROOT / "bin/jsh", checkout / "bin/jsh")
        (checkout / "dotfiles/.zshrc").write_text("# fixture\n")
        for location in (checkout, self.home / "moved checkout"):
            if location != checkout:
                checkout.rename(location)
            result = subprocess.run(
                ["/bin/bash", str(location / "install.sh")],
                env=self.env,
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((self.home / ".jsh").readlink(), location)
            for link, source in ((".zshrc", "dotfiles/.zshrc"), (".local/bin/jsh", "bin/jsh")):
                self.assertEqual((self.home / link).readlink(), location / source)
            result = subprocess.run(
                [str(self.home / ".local/bin/jsh"), "--help"],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Usage: jsh", result.stdout)

    def installer_scope_fixture(self):
        checkout = self.home / "checkout"
        for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
            (checkout / name).mkdir(parents=True)
        for name in ("scripts/lib/common.sh", "lib/shell/output.sh", "install.sh"):
            shutil.copy2(ROOT / name, checkout / name)
        (checkout / "scripts/packages.sh").write_text("printf 'BREW_UPDATE\\n'\n")
        (checkout / "scripts/shell.sh").write_text("exit 0\n")
        return checkout

    def test_installer_reports_scope_before_package_work(self):
        checkout = self.installer_scope_fixture()
        (self.home / ".jsh").symlink_to(checkout)
        env = self.env | {"JSH_PLATFORM": "darwin"}
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--update"], env=env,
            cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"=   :-=-:.*Update.*-:")
        self.assertIn("› core", result.stdout)
        self.assertNotIn("› OS:", result.stdout)
        self.assertNotIn("› Module:", result.stdout)
        self.assertNotIn("Scope:", result.stdout)
        self.assertLess(result.stdout.index("Update"), result.stdout.index("BREW_UPDATE"))

    def test_installer_shows_progress_and_components_when_current(self):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/packages.sh").write_text("sleep 0.5\n")
        (self.home / ".jsh").symlink_to(checkout)
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", str(checkout / "install.sh"), "tools"],
            env=self.env, cwd=self.home, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0, output)
        display = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", output.decode(errors="replace"))
        for component in ("core", "shell", "links", "tools"):
            self.assertIn(f"› {component}", display)
            self.assertIn(f"\x1b[36m›\x1b[0m \x1b[36m{component}\x1b[0m".encode(), output)
        self.assertIn("Starting package checks", display)
        self.assertIn("Everything is current", display)

    def test_installer_scope_includes_distinct_desktop(self):
        checkout = self.installer_scope_fixture()
        env = self.env | {"JSH_PLATFORM": "debian", "JSH_DESKTOP": "xfce"}
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--dry-run", "core"], env=env,
            cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"=   :-=-:.*Preview.*-:")
        self.assertIn("› core", result.stdout)
        self.assertNotIn("› OS:", result.stdout)
        self.assertNotIn("› Desktop:", result.stdout)
        self.assertNotIn("Scope:", result.stdout)

    def test_monitored_update_colors_package_heading(self):
        checkout = self.installer_scope_fixture()
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--update", "core"],
            env=self.env | {"JSH_PROGRESS_FILE": str(self.home / "progress")},
            cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("\x1b[36m›\x1b[0m \x1b[36mpackages\x1b[0m", result.stdout)

    def test_installer_rejects_removed_scope_option_before_changes(self):
        checkout = self.installer_scope_fixture()
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--minimal"],
            env=self.env, cwd=self.home,
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("unknown option", result.stderr)
        self.assertFalse((self.home / ".jsh").exists())

    def test_monitored_child_leaves_handoff_to_monitor(self):
        checkout = self.installer_scope_fixture()
        result = subprocess.run(
            ["bash", str(checkout / "install.sh")],
            env=self.env | {"JSH_PROGRESS_FILE": str(self.home / "progress")},
            cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Ready", result.stdout)
        self.assertNotIn("Opening the jsh runtime", result.stdout)

    def test_installer_numbers_bootstrap_and_selected_groups(self):
        checkout = self.installer_scope_fixture()
        progress = self.home / "progress"
        for group in ("git", "tools"):
            (checkout / f"scripts/{group}.sh").write_text(
                'cat "$JSH_PROGRESS_FILE" >> "$HOME/steps"\n')
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "core", "git", "tools"],
            env=self.env | {"JSH_PROGRESS_FILE": str(progress)},
            cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / "steps").read_text(),
                         "[4/5] git  Starting git\n[5/5] tools  Starting tools\n")

    def test_installer_ignores_inherited_progress_path_on_a_terminal(self):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/packages.sh").write_text("sleep 0.5\n")
        (self.home / ".jsh").symlink_to(checkout)
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", str(checkout / "install.sh"), "tools"],
            env=self.env | {"JSH_PROGRESS_FILE": str(self.home / "stale")},
            cwd=self.home, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0, output)
        self.assertIn("⠋", output.decode(errors="replace"))
        self.assertFalse((self.home / "stale").exists())

    def test_installer_reloads_the_existing_runtime_without_nesting(self):
        checkout = self.installer_scope_fixture()
        launcher = checkout / "bin/jsh"
        launcher.write_text('#!/bin/sh\ntouch "$HOME/nested-runtime"\n')
        launcher.chmod(0o755)
        for rc in (".bashrc.local", ".jshrc"):
            (self.home / rc).write_text('JSH_TEST_LOADS=$((${JSH_TEST_LOADS:-0} + 1))\n')
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_terminal(
                    shell,
                    f'''before=$$
bash {shlex.quote(str(checkout / "install.sh"))} core
printf '\\nRELOAD_RESULT:%s:%s\\n' "$([[ $$ == "$before" ]] && printf same)" "$JSH_TEST_LOADS"
''',
                    JSH_LOAD_CONFIG="1",
                )
                self.assertIn("RELOAD_RESULT:same:2", output)
                self.assertIn("Reloading the jsh runtime...", output)
                self.assertFalse((self.home / "nested-runtime").exists(), output)

    def test_installer_opens_runtime_when_no_runtime_is_active(self):
        checkout = self.installer_scope_fixture()
        launcher = checkout / "bin/jsh"
        launcher.write_text('#!/bin/sh\ntouch "$HOME/opened-runtime"\n')
        launcher.chmod(0o755)
        output = self.run_terminal(
            "/bin/bash", f'bash {shlex.quote(str(checkout / "install.sh"))} core',
            JSH_RUNTIME_DIR="", JSH_LOAD_CONFIG="0",
        )
        self.assertIn("Opening the jsh runtime...", output)
        self.assertTrue((self.home / "opened-runtime").exists())

    def test_installer_preview_and_failure_do_not_request_reload(self):
        checkout = self.installer_scope_fixture()
        for args in (("--dry-run", "core"), ("git",)):
            with self.subTest(args=args):
                (checkout / "scripts/git.sh").write_text("exit 7\n")
                result = subprocess.run(
                    ["bash", str(checkout / "install.sh"), *args],
                    env=self.env | {"JSH_RELOAD_PID": "12345"}, cwd=self.home,
                    capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, 0 if args[0] == "--dry-run" else 1,
                                 result.stdout + result.stderr)
                self.assertFalse((self.home / "runtime/reload-12345").exists())

    def test_installer_offers_reload_for_runtime_without_reload_hook(self):
        checkout = self.installer_scope_fixture()
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "core"],
            env=self.env, cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Run "jsh reload" to refresh the current runtime', result.stdout)

    def test_installer_activity_identifies_the_check_in_progress(self):
        progress = self.home / "progress"
        result = subprocess.run(
            ["bash", "-c", '. "$JSH_ROOT/scripts/lib/common.sh"; '
             'JSH_STEP="[11/25] tools "; jsh::activity "Checking Syncthing settings"'],
            env=self.env | {"JSH_PROGRESS_FILE": str(progress)},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(progress.read_text(), "[11/25] tools  Checking Syncthing settings\n")

    def test_package_checks_identify_the_package_manager(self):
        progress = self.home / "progress"
        progress.write_text("")
        self.tool("brew", '''case "$1" in
  list) if [ "$3" = -1 ]; then cat "$JSH_PROGRESS_FILE" > "$HOME/brew-progress"; fi ;;
esac''')
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/packages.sh"), "--dry-run", "core"],
            env=self.env | {"JSH_PLATFORM": "darwin", "JSH_PROGRESS_FILE": str(progress),
                            "JSH_STEP": "[bootstrap] core "},
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Checking Homebrew formulae", (self.home / "brew-progress").read_text())

    def test_link_check_reports_its_destination(self):
        progress = self.home / "progress"
        progress.write_text("")
        result = subprocess.run(
            ["bash", "-c", '. "$JSH_ROOT/scripts/lib/common.sh"; '
             'jsh::link "$HOME/source" "$HOME/.zshrc"'],
            env=self.env | {"JSH_DRY_RUN": "1", "JSH_PROGRESS_FILE": str(progress),
                            "JSH_STEP": "[bootstrap] links "},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Checking link ~/.zshrc", progress.read_text())

    def test_installer_summarizes_changes_and_failed_groups(self):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/git.sh").write_text("exit 0\n")
        (checkout / "scripts/ghostty.sh").write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\njsh::changed "example"\njsh::notice "Restart app"\n'
        )
        (checkout / "scripts/kube.sh").write_text("exit 1\n")
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "git", "ghostty", "kube", "core", "shell"],
            env=self.env, cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        output = result.stdout + result.stderr
        self.assertIn("kube failed", output)
        self.assertIn("Finished with errors", output)
        self.assertIn("1 changed", output)
        self.assertIn("1 failed", output)
        self.assertEqual(output.count("Restart app"), 1, output)
        self.assertIn("Action needed", output)
        self.assertNotIn("completed (bootstrap)", output)

    def test_installer_preview_labels_changes_without_modifying_home(self):
        checkout = self.installer_scope_fixture()
        (checkout / "dotfiles/.zshrc").write_text("fixture\n")
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--dry-run"],
            env=self.env, cwd=self.home,
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("would link", result.stdout)
        self.assertIn("~/.zshrc", result.stdout)
        self.assertIn("Preview complete", result.stdout)
        self.assertIn("No settings changed", result.stdout)
        self.assertFalse((self.home / ".zshrc").exists())

    def test_monitored_installer_keeps_task_output_out_of_install_and_update(self):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/packages.sh").write_text('''
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::task "Installing packages" bash -c 'echo raw-package-output; sleep 0.4'
jsh::emit added jq package
''')
        (checkout / "scripts/shell.sh").write_text('''
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::task "Updating plugins" bash -c 'echo raw-update-output; sleep 0.4'
''')
        (checkout / "scripts/git.sh").write_text('''
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::activity "Checking Git settings"
sleep 0.3
jsh::task "Configuring Git" bash -c 'echo raw-config-output; sleep 0.4'
sleep 0.3
jsh::changed "Git settings"
''')
        for args in ("git", "--update git"):
            with self.subTest(args=args):
                master, slave = pty.openpty()
                code = f'''source "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/monitor"
mkdir -p "$JSH_TMP"
export JSH_PROGRESS_FILE="$JSH_TMP/progress"
jsh::monitor bash {shlex.quote(str(checkout / "install.sh"))} {args}
'''
                process = subprocess.Popen(
                    ["bash", "-c", code], env=self.env, stdin=subprocess.DEVNULL,
                    stdout=slave, stderr=slave,
                )
                os.close(slave)
                output = bytearray()
                while True:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                os.close(master)
                self.assertEqual(process.wait(timeout=10), 0, output)
                self.assertNotIn(b"raw-package-output", output)
                self.assertNotIn(b"raw-update-output", output)
                self.assertNotIn(b"raw-config-output", output)
                self.assertIn(b"\x1b[36mcore\x1b[0m", output)
                self.assertIn(b"\x1b[36mshell\x1b[0m", output)
                self.assertIn(b"\x1b[36mgit\x1b[0m", output)
                self.assertIn(b"Installing packages...", output)
                self.assertIn(b"Updating plugins...", output)
                self.assertIn(b"Checking Git settings...", output.rsplit(b"Configuring Git...", 1)[-1])
                self.assertIn(b"Ready", output)

    def test_installer_failure_keeps_diagnostics_and_continues(self):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/git.sh").write_text('''
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::task "Updating Git" bash -c 'echo useful-error; exit 7' || exit $?
''')
        (checkout / "scripts/ghostty.sh").write_text('''
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::changed "Ghostty settings"
''')
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--update", "git", "ghostty"],
            env=self.env, cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("useful-error", result.stderr)
        self.assertIn("Log:", result.stderr)
        self.assertIn("Ghostty settings", result.stdout)
        self.assertIn("Finished with errors", result.stdout)
        self.assertTrue(any(b"useful-error" in path.read_bytes() for path in
                            (self.home / ".local/state/jsh/logs").iterdir()))

    def test_installer_reports_bootstrap_failures(self):
        for script in ("packages", "shell"):
            with self.subTest(script=script):
                checkout = self.home / script
                for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
                    (checkout / name).mkdir(parents=True)
                for name in ("scripts/lib/common.sh", "lib/shell/output.sh", "install.sh"):
                    shutil.copy2(ROOT / name, checkout / name)
                (checkout / "scripts/packages.sh").write_text("exit 3\n" if script == "packages" else "exit 0\n")
                (checkout / "scripts/shell.sh").write_text("exit 3\n" if script == "shell" else "exit 0\n")
                result = subprocess.run(
                    ["bash", str(checkout / "install.sh"), "git"],
                    env=self.env | {"HOME": str(checkout)}, cwd=checkout,
                    capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                name = "core" if script == "packages" else "shell"
                self.assertIn(f"{name} bootstrap failed (3)", result.stderr)

    def test_git_repository_updates_suppress_noop_messages(self):
        checkout = self.home / "checkout"
        for name in ("scripts/lib", "scripts/skills", "lib/shell"):
            (checkout / name).mkdir(parents=True)
        for name in ("scripts/lib/common.sh", "lib/shell/output.sh", "scripts/shell.sh", "scripts/skills.sh"):
            shutil.copy2(ROOT / name, checkout / name)
        (checkout / "scripts/skills/repos.tsv").write_text("example\thttps://example.invalid/example.git\n")
        (checkout / "scripts/skills/links.tsv").write_text("")
        for name in ("fzf", "fzf-tab", "zsh-completions", "zsh-autosuggestions", "zsh-syntax-highlighting", "skills/example"):
            (self.home / "vendor" / name / ".git").mkdir(parents=True)
        self.tool("git", '''case " $* " in
  *" pull "*) printf '%s\\n' "$*" >> "$HOME/git-calls" ;;
  *" rev-parse "*) printf 'unchanged\\n' ;;
esac''')
        for script in ("shell", "skills"):
            result = subprocess.run(
                ["bash", str(checkout / "scripts" / f"{script}.sh"), "--update"],
                env=self.env | {"JSH_ROOT": str(checkout)}, cwd=self.home,
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            expected = "shell plugin fzf: up to date" if script == "shell" else "skill repository example: up to date"
            self.assertIn(expected, result.stdout)
        calls = (self.home / "git-calls").read_text().splitlines()
        self.assertEqual(len(calls), 6)
        self.assertTrue(all("--quiet" in call for call in calls), calls)

    def test_git_get_uses_matching_profile_key(self):
        profiles = self.home / "profiles.json"
        profiles.write_text('{"profiles": {"work": {"user": "skulltrail", "ssh_key": "key with space"}}}')
        self.tool("git", '''printf '%s|%s\\n' "$GIT_SSH_COMMAND" "$*" >> "$HOME/git-calls"
case "$*" in
  *git@github.com:skulltrail/skulltrail.git*) exit 0 ;;
  *) exit 1 ;;
esac''')
        result = subprocess.run(
            [str(ROOT / "bin/git"), "get", "skulltrail/skulltrail"],
            env=self.env | {"JSH_GIT_PROFILES": str(profiles)}, cwd=self.home,
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.home / "git-calls").read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all("ssh -F /dev/null -i " in call and "key\\ with\\ space" in call and "IdentitiesOnly=yes" in call for call in calls), calls)
        self.assertIn("clone -c core.sshCommand=", calls[1])
        self.assertTrue(all("git@github.com:skulltrail/skulltrail.git" in call for call in calls))

    def test_git_get_without_matching_profile_uses_https(self):
        self.tool("git", '''printf '%s\\n' "$*" >> "$HOME/git-calls"''')
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "bin/git"), "get", "other/project"],
            env=self.env | {"JSH_GIT_PROFILES": str(self.home / "missing.json")}, cwd=self.home,
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.home / "git-calls").read_text().splitlines()
        self.assertTrue(all("https://github.com/other/project.git" in call for call in calls), calls)
        self.assertNotIn("core.sshCommand", calls[-1])

    def test_git_profiles_lists_and_marks_matching_identity(self):
        profiles = self.home / "profiles.json"
        profiles.write_text('{"profiles":{"anon":{"name":"Anon","email":"anon@example.org","user":"skulltrail"},"work":{"name":"Work","email":"work@example.org","user":"work"}}}')
        subprocess.run(["git", "init", "-q", str(self.home / "repo")], env=self.env, check=True)
        repo = self.home / "repo"
        subprocess.run(["git", "config", "user.email", "anon@example.org"], env=self.env, cwd=repo, check=True)
        def listing():
            return subprocess.run([str(ROOT / "bin/git"), "profiles"], env=self.env | {"JSH_GIT_PROFILES": str(profiles)}, cwd=repo, capture_output=True, text=True)
        result = listing()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"(?m)^\*\s+anon\s+")
        self.assertRegex(result.stdout, r"(?m)^\s+work\s+")
        subprocess.run(["git", "config", "user.email", "unmatched@example.org"], env=self.env, cwd=repo, check=True)
        self.assertNotIn("*", listing().stdout)

    def test_gh_status_uses_selected_profile(self):
        zsh, jq = shutil.which("zsh"), shutil.which("jq")
        if not zsh or not jq:
            self.skipTest("zsh and jq required")
        profiles = self.home / "profiles.json"
        profiles.write_text('{"profiles":{"anon":{"email":"anon@example.org","user":"skulltrail"}}}')
        self.tool("git", 'case "$1" in rev-parse) exit 0;; config) echo anon@example.org;; esac')
        self.tool("gh", 'if [ "$1" = auth ] && [ "$2" = token ]; then printf token-%s "$6"; else printf "%s:%s\\n" "${GH_TOKEN-unset}" "$*"; fi')
        self.tool("jq", f'exec "{jq}" "$@"')
        rc = (ROOT / "dotfiles/.zshrc").read_text()
        function = rc[rc.index("gh() {\n"):rc.index("\n# Interactive shell start:")]
        script = self.home / "function.zsh"
        script.write_text(function)
        def call(args):
            return subprocess.run([zsh, "-f", "-c", f'source "$1"; shift; gh "$@"', "test", str(script), *args], env=self.env | {"JSH_GIT_PROFILES": str(profiles)}, capture_output=True, text=True)
        self.assertEqual(call(["auth", "status"]).stdout, "token-skulltrail:auth status\n")
        self.assertEqual(call(["auth", "login"]).stdout, "unset:auth login\n")
        self.assertEqual(call(["workflow", "list"]).stdout, "token-skulltrail:workflow list\n")

    def test_git_profile_completion_reads_profiles_without_creating_them(self):
        profiles = self.home / "profiles.json"
        profiles.write_text(
            '{"profiles": {"work": {"name": "Work", "email": "work@example.org"},'
            ' "personal": {"name": "Me", "email": "you@example.com"}}}'
        )
        env = self.env | {"JSH_GIT_PROFILES": str(profiles)}
        result = subprocess.run(
            [str(ROOT / "bin/git"), "__complete", "profile"],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "work\n", ""))
        missing = self.home / "missing/profiles.json"
        for kind, path in (("profile", missing), ("other", profiles)):
            result = subprocess.run(
                [str(ROOT / "bin/git"), "__complete", kind],
                env=self.env | {"JSH_GIT_PROFILES": str(path)},
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertFalse(missing.parent.exists())

    def test_bash_completions_extend_native_git_and_complete_project_names(self):
        (self.home / "Projects/alpha").mkdir(parents=True)
        profiles = self.home / "profiles.json"
        profiles.write_text('{"profiles": {"work": {"name": "Work", "email": "work@example.org"}}}')
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    _git() { COMPREPLY=(create-native); }
                    COMP_WORDS=(git cr); COMP_CWORD=1
                    _jsh_git_complete
                    [[ " ${COMPREPLY[*]} " == *' create '* && " ${COMPREPLY[*]} " == *' create-native '* ]] || exit 1
                    COMP_WORDS=(j al)
                    _jsh_jump_complete
                    [[ " ${COMPREPLY[*]} " == *' alpha '* ]] || exit 2
                    _git() { touch "$HOME/native-$BASH_VERSION"; COMPREPLY=(native); }
                    COMP_WORDS=(git profile w); COMP_CWORD=2; _jsh_git_complete
                    [[ "${COMPREPLY[*]}" == 'work ' ]] || exit 3
                    COMP_WORDS=(git profile --l); COMP_CWORD=2; _jsh_git_complete
                    [[ "${COMPREPLY[*]}" == '--list ' ]] || exit 4
                    COMP_WORDS=(git load --f); COMP_CWORD=2; _jsh_git_complete
                    [[ "${COMPREPLY[*]}" == '--force ' ]] || exit 5
                    COMP_WORDS=(git create app w); COMP_CWORD=3; _jsh_git_complete
                    [[ "${COMPREPLY[*]}" == 'work ' ]] || exit 6
                    COMP_WORDS=(git create w); COMP_CWORD=2; _jsh_git_complete
                    (( ${#COMPREPLY[@]} == 0 )) || exit 7
                    COMP_WORDS=(git handoff --d); COMP_CWORD=2; _jsh_git_complete
                    [[ "${COMPREPLY[*]}" == '--dry-run ' ]] || exit 8
                    COMP_WORDS=(git amend -); COMP_CWORD=2; _jsh_git_complete
                    [[ $(printf '%s|' "${COMPREPLY[@]}") == '-x |-t |-h |--help |' ]] || exit 9
                    COMP_WORDS=(git save --h); COMP_CWORD=2; _jsh_git_complete
                    [[ "${COMPREPLY[*]}" == '--help ' ]] || exit 10
                    [[ ! -e $HOME/native-$BASH_VERSION ]] || exit 11
                    COMP_WORDS=(git status s); COMP_CWORD=2; _jsh_git_complete
                    [[ ${COMPREPLY[*]} == native && -e $HOME/native-$BASH_VERSION ]] || exit 12
                """,
                    JSH_GIT_PROFILES=str(profiles),
                )

    def test_zsh_completes_project_jumps(self):
        for shell in SHELLS:
            if "zsh" not in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    [[ $_comps[j] == _jsh_jump ]] || exit 1
                    [[ $_comps[p] == _jsh_jump ]] || exit 2
                """,
                )

    def test_zsh_lists_kube_contexts_and_git_profiles(self):
        self.tool("kubectl", "printf '%s\\n' dev prod")
        profiles = self.home / "profiles.json"
        profiles.write_text('{"profiles": {"work": {"name": "Work", "email": "work@example.org"}}}')
        for shell in SHELLS:
            if "zsh" not in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                output = self.list_choices(shell, "kubectx ")
                self.assertIn("prod", output)
                for bogus in ("-J", "-default-"):
                    self.assertNotIn(bogus, output)
                output = self.list_choices(shell, "git profile ", JSH_GIT_PROFILES=str(profiles))
                self.assertIn("work", output)

    def test_kubecolor_passes_completion_requests_through(self):
        self.tool("kubectl", 'printf "%s\\n" "$@"; printf ":4\\n"')
        result = subprocess.run(
            [str(ROOT / "bin/kubecolor"), "__complete", "get", ""],
            env=self.env | {"KUBECOLOR_FORCE_COLORS": "always"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertEqual(result.stdout, "__complete\nget\n\n:4\n")

    def test_kubecolor_reuses_kubectl_completion(self):
        self.tool(
            "kubectl",
            """case "$*" in
  "completion bash") echo '__start_kubectl() { :; }; complete -o default -F __start_kubectl kubectl' ;;
  "completion zsh") echo '_kubectl() { :; }; compdef _kubectl kubectl' ;;
esac""",
        )
        self.tool("task", "[ \"$*\" != '--completion bash' ] || echo '_task_fixture() { :; }; complete -F _task_fixture task'")
        for plugin in ("fzf", "fzf-tab", "zsh-autosuggestions", "zsh-completions", "zsh-syntax-highlighting"):
            (self.home / "vendor" / plugin).mkdir()
        self.each_shell(
            """
            if [[ -n ${ZSH_VERSION:-} ]]; then
                [[ $_comps[kubecolor] == _kubectl ]] || exit 1
            else
                [[ $(complete -p kubecolor) == *'-F __start_kubectl'* ]] || exit 2
                [[ $(complete -p task) == *'-F _task_fixture'* ]] || exit 3
            fi
        """,
            JSH_LOAD_CONFIG="1",
        )

    def test_bash_completes_through_aliases(self):
        self.tool(
            "kubectl",
            """case "$*" in
  "completion bash") echo '__start_kubectl() { COMPREPLY=("${COMP_WORDS[*]}|${COMP_CWORD}|${COMP_LINE}|${COMP_POINT}|$3"); }; complete -o default -F __start_kubectl kubectl' ;;
  *get-contexts*) printf '%s\\n' dev prod ;;
esac""",
        )
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    PATH=$HOME/tools:$PATH
                    [[ $(complete -p kg) == *_jsh_alias_complete* ]] || exit 1
                    [[ $(complete -p kx) == *_jsh_alias_complete* ]] || exit 2
                    [[ $(complete -p kubectl) == *__start_kubectl* ]] || exit 3
                    COMP_WORDS=(kg po); COMP_CWORD=1; COMP_LINE='kg po'; COMP_POINT=5
                    _jsh_alias_complete kg po kg
                    [[ ${COMPREPLY[0]} == 'kubectl get po|2|kubectl get po|14|get' ]] || exit 4
                    [[ ${COMP_WORDS[*]} == 'kg po' && $COMP_CWORD == 1 ]] || exit 5
                    COMP_WORDS=(kx p); COMP_CWORD=1; COMP_LINE='kx p'; COMP_POINT=4
                    _jsh_alias_complete kx p kx
                    [[ ${COMPREPLY[*]} == prod ]] || exit 6
                    alias zzfixture=zzmissing
                    source "$JSH/lib/shell/completion.sh"
                    ! complete -p zzfixture 2>/dev/null || exit 7
                    [[ $(complete -p | grep -c ' kg$') == 1 ]] || exit 8
                    [[ $(complete -p kn) == *_jsh_alias_complete* && $(complete -p kn) != *'-o default'* ]] || exit 9
                    [[ $(complete -p kx) == *'-o default'* ]] || exit 10
                """,
                    JSH_LOAD_CONFIG="1",
                )

    def test_kube_switchers_complete_contexts_and_namespaces(self):
        # The rc puts Homebrew's real kubectl ahead of the stub, so the shell code restores PATH.
        self.tool(
            "kubectl",
            """case "$*" in
  *get-contexts*) printf '%s\\n' dev prod arn:aws:eks:us-east-1:1:cluster/x '$(touch $HOME/pwned)' ;;
  *namespaces*) printf '%s\\n' default kube-system ;;
esac""",
        )
        self.each_shell(
            """
            PATH=$HOME/tools:$PATH
            if [[ -n ${ZSH_VERSION:-} ]]; then
                [[ $_comps[kubectx] == _jsh_kubectx ]] || exit 1
                [[ $_comps[kubens] == _jsh_kubens ]] || exit 2
                [[ $(_jsh_kube_contexts) == *prod* ]] || exit 3
                [[ $(_jsh_kube_namespaces) == *kube-system* ]] || exit 4
            else
                [[ $(complete -p kubectx) == *'-o default'* ]] || exit 1
                COMP_WORDS=(kubectx p); COMP_CWORD=1; _jsh_kubectx_complete
                [[ ${COMPREPLY[*]} == prod ]] || exit 2
                COMP_WORDS=(kubectx -d d); COMP_CWORD=2; _jsh_kubectx_complete
                [[ ${COMPREPLY[*]} == dev ]] || exit 3
                COMP_WORDS=(kubectx dev ''); COMP_CWORD=2; _jsh_kubectx_complete
                (( ${#COMPREPLY[@]} == 0 )) || exit 4
                COMP_WORDS=(kubectx --add ''); COMP_CWORD=2; _jsh_kubectx_complete
                (( ${#COMPREPLY[@]} == 0 )) || exit 5
                COMP_WORDS=(kubens kube); COMP_CWORD=1; _jsh_kubens_complete
                [[ ${COMPREPLY[*]} == kube-system ]] || exit 6
                COMP_WORDS=(kubens a ''); COMP_CWORD=2; _jsh_kubens_complete
                (( ${#COMPREPLY[@]} == 0 )) || exit 7
                COMP_WORDS=(kubectx arn : aws); COMP_CWORD=3; COMP_LINE='kubectx arn:aws'; COMP_POINT=15
                _jsh_kubectx_complete
                [[ ${#COMPREPLY[@]} == 1 && ${COMPREPLY[0]} == aws:eks:us-east-1:1:cluster/x ]] || exit 8
                COMP_WORDS=(kubectx -d arn : aws); COMP_CWORD=4; COMP_LINE='kubectx -d arn:aws'; COMP_POINT=18
                _jsh_kubectx_complete
                [[ ${#COMPREPLY[@]} == 1 && ${COMPREPLY[0]} == aws:eks:us-east-1:1:cluster/x ]] || exit 11
                COMP_WORDS=(kubectx arn :); COMP_CWORD=2; COMP_LINE='kubectx arn:'; COMP_POINT=12
                _jsh_kubectx_complete
                [[ ${#COMPREPLY[@]} == 1 && ${COMPREPLY[0]} == aws:eks:us-east-1:1:cluster/x ]] || exit 12
                COMP_WORDS=(kubectx '$(t'); COMP_CWORD=1; _jsh_kubectx_complete
                [[ ${#COMPREPLY[@]} == 1 && ${COMPREPLY[0]} == '$(touch' ]] || exit 13
                [[ ! -e $HOME/pwned ]] || exit 14
                command cp -f "$HOME/tools/kubectl" "$HOME/kubectl.good"
                printf '#!/bin/sh\\necho oops >&2\\nexit 1\\n' > "$HOME/tools/kubectl"
                COMP_WORDS=(kubectx ''); COMP_CWORD=1; _jsh_kubectx_complete
                [[ ${COMPREPLY[*]} == '- -a --add -c --current -d --delete -u --unset -h --help' ]] || exit 9
                COMP_WORDS=(kubens ''); COMP_CWORD=1; _jsh_kubens_complete
                [[ ${COMPREPLY[*]} == '- -c --current -h --help' ]] || exit 10
                command mv -f "$HOME/kubectl.good" "$HOME/tools/kubectl"
            fi
        """
        )

    def test_kubens_reports_unknown_namespace_for_equals_argument(self):
        self.tool(
            "kubectl",
            """case "$*" in
  *current-context*) printf '%s\\n' dev ;;
  *"get namespaces"*) printf '%s\\n' default ;;
esac""",
        )
        result = subprocess.run(
            [str(ROOT / "bin/kubens"), "a=b"],
            env=self.env | {"KUBECTX_IGNORE_FZF": "1"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('no namespace exists with name "a=b"', result.stderr)
        self.assertNotIn("command not found", result.stderr)

    def test_nukem_completes_only_terminating_namespaces(self):
        stub = """echo "$*" >> "$HOME/calls"
case "$*" in
  *get-contexts*) printf '%s\\n' dev prod ;;
  *Terminating*) echo stuck ;;
esac"""
        self.tool("kubectl", stub)
        hook = subprocess.run(
            [str(ROOT / "bin/nukem"), "__complete", "namespace", "prod"],
            env=self.env | {"NUKEM_TIMEOUT": "2"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual((hook.returncode, hook.stdout, hook.stderr), (0, "stuck\n", ""))
        self.assertIn("--context prod", (self.home / "calls").read_text())
        self.tool("kubectl", "echo oops >&2; exit 1")
        hook = subprocess.run(
            [str(ROOT / "bin/nukem"), "__complete", "namespace"],
            env=self.env | {"NUKEM_TIMEOUT": "2"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual((hook.returncode, hook.stdout, hook.stderr), (0, "", ""))
        self.tool("kubectl", stub)
        (self.home / "calls").unlink()
        self.each_shell(
            """
            PATH=$HOME/tools:$PATH
            if [[ -n ${ZSH_VERSION:-} ]]; then
                [[ $_comps[nukem] == _jsh_nukem ]] || exit 1
            else
                COMP_WORDS=(nukem -c d); COMP_CWORD=2; _jsh_nukem_complete
                [[ ${COMPREPLY[*]} == dev ]] || exit 1
                COMP_WORDS=(nukem -c prod s); COMP_CWORD=3; _jsh_nukem_complete
                [[ ${COMPREPLY[*]} == stuck ]] || exit 2
                grep -q -- '--context prod' "$HOME/calls" || exit 3
                COMP_WORDS=(nukem stuck s); COMP_CWORD=2; _jsh_nukem_complete
                (( ${#COMPREPLY[@]} == 0 )) || exit 4
                COMP_WORDS=(nukem --d); COMP_CWORD=1; _jsh_nukem_complete
                [[ ${COMPREPLY[*]} == --dry-run ]] || exit 5
            fi
        """
        )

    def test_bash_completes_jssh_hosts_and_proxy_presets(self):
        (self.home / ".ssh").mkdir()
        (self.home / ".ssh/config").write_text("Host alpha beta *.wild\n")
        self.tool("cuprobe", "true")
        self.each_shell(
            """
            if [[ -n ${ZSH_VERSION:-} ]]; then
                [[ $_comps[jssh] == _jsh_jssh ]] || exit 1
                [[ $_comps[proxy] == _jsh_proxy ]] || exit 2
            else
                _command_offset() { COMPREPLY=(offset-$1); }
                COMP_WORDS=(jssh a); COMP_CWORD=1; _jsh_jssh_complete
                [[ ${COMPREPLY[*]} == alpha ]] || exit 1
                COMP_WORDS=(jssh --c); COMP_CWORD=1; _jsh_jssh_complete
                [[ ${COMPREPLY[*]} == --check ]] || exit 2
                COMP_WORDS=(proxy -p t); COMP_CWORD=2; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == tor ]] || exit 3
                COMP_WORDS=(proxy -p tor curl ''); COMP_CWORD=4; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == offset-3 ]] || exit 4
                COMP_WORDS=(proxy cu); COMP_CWORD=1; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == offset-1 ]] || exit 5
                COMP_WORDS=(proxy -p tor cu); COMP_CWORD=3; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == offset-3 ]] || exit 6
                COMP_WORDS=(proxy -u ''); COMP_CWORD=2; _jsh_proxy_complete
                (( ${#COMPREPLY[@]} == 0 )) || exit 7
                COMP_WORDS=(proxy -- cu); COMP_CWORD=2; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == offset-2 ]] || exit 8
                unset -f _command_offset
                COMP_WORDS=(proxy cupr); COMP_CWORD=1; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == cuprobe ]] || exit 9
                COMP_WORDS=(proxy -p tor cupr); COMP_CWORD=3; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == cuprobe ]] || exit 10
                COMP_WORDS=(proxy -- cupr); COMP_CWORD=2; _jsh_proxy_complete
                [[ ${COMPREPLY[*]} == cuprobe ]] || exit 11
                COMP_WORDS=(proxy ''); COMP_CWORD=1; _jsh_proxy_complete
                [[ " ${COMPREPLY[*]} " == *" --preset "* && " ${COMPREPLY[*]} " == *" cuprobe "* ]] || exit 12
            fi
        """
        )

    def test_bash_initializes_installed_hooks_once(self):
        for name in ("direnv", "atuin", "zoxide"):
            self.tool(
                name,
                f"""cat <<'HOOK'
{name}_inits=$((${{{name}_inits:-0}} + 1))
_{name}_test_hook() {{ {name}_visits=$((${{{name}_visits:-0}} + 1)); export DIRENV_DIR=loaded; }}
complete -o nosort -F _{name}_test_hook {name}-fixture
PROMPT_COMMAND="${{PROMPT_COMMAND:+${{PROMPT_COMMAND}};}}_{name}_test_hook"
HOOK""",
            )
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    jsh reload; jsh reload
                    false
                    eval "$PROMPT_COMMAND"
                    [[ $direnv_inits == 1 && $atuin_inits == 1 && $zoxide_inits == 1 ]] || exit 1
                    [[ $direnv_visits == 1 && $atuin_visits == 1 && $zoxide_visits == 1 ]] || exit 2
                    [[ ${_JSH_BASH_RENDERED_PROMPT} == *direnv* && ${_JSH_BASH_RENDERED_PROMPT} == *'x 1'* ]] || exit 3
                    [[ $(complete -p direnv-fixture) == *'-F _direnv_test_hook'* ]] || exit 4
                    [[ $(type -t complete) == builtin ]] || exit 5
                """,
                    JSH_LOAD_CONFIG="1",
                )

    def test_bash_ascii_prompt_handles_tiny_terminals_and_escapes_names(self):
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    r"""
                    COLUMNS=1
                    JSH_PROMPT_MODE=ascii
                    _jsh_bash_prompt
                    [[ ${_JSH_BASH_RENDERED_PROMPT} != *…* ]] || exit 1
                    _jsh_bash_prompt_escape 'back\slash'
                    [[ $REPLY == 'back\slash' ]] || exit 2
                    _jsh_bash_prompt_escape $'bad\033name'
                    [[ $REPLY == 'bad?name' ]] || exit 3
                """,
                )

    def test_portable_helpers_keep_validation_and_utf8_url_encoding(self):
        self.each_shell("""
            [[ $(urlencode 'a b%é') == 'a%20b%25%C3%A9' ]] || exit 1
            [[ $(urldecode 'a%20b%25%C3%A9') == 'a b%é' ]] || exit 2
            [[ $(calc 1+2) == 3* ]] || exit 3
            calc '$(touch UNEXPECTED)' >/dev/null 2>&1 && exit 4
            [[ ! -e UNEXPECTED ]] || exit 5
            genpass 0 >/dev/null 2>&1 && exit 6
            proxy+ invalid >/dev/null 2>&1 && exit 7
            proxy+ 'http://localhost:8080' || exit 8
            [[ $HTTP_PROXY == http://localhost:8080 ]] || exit 9
            proxy-
            [[ -z ${HTTP_PROXY+x} ]] || exit 10
        """)

    def test_bash_history_is_available_before_shell_exit(self):
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                runtime = str(self.home / Path(shell).parent.parent.name)
                self.run_terminal(shell, "history -s first-session-entry", JSH_RUNTIME_DIR=runtime)
                self.assertIn("first-session-entry", (Path(runtime) / "bash_history").read_text())
                output = self.run_terminal(
                    shell,
                    """history -s shared-history-entry
command grep -q '^shared-history-entry$' "$HISTFILE" && printf '\\nHISTORY_OK\\n'
""",
                    JSH_RUNTIME_DIR=runtime,
                )
                self.assertIn("\r\nHISTORY_OK\r\n", output)

    def test_rendered_prompts_never_execute_names_and_preserve_status(self):
        repo = self.home / "$(touch PATH_EXECUTED)"
        repo.mkdir()
        branch = "$(touch${IFS}BRANCH_EXECUTED)"
        subprocess.run(
            ["/usr/bin/git", "init", "-b", branch, str(repo)],
            env=self.env,
            capture_output=True,
            check=True,
        )
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_terminal(
                    shell,
                    f"""export VIRTUAL_ENV='$(touch ENV_EXECUTED)'
cd {shlex.quote(str(repo))}
false
printf '\\nSTATUS:%s\\n' "$?"
""",
                    NO_COLOR="",
                    COLUMNS="160",
                )
                self.assertIn("\r\nSTATUS:1\r\n", output)
                self.assertIn(branch, output)
                for directory in (self.home, repo):
                    for name in ("PATH_EXECUTED", "BRANCH_EXECUTED", "ENV_EXECUTED"):
                        self.assertFalse((directory / name).exists(), output)

    def test_bash_ps0_preexec_expansion_survives_prompt_safety(self):
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            version = subprocess.run(
                [
                    shell,
                    "-c",
                    "(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))",
                ]
            )
            if version.returncode:
                continue
            with self.subTest(shell=shell):
                output = self.run_terminal(shell, "true", PS0="$(printf PREEXEC_FIRED)")
                self.assertNotIn("$(printf PREEXEC_FIRED)", output)
                self.assertGreaterEqual(output.count("PREEXEC_FIRED"), 2, output)

    def test_bash_prompt_reports_git_state_and_honors_color_controls(self):
        repo = self.home / "repo"
        repo.mkdir()

        def git(*args):
            subprocess.run(
                ["/usr/bin/git", "-C", str(repo), *args],
                check=True,
                capture_output=True,
                env=self.env,
            )

        git("init", "-b", "main")
        (repo / "tracked").write_text("before\n")
        git("add", ".")
        git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "first")
        (repo / "tracked").write_text("after\n")
        (repo / "staged").touch()
        git("add", "staged")
        (repo / "untracked").touch()
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    cd "$HOME/repo" || exit 1
                    false
                    _jsh_bash_prompt
                    [[ ${_JSH_BASH_RENDERED_PROMPT} == *main* && ${_JSH_BASH_RENDERED_PROMPT} == *'+1'* && ${_JSH_BASH_RENDERED_PROMPT} == *'!1'* && ${_JSH_BASH_RENDERED_PROMPT} == *'?1'* ]] || exit 2
                    [[ ${_JSH_BASH_RENDERED_PROMPT} == *'1'* && ${_JSH_BASH_RENDERED_PROMPT} == *'38;2;0;191;255'* ]] || exit 3
                    export NO_COLOR=''
                    _jsh_bash_prompt
                    [[ ${_JSH_BASH_RENDERED_PROMPT} != *'\\e['* && ${_JSH_BASH_RENDERED_PROMPT} != *$'\\033'* ]] || exit 4
                    unset NO_COLOR
                    JSH_PLAIN_OUTPUT=1
                    _jsh_bash_prompt
                    [[ ${_JSH_BASH_RENDERED_PROMPT} != *'\\e['* ]] || exit 5
                """,
                )

    def test_bash_hooks_run_once_and_preserve_failure_status(self):
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    counter=0
                    custom_hook() { seen=$?; counter=$((counter + 1)); return 0; }
                    PROMPT_COMMAND=custom_hook
                    jsh reload
                    jsh reload
                    false
                    eval "$PROMPT_COMMAND"
                    [[ $counter == 1 && $seen == 1 && ${_JSH_BASH_RENDERED_PROMPT} == *'1'* ]] || exit 1
                    if (( BASH_VERSINFO[0] >= 5 )); then
                        PROMPT_COMMAND=(custom_hook 'counter=$((counter + 1))')
                        jsh reload
                        false
                        for hook in "${PROMPT_COMMAND[@]}"; do eval "$hook"; done
                        [[ $counter == 3 && $seen == 1 && ${_JSH_BASH_RENDERED_PROMPT} == *'1'* ]] || exit 2
                    fi
                """,
                )

    def test_bash_reload_preserves_quoted_and_terminated_prompt_hooks(self):
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    PROMPT_COMMAND="printf '%s' ';_jsh_bash_prompt;' > '$HOME/hook-result';"
                    jsh reload; jsh reload
                    eval "$PROMPT_COMMAND"
                    [[ $(command cat "$HOME/hook-result") == ';_jsh_bash_prompt;' ]] || exit 1
                """,
                )

    def test_bash_reload_keeps_one_renderer_when_a_framework_surrounds_hooks(self):
        for shell in SHELLS:
            if "zsh" in Path(shell).name:
                continue
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    """
                    for ((i=0; i<3; i++)); do
                        PROMPT_COMMAND=$'true\\n'"${PROMPT_COMMAND}"$'\\ntrue'
                        jsh reload
                    done
                    false
                    eval "$PROMPT_COMMAND"
                    [[ ${_JSH_BASH_RENDERED_PROMPT} == *'x 1'* ]] || exit 1
                """,
                )

    def test_remote_payload_contains_runnable_shells_and_invalidates_cache(self):
        vendor = self.home / "vendor"
        for relative in (
            "zsh-autosuggestions/LICENSE",
            "zsh-autosuggestions/zsh-autosuggestions.zsh",
            "zsh-completions/LICENSE",
            "zsh-completions/src/_test",
            "zsh-syntax-highlighting/.revision-hash",
            "zsh-syntax-highlighting/.version",
            "zsh-syntax-highlighting/COPYING.md",
            "zsh-syntax-highlighting/zsh-syntax-highlighting.zsh",
            "zsh-syntax-highlighting/highlighters/main/test.zsh",
        ):
            target = vendor / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("# fixture\n")
        source = self.home / "source"
        files = [
            ROOT / "bin/jssh",
            ROOT / "dotfiles/.zshrc",
            ROOT / "dotfiles/.bashrc",
            *(ROOT / "lib/shell").glob("*.sh"),
        ]
        for file in files:
            target = source / file.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)

        def payload():
            result = subprocess.run(
                ["/bin/bash", "-c", '. "$JSH_ROOT/bin/jssh"; _jssh_build_payload'],
                env=self.env
                | {"JSH_ROOT": str(source), "JSSH_CACHE_DIR": str(self.home / "payload-cache")},
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return Path(result.stdout.strip())

        first = payload()
        unpacked = self.home / "unpacked"
        with tarfile.open(first) as archive:
            archive.extractall(unpacked, filter="data")
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.run_shell(
                    shell,
                    "type j >/dev/null && alias l >/dev/null",
                    JSH_ROOT=str(unpacked / "jsh"),
                    JSH_VENDOR=str(unpacked / "jsh/vendor"),
                )
        with (source / "lib/shell/commands.sh").open("a") as file:
            file.write("\n# cache invalidation fixture\n")
        self.assertNotEqual(first, payload())


    def test_installer_runs_global_brew_updates_in_package_step(self):
        checkout = self.installer_scope_fixture()
        shutil.copy2(ROOT / "scripts/packages.sh", checkout / "scripts/packages.sh")
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq is required for Homebrew metadata")
        (self.tools / "jq").symlink_to(jq)
        self.tool("brew", '''case "$1" in
  update) exit 0 ;;
  info) printf '%s\\n' '{"formulae":[{"full_name":"retired-formula","deprecated":true}],"casks":[{"token":"retired-cask","deprecated":true}]}' ;;
  outdated) case "$2" in --formula) echo unrelated-formula ;; --cask) echo chatgpt ;; esac ;;
  upgrade) printf '%s: %s\\n' "$JSH_STEP" "$*" >> "$HOME/actions" ;;
esac''')
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--update", "ghostty"],
            env=self.env | {"JSH_PLATFORM": "darwin"}, cwd=self.home,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.home / "actions").exists(), result.stdout + result.stderr)
        actions = (self.home / "actions").read_text().splitlines()
        self.assertEqual(len(actions), 2, actions)
        self.assertTrue(all(" packages " in line for line in actions), actions)
        self.assertTrue(any("unrelated-formula" in line for line in actions), actions)
        self.assertTrue(any("chatgpt" in line for line in actions), actions)

    def test_brew_update_includes_unlisted_packages_and_removes_deprecated(self):
        if os.uname().sysname == "Darwin":
            self.tool("stat", '''if [ "$1" = -c ] && [ "$2" = %a ]; then
  shift 2
  exec /usr/bin/stat -f %Lp "$@"
fi
exec /usr/bin/stat "$@"''')
        self.tool(
            "brew",
            """case "$1" in
  update) exit 0 ;;
  info) printf '%s\\n' '{"formulae":[{"name":"opencode","full_name":"opencode","deprecated":false,"disabled":false},{"name":"libclc","full_name":"libclc","deprecated":false,"disabled":false},{"name":"gemini-cli","full_name":"gemini-cli","deprecated":true,"disabled":false},{"name":"icu4c@76","full_name":"icu4c@76","deprecated":true,"disabled":false}],"casks":[]}' ;;
  outdated) printf '%s\\n' opencode libclc gemini-cli ;;
  uses) case "$*" in *icu4c@76*) printf '%s\\n' dependent ;; esac ;;
  uninstall) printf '%s\\n' "$*" >> "$HOME/actions" ;;
  upgrade) printf '%s\\n' "$*" >> "$HOME/actions" ;;
esac""",
        )
        config = self.home / "config"
        trust_dir = config / "homebrew"
        trust_dir.mkdir(parents=True)
        trust_dir.chmod(0o775)
        env = self.env | {"JSH_PLATFORM": "linux", "XDG_STATE_HOME": str(self.home / "state"),
                          "XDG_CONFIG_HOME": str(config)}
        preview = subprocess.run(
            ["bash", str(ROOT / "scripts/packages.sh"), "--dry-run", "--update", "ai"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertFalse((self.home / "actions").exists())
        self.assertEqual(trust_dir.stat().st_mode & 0o777, 0o775)
        self.assertIn("gemini-cli", preview.stdout)
        self.assertIn("libclc", preview.stdout)
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/packages.sh"), "--update", "ai"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actions = (self.home / "actions").read_text()
        self.assertIn("uninstall --formula gemini-cli", actions)
        self.assertNotIn("uninstall --formula icu4c@76", actions)
        self.assertIn("Keeping icu4c@76; installed packages depend on it: dependent", result.stdout)
        self.assertNotIn("Keeping icu4c@76", result.stderr)
        self.assertEqual(trust_dir.stat().st_mode & 0o022, 0)
        self.assertIn("libclc", actions)
        self.assertNotIn("gemini-cli", next(line for line in actions.splitlines() if line.startswith("upgrade")))


    def test_task_streams_completed_output_above_progress(self):
        import fcntl
        import re
        import struct
        import termios

        self.tool("progress-mock", r'''printf 'bottle finished\n'
printf 'café 完了\n'
sleep 0.3
printf 'download 10%%\rdownload 90%%\r'
sleep 0.3
printf 'download complete\n'
sleep 0.3
printf 'last output without newline'
''')
        for monitored in (False, True):
            with self.subTest(monitored=monitored):
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                command = r'''source "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/work"
mkdir -p "$JSH_TMP"
'''
                if monitored:
                    command += r'''export JSH_PROGRESS_FILE="$JSH_TMP/progress"
jsh::monitor bash -c 'source "$JSH_ROOT/scripts/lib/common.sh"; JSH_TMP="$HOME/work"; jsh::task "Homebrew upgrade: eslint" progress-mock'
'''
                else:
                    command += 'jsh::task "Homebrew upgrade: eslint" progress-mock\n'
                process = subprocess.Popen(
                    ["bash", "-c", command], env=self.env, stdin=subprocess.DEVNULL,
                    stdout=slave, stderr=slave,
                )
                os.close(slave)
                output = bytearray()
                while True:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output.extend(data)
                os.close(master)
                self.assertEqual(process.wait(timeout=10), 0)
                display = output.decode(errors="replace")
                self.assertEqual(display.count("bottle finished"), 1, display)
                self.assertEqual(display.count("café 完了"), 1, display)
                self.assertNotIn("�", display)
                self.assertEqual(display.count("download complete"), 1, display)
                plain = re.sub(r"\x1b\[[0-9;]*m", "", display)
                self.assertEqual(plain.count("last output without newline\r\n"), 1, display)
                self.assertIn("download 90%", display)
                self.assertRegex(display, r"eslint[^\n]*\n  download 90%")
                self.assertIn("\x1b[36m", display)

    def test_task_labels_no_upgrade_messages(self):
        import re

        self.tool("progress-no-upgrade", r'''printf 'No updates available\nAlready installed\nNothing to upgrade'
if [ "${1:-}" = newline ]; then printf '\n'; fi
''')
        for monitored in (False, True):
            for ending in ("newline", "partial"):
                with self.subTest(monitored=monitored, ending=ending):
                    master, slave = pty.openpty()
                    code = r'''source "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/work"
mkdir -p "$JSH_TMP"
'''
                    task = f'jsh::task "Updating graphify" progress-no-upgrade {ending}'
                    if monitored:
                        code += 'export JSH_PROGRESS_FILE="$JSH_TMP/progress"\n'
                        code += f"jsh::monitor bash -c 'source \"$JSH_ROOT/scripts/lib/common.sh\"; JSH_TMP=\"$HOME/work\"; {task}'\n"
                    else:
                        code += task + "\n"
                    process = subprocess.Popen(
                        ["bash", "-c", code], env=self.env, stdin=subprocess.DEVNULL,
                        stdout=slave, stderr=slave,
                    )
                    os.close(slave)
                    output = bytearray()
                    while True:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)
                    os.close(master)
                    self.assertEqual(process.wait(timeout=10), 0)
                    plain = re.sub(rb"\x1b\[[0-9;]*m", b"", output)
                    self.assertEqual(plain.count(b"Updating graphify:"), 1, output)
                    self.assertIn(b"Updating graphify:\r\n", plain)
                    self.assertIn(b"  No updates available\r\n", plain)
                    self.assertIn(b"  Already installed\r\n", plain)
                    self.assertIn(b"  Nothing to upgrade\r\n", plain)

    def test_rea_update_labels_npm_output(self):
        self.tool("node", "exit 0")
        self.tool("rea", '''case "$1" in
  --version) printf '1.0\\n' ;;
  setup) printf '{"plannedActions":[]}\\n' ;;
esac''')
        self.tool("graphify", "printf 'graphify 1.0\\n'")
        self.tool("jq", "printf '0\\n'")
        self.tool("npm", "printf 'up to date\\n'")
        skill = self.home / ".agents/skills/graphify"
        skill.mkdir(parents=True)
        (skill / ".graphify_version").write_text("1.0")
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/ai/rea.sh")],
            env=self.env | {"JSH_PHASE": "update", "JSH_PROGRESS_FILE": str(self.home / "progress")},
            cwd=self.home, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Updating rea-agents:\n  up to date", result.stderr)

    def test_progress_redraw_does_not_clear_before_each_frame(self):
        for monitored in (False, True):
            with self.subTest(monitored=monitored):
                master, slave = pty.openpty()
                code = r'''. "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/work"
mkdir -p "$JSH_TMP"
'''
                if monitored:
                    code += r'''export JSH_PROGRESS_FILE="$JSH_TMP/progress"
printf 'Checking Homebrew updates\n' > "$JSH_PROGRESS_FILE"
jsh::monitor sleep 0.7
'''
                else:
                    code += 'jsh::task "Checking Homebrew updates" sleep 0.7\n'
                process = subprocess.Popen(
                    ["bash", "-c", code], env=self.env, stdin=subprocess.DEVNULL,
                    stdout=slave, stderr=slave,
                )
                os.close(slave)
                output = bytearray()
                while True:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                os.close(master)
                self.assertEqual(process.wait(timeout=10), 0)
                self.assertGreaterEqual(output.count(b"Checking Homebrew updates"), 3)
                self.assertLessEqual(output.count(b"\r\x1b[J"), 1, output)

    def test_task_progress_wraps_and_colors_without_erasing_completed_items(self):
        import fcntl
        import struct
        import termios

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 36, 0, 0))
        code = r'''
. "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/work"
mkdir -p "$JSH_TMP"
jsh::changed "finished package"
jsh::task "A deliberately long operation label for wrapping" bash -c 'sleep 1'
'''
        process = subprocess.Popen(
            ["bash", "-c", code], env=self.env, stdin=subprocess.DEVNULL,
            stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()
        while True:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0)
        display = output.decode(errors="replace")
        self.assertIn("finished package", display)
        self.assertIn("for wrapping", display)
        self.assertRegex(display, r"operation \x1b\[K\r?\nlabel for wrapping")
        self.assertLess(display.index("finished package"), display.index("A deliberately"))
        self.assertIn("\x1b[36m", display)

    def test_progress_colors_component_and_marks_action_in_progress(self):
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", "-c", '. "$JSH_ROOT/scripts/lib/common.sh"; '
             'JSH_TMP="$HOME"; JSH_STEP="[2/3] fonts "; jsh::task "Installing fonts" sleep 0.3'],
            env=self.env, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0)
        self.assertIn(b"\x1b[36mfonts\x1b[0m\x1b[37m  Installing fonts...", output)

    def test_task_failure_preserves_log_and_sanitizes_terminal_output(self):
        self.tool("progress-fail", r'''printf 'safe\033[2Jtext\n'
sleep 0.2
exit 7
''')
        code = r'''. "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/work"
mkdir -p "$JSH_TMP"
jsh::task "failing task" progress-fail
'''
        for terminal in (False, True):
            with self.subTest(terminal=terminal):
                master, slave = pty.openpty() if terminal else (None, None)
                process = subprocess.Popen(
                    ["bash", "-c", code], env=self.env | {"NO_COLOR": "1"},
                    stdin=subprocess.DEVNULL, stdout=slave if terminal else subprocess.PIPE,
                    stderr=slave if terminal else subprocess.PIPE,
                )
                if terminal:
                    os.close(slave)
                    output = bytearray()
                    while True:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)
                    os.close(master)
                    display = output.decode(errors="replace")
                    self.assertIn("safetext", display)
                    self.assertNotIn("\x1b[2J", display)
                    self.assertNotIn("\x1b[36m", display)
                    status = process.wait(timeout=10)
                else:
                    _, error = process.communicate(timeout=10)
                    display = error.decode(errors="replace")
                    status = process.returncode
                self.assertEqual(status, 7, display)
                self.assertIn("failing task failed (7)", display)
                logs = list((self.home / ".local/state/jsh/logs").iterdir())
                self.assertTrue(any(b"safe\x1b[2Jtext" in path.read_bytes() for path in logs))

    def test_task_clears_progress_and_stops_child_on_interrupt(self):
        import fcntl
        import struct
        import termios

        checkout = self.home / "checkout"
        for name in ("scripts/lib", "lib/shell"):
            (checkout / name).mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/lib/common.sh", checkout / "scripts/lib/common.sh")
        shutil.copy2(ROOT / "lib/shell/output.sh", checkout / "lib/shell/output.sh")
        script = checkout / "scripts/progress.sh"
        script.write_text('''#!/usr/bin/env bash
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::task "test operation" bash -c 'echo $$ > "$HOME/child"; exec sleep 20'
''')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 60, 0, 0))
        process = subprocess.Popen(
            ["bash", str(script)], env=self.env | {"JSH_ROOT": str(checkout)},
            stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()
        deadline = time.monotonic() + 10
        while b"test operation" not in output and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output.extend(os.read(master, 65536))
        self.assertIn(b"test operation", output)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 36, 0, 0))
        deadline = time.monotonic() + 2
        while output.count(b"test operation") < 2 and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output.extend(os.read(master, 65536))
        self.assertGreaterEqual(output.count(b"test operation"), 2, output)
        os.kill(process.pid, signal.SIGTERM)
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 143)
        self.assertTrue(output.endswith(b"\r\x1b[J"), output)
        child = int((self.home / "child").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_progress_clear_accounts_for_terminal_shrink(self):
        import fcntl
        import struct
        import termios

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        code = r'''source "$JSH_ROOT/scripts/lib/common.sh"
stty -echo
jsh::progress_draw 123456789012345678901234567890123456789012345 0 0
IFS= read -r reply
jsh::progress_clear
'''
        process = subprocess.Popen(
            ["bash", "-c", code], env=self.env | {"NO_COLOR": "1"},
            stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()
        while b"0m00s" not in output:
            self.assertTrue(select.select([master], [], [], 5)[0])
            output.extend(os.read(master, 65536))
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 20, 0, 0))
        os.write(master, b"\n")
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0)
        self.assertTrue(output.endswith(b"\x1b[2A\r\x1b[J"), output)


    def test_installer_monitor_keeps_progress_visible_between_child_updates(self):
        import fcntl
        import struct
        import termios

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 60, 0, 0))
        code = r'''
. "$JSH_ROOT/scripts/lib/common.sh"
JSH_TMP="$HOME/work"
mkdir -p "$JSH_TMP"
export JSH_PROGRESS_FILE="$JSH_TMP/progress"
jsh::monitor bash -c 'printf "Reading metadata\\n" > "$JSH_PROGRESS_FILE"; printf "~ zip\\n"; sleep 1.5; printf "~ XFCE desktop\\n"'
'''
        process = subprocess.Popen(["bash", "-c", code], env=self.env, stdin=subprocess.DEVNULL,
                                   stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        while True:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0, output.decode(errors="replace"))
        display = output.decode(errors="replace")
        self.assertIn("⠋", display)
        self.assertIn("⠙", display)
        self.assertIn("\x1b[2m", display)
        self.assertGreaterEqual(display.count("Reading metadata"), 3)
        self.assertLess(display.index("~"), display.index("XFCE desktop"))


    def test_dock_app_names_hide_paths_and_desktop_ids(self):
        result = subprocess.run(
            ["bash", "-c", '. "$JSH_ROOT/scripts/lib/desktop.sh"; '
             'jsh::desktop_names "$1"', "bash",
             "/usr/share/applications/com.mitchellh.ghostty.desktop;"
             "/tmp/com.visualstudio.code.desktop;com.spotify.Client;waterfox;"],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Ghostty, VS Code, Spotify, Waterfox")


if __name__ == "__main__":
    unittest.main()
