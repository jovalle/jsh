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
import sqlite3
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


def copy_group_sources(checkout):
    site = checkout / "ansible/site.yml"
    site.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "ansible/site.yml", site)
    for source in (ROOT / "ansible/roles").glob("*/meta/main.yml"):
        target = checkout / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def write_group_sources(checkout, groups):
    tasks = []
    platform_names = {
        "all": ("MacOSX", "Debian", "EL"),
        "darwin": ("MacOSX",),
        "linux": ("Debian", "EL"),
    }
    conditions = {
        "all": "",
        "darwin": "      when: jsh_platform == 'darwin'\n",
        "linux": "      when: jsh_platform != 'darwin'\n",
    }
    for name, platform, purpose in groups:
        tasks.append(
            f"    - name: {name}\n"
            "      ansible.builtin.include_role:\n"
            f"        name: {name}\n"
            f"        apply: {{tags: [{name}]}}\n"
            f"      tags: [{name}]\n"
            f"{conditions[platform]}"
        )
        meta = checkout / f"ansible/roles/{name}/meta/main.yml"
        meta.parent.mkdir(parents=True, exist_ok=True)
        platforms = "".join(
            f"    - name: {item}\n      versions: [all]\n" for item in platform_names[platform]
        )
        meta.write_text(
            "---\ngalaxy_info:\n"
            f"  description: {purpose}\n"
            f"  platforms:\n{platforms}"
            "dependencies: []\n"
        )
    site = checkout / "ansible/site.yml"
    site.parent.mkdir(parents=True, exist_ok=True)
    site.write_text("---\n- hosts: localhost\n  gather_facts: false\n  tasks:\n" + "".join(tasks))


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
            TMPDIR=str(self.home),
        )
        # Avoid Homebrew discovery leaking installed tools into these isolated shells.
        self.tool("brew", 'printf "HOMEBREW_PREFIX=/nonexistent\\n"')
        for name in ("atuin", "zoxide", "direnv", "fzf", "docker", "kubectl", "task"):
            self.tool(name, "exit 0")

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def mock_installer_playbook(self, checkout):
        (checkout / "scripts/ansible.sh").write_text("exit 0\n")
        playbook = checkout / "local/ansible/venv/bin/ansible-playbook"
        playbook.parent.mkdir(parents=True)
        body = """#!/usr/bin/env bash
set -u
export JSH_OUTPUT=renderer
playbook_args=("__DOLLAR__@")
set --
. "__DOLLAR__JSH_ROOT/scripts/lib/common.sh"
set -- "__DOLLAR__{playbook_args[@]}"
unset playbook_args
tags=
previous=
for argument; do
  if [[ __DOLLAR__previous == --tags ]]; then tags=__DOLLAR__argument; fi
  previous=__DOLLAR__argument
done
old_ifs=__DOLLAR__IFS
IFS=,
set -- __DOLLAR__tags
IFS=__DOLLAR__old_ifs
status=0
for group; do
  platform=all
  purpose=
  tab=__DOLLAR__(printf "\t")
  while IFS="__DOLLAR__tab" read -r name description; do
    if [[ __DOLLAR__name == "__DOLLAR__group" ]]; then purpose=__DOLLAR__description; break; fi
  done < <(jsh::roles table)
  supported=0
  while IFS= read -r name; do
    if [[ __DOLLAR__name == "__DOLLAR__group" ]]; then supported=1; break; fi
  done < <(jsh::roles here)
  if (( ! supported )); then
    if [[ __DOLLAR__JSH_PLATFORM == darwin ]]; then platform=linux; else platform=darwin; fi
  fi
  printf "\036group\t%s\t%s\n" "__DOLLAR__group" "__DOLLAR__purpose"
  if [[ __DOLLAR__platform == linux && __DOLLAR__JSH_PLATFORM == darwin ]]; then
    if [[ __DOLLAR__group == linux ]]; then message="Skipping Linux configuration on macOS"
    else message="Skipping __DOLLAR__group on macOS: Linux only"; fi
    printf "\036item\tskip\t%s\n\036stepclose\n" "__DOLLAR__message"
    continue
  fi
  if [[ __DOLLAR__platform == darwin && __DOLLAR__JSH_PLATFORM != darwin ]]; then
    if [[ __DOLLAR__group == macos ]]; then message="Skipping macOS configuration on Linux"
    else message="Skipping __DOLLAR__group on Linux: macOS only"; fi
    printf "\036item\tskip\t%s\n\036stepclose\n" "__DOLLAR__message"
    continue
  fi
  code=0
  if [[ -f __DOLLAR__JSH_ROOT/scripts/__DOLLAR__group.sh ]]; then
    bash "__DOLLAR__JSH_ROOT/scripts/__DOLLAR__group.sh" || code=__DOLLAR__?
  fi
  if ((code)); then
    printf "\036item\tfail\t%s failed (%s)\n" "__DOLLAR__group" "__DOLLAR__code"
    printf "%s failed (%s)\n" "__DOLLAR__group" "__DOLLAR__code" >>"__DOLLAR__JSH_REPORT/failures"
    status=2
  fi
  printf "\036stepclose\n"
done
exit "__DOLLAR__status"
""".replace("__DOLLAR__", chr(36))
        playbook.write_text(body)
        playbook.chmod(0o755)

    def test_no_current_output_helper_remains(self):
        files = sorted((ROOT / "scripts").rglob("*.sh"))
        offenders = [
            str(file.relative_to(ROOT)) for file in files if "jsh::current" in file.read_text()
        ]
        self.assertEqual(offenders, [])

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

    def run_on_terminal(self, code, env):
        """Run CODE in Bash with stdout and stderr on a pseudo-terminal; return what it drew."""
        master, slave = pty.openpty()
        process = subprocess.Popen(
            ["bash", "-c", code], env=env, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave
        )
        os.close(slave)
        output = bytearray()
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break  # PTYs return EIO when their slave closes.
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.wait(timeout=10), 0, output.decode(errors="replace"))
        return output.decode()

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
            target = shutil.which(name, path="/usr/bin:/bin")
            assert target, f"{name} not found in /usr/bin:/bin"
            (self.tools / name).symlink_to(target)
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

    def test_file_and_link_helpers_report_current_and_preview_facts(self):
        source = self.home / "source"
        file_destination = self.home / "settings.conf"
        link_destination = self.home / "linked"
        source.write_text("wanted\n")

        def run(function, destination):
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    '. "$JSH_ROOT/scripts/lib/common.sh"; jsh::' + function + ' "$1" "$2"',
                    "test",
                    str(source),
                    str(destination),
                ],
                env=self.env | {"JSH_DRY_RUN": "1"},
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        self.assertIn("! ~/settings.conf is missing  would add", run("file", file_destination))
        self.assertIn("! ~/linked is missing  would add", run("link", link_destination))
        file_destination.write_text("old\n")
        link_destination.symlink_to(self.home / "other")
        self.assertIn("! ~/settings.conf differs  would change", run("file", file_destination))
        self.assertIn("! ~/linked points elsewhere  would change", run("link", link_destination))
        file_destination.write_text("wanted\n")
        link_destination.unlink()
        link_destination.symlink_to(source)
        self.assertIn("✓ ~/settings.conf is current", run("file", file_destination))
        self.assertIn("✓ ~/linked linked", run("link", link_destination))

    def test_download_keeps_the_callers_step(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$JSH_ROOT/scripts/lib/common.sh"; '
                'jsh::step check assets; jsh::download https://example.invalid/file "$HOME/file"',
            ],
            env=self.env | {"JSH_DRY_RUN": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Checking assets...", result.stdout)
        self.assertIn("would download https://example.invalid/file", result.stdout)
        self.assertNotIn("Downloaded file", result.stdout)

    def test_mirrors_only_skips_public_sources_and_refuses_downloads(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$JSH_ROOT/scripts/lib/common.sh"; jsh::step check assets; '
                "jsh::internet fonts && exit 9; "
                'jsh::download https://example.invalid/file "$HOME/file" && exit 8; exit 0',
            ],
            env=self.env | {"JSH_DRY_RUN": "1", "JSH_MIRRORS_ONLY": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Skipping fonts: not on an internal mirror", result.stdout)
        self.assertIn("refusing to download https://example.invalid/file", result.stdout)
        self.assertNotIn("would download", result.stdout)

    def test_installer_links_follow_the_checkout_location(self):
        checkout = self.home / "checkout with spaces"
        for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
            (checkout / name).mkdir(parents=True)
        for name in (
            "scripts/lib/common.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
        ):
            shutil.copy2(ROOT / name, checkout / name)
        copy_group_sources(checkout)
        # Keep real link/backup logic; avoid package installation and downloads.
        for name in ("packages.sh", "shell.sh"):
            (checkout / "scripts" / name).write_text("exit 0\n")
        shutil.copy2(ROOT / "install.sh", checkout / "install.sh")
        shutil.copy2(ROOT / "bin/jsh", checkout / "bin/jsh")
        self.mock_installer_playbook(checkout)
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

    def test_installer_links_ghostty_linux_config_off_macos(self):
        checkout = self.home / "checkout"
        for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
            (checkout / name).mkdir(parents=True)
        for name in (
            "scripts/lib/common.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
            "install.sh",
        ):
            shutil.copy2(ROOT / name, checkout / name)
        copy_group_sources(checkout)
        for name in ("packages.sh", "shell.sh"):
            (checkout / "scripts" / name).write_text("exit 0\n")
        self.mock_installer_playbook(checkout)
        shutil.copytree(ROOT / "dotfiles/.config/ghostty", checkout / "dotfiles/.config/ghostty")
        if os.uname().sysname == "Darwin":
            # jsh::link uses GNU mv -T for Linux platforms; BSD mv spells it -h.
            self.tool(
                "mv",
                'if [ "$1" = -fT ]; then shift; exec /bin/mv -fh "$@"; fi\n' 'exec /bin/mv "$@"',
            )
        for platform in ("debian", "rhel", "darwin"):
            with self.subTest(platform=platform):
                home = self.home / f"home-{platform}"
                home.mkdir()
                result = subprocess.run(
                    ["/bin/bash", str(checkout / "install.sh")],
                    env=self.env | {"HOME": str(home), "JSH_PLATFORM": platform},
                    cwd=home,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                ghostty = home / ".config/ghostty"
                self.assertEqual(
                    (ghostty / "config").readlink(), checkout / "dotfiles/.config/ghostty/config"
                )
                linux = ghostty / "linux.conf"
                if platform == "darwin":
                    self.assertFalse(linux.is_symlink() or linux.exists())
                else:
                    self.assertEqual(
                        linux.readlink(), checkout / "dotfiles/.config/ghostty/linux.conf"
                    )

    def installer_scope_fixture(self):
        checkout = self.home / "checkout"
        for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
            (checkout / name).mkdir(parents=True)
        for name in (
            "scripts/lib/common.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
            "install.sh",
            "scripts/configure.sh",
        ):
            shutil.copy2(ROOT / name, checkout / name)
        copy_group_sources(checkout)
        (checkout / "scripts/packages.sh").write_text("printf 'BREW_UPDATE\\n'\n")
        (checkout / "scripts/shell.sh").write_text("exit 0\n")
        self.mock_installer_playbook(checkout)
        return checkout

    def configure_fixture(self):
        # scripts/configure.sh requires an installed checkout at ~/.jsh.
        checkout = self.installer_scope_fixture()
        (self.home / ".jsh").symlink_to(checkout)
        return checkout

    def run_interrupted_plain_installer(self, package_script, parent_wait=False):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/packages.sh").write_text(package_script)
        if parent_wait:
            source = (checkout / "install.sh").read_text()
            source = source.replace(
                "jsh::step detect platform\n",
                'jsh::step detect platform\n: >"$HOME/interrupt-ready"\nsleep 30 >/dev/null 2>&1 & wait $!\n',
            )
            (checkout / "install.sh").write_text(source)
        self.tool("python3", "exit 1")
        process = subprocess.Popen(
            ["bash", str(checkout / "install.sh")],
            env=self.env | {"NO_COLOR": "1"},
            cwd=self.home,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        ready = self.home / "interrupt-ready"
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(ready.exists())
        os.killpg(process.pid, signal.SIGINT)
        output, _ = process.communicate(timeout=10)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.assertEqual(process.returncode, 130, output)
        return output

    def test_plain_installer_interrupt_reports_parent_step(self):
        output = self.run_interrupted_plain_installer("exit 0\n", parent_wait=True)
        self.assertIn("✕ Stopped detecting platform", output)
        self.assertNotIn("✕ core  Bootstrap packages and the checkout link", output)
        self.assertIn("Finished with errors", output)

    def test_plain_installer_interrupt_reports_child_step(self):
        output = self.run_interrupted_plain_installer(
            '. "$JSH_ROOT/scripts/lib/common.sh"\n'
            "jsh::step check packages\n"
            ': >"$HOME/interrupt-ready"\n'
            "sleep 30 >/dev/null 2>&1 & wait $!\n"
        )
        self.assertIn("✕ Stopped checking packages", output)
        self.assertNotIn("✕ core  Bootstrap packages and the checkout link", output)
        self.assertIn("Finished with errors", output)

    def test_installer_detects_platform_and_skips_other_platform_groups(self):
        checkout = self.installer_scope_fixture()
        write_group_sources(
            checkout,
            [
                ("macos", "darwin", "Mac settings"),
                ("linux", "linux", "Linux settings"),
                ("dev", "all", "Developer tools"),
            ],
        )
        self.tool(
            "id", 'if [ "$1" = -Gn ]; then echo "staff admin"; else exec /usr/bin/id "$@"; fi'
        )
        result = subprocess.run(
            ["bash", str(checkout / "install.sh")],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Detected macOS", result.stdout)
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh")],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("› linux  Linux settings", result.stdout)
        self.assertIn("Skipping Linux configuration on macOS", result.stdout)

    def test_named_roles_print_no_skips_for_unnamed_roles(self):
        checkout = self.configure_fixture()
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "patches"],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("› patches  Apply managed settings", result.stdout)
        self.assertNotIn("Skipping", result.stdout)

    def test_installer_without_python_uses_plain_platform_skips_and_summary(self):
        checkout = self.installer_scope_fixture()
        self.tool("python3", "exit 1")
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--dry-run"],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Detecting platform...", result.stdout)
        self.assertIn("Preview complete  1 would change", result.stdout)
        self.assertNotIn(" failed", result.stdout)
        (self.home / ".jsh").symlink_to(checkout)
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "--dry-run", "linux", "services"],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Skipping Linux configuration on macOS", result.stdout)
        self.assertIn("Skipping services on macOS: Linux only", result.stdout)
        self.assertIn("Preview complete", result.stdout)
        self.assertNotIn(" failed", result.stdout)

    def test_configure_without_admin_runs_only_unprivileged_roles(self):
        checkout = self.configure_fixture()
        self.tool("id", 'if [ "$1" = -Gn ]; then echo staff; else exec /usr/bin/id "$@"; fi')
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "--dry-run"],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("› configure  Apps, agents, and system settings", result.stdout)
        self.assertIn("Skipping other setup roles: needs admin rights", result.stdout)
        self.assertIn("agentics", result.stdout)
        self.assertNotIn("› macos", result.stdout)

    def test_configure_without_cached_sudo_records_action_needed(self):
        checkout = self.configure_fixture()
        self.tool("id", 'if [ "$1" = -Gn ]; then echo staff sudo; else exec /usr/bin/id "$@"; fi')
        self.tool("sudo", "exit 1")
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "--dry-run"],
            env=self.env | {"JSH_PLATFORM": "debian"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Skipping other setup roles: needs admin rights", result.stdout)
        self.assertIn(
            "Configuration needs sudo; run `sudo -v` first, then rerun `make configure`",
            result.stdout,
        )
        self.assertIn("Action needed", result.stdout)

    def test_installer_clears_status_lines_before_headers_and_summary(self):
        checkout = self.installer_scope_fixture()
        (checkout / "dotfiles/.testrc").write_text("x\n")
        (self.home / ".testrc").symlink_to(checkout / "dotfiles/.testrc")
        (self.home / ".jsh").symlink_to(checkout)
        display = self.run_on_terminal(
            f'cd "$HOME" && bash "{checkout}/install.sh" --update',
            self.env | {"NO_COLOR": "1", "JSH_PLATFORM": "darwin"},
        )
        # A clear erases the line, so only text after the last one stays visible.
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        self.assertIn("› links  Dotfiles and commands", lines, display)
        self.assertIn("✓ ~/.testrc linked", lines, display)
        self.assertNotIn("✓ links  Dotfiles and commands", lines, display)
        self.assertTrue(any(line.startswith("Ready  ") for line in lines), display)
        self.assertEqual(
            [
                line
                for line in lines
                if "Linking dotfiles..." in line or "Linking commands..." in line
            ],
            [],
            display,
        )
        display = self.run_on_terminal(
            f'cd "$HOME" && bash "{checkout}/scripts/configure.sh" --update apps',
            self.env | {"NO_COLOR": "1", "JSH_PLATFORM": "darwin"},
        )
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        self.assertIn("› maintenance", lines, display)
        self.assertTrue(any(line.startswith("› apps") for line in lines), display)
        self.assertTrue(any(line.startswith("Ready  ") for line in lines), display)

    def test_installer_reports_scope_before_package_work(self):
        checkout = self.installer_scope_fixture()
        (self.home / ".jsh").symlink_to(checkout)
        env = self.env | {"JSH_PLATFORM": "darwin"}
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--update"],
            env=env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"=   :-=-:.*Update.*-:")
        self.assertIn("› core  Bootstrap packages and the checkout link", result.stdout)
        self.assertIn("Detecting platform...", result.stdout)
        self.assertIn("Detected macOS", result.stdout)
        self.assertNotIn("Installing core packages...", result.stdout)
        self.assertLess(result.stdout.index("› core"), result.stdout.index("BREW_UPDATE"))
        self.assertNotIn("› OS:", result.stdout)
        self.assertNotIn("› Module:", result.stdout)
        self.assertNotIn("Scope:", result.stdout)
        self.assertLess(result.stdout.index("Update"), result.stdout.index("BREW_UPDATE"))

    def test_installer_shows_components_when_current(self):
        checkout = self.installer_scope_fixture()
        (checkout / "scripts/packages.sh").write_text("sleep 0.5\n")
        (self.home / ".jsh").symlink_to(checkout)

        def run(*command):
            master, slave = pty.openpty()
            process = subprocess.Popen(
                ["bash", *command],
                env=self.env,
                cwd=self.home,
                stdin=subprocess.DEVNULL,
                stdout=slave,
                stderr=slave,
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
            return output

        for command, components in (
            ((str(checkout / "install.sh"),), ("core", "shell", "links")),
            ((str(checkout / "scripts/configure.sh"), "wox"), ("wox",)),
        ):
            output = run(*command)
            display = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", output.decode(errors="replace"))
            for component in components:
                self.assertIn(f"› {component}", display)
                self.assertIn(f"\x1b[1;36m› {component}\x1b[0m".encode(), output)
            self.assertIn("Everything is current", display)
            self.assertNotIn("  0 failed", display)

    def test_installer_scope_includes_distinct_desktop(self):
        checkout = self.installer_scope_fixture()
        env = self.env | {"JSH_PLATFORM": "debian", "JSH_DESKTOP": "xfce"}
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--dry-run"],
            env=env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"=   :-=-:.*Preview.*-:")
        self.assertIn("› core  Bootstrap packages and the checkout link", result.stdout)
        self.assertIn("Detected Debian-family Linux", result.stdout)
        self.assertIn("Detected desktop: xfce", result.stdout)
        self.assertNotIn("› OS:", result.stdout)
        self.assertNotIn("› Desktop:", result.stdout)
        self.assertNotIn("Scope:", result.stdout)

    def test_make_list_rejects_groups(self):
        roles = subprocess.run(
            ["make", "--no-print-directory", "-C", str(ROOT), "list", "roles"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(roles.returncode, 0, roles.stdout + roles.stderr)
        self.assertEqual(
            roles.stdout.split(),
            [
                "macos",
                "linux",
                "packages",
                "services",
                "apps",
                "desktop",
                "wox",
                "patches",
                "agentics",
            ],
        )
        groups = subprocess.run(
            ["make", "--no-print-directory", "-C", str(ROOT), "list", "groups"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(groups.returncode, 2, groups.stdout + groups.stderr)
        self.assertIn("make list: only roles", groups.stderr)

    def test_installer_rejects_unknown_names_before_changes(self):
        checkout = self.installer_scope_fixture()
        for script in ("install.sh", "scripts/configure.sh"):
            for argument in ("--minimal", "nope", "git", "core"):
                with self.subTest(script=script, argument=argument):
                    result = subprocess.run(
                        ["bash", str(checkout / script), argument],
                        env=self.env,
                        cwd=self.home,
                        capture_output=True,
                        text=True,
                        timeout=20,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    if argument.startswith("-"):
                        self.assertIn("unknown option or role", result.stderr)
                    elif script == "install.sh":
                        self.assertIn(
                            f"install.sh takes no roles; run make configure {argument}",
                            result.stderr,
                        )
                    else:
                        self.assertIn(f"unknown option or role: {argument}", result.stderr)
                        self.assertIn("rerun with names from make list roles", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse((self.home / ".jsh").exists())

    def test_installer_lists_roles_and_runs_them_in_file_order(self):
        checkout = self.installer_scope_fixture()
        write_group_sources(
            checkout,
            [
                ("macos", "darwin", "Mac settings"),
                ("linux", "linux", "Linux settings"),
                ("dev", "all", "Developer tools"),
            ],
        )
        for name in ("macos", "linux", "dev"):
            (checkout / f"scripts/{name}.sh").write_text(f'printf "%s\\n" {name} >> "$HOME/ran"\n')
        self.tool(
            "id", 'if [ "$1" = -Gn ]; then echo "staff admin"; else exec /usr/bin/id "$@"; fi'
        )
        (self.home / ".jsh").symlink_to(checkout)

        def run(*args):
            return subprocess.run(
                ["/bin/bash", str(checkout / "scripts/configure.sh"), *args],
                env=self.env | {"JSH_PLATFORM": "darwin"},
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=20,
            )

        self.assertEqual(run("--list").stdout, "macos\nlinux\ndev\n")
        self.assertRegex(run("--help").stdout, r"\n  dev +Developer tools\n")
        result = run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / "ran").read_text(), "macos\ndev\n")
        self.assertIn("› macos  Mac settings", result.stdout)
        self.assertIn("› linux  Linux settings", result.stdout)
        self.assertIn("Skipping Linux configuration on macOS", result.stdout)
        self.assertLess(result.stdout.index("› macos"), result.stdout.index("› linux"))
        self.assertLess(result.stdout.index("› linux"), result.stdout.index("› dev"))

    def test_installer_rejects_malformed_group_sources(self):
        checkout = self.installer_scope_fixture()
        cases = (
            (
                "site",
                "---\n- hosts: localhost\n  tasks:\n"
                "    - name: dev\n      ansible.builtin.include_role:\n"
                "        apply: {tags: [dev]}\n",
                "site.yml line 5",
            ),
            (
                "metadata",
                "---\ngalaxy_info:\n  description: Tools\n",
                "ansible/roles/dev/meta/main.yml",
            ),
        )
        for source, contents, error in cases:
            with self.subTest(source=source):
                write_group_sources(checkout, [("dev", "all", "Tools")])
                if source == "site":
                    (checkout / "ansible/site.yml").write_text(contents)
                else:
                    (checkout / "ansible/roles/dev/meta/main.yml").write_text(contents)
                result = subprocess.run(
                    ["/bin/bash", str(checkout / "scripts/configure.sh"), "--list"],
                    env=self.env,
                    cwd=self.home,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(error, result.stderr)

    def test_piped_install_defers_role_names_to_the_checkout(self):
        self.tool("git", "exit 0")
        script = (ROOT / "install.sh").read_text()

        def piped(*args):
            return subprocess.run(
                ["/bin/bash", "-s", "--", *args],
                input=script,
                env=self.env,
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=20,
            )

        preview = piped("--dry-run")
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn("would clone", preview.stdout)
        named = piped("--dry-run", "nope")
        self.assertEqual(named.returncode, 2, named.stdout + named.stderr)
        self.assertIn("install.sh takes no roles; run make configure nope", named.stderr)
        bogus = piped("--bogus")
        self.assertEqual(bogus.returncode, 2)
        self.assertIn("unknown option", bogus.stderr)
        helped = piped("--help")
        self.assertEqual(helped.returncode, 0)
        self.assertIn("configured separately with make configure", helped.stdout)
        self.assertFalse((self.home / ".jsh").exists())

    def test_installer_reloads_the_existing_runtime_without_nesting(self):
        checkout = self.installer_scope_fixture()
        launcher = checkout / "bin/jsh"
        launcher.write_text('#!/bin/sh\ntouch "$HOME/nested-runtime"\n')
        launcher.chmod(0o755)
        python = shlex.quote(shutil.which("python3"))
        self.tool(
            "python3",
            f"""case "$1" in
  */lib/output.py) touch "$HOME/renderer-started" ;;
esac
exec {python} "$@"
""",
        )
        self.tool(
            "mkdir",
            """target=
for argument in "$@"; do target=$argument; done
/bin/mkdir "$@" || exit
case $target in
  */reload-*)
    if /bin/ps -axo command= | /usr/bin/grep -F "$HOME/checkout/lib/output.py" |
      /usr/bin/grep -qv "[g]rep"; then
      touch "$HOME/renderer-alive-at-handoff"
    fi
    ;;
esac
""",
        )
        for rc in (".bashrc.local", ".jshrc"):
            (self.home / rc).write_text("JSH_TEST_LOADS=$((${JSH_TEST_LOADS:-0} + 1))\n")
        for shell in SHELLS:
            with self.subTest(shell=shell):
                for marker in ("renderer-started", "renderer-alive-at-handoff"):
                    (self.home / marker).unlink(missing_ok=True)
                output = self.run_terminal(
                    shell,
                    f"""before=$$
bash {shlex.quote(str(checkout / "install.sh"))}
printf '\\nRELOAD_RESULT:%s:%s\\n' "$([[ $$ == "$before" ]] && printf same)" "$JSH_TEST_LOADS"
""",
                    JSH_LOAD_CONFIG="1",
                )
                self.assertIn("RELOAD_RESULT:same:2", output)
                self.assertIn("Reloading the jsh runtime...", output)
                self.assertTrue((self.home / "renderer-started").exists(), output)
                self.assertFalse((self.home / "renderer-alive-at-handoff").exists(), output)
                self.assertFalse((self.home / "nested-runtime").exists(), output)

    def test_installer_opens_runtime_when_no_runtime_is_active(self):
        checkout = self.installer_scope_fixture()
        launcher = checkout / "bin/jsh"
        launcher.write_text(
            '#!/bin/sh\nprintf "%s:%s\\n" "${JSH_OUTPUT+x}" '
            '"${JSH_SESSION_START+x}" > "$HOME/runtime-session-env"\n'
            'touch "$HOME/opened-runtime"\n'
        )
        launcher.chmod(0o755)
        output = self.run_terminal(
            "/bin/bash",
            f'bash {shlex.quote(str(checkout / "install.sh"))}',
            JSH_RUNTIME_DIR="",
            JSH_LOAD_CONFIG="0",
        )
        self.assertIn("Opening the jsh runtime...", output)
        self.assertTrue((self.home / "opened-runtime").exists())
        self.assertEqual((self.home / "runtime-session-env").read_text(), ":\n")

    def test_installer_preview_and_failure_do_not_request_reload(self):
        checkout = self.installer_scope_fixture()
        (self.home / ".jsh").symlink_to(checkout)
        for args in (("install.sh", "--dry-run"), ("scripts/configure.sh", "apps")):
            with self.subTest(args=args):
                (checkout / "scripts/apps.sh").write_text("exit 7\n")
                result = subprocess.run(
                    ["bash", str(checkout / args[0]), *args[1:]],
                    env=self.env | {"JSH_RELOAD_PID": "12345"},
                    cwd=self.home,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(
                    result.returncode,
                    0 if args[1] == "--dry-run" else 1,
                    result.stdout + result.stderr,
                )
                self.assertFalse((self.home / "runtime/reload-12345").exists())

    def test_installer_offers_reload_for_runtime_without_reload_hook(self):
        checkout = self.installer_scope_fixture()
        result = subprocess.run(
            ["bash", str(checkout / "install.sh")],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Run "jsh reload" to refresh the current runtime', result.stdout)

    def test_configure_summarizes_changes_and_failed_roles(self):
        checkout = self.configure_fixture()
        (checkout / "scripts/apps.sh").write_text("exit 0\n")
        (checkout / "scripts/wox.sh").write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\njsh::changed "example"\njsh::notice "Restart app"\n'
        )
        (checkout / "scripts/patches.sh").write_text("exit 1\n")
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "apps", "wox", "patches"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        output = result.stdout + result.stderr
        self.assertIn("✕ patches failed (1)", output)
        self.assertIn("Finished with errors", output)
        self.assertIn("1 changed", output)
        self.assertIn("2 failed", output)
        self.assertEqual(output.count("Restart app"), 2, output)
        self.assertIn("Action needed", output)
        self.assertNotIn("completed (bootstrap)", output)

    def test_configure_emits_one_failure_item_for_a_failing_group(self):
        checkout = self.configure_fixture()
        (checkout / "scripts/apps.sh").write_text("""set -e
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::step check links
jsh::ok x
false
""")
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "apps"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines().count("✕ apps failed (1)"), 1, result.stdout)
        self.assertIn("Failed\n  ✕ apps failed (1)", result.stdout)

    def test_configure_continues_to_the_last_group_after_earlier_failure(self):
        checkout = self.configure_fixture()
        write_group_sources(checkout, [("a", "all", "First"), ("b", "all", "Second")])
        (checkout / "scripts/a.sh").write_text("exit 1\n")
        (checkout / "scripts/b.sh").write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\n'
            "jsh::step check thing\n"
            'jsh::ok "thing is current"\n'
        )
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "a", "b"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("✕ a failed (1)", result.stdout)
        self.assertIn("› b  Second", result.stdout)
        self.assertIn("✓ thing is current", result.stdout)
        self.assertLess(
            result.stdout.index("✓ thing is current"),
            result.stdout.index("✕ host configuration failed (2)"),
        )
        self.assertNotIn("✕ Stopped checking thing", result.stdout)

    def test_installer_preview_labels_changes_without_modifying_home(self):
        checkout = self.installer_scope_fixture()
        (checkout / "dotfiles/.zshrc").write_text("fixture\n")
        result = subprocess.run(
            ["bash", str(checkout / "install.sh"), "--dry-run"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("! ~/.zshrc is missing  would add", result.stdout)
        self.assertIn("Preview complete", result.stdout)
        self.assertIn("No settings changed", result.stdout)
        self.assertFalse((self.home / ".zshrc").exists())

    def test_configure_keeps_task_output_in_the_log(self):
        checkout = self.configure_fixture()
        (checkout / "scripts/apps.sh").write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\n'
            'if read -r line; then echo "read:$line"; else echo stdin-closed; fi\n'
            'jsh::task "Configuring apps" bash -c "echo raw-config-output"\n'
            'jsh::changed "apps settings"\n'
        )
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "apps"],
            env=self.env,
            cwd=self.home,
            input="typed\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        out = result.stdout
        self.assertIn("stdin-closed", out)
        self.assertNotIn("Configuring apps", out)
        self.assertNotIn("raw-config-output", out)
        marks = [out.index(text) for text in ("› apps", "apps settings", "Ready")]
        self.assertEqual(marks, sorted(marks), out)

    def test_configure_failure_keeps_diagnostics_and_continues(self):
        checkout = self.configure_fixture()
        (checkout / "scripts/apps.sh").write_text("""
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::task "Updating Git" bash -c 'echo useful-error; exit 7' || exit $?
""")
        (checkout / "scripts/wox.sh").write_text("""
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::changed "Ghostty settings"
""")
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "--update", "apps", "wox"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("useful-error", result.stdout)
        self.assertIn("Log:", result.stdout)
        self.assertIn("Ghostty settings", result.stdout)
        self.assertIn("Finished with errors", result.stdout)
        self.assertTrue(
            any(
                b"useful-error" in path.read_bytes()
                for path in (self.home / ".local/state/jsh/logs").iterdir()
            )
        )

    def test_installer_reports_bootstrap_failures(self):
        for script in ("packages", "shell"):
            with self.subTest(script=script):
                checkout = self.home / script
                for name in ("scripts/lib", "lib/shell", "bin", "dotfiles"):
                    (checkout / name).mkdir(parents=True)
                for name in (
                    "scripts/lib/common.sh",
                    "lib/shell/output.sh",
                    "lib/output.py",
                    "lib/verbs.tsv",
                    "install.sh",
                ):
                    shutil.copy2(ROOT / name, checkout / name)
                copy_group_sources(checkout)
                (checkout / "scripts/packages.sh").write_text(
                    "exit 3\n" if script == "packages" else "exit 0\n"
                )
                (checkout / "scripts/shell.sh").write_text(
                    "exit 3\n" if script == "shell" else "exit 0\n"
                )
                result = subprocess.run(
                    ["bash", str(checkout / "install.sh")],
                    env=self.env | {"HOME": str(checkout)},
                    cwd=checkout,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                name = "core" if script == "packages" else "shell"
                self.assertIn(f"✕ {name} failed (3)", result.stdout)
                self.assertIn("Finished with errors", result.stdout)
                self.assertIn("1 failed", result.stdout)

    def test_shell_preview_update_checks_remote_head(self):
        vendor = self.home / "shell-preview"
        for name in (
            "fzf",
            "fzf-tab",
            "zsh-completions",
            "zsh-autosuggestions",
            "zsh-syntax-highlighting",
        ):
            (vendor / name / ".git").mkdir(parents=True)
        self.tool(
            "git",
            """case " $* " in
  *" rev-parse "*) printf "abc1234000000000000000000000000000000000\n" ;;
  *" ls-remote "*)
    case "${JSH_REMOTE_STATE:-equal}" in
      behind) printf "def5678000000000000000000000000000000000\tHEAD\n" ;;
      equal) printf "abc1234000000000000000000000000000000000\tHEAD\n" ;;
      fail) exit 1 ;;
    esac
    ;;
esac""",
        )

        def run(remote):
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/shell.sh"), "--dry-run", "--update"],
                env=self.env | {"JSH_VENDOR": str(vendor), "JSH_REMOTE_STATE": remote},
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        self.assertIn("! fzf is behind  would change", run("behind"))
        self.assertIn("✓ fzf is up to date", run("equal"))
        self.assertIn("fzf: could not check for updates", run("fail"))

    def test_shell_reports_fzf_version_state(self):
        vendor = self.home / "fzf-fixture"
        for name in (
            "fzf",
            "fzf-tab",
            "zsh-completions",
            "zsh-autosuggestions",
            "zsh-syntax-highlighting",
        ):
            (vendor / name / ".git").mkdir(parents=True)
        installer = vendor / "fzf/install"
        installer.write_text("#!/bin/sh\nversion=0.60.0\nexit 0\n")
        installer.chmod(0o755)
        binary = vendor / "fzf/bin/fzf"
        binary.parent.mkdir()

        def run(version=None):
            if version is None:
                binary.unlink(missing_ok=True)
            else:
                binary.write_text(f"#!/bin/sh\necho '{version} (mock)'\n")
                binary.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/shell.sh")],
                env=self.env | {"JSH_VENDOR": str(vendor)},
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        mismatch = run("0.59.0")
        self.assertIn("! fzf is 0.59.0", mismatch)
        self.assertIn("~ fzf set 0.60.0", mismatch)
        self.assertNotIn("fzf is not installed", mismatch)
        self.assertIn("✓ fzf is 0.60.0", run("0.60.0"))
        missing = run()
        self.assertIn("! fzf is not installed", missing)
        self.assertIn("+ fzf installed", missing)

    def test_shell_on_mirrors_only_hosts_clones_and_downloads_nothing(self):
        vendor = self.home / "mirror-fixture"
        (vendor / "fzf/.git").mkdir(parents=True)
        installer = vendor / "fzf/install"
        installer.write_text('#!/bin/sh\nversion=0.60.0\ntouch "$HOME/fzf-download"\n')
        installer.chmod(0o755)
        self.tool("git", 'printf "%s\\n" "$*" >> "$HOME/git.log"')
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/shell.sh"), "--update"],
            env=self.env | {"JSH_VENDOR": str(vendor), "JSH_MIRRORS_ONLY": "1"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Skipping fzf update: not on an internal mirror", result.stdout)
        self.assertIn("Skipping zsh-completions: not on an internal mirror", result.stdout)
        self.assertIn("Skipping fzf binary: not on an internal mirror", result.stdout)
        log = self.home / "git.log"
        self.assertNotIn("clone", log.read_text() if log.exists() else "")
        self.assertNotIn("pull", log.read_text() if log.exists() else "")
        self.assertFalse((self.home / "fzf-download").exists())

    def test_git_repository_updates_suppress_noop_messages(self):
        checkout = self.home / "checkout"
        for name in ("scripts/lib", "lib/shell"):
            (checkout / name).mkdir(parents=True)
        for name in (
            "scripts/lib/common.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
            "scripts/shell.sh",
        ):
            shutil.copy2(ROOT / name, checkout / name)
        for name in (
            "fzf",
            "fzf-tab",
            "zsh-completions",
            "zsh-autosuggestions",
            "zsh-syntax-highlighting",
        ):
            (self.home / "vendor" / name / ".git").mkdir(parents=True)
        self.tool(
            "git",
            """case " $* " in
  *" pull "*) printf '%s\\n' "$*" >> "$HOME/git-calls" ;;
  *" rev-parse "*) printf 'unchanged\\n' ;;
esac""",
        )
        result = subprocess.run(
            ["bash", str(checkout / "scripts/shell.sh"), "--update"],
            env=self.env | {"JSH_ROOT": str(checkout)},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("✓ fzf is up to date", result.stdout)
        calls = (self.home / "git-calls").read_text().splitlines()
        self.assertEqual(len(calls), 5)
        self.assertTrue(all("--quiet" in call for call in calls), calls)

    def test_git_get_uses_matching_profile_key(self):
        profiles = self.home / "profiles.json"
        profiles.write_text(
            '{"profiles": {"work": {"user": "skulltrail", "ssh_key": "key with space"}}}'
        )
        self.tool(
            "git",
            """printf '%s|%s\\n' "$GIT_SSH_COMMAND" "$*" >> "$HOME/git-calls"
case "$*" in
  *git@github.com:skulltrail/skulltrail.git*) exit 0 ;;
  *) exit 1 ;;
esac""",
        )
        result = subprocess.run(
            [str(ROOT / "bin/git"), "get", "skulltrail/skulltrail"],
            env=self.env | {"JSH_GIT_PROFILES": str(profiles)},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.home / "git-calls").read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(
            all(
                "ssh -F /dev/null -i " in call
                and "key\\ with\\ space" in call
                and "IdentitiesOnly=yes" in call
                for call in calls
            ),
            calls,
        )
        self.assertIn("clone -c core.sshCommand=", calls[1])
        self.assertTrue(all("git@github.com:skulltrail/skulltrail.git" in call for call in calls))

    def test_git_get_without_matching_profile_uses_https(self):
        self.tool("git", '''printf '%s\\n' "$*" >> "$HOME/git-calls"''')
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "bin/git"), "get", "other/project"],
            env=self.env | {"JSH_GIT_PROFILES": str(self.home / "missing.json")},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.home / "git-calls").read_text().splitlines()
        self.assertTrue(
            all("https://github.com/other/project.git" in call for call in calls), calls
        )
        self.assertNotIn("core.sshCommand", calls[-1])

    def test_git_profile_isolates_selected_ssh_key(self):
        profiles = self.home / "profiles.json"
        profiles.write_text(
            '{"profiles":{"anon":{"name":"Anon","email":"anon@example.org","ssh_key":"key with space"}}}'
        )
        repo = self.home / "repo"
        subprocess.run(["git", "init", "-q", str(repo)], env=self.env, check=True)
        result = subprocess.run(
            [str(ROOT / "bin/git"), "profile", "anon"],
            env=self.env | {"JSH_GIT_PROFILES": str(profiles)},
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        command = subprocess.check_output(
            ["git", "config", "core.sshCommand"], env=self.env, cwd=repo, text=True
        )
        self.assertEqual(
            shlex.split(command),
            ["ssh", "-F", "/dev/null", "-i", "~/.ssh/key with space", "-o", "IdentitiesOnly=yes"],
        )

    def test_git_profiles_lists_and_marks_matching_identity(self):
        profiles = self.home / "profiles.json"
        profiles.write_text(
            '{"profiles":{"anon":{"name":"Anon","email":"anon@example.org","user":"skulltrail"},"work":{"name":"Work","email":"work@example.org","user":"work"}}}'
        )
        subprocess.run(["git", "init", "-q", str(self.home / "repo")], env=self.env, check=True)
        repo = self.home / "repo"
        subprocess.run(
            ["git", "config", "user.email", "anon@example.org"], env=self.env, cwd=repo, check=True
        )

        def listing():
            return subprocess.run(
                [str(ROOT / "bin/git"), "profiles"],
                env=self.env | {"JSH_GIT_PROFILES": str(profiles)},
                cwd=repo,
                capture_output=True,
                text=True,
            )

        result = listing()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"(?m)^\*\s+anon\s+")
        self.assertRegex(result.stdout, r"(?m)^\s+work\s+")
        subprocess.run(
            ["git", "config", "user.email", "unmatched@example.org"],
            env=self.env,
            cwd=repo,
            check=True,
        )
        self.assertNotIn("*", listing().stdout)

    def test_gh_status_uses_selected_profile(self):
        zsh, jq = shutil.which("zsh"), shutil.which("jq")
        if not zsh or not jq:
            self.skipTest("zsh and jq required")
        profiles = self.home / "profiles.json"
        profiles.write_text(
            '{"profiles":{"anon":{"email":"anon@example.org","user":"skulltrail"}}}'
        )
        self.tool("git", 'case "$1" in rev-parse) exit 0;; config) echo anon@example.org;; esac')
        self.tool(
            "gh",
            'if [ "$1" = auth ] && [ "$2" = token ]; then printf token-%s "$6"; else printf "%s:%s\\n" "${GH_TOKEN-unset}" "$*"; fi',
        )
        self.tool("jq", f'exec "{jq}" "$@"')
        rc = (ROOT / "dotfiles/.zshrc").read_text()
        function = rc[rc.index("gh() {\n") : rc.index("\n# Interactive shell start:")]
        script = self.home / "function.zsh"
        script.write_text(function)

        def call(args):
            return subprocess.run(
                [zsh, "-f", "-c", f'source "$1"; shift; gh "$@"', "test", str(script), *args],
                env=self.env | {"JSH_GIT_PROFILES": str(profiles)},
                capture_output=True,
                text=True,
            )

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
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "work\n", ""))
        missing = self.home / "missing/profiles.json"
        for kind, path in (("profile", missing), ("other", profiles)):
            result = subprocess.run(
                [str(ROOT / "bin/git"), "__complete", kind],
                env=self.env | {"JSH_GIT_PROFILES": str(path)},
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertFalse(missing.parent.exists())

    def test_global_hooks_reject_coauthor_trailers_and_run_repository_hooks(self):
        repo, remote = self.home / "repo", self.home / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], env=self.env, check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], env=self.env, check=True)

        def git(*args):
            return subprocess.run(
                ["git", "-C", str(repo), *args],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=20,
            )

        for key, value in (
            ("user.email", "anon@example.org"),
            ("user.name", "Anon"),
            ("core.hooksPath", str(ROOT / "lib/git/hooks")),
        ):
            git("config", key, value)
        git("remote", "add", "origin", str(remote))
        for name, body in (
            ("pre-commit", 'echo pre-commit >> "$HOME/ran"'),
            ("pre-push", 'cat > "$HOME/pushed"'),
        ):
            hook = repo / ".git/hooks" / name
            hook.write_text(f"#!/bin/sh\n{body}\n")
            hook.chmod(0o755)
        for trailer in ("Co-authored-by: Bot <bot@example.org>", "co-authored-by:Bot"):
            with self.subTest(trailer=trailer):
                rejected = git("commit", "-q", "--allow-empty", "-m", f"fix: x\n\n{trailer}")
                self.assertEqual(rejected.returncode, 1, rejected.stdout + rejected.stderr)
                self.assertIn("remove the Co-authored-by trailer", rejected.stderr)
        accepted = git("commit", "-q", "--allow-empty", "-m", "fix: x\n\nRefs: #1")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual((self.home / "ran").read_text(), "pre-commit\n" * 3)
        pushed = git("push", "-q", "origin", "main")
        self.assertEqual(pushed.returncode, 0, pushed.stderr)
        self.assertIn("refs/heads/main", (self.home / "pushed").read_text())

    def test_global_hooks_run_tracked_hooks_only_after_opt_in(self):
        repo, remote = self.home / "repo", self.home / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], env=self.env, check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], env=self.env, check=True)

        def git(*args):
            return subprocess.run(
                ["git", "-C", str(repo), *args],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=20,
            )

        for key, value in (
            ("user.email", "anon@example.org"),
            ("user.name", "Anon"),
            ("core.hooksPath", str(ROOT / "lib/git/hooks")),
        ):
            git("config", key, value)
        git("remote", "add", "origin", str(remote))
        for place, label in ((".githooks", "tracked"), (".git/hooks", "installed")):
            (repo / place).mkdir(exist_ok=True)
            for name, body in (
                ("pre-commit", f'echo {label} >> "$HOME/ran"'),
                ("pre-push", f'cat > "$HOME/pushed-{label}"'),
            ):
                hook = repo / place / name
                hook.write_text(f"#!/bin/sh\n{body}\n")
                hook.chmod(0o755)
        self.assertEqual(git("commit", "-q", "--allow-empty", "-m", "fix: a").returncode, 0)
        self.assertEqual((self.home / "ran").read_text(), "installed\n")
        git("config", "jsh.hooks", "true")
        self.assertEqual(git("commit", "-q", "--allow-empty", "-m", "fix: b").returncode, 0)
        self.assertEqual((self.home / "ran").read_text(), "installed\ntracked\ninstalled\n")
        pushed = git("push", "-q", "origin", "main")
        self.assertEqual(pushed.returncode, 0, pushed.stderr)
        for label in ("tracked", "installed"):
            self.assertIn("refs/heads/main", (self.home / f"pushed-{label}").read_text())

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
        self.tool(
            "task",
            "[ \"$*\" != '--completion bash' ] || echo '_task_fixture() { :; }; complete -F _task_fixture task'",
        )
        for plugin in (
            "fzf",
            "fzf-tab",
            "zsh-autosuggestions",
            "zsh-completions",
            "zsh-syntax-highlighting",
        ):
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
        self.each_shell("""
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
        """)

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
        self.each_shell("""
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
        """)

    def test_sessionless_redirect_disables_tty_color(self):
        code = r"""
            has() { return 1; }
            JSH=$JSH_ROOT
            JSH_OS=linux
            _jsh_agent_shell=1
            . "$JSH_ROOT/lib/shell/output.sh"
            . "$JSH_ROOT/lib/shell/commands.sh"
            _j_ui_message success x | od -An -tx1
        """
        display = self.run_on_terminal(code, self.env)
        self.assertEqual(
            " ".join(display.split()),
            "e2 9c 93 20 78 0a",
            display,
        )

    def test_sessionless_color_always_forces_pipe_color(self):
        code = '. "$JSH_ROOT/lib/shell/output.sh"; jsh::ok x'
        result = subprocess.run(
            ["bash", "-c", code],
            env=self.env | {"JSH_COLOR": "always"},
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, b"\x1b[32m\xe2\x9c\x93\x1b[0m x\n")
        self.assertEqual(result.stderr, b"")

    def test_sessionless_direct_tty_uses_color(self):
        code = '. "$JSH_ROOT/lib/shell/output.sh"; jsh::ok x'
        display = self.run_on_terminal(code, self.env)
        self.assertEqual(display, "\x1b[32m✓\x1b[0m x\r\n")

    def test_sessionless_direct_tty_honors_color_disablers(self):
        code = '. "$JSH_ROOT/lib/shell/output.sh"; jsh::ok x'
        cases = (
            ("JSH_COLOR=never", {"JSH_COLOR": "never"}),
            ("NO_COLOR", {"NO_COLOR": "1"}),
            ("NO_COLOR overrides always", {"NO_COLOR": "1", "JSH_COLOR": "always"}),
        )
        for name, environment in cases:
            with self.subTest(case=name):
                display = self.run_on_terminal(code, self.env | environment)
                self.assertEqual(display, "✓ x\r\n")

    def test_converted_shell_files_do_not_use_log_aliases(self):
        paths = (
            "bin/jssh",
            "bin/nukem",
            "bin/proxy",
            "lib/shell/commands.sh",
            "lib/shell/navigation.sh",
        )
        legacy = "jsh::" + "log_"
        offenders = [path for path in paths if legacy in (ROOT / path).read_text()]
        self.assertEqual(offenders, [])

    def test_shell_command_conversions_keep_status_and_data_formats(self):
        source = self.home / "source"
        source.write_text("fixture\n")
        code = r"""
            has() { command -v "$1" >/dev/null 2>&1; }
            JSH=$JSH_ROOT
            JSH_OS=linux
            _jsh_agent_shell=1
            GIT_BASE=$HOME/Projects
            . "$JSH_ROOT/lib/shell/output.sh"
            . "$JSH_ROOT/lib/shell/navigation.sh"
            . "$JSH_ROOT/lib/shell/commands.sh"
            backup "$HOME/source"
            up invalid || :
            j --remove || :
        """
        result = subprocess.run(
            ["bash", "-c", code],
            env=self.env | {"NO_COLOR": "1"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(
            result.stdout,
            rf"^\+ Backup created: {re.escape(str(source))}\.\d{{8}}_\d{{6}}\.bak\n$",
        )
        self.assertEqual(
            result.stderr,
            "Usage: up <positive-count>\n! Not in database: ~\n",
        )

    def test_bin_commands_use_shared_symbols(self):
        self.tool("kubectl", "exit 0")
        for name, arguments in (("proxy", ["--bogus"]), ("nukem", [])):
            with self.subTest(command=name):
                result = subprocess.run(
                    [str(ROOT / "bin" / name), *arguments],
                    env=self.env | {"NO_COLOR": "1"},
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stderr[:2], "✕ ", result.stderr)

    def test_launcher_errors_use_shared_fail_symbol(self):
        result = subprocess.run(
            [str(ROOT / "bin/jsh"), "setup"],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(
            result.stderr,
            "✕ jsh: expected shell options; use install.sh for setup\n",
        )

    def test_proxy_configuration_heading_is_context(self):
        result = subprocess.run(
            [str(ROOT / "bin/proxy"), "--verbose", "--url", "http://localhost:8080", "true"],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "Proxy Configuration", result.stdout)

    def test_interactive_handoffs_do_not_start_a_renderer(self):
        self.tool("python3", 'printf python >> "$HOME/python-calls"; exit 1')
        self.tool("child-shell", 'printf proxy >> "$HOME/handoffs"')
        proxy = subprocess.run(
            [str(ROOT / "bin/proxy"), "--url", "http://localhost:8080", "--shell"],
            env=self.env | {"NO_COLOR": "1", "SHELL": str(self.tools / "child-shell")},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(proxy.returncode, 0, proxy.stdout + proxy.stderr)
        self.assertIn("Starting shell with proxy configured...", proxy.stdout)
        self.assertNotIn("\r", proxy.stdout + proxy.stderr)

        self.tool("ssh", 'printf ssh >> "$HOME/handoffs"')
        raw = subprocess.run(
            [str(ROOT / "bin/jssh"), "--raw", "example"],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(raw.returncode, 0, raw.stdout + raw.stderr)
        self.assertEqual((self.home / "handoffs").read_text(), "proxyssh")
        self.assertFalse((self.home / "python-calls").exists())
        self.assertFalse((self.home / "runtime").exists())

    def test_bin_commands_run_without_setup_library(self):
        checkout = self.home / "commands"
        (checkout / "bin").mkdir(parents=True)
        (checkout / "lib/shell").mkdir(parents=True)
        shutil.copy2(ROOT / "lib/shell/output.sh", checkout / "lib/shell/output.sh")
        for name in ("kubectx", "kubens", "nukem", "proxy"):
            with self.subTest(command=name):
                shutil.copy2(ROOT / "bin" / name, checkout / "bin" / name)
                result = subprocess.run(
                    ["bash", str(checkout / "bin" / name), "--help"],
                    env=self.env | {"JSH_ROOT": str(checkout)},
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")

    def test_confirm_needs_a_terminal_or_yes(self):
        code = '. "$JSH_ROOT/lib/shell/output.sh"; jsh::confirm "Delete?"'
        refused = subprocess.run(
            ["bash", "-c", code],
            env=self.env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(refused.returncode, 1)
        self.assertIn("Use --yes to apply changes without a terminal.", refused.stderr)
        accepted = subprocess.run(
            ["bash", "-c", code],
            env=self.env | {"JSH_ASSUME_YES": "1"},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_bash_completes_jssh_hosts_and_proxy_presets(self):
        (self.home / ".ssh").mkdir()
        (self.home / ".ssh/config").write_text("Host alpha beta *.wild\n")
        self.tool("cuprobe", "true")
        self.each_shell("""
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
        """)

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

    def test_brew_reports_each_package_in_preview_and_current_state(self):
        self.tool(
            "brew",
            """case "$*" in
  "list --formula -1") [ "${JSH_TEST_INSTALLED:-0}" != 1 ] || printf "jq\n" ;;
  list*) exit 1 ;;
esac""",
        )

        def run(installed):
            return subprocess.run(
                ["bash", str(ROOT / "scripts/packages.sh"), "--dry-run", "core"],
                env=self.env | {"JSH_PLATFORM": "darwin", "JSH_TEST_INSTALLED": installed},
                capture_output=True,
                text=True,
                timeout=20,
            )

        current = run("1")
        self.assertEqual(current.returncode, 0, current.stdout + current.stderr)
        self.assertIn("✓ jq is installed", current.stdout)
        missing = run("0")
        self.assertEqual(missing.returncode, 0, missing.stdout + missing.stderr)
        self.assertIn("! jq is not installed  would add", missing.stdout)

    def test_brew_resolves_unlisted_alias_before_reporting_package(self):
        self.tool(
            "brew",
            """printf "%s\n" "$*" >> "$HOME/brew-calls"
case "$*" in
  "list --formula -1") printf "python@3.12\n" ;;
  "list --versions python")
    [ "${JSH_ALIAS_RESOLVES:-0}" = 1 ] || exit 1
    printf "python 3.14\n"
    ;;
  list*) exit 1 ;;
esac""",
        )

        def run(resolves):
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/packages.sh"), "--dry-run", "core"],
                env=self.env | {"JSH_PLATFORM": "darwin", "JSH_ALIAS_RESOLVES": resolves},
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        missing = run("0")
        self.assertIn("! python is not installed  would add", missing)
        self.assertNotIn("✓ python is installed", missing)
        resolved = run("1")
        self.assertIn("✓ python is installed", resolved)
        self.assertNotIn("! python is not installed", resolved)
        self.assertEqual(
            (self.home / "brew-calls").read_text().count("list --versions python\n"), 2
        )

    def test_brew_early_returns_do_not_open_empty_steps(self):
        state = self.home / "package-state"
        (state / "brew").mkdir(parents=True)
        (state / "brew/formulae").touch()
        code = (
            '. "$JSH_ROOT/scripts/lib/common.sh"; '
            '. "$JSH_ROOT/scripts/lib/packages.sh"; jsh::brew formulae jq'
        )
        for environment in ({"JSH_PACKAGE_STATE": str(state)}, {"JSH_BREW_DEFER": "1"}):
            with self.subTest(environment=environment):
                result = subprocess.run(
                    ["bash", "-c", code],
                    env=self.env | {"JSH_DRY_RUN": "1", "JSH_UPDATE": "1"} | environment,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("Homebrew formulae", result.stdout)

    def test_brew_casks_report_platform_skip_without_opening_a_step(self):
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$JSH_ROOT/scripts/lib/common.sh"; '
                '. "$JSH_ROOT/scripts/lib/packages.sh"; jsh::brew casks example',
            ],
            env=self.env | {"JSH_DRY_RUN": "1", "JSH_PLATFORM": "linux"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Skipping Homebrew casks: macOS only", result.stdout)
        self.assertNotIn("Checking Homebrew casks...", result.stdout)

    def test_configure_runs_global_brew_updates_in_package_step(self):
        checkout = self.configure_fixture()
        for name in ("scripts/packages.sh", "scripts/lib/packages.sh"):
            shutil.copy2(ROOT / name, checkout / name)
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq is required for Homebrew metadata")
        (self.tools / "jq").symlink_to(jq)
        self.tool(
            "brew",
            """case "$1" in
  update) exit 0 ;;
  info) printf '%s\\n' '{"formulae":[{"full_name":"retired-formula","deprecated":true}],"casks":[{"token":"retired-cask","deprecated":true}]}' ;;
  outdated) case "$2" in --formula) echo unrelated-formula ;; --cask) echo chatgpt ;; esac ;;
  upgrade) printf '%s\\n' "$*" >> "$HOME/actions"; printf 'UPGRADED %s\\n' "$*" ;;
esac""",
        )
        result = subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), "--update", "wox"],
            env=self.env | {"JSH_PLATFORM": "darwin"},
            cwd=self.home,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
        out = result.stdout
        self.assertEqual(result.returncode, 0, out)
        self.assertTrue((self.home / "actions").exists(), out)
        actions = (self.home / "actions").read_text().splitlines()
        self.assertEqual(len(actions), 2, actions)
        self.assertLess(out.index("› maintenance"), out.index("~ unrelated-formula upgraded"), out)
        self.assertLess(out.index("~ chatgpt upgraded"), out.index("› wox"), out)
        self.assertNotIn("UPGRADED", out)
        self.assertTrue(any("unrelated-formula" in line for line in actions), actions)
        self.assertTrue(any("chatgpt" in line for line in actions), actions)

    def test_brew_update_includes_unlisted_packages_and_removes_deprecated(self):
        if os.uname().sysname == "Darwin":
            self.tool(
                "stat",
                '''if [ "$1" = -c ] && [ "$2" = %a ]; then
  shift 2
  exec /usr/bin/stat -f %Lp "$@"
fi
exec /usr/bin/stat "$@"''',
            )
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
        env = self.env | {
            "JSH_PLATFORM": "linux",
            "XDG_STATE_HOME": str(self.home / "state"),
            "XDG_CONFIG_HOME": str(config),
        }
        preview = subprocess.run(
            ["bash", str(ROOT / "scripts/packages.sh"), "--dry-run", "--update", "maintenance"],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertFalse((self.home / "actions").exists())
        self.assertEqual(trust_dir.stat().st_mode & 0o777, 0o775)
        self.assertIn("! gemini-cli is deprecated  would remove", preview.stdout)
        self.assertIn("! libclc is outdated  would change", preview.stdout)
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/packages.sh"), "--update", "maintenance"],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actions = (self.home / "actions").read_text()
        self.assertIn("uninstall --formula gemini-cli", actions)
        self.assertNotIn("uninstall --formula icu4c@76", actions)
        self.assertIn("Keeping icu4c@76: needed by dependent", result.stdout)
        self.assertIn("- gemini-cli removed", result.stdout)
        self.assertIn("~ libclc upgraded", result.stdout)
        self.assertNotIn("Keeping icu4c@76", result.stderr)
        self.assertEqual(trust_dir.stat().st_mode & 0o022, 0)
        self.assertIn("libclc", actions)
        self.assertNotIn(
            "gemini-cli", next(line for line in actions.splitlines() if line.startswith("upgrade"))
        )

    def test_packages_reject_nonbootstrap_groups(self):
        checkout = self.home / "packages"
        for name in ("scripts/lib", "lib/shell"):
            (checkout / name).mkdir(parents=True)
        for name in (
            "scripts/packages.sh",
            "scripts/lib/common.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
        ):
            shutil.copy2(ROOT / name, checkout / name)
        if (ROOT / "scripts/lib/packages.sh").exists():
            shutil.copy2(ROOT / "scripts/lib/packages.sh", checkout / "scripts/lib/packages.sh")

        def run(group):
            return subprocess.run(
                ["bash", str(checkout / "scripts/packages.sh"), "--dry-run", group],
                env=self.env | {"JSH_ROOT": str(checkout)},
                capture_output=True,
                text=True,
                timeout=20,
            )

        extra = run("extra")
        self.assertEqual(extra.returncode, 2, extra.stdout + extra.stderr)
        self.assertIn("unknown package group: extra", extra.stdout)
        unknown = run("nope")
        self.assertEqual(unknown.returncode, 2)
        self.assertIn("unknown package group: nope", unknown.stdout)

    def test_keybinding_helpers_emit_one_sessionless_preview_line(self):
        for name in ("pactl", "xrandr", "flock"):
            self.tool(name, "exit 0")
        cases = (
            (
                "ansible/roles/desktop/files/audio/cycle.sh",
                "would cycle the default audio output\n",
            ),
            (
                "ansible/roles/desktop/files/display/toggle.sh",
                "would toggle the ultrawide display split\n",
            ),
        )
        for relative, expected in cases:
            with self.subTest(script=relative):
                result = subprocess.run(
                    [shutil.which("bash"), str(ROOT / relative), "--dry-run"],
                    env=self.env | {"NO_COLOR": "1", "JSH_DESKTOP": ""},
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(
                    (result.returncode, result.stdout, result.stderr), (0, expected, "")
                )

    def test_setup_scripts_reject_unknown_options(self):
        for name in ("ansible.sh", "shell.sh"):
            with self.subTest(script=name):
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts" / name), "--dry-run", "--bogus"],
                    env=self.env,
                    cwd=self.home,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("unknown option: --bogus", result.stderr)

    def test_setup_script_help_names_the_script(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/shell.sh"), "--help"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines()[0], "Install shell plugins and their matching fzf binary."
        )

    def test_standalone_script_opens_one_session_with_its_group_header(self):
        child = self.home / "child.sh"
        child.write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\nprintf "%s\n" "$JSH_OUTPUT" > "$HOME/child-output"\njsh::ok b\n'
        )
        parent = self.home / "parent.sh"
        parent.write_text(
            'set -e\n. "$JSH_ROOT/scripts/lib/common.sh"\njsh::step check things\njsh::ok a\nbash "$HOME/child.sh"\n'
        )
        real_python = shutil.which("python3")
        assert real_python is not None
        self.tool(
            "python3",
            f"""
if [ "$1" = "{ROOT}/lib/output.py" ] && [ "$2" = render ]; then
  printf 'render\n' >> "$HOME/renderers"
fi
exec "{real_python}" "$@"
""",
        )
        result = subprocess.run(
            ["bash", str(parent)],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.count("› parent"), 1, result.stdout)
        for line in ("Checking things...", "✓ a", "✓ b", "Ready  Everything is current"):
            self.assertIn(line, result.stdout)
        self.assertNotIn("✓ parent", result.stdout)
        self.assertEqual((self.home / "child-output").read_text(), "renderer\n")
        self.assertEqual((self.home / "renderers").read_text(), "render\n")

    def test_detach_closes_session_descriptors_and_clears_environment(self):
        self.tool(
            "detached",
            'printf "%s:%s:%s:%s\\n" "${JSH_OUTPUT+x}" "${JSH_REPORT+x}" '
            '"${JSH_SESSION_START+x}" "${JSH_PACKAGE_STATE+x}" '
            '> "$HOME/detach-env"; sleep 6',
        )
        script = self.home / "detach.sh"
        script.write_text('. "$JSH_ROOT/scripts/lib/common.sh"\n' "jsh::detach detached\n")
        started = time.monotonic()
        process = subprocess.Popen(
            ["bash", str(script)],
            env=self.env | {"JSH_PACKAGE_STATE": "inherited"},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        output, _ = process.communicate(timeout=2)
        self.assertLess(time.monotonic() - started, 2, output)
        deadline = time.monotonic() + 2
        marker = self.home / "detach-env"
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(marker.read_text(), ":::\n")

    def test_session_does_not_wait_for_daemonized_children(self):
        for failing in (False, True):
            with self.subTest(failing=failing):
                script = self.home / f"daemon-{failing}.sh"
                script.write_text(
                    'set -e\n. "$JSH_ROOT/scripts/lib/common.sh"\n'
                    "jsh::step start vm\nsleep 30 &\n"
                    f'printf "%s\n" "$!" > "$HOME/daemon-{failing}.pid"\n'
                    "jsh::ok started\n" + ("false\n" if failing else "")
                )
                output = self.home / f"daemon-{failing}.output"
                started = time.monotonic()
                process = None
                daemon_pid = None
                try:
                    with output.open("w+") as stream:
                        process = subprocess.Popen(
                            ["bash", str(script)],
                            env=self.env | {"NO_COLOR": "1"},
                            stdout=stream,
                            stderr=stream,
                            text=True,
                        )
                        self.assertEqual(process.wait(timeout=5), 1 if failing else 0)
                        elapsed = time.monotonic() - started
                        stream.seek(0)
                        display = stream.read()
                    self.assertLess(elapsed, 5)
                    if failing:
                        self.assertIn("✓ started\n✕ daemon-True failed (1)\n", display)
                        self.assertNotIn("✕ daemon-True\n", display)
                        self.assertNotIn("✕ Stopped starting vm", display)
                        self.assertIn("Failed\n  ✕ daemon-True failed (1)", display)
                    else:
                        self.assertIn("Starting vm...", display)
                        self.assertIn("Ready  Everything is current", display)
                finally:
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    pid_path = self.home / f"daemon-{failing}.pid"
                    if pid_path.exists():
                        daemon_pid = int(pid_path.read_text())
                    if daemon_pid is not None:
                        try:
                            os.kill(daemon_pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass

    def test_non_interrupt_failure_reports_session_owner(self):
        script = self.home / "failure.sh"
        script.write_text(
            'set -e\n. "$JSH_ROOT/scripts/lib/common.sh"\njsh::step check links\njsh::ok x\nfalse\n'
        )
        result = subprocess.run(
            ["bash", str(script)],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("✓ x\n✕ failure failed (1)\n", result.stdout)
        self.assertNotIn("✕ failure\n", result.stdout)
        self.assertNotIn("✕ Stopped checking links", result.stdout)
        self.assertIn("Failed\n  ✕ failure failed (1)", result.stdout)

    def test_direct_vscode_failure_marks_group_and_failed_list_in_both_modes(self):
        script = self.home / "vscode.sh"
        script.write_text(
            'set -e\n. "$JSH_ROOT/scripts/lib/common.sh"\n'
            "jsh::step check links\n"
            "jsh::ok x\n"
            "false\n"
        )
        for mode in ("renderer", "plain"):
            if mode == "plain":
                self.tool("python3", "exit 1")
            with self.subTest(mode=mode):
                result = subprocess.run(
                    ["bash", str(script)],
                    env=self.env | {"NO_COLOR": "1"},
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("✓ x\n✕ vscode failed (1)\n", result.stdout)
                self.assertNotIn("✕ vscode  Merge VS Code settings", result.stdout)
                self.assertNotIn("✕ Stopped checking links", result.stdout)
                self.assertIn("Failed\n  ✕ vscode failed (1)", result.stdout)

    def test_renderer_task_failure_prints_summary_and_failed_list(self):
        self.tool("task-fail", "printf 'task problem\\n'; exit 7")
        script = self.home / "task-failure.sh"
        script.write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\n' 'jsh::task "Configuring tool" task-fail\n'
        )
        result = subprocess.run(
            ["bash", str(script)],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("Finished with errors  Everything is current  1 failed", result.stdout)
        self.assertIn("Failed\n  ✕ Configuring tool failed (7)", result.stdout)
        self.assertNotIn("task-failure failed (7)", result.stdout)

    def test_missing_or_stub_python_falls_back_to_plain(self):
        script = self.home / "fallback.sh"
        script.write_text(
            'set -e\n. "$JSH_ROOT/scripts/lib/common.sh"\njsh::step check things\njsh::ok a\n'
        )
        self.tool("python3", "printf 'invoked\\n' >> \"$HOME/python-calls\"; exit 1")
        result = subprocess.run(
            ["bash", str(script)],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Checking things...\n✓ a\n", result.stdout)
        self.assertIn("Ready  Everything is current", result.stdout)
        self.assertNotIn("  0 failed", result.stdout)
        self.assertEqual((self.home / "python-calls").read_text(), "invoked\n")

        script.write_text('set -e\n. "$JSH_ROOT/scripts/lib/common.sh"\nfalse\n')
        failed = subprocess.run(
            ["bash", str(script)],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("Finished with errors", failed.stdout)

        (self.home / "python-calls").unlink()
        self.tool("python3", "printf 'invoked\\n' >> \"$HOME/python-calls\"; exit 0")
        self.tool("xcode-select", "exit 2")
        stub = self.home / "stub.sh"
        stub.write_text("""set -e
command() {
  if [[ $1 == -v && $2 == python3 ]]; then printf '/usr/bin/python3\n'; else builtin command "$@"; fi
}
. "$JSH_ROOT/scripts/lib/common.sh"
jsh::step check things
jsh::ok a
""")
        result = subprocess.run(
            ["bash", str(stub)],
            env=self.env | {"NO_COLOR": "1", "JSH_PLATFORM": "darwin"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Checking things...\n✓ a\n", result.stdout)
        self.assertFalse((self.home / "python-calls").exists())

    def test_task_shows_latest_output_on_one_transient_line(self):
        self.tool(
            "task-mock",
            r"""printf 'bottle finished\n'
printf 'café 完了\n'
sleep 0.2
printf 'download 10%%\rdownload 90%%\r'
sleep 0.2
printf 'download complete\n\n'
sleep 0.2
printf 'last output without newline'
""",
        )
        code = (
            '. "$JSH_ROOT/scripts/lib/common.sh"; '
            "jsh::step update packages; "
            'jsh::task "Homebrew upgrade: eslint" task-mock'
        )
        env = self.env | {"NO_COLOR": "1"}
        result = subprocess.run(
            ["bash", "-c", code], env=env, capture_output=True, text=True, timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertNotIn("bottle finished", result.stdout)
        self.assertNotIn("download 90%", result.stdout)
        self.assertNotIn("last output without newline", result.stdout)
        self.assertIn("Updating packages...", result.stdout)
        display = self.run_on_terminal(code, env)
        frames = display.split("\r\x1b[K")
        self.assertNotIn("download 10%", display)
        self.assertTrue(
            any(
                "Homebrew upgrade: eslint  last output without newline" in frame for frame in frames
            ),
            display,
        )

    def test_status_line_names_the_step_until_the_next_output(self):
        code = (
            '. "$JSH_ROOT/scripts/lib/common.sh"\n'
            "jsh::step check settings\n"
            "jsh::status policy\n"
            "sleep 0.2\n"
            'jsh::changed "app settings"\n'
        )
        env = self.env | {"NO_COLOR": "1"}
        result = subprocess.run(
            ["bash", "-c", code], env=env, capture_output=True, text=True, timeout=10
        )
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertIn("Checking settings...\n~ app settings\n", result.stdout)
        display = self.run_on_terminal(code, env)
        self.assertIn("Checking settings...  policy", display)
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        self.assertFalse(any("Checking settings" in line for line in lines), lines)
        self.assertIn("~ app settings", lines)

    def test_app_settings_parse_large_json_quickly_and_still_accept_jsonc(self):
        (self.home / "large.json").write_text(
            json.dumps({f"key{index}": {"value": f"text {index}"} for index in range(10000)})
        )
        (self.home / "settings.jsonc").write_text('{\n  // comment\n  "url": "a//b",\n}\n')
        (self.home / "list.json").write_text("[1]\n")
        code = (
            '. "$JSH_ROOT/ansible/helpers/apps.sh"\n'
            'app::jsonc "$HOME/large.json" | jq -r .key9999.value\n'
            'app::jsonc "$HOME/settings.jsonc" | jq -c .\n'
            'app::jsonc "$HOME/list.json" || echo rejected\n'
        )
        result = subprocess.run(
            ["bash", "-c", code],
            env=self.env | {"JSH_OUTPUT": "plain"},
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.stdout, 'text 9999\n{"url":"a//b"}\nrejected\n', result.stderr)
        self.assertIn("settings must be an object", result.stderr)

    def test_brew_batch_retry_records_only_final_package_failures(self):
        self.tool(
            "brew",
            """case "$*" in
  "list --formula -1") exit 0 ;;
  "list --versions"*) exit 1 ;;
  "install --formula one two") exit 7 ;;
  "install --formula two") [ "${JSH_RETRY_TWO:-ok}" = ok ] || exit 9 ;;
esac""",
        )
        code = (
            '. "$JSH_ROOT/scripts/lib/common.sh"; '
            '. "$JSH_ROOT/scripts/lib/packages.sh"; '
            "jsh::group packages; jsh::brew formulae one two"
        )
        succeeded = subprocess.run(
            ["bash", "-c", code],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(succeeded.returncode, 0, succeeded.stdout + succeeded.stderr)
        self.assertIn("› packages", succeeded.stdout)
        self.assertNotIn("✓ packages", succeeded.stdout)
        self.assertNotIn("failed", succeeded.stdout)

        failed = subprocess.run(
            ["bash", "-c", code],
            env=self.env | {"NO_COLOR": "1", "JSH_RETRY_TWO": "fail"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertEqual(failed.stdout.count("Homebrew install: two failed (9)"), 2, failed.stdout)
        self.assertNotIn("Homebrew install: one two failed", failed.stdout)
        self.assertIn("1 failed", failed.stdout)

    def test_brew_caveats_become_notices_without_completion_paths(self):
        self.tool(
            "brew-batch",
            r"""cat <<'EOF'
==> Pouring tool--1.0.bottle.tar.gz
==> Caveats
zsh completions have been installed to:
  /opt/homebrew/share/zsh/site-functions
Bash completion has been installed to:
  /opt/homebrew/etc/bash_completion.d
==> tool
Run tool init
  before first use.
EOF""",
        )
        self.tool(
            "brew-single",
            r"""cat <<'EOF'
==> Caveats
foo needs a restart.
==> Moving App 'Foo.app' to '/Applications/Foo.app'
EOF""",
        )
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$JSH_ROOT/scripts/lib/common.sh"; . "$JSH_ROOT/scripts/lib/packages.sh"\n'
                "jsh::task install brew-batch; jsh::brew_caveats gh git user/tap/tool\n"
                "jsh::task upgrade brew-single; jsh::brew_caveats foo",
            ],
            env=self.env | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            result.stdout.count("tool: Run tool init before first use."), 2, result.stdout
        )
        self.assertEqual(result.stdout.count("foo: foo needs a restart."), 2, result.stdout)
        self.assertIn("! tool: Run tool init before first use.", result.stdout)
        self.assertIn("! foo: foo needs a restart.", result.stdout)
        self.assertIn("\nAction needed\n• tool: Run tool init before first use.\n"
                      "• foo: foo needs a restart.\n", result.stdout)
        self.assertNotIn("site-functions", result.stdout)
        self.assertNotIn("bash_completion.d", result.stdout)

    def _run_app_reopen(self, restart_visible):
        self.tool("jq", "exit 0")
        self.tool("uname", "echo Linux")
        self.tool(
            "pgrep",
            'if [ ! -f "$HOME/pgrep-initial" ]; then\n'
            '  : >"$HOME/pgrep-initial"; echo 999999; exit 0\n'
            "fi\n"
            'if [ "${JSH_TEST_RESTART_VISIBLE:-0}" = 1 ] && '
            '[ -f "$HOME/launcher-pid" ]; then\n'
            '  pid=$(cat "$HOME/launcher-pid")\n'
            '  kill -0 "$pid" 2>/dev/null && exit 0\n'
            "fi\nexit 1",
        )
        self.tool(
            "long-launch",
            'printf "%s\\n" "$$" >"$HOME/launcher-pid"\nexec sleep 30',
        )
        harness = self.home / "app-reopen.sh"
        harness.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            '. "$JSH_ROOT/ansible/helpers/apps.sh"\n'
            "APP_LAUNCH=(long-launch)\n"
            "apply_settings() { :; }\n"
            "app::with_closed TestApp test-app apply_settings\n"
        )
        started = time.monotonic()
        try:
            result = subprocess.run(
                ["bash", str(harness)],
                env=self.env | {"JSH_TEST_RESTART_VISIBLE": "1" if restart_visible else "0"},
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=10,
            )
        finally:
            pid_file = self.home / "launcher-pid"
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        return result, time.monotonic() - started

    def test_app_reopen_detaches_long_running_launcher(self):
        result, elapsed = self._run_app_reopen(True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(elapsed, 3, result.stdout + result.stderr)
        self.assertIn("! TestApp needs a restart", result.stdout)
        self.assertIn("~ TestApp restarted", result.stdout)

    def test_app_reopen_reports_when_process_never_appears(self):
        result, elapsed = self._run_app_reopen(False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(elapsed, 8, result.stdout + result.stderr)
        self.assertIn("TestApp did not restart; open it manually", result.stdout)
        self.assertNotIn("~ TestApp restarted", result.stdout)

    def test_rea_reports_compared_graphify_and_registration_state(self):
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq required")
        self.tool("jq", f'exec {shlex.quote(jq)} "$@"')
        self.tool("node", "exit 0")
        self.tool(
            "rea",
            'case "$1" in\n'
            "  --version) echo 1.0 ;;\n"
            '  setup) echo "{\\"plannedActions\\":[{},{}]}" ;;\n'
            "esac",
        )
        self.tool(
            "graphify",
            'case "$1" in\n'
            '  --version) echo "graphify 2.0" ;;\n'
            "  install) exit 0 ;;\n"
            "esac",
        )
        self.tool("npm", "exit 0")
        skill = self.home / ".agents/skills/graphify"
        skill.mkdir(parents=True)
        (skill / ".graphify_version").write_text("1.0")
        result = subprocess.run(
            ["bash", str(ROOT / "ansible/roles/agentics/files/rea.sh")],
            env=self.env | {"JSH_PHASE": "update"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("! graphify skill is 1.0", result.stdout)
        self.assertIn("~ graphify skill set 2.0", result.stdout)
        self.assertIn("! REA has 2 planned registration changes", result.stdout)
        self.assertIn("~ REA registrations updated", result.stdout)
        self.assertNotIn("skill is out of date", result.stdout)

    def test_rea_preview_without_graphify_works_in_modern_bash(self):
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        self.tool("node", "exit 0")
        result = subprocess.run(
            [bash, str(ROOT / "ansible/roles/agentics/files/rea.sh"), "--dry-run"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("! graphify skill is missing", result.stdout)

    def test_rea_reports_missing_graphify_and_unchecked_preview_registration(self):
        self.tool("node", "exit 0")
        self.tool(
            "graphify",
            'case "$1" in\n'
            '  --version) echo "graphify 2.0" ;;\n'
            "  install) exit 0 ;;\n"
            "esac",
        )
        result = subprocess.run(
            ["bash", str(ROOT / "ansible/roles/agentics/files/rea.sh"), "--dry-run"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("! graphify skill is missing", result.stdout)
        self.assertIn("REA registration unchecked in preview", result.stdout)
        self.assertNotIn("REA has 1 planned registration change", result.stdout)

    def test_rea_update_keeps_npm_output_in_the_log(self):
        self.tool("node", "exit 0")
        self.tool(
            "rea",
            """case "$1" in
  --version) printf '1.0\\n' ;;
  setup) printf '{"plannedActions":[]}\\n' ;;
esac""",
        )
        self.tool("graphify", "printf 'graphify 1.0\\n'")
        self.tool("jq", "printf '0\\n'")
        self.tool("npm", "printf 'up to date\\n'")
        skill = self.home / ".agents/skills/graphify"
        skill.mkdir(parents=True)
        (skill / ".graphify_version").write_text("1.0")
        result = subprocess.run(
            ["bash", str(ROOT / "ansible/roles/agentics/files/rea.sh")],
            env=self.env | {"JSH_PHASE": "update"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("up to date", result.stdout + result.stderr)

    def test_task_failure_preserves_log_and_sanitizes_terminal_output(self):
        self.tool("progress-fail", r'''printf 'safe\033[2Jtext\n'
exit 7
''')
        code = r'''. "$JSH_ROOT/scripts/lib/common.sh"
jsh::task "failing task" progress-fail
'''
        for terminal in (False, True):
            with self.subTest(terminal=terminal):
                if terminal:
                    master, slave = pty.openpty()
                    process = subprocess.Popen(
                        ["bash", "-c", code],
                        env=self.env | {"NO_COLOR": "1"},
                        stdin=subprocess.DEVNULL,
                        stdout=slave,
                        stderr=slave,
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
                    display = output.decode(errors="replace")
                    status = process.wait(timeout=10)
                else:
                    result = subprocess.run(
                        ["bash", "-c", code],
                        env=self.env | {"NO_COLOR": "1"},
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    display = result.stdout
                    status = result.returncode
                    self.assertEqual(result.stderr, "")
                self.assertEqual(status, 7, display)
                self.assertIn("safetext", display)
                self.assertNotIn("\x1b[2J", display)
                self.assertNotIn("\x1b[36m", display)
                self.assertIn("✕ failing task failed (7)", display)
                self.assertIn("    Log: ", display)
                logs = list((self.home / ".local/state/jsh/logs").iterdir())
                self.assertTrue(any(b"safe\x1b[2Jtext" in path.read_bytes() for path in logs))

    def test_task_stops_child_on_interrupt(self):
        script = self.home / "interrupt.sh"
        script.write_text(
            '. "$JSH_ROOT/scripts/lib/common.sh"\n'
            'jsh::task "test operation" bash -c \'echo $$ > "$HOME/child"; exec sleep 20\'\n'
        )
        for signum, status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=signum.name):
                child = self.home / "child"
                child.unlink(missing_ok=True)
                process = subprocess.Popen(
                    ["bash", str(script)],
                    env=self.env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                deadline = time.monotonic() + 10
                while not child.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                process.send_signal(signum)
                self.assertEqual(process.wait(timeout=10), status)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(child.read_text()), 0)
                self.assertEqual(list(self.home.glob("jsh.*")), [])

    def test_xfce_plugin_preview_reports_descriptor_drift(self):
        runtime = self.home / "plugin-fixture"
        (runtime / "ansible/roles/desktop/files").mkdir(parents=True)
        (runtime / "scripts/lib").mkdir(parents=True)
        (runtime / "ansible/helpers").mkdir(parents=True)
        (runtime / "lib/shell").mkdir(parents=True)
        for name in (
            "scripts/lib/common.sh",
            "ansible/helpers/desktop.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
        ):
            target = runtime / name
            shutil.copy2(ROOT / name, target)
        source = (ROOT / "ansible/roles/desktop/files/plugin.sh").read_text()
        source = source.replace(
            "stock=/usr/share/xfce4/panel/plugins/pulseaudio.desktop",
            "stock=${JSH_TEST_STOCK}",
        ).replace(
            "target=/usr/share/xfce4/panel/plugins/jsh-pulseaudio.desktop",
            "target=${JSH_TEST_TARGET}",
        )
        script = runtime / "ansible/roles/desktop/files/plugin.sh"
        script.write_text(source)
        (runtime / "ansible/roles/desktop/files/pulseaudio.patch").touch()

        stock = self.home / "pulseaudio.desktop"
        target = self.home / "jsh-pulseaudio.desktop"
        stock.write_text("[Desktop Entry]\nX-XFCE-Module=pulseaudio-plugin\n")
        current = (
            "[Desktop Entry]\nX-XFCE-Module=jsh-pulseaudio\n\n"
            "X-Jsh-Fingerprint=fixture\nX-Jsh-Version=1.2.3\n"
        )
        target.write_text(current)
        library = self.home / "lib/xfce4/panel/plugins/libjsh-pulseaudio.so"
        library.parent.mkdir(parents=True)
        library.touch()
        self.tool("uname", "echo Linux")
        self.tool("apt-get", "exit 0")
        self.tool("meson", "exit 0")
        self.tool("pkg-config", 'printf "%s\\n" "$HOME/lib"')
        self.tool("sha256sum", 'printf "fixture  -\\n"')
        env = self.env | {
            "JSH_ROOT": str(runtime),
            "JSH_DRY_RUN": "1",
            "JSH_HOST": "colossus",
            "JSH_DESKTOP": "xfce",
            "JSH_TEST_STOCK": str(stock),
            "JSH_TEST_TARGET": str(target),
        }

        def run():
            result = subprocess.run(
                ["bash", str(script)],
                env=env,
                cwd=self.home,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout + result.stderr

        display = run()
        self.assertIn("✓ XFCE Wave:3 audio plugin is 1.2.3", display)
        target.write_text(current + "X-Local-Drift=true\n")
        display = run()
        self.assertIn(
            "! XFCE Wave:3 audio plugin is out of date  would change",
            display,
        )
        self.assertNotIn("update is unchecked in preview", display)

    def test_desktop_panel_reapply_reports_each_setting_once(self):
        source = (ROOT / "ansible/roles/desktop/files/panel.sh").read_text()
        functions = source[source.index("xfconf_set() {") : source.index("case ${1:-apply} in")]
        harness = self.home / "panel-reapply.sh"
        harness.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            '. "$JSH_ROOT/scripts/lib/common.sh"\n'
            "SCRIPT_DIR=$JSH_ROOT/scripts\n"
            "panel_files_changed=0\npanel_quiet=0\n"
            + functions
            + "apply_panel() { xfconf_set xfce4-panel /test string wanted; }\n"
            'jsh::step check "XFCE panel"\n'
            "apply_panel\nrestart_panel\n"
        )
        self.tool(
            "xfconf-query",
            'state="$HOME/xfconf-state"\n'
            'case " $* " in\n'
            '  *" -lv "*) if [ -f "$state" ]; then '
            'printf "/test %s\\n" "$(cat "$state")"; else '
            'printf "/test old\\n"; fi ;;\n'
            '  *" -s "*) for argument in "$@"; do value=$argument; done; '
            'printf "%s\\n" "$value" > "$state" ;;\n'
            '  *) if [ -f "$state" ]; then cat "$state"; else '
            'printf "old\\n"; fi ;;\n'
            "esac",
        )
        self.tool(
            "xfce4-panel",
            'if [ "$1" = --quit ]; then '
            'touch "$HOME/panel-stopped"; else '
            'rm -f "$HOME/panel-stopped"; fi',
        )
        self.tool("pgrep", '[ ! -f "$HOME/panel-stopped" ]')
        self.tool("timeout", 'shift; "$@"')
        result = subprocess.run(
            ["bash", str(harness)],
            env=self.env | {"JSH_DESKTOP": "xfce"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        setting_lines = [line for line in result.stdout.splitlines() if "xfce4-panel/test" in line]
        self.assertEqual(
            setting_lines,
            ["! xfce4-panel/test is not wanted", "~ xfce4-panel/test set wanted"],
        )
        self.assertEqual(
            [line for line in setting_lines if line.startswith("~ ")],
            ["~ xfce4-panel/test set wanted"],
        )

    def test_dock_app_names_hide_paths_and_desktop_ids(self):
        applications = self.home / ".local/share/applications"
        applications.mkdir(parents=True)
        desktop_ids = (
            "com.mitchellh.ghostty.desktop",
            "waterfox.desktop",
            "com.visualstudio.code.desktop",
            "com.spotify.Client.desktop",
        )
        for desktop_id in desktop_ids:
            (applications / desktop_id).touch()
        self.tool("xfconf-query", "exit 0")
        result = subprocess.run(
            ["bash", str(ROOT / "ansible/roles/desktop/files/dock/pins.sh"), "--dry-run"],
            env=self.env | {"JSH_DESKTOP": "xfce"},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        display = result.stdout + result.stderr
        dock_lines = [
            line.rstrip()
            for line in display.splitlines()
            if "dock pins" in line and "preview" in line
        ]
        self.assertEqual(
            dock_lines,
            ["XFCE dock pins are unchecked in preview: Ghostty, Waterfox, VS Code, Spotify"],
        )
        for hidden in (*desktop_ids, str(applications)):
            self.assertNotIn(hidden, display)

    def test_interactive_shell_discards_inherited_output_session(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(
                    shell,
                    "jsh::fail x 2>&1",
                    JSH_OUTPUT="renderer",
                    JSH_REPORT=str(self.home / "inherited-report"),
                    JSH_SESSION_START="1",
                )
                self.assertIn("✕ x", output)
                self.assertNotIn("\x1eitem", output)


class OutputChecks(unittest.TestCase):
    def test_cafe_reports_errors_with_shared_symbols(self):
        code = (
            "import platform, runpy, sys; "
            "from unittest import mock; "
            "sys.argv = [sys.argv[1]]; "
            'patch = mock.patch.object(platform, "system", return_value="Plan 9"); '
            'patch.start(); runpy.run_path(sys.argv[0], run_name="__main__")'
        )
        result = subprocess.run(
            ["python3", "-c", code, str(ROOT / "bin/cafe")],
            env=os.environ | {"NO_COLOR": "1", "TERM": "dumb"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue(result.stderr.startswith("✕ cafe:"), result.stderr)

    def test_cafe_stopped_item_starts_on_new_tty_line(self):
        import contextlib
        import importlib.machinery
        import importlib.util
        import io
        from unittest import mock

        class Terminal(io.StringIO):
            def isatty(self):
                return True

        loader = importlib.machinery.SourceFileLoader("jsh_cafe_interrupt", str(ROOT / "bin/cafe"))
        spec = importlib.util.spec_from_loader("jsh_cafe_interrupt", loader)
        cafe = importlib.util.module_from_spec(spec)
        loader.exec_module(cafe)
        terminal = Terminal()
        with mock.patch.object(cafe.output, "info"), mock.patch.object(
            cafe.output, "ok"
        ) as stopped, mock.patch.object(
            cafe.time, "sleep", side_effect=KeyboardInterrupt
        ), contextlib.redirect_stdout(
            terminal
        ):
            cafe.wait_until_stopped("testing")
        self.assertEqual(terminal.getvalue(), "\n")
        stopped.assert_called_once_with("Caffeine stopped")

    def test_genmon_lines_are_unchanged(self):
        import contextlib
        import importlib.machinery
        import importlib.util
        import io
        from unittest import mock

        def load(name, path):
            loader = importlib.machinery.SourceFileLoader(name, str(path))
            spec = importlib.util.spec_from_loader(name, loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
            return module

        cafe = load("jsh_cafe_genmon", ROOT / "bin/cafe")
        mic_check = Path("ansible/roles/desktop/files/audio/mic-check")
        microphone = load("jsh_microphone_genmon", ROOT / mic_check)
        cafe.SCRIPT = Path("/mock/jsh/bin/cafe")
        microphone.SCRIPT = Path("/mock/jsh") / mic_check
        display = io.StringIO()
        with mock.patch.object(
            cafe, "running_pid", side_effect=[None, None, 123]
        ), mock.patch.object(
            cafe.Path, "is_file", side_effect=[False, True, False]
        ), mock.patch.object(
            microphone, "status", side_effect=["muted", "live", "unavailable"]
        ), contextlib.redirect_stdout(
            display
        ):
            cafe.show_xfce_status()
            cafe.show_xfce_status()
            cafe.show_xfce_status()
            microphone.panel()
            microphone.panel()
            microphone.panel()
        self.assertEqual(
            display.getvalue(),
            "<img>/mock/jsh/dotfiles/.local/share/icons/hicolor/scalable/status/"
            "cafe-off-symbolic.svg</img><click>/mock/jsh/bin/cafe --xfce-toggle"
            "</click><tool>Cafe: Inactive (Normal sleep - Click to disable sleep)"
            "</tool>\n"
            "<icon>cafe-off-symbolic</icon><iconclick>/mock/jsh/bin/cafe "
            "--xfce-toggle</iconclick><tool>Cafe: Inactive (Normal sleep - Click "
            "to disable sleep)</tool>\n"
            "<img>/mock/jsh/dotfiles/.local/share/icons/hicolor/scalable/status/"
            "cafe-on-symbolic.svg</img><click>/mock/jsh/bin/cafe --xfce-toggle"
            "</click><tool>Cafe: Active (Sleep disabled - Click to allow sleep)"
            "</tool>\n"
            "<img>/mock/jsh/ansible/roles/desktop/files/audio/microphone-muted.svg</img><tool>"
            "Elgato Wave:3: Muted</tool>\n"
            "<img>/mock/jsh/ansible/roles/desktop/files/audio/microphone-live.svg</img><tool>"
            "Elgato Wave:3: Live</tool>\n"
            "<img>/mock/jsh/ansible/roles/desktop/files/audio/microphone-unavailable.svg</img>"
            "<tool>Elgato Wave:3: Unavailable</tool>\n",
        )

    def test_python_sessionless_items_match_bash(self):
        import contextlib
        import importlib.util
        import io
        from unittest import mock

        spec = importlib.util.spec_from_file_location("jsh_python_output", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ, {"NO_COLOR": "1", "TERM": "xterm"}
        ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            module.ok("current")
            module.drift("drifted")
            module.added("added now", "missing before")
            module.changed("changed now", "old before")
            module.removed("removed now", "present before")
            module.fail("failed")
            module.info("context")
            module.notice("take action")
            module.skipped("optional work")
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            "jsh::ok current; jsh::drift drifted; "
            'jsh::added "added now" "missing before"; '
            'jsh::changed "changed now" "old before"; '
            'jsh::removed "removed now" "present before"; '
            "jsh::fail failed; jsh::info context; "
            'jsh::notice "take action"; jsh::skipped "optional work"'
        )
        bash = self.run_output_shell("/bin/bash", code)
        self.assertEqual(
            (stdout.getvalue().encode(), stderr.getvalue().encode()), (bash.stdout, bash.stderr)
        )

    def test_python_steps_fall_back_without_verbs_table(self):
        with tempfile.TemporaryDirectory(prefix="jsh-output-no-verbs-") as directory:
            runtime = Path(directory)
            shutil.copy2(ROOT / "lib/output.py", runtime / "output.py")
            code = """import importlib.util
import sys
spec = importlib.util.spec_from_file_location("isolated_output", sys.argv[1])
output = importlib.util.module_from_spec(spec)
spec.loader.exec_module(output)
output.step("check", "outside")
with output.session():
    output.step("check", "inside")
    output.ok("current")
"""
            result = subprocess.run(
                ["python3", "-c", code, str(runtime / "output.py")],
                env=os.environ | {"NO_COLOR": "1", "TERM": "dumb"},
                capture_output=True,
                text=True,
                timeout=10,
            )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr),
            (0, "check outside...\ncheck inside...\n✓ current\n", ""),
        )

    def test_python_steps_fall_back_with_malformed_verbs_table(self):
        import contextlib
        import importlib.util
        import io
        from unittest import mock

        with tempfile.TemporaryDirectory(prefix="jsh-output-bad-verbs-") as directory:
            runtime = Path(directory)
            shutil.copy2(ROOT / "lib/output.py", runtime / "output.py")
            (runtime / "verbs.tsv").write_text("malformed\n")
            spec = importlib.util.spec_from_file_location(
                "jsh_output_bad_verbs", runtime / "output.py"
            )
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            with self.assertRaisesRegex(ValueError, "expected verb, ing, and past"):
                module.verbs()
            stdout = io.StringIO()
            with mock.patch.dict(
                os.environ, {"NO_COLOR": "1", "TERM": "dumb"}
            ), contextlib.redirect_stdout(stdout):
                module.step("check", "outside")
                with module.session():
                    module.step("check", "inside")
                    module.ok("current")
        self.assertEqual(stdout.getvalue(), "check outside...\ncheck inside...\n✓ current\n")

    def test_python_session_streams_items_and_closes_groups(self):
        import contextlib
        import importlib.util
        import io
        from unittest import mock

        spec = importlib.util.spec_from_file_location("jsh_python_session", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ, {"NO_COLOR": "1", "TERM": "dumb"}
        ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), module.session():
            module.group("tools", "Install tools")
            module.step("check", "packages")
            module.ok("jq is installed")
            module.drift("rg is not installed")
            module.skipped("optional package")
        self.assertEqual(
            stdout.getvalue().splitlines(),
            [
                "",
                "› tools  Install tools",
                "Checking packages...",
                "✓ jq is installed",
                "! rg is not installed",
                "Skipping optional package",
            ],
        )
        self.assertEqual(stderr.getvalue(), "")

    def test_python_sessionless_color_follows_each_destination(self):
        import importlib.util
        import io
        from unittest import mock

        class Stream(io.StringIO):
            def __init__(self, tty):
                super().__init__()
                self.tty = tty

            def isatty(self):
                return self.tty

        spec = importlib.util.spec_from_file_location("jsh_python_color", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        stdout = Stream(True)
        stderr = Stream(False)
        with mock.patch.object(module.sys, "stdout", stdout), mock.patch.object(
            module.sys, "stderr", stderr
        ), mock.patch.dict(os.environ, {"TERM": "xterm"}, clear=True):
            module.ok("current")
            module.fail("failed")
            os.environ["JSH_COLOR"] = "always"
            module.notice("action")
            os.environ["TERM"] = "dumb"
            module.drift("drifted")
        self.assertEqual(stdout.getvalue(), "\x1b[32m✓\x1b[0m current\n")
        self.assertEqual(stderr.getvalue(), "✕ failed\n\x1b[33m!\x1b[0m action\n! drifted\n")

    def test_importing_python_output_has_no_runtime_side_effects(self):
        import contextlib
        import importlib.util
        import io
        from unittest import mock

        spec = importlib.util.spec_from_file_location("jsh_output_import", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(Path, "open", side_effect=AssertionError("verbs read")), mock.patch(
            "threading.Thread.start", side_effect=AssertionError("thread started")
        ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            spec.loader.exec_module(module)
        self.assertEqual((stdout.getvalue(), stderr.getvalue()), ("", ""))

    def render_terminal(self, events: list[tuple], **environment: str) -> str:
        master, slave = pty.openpty()
        env = {
            name: value
            for name, value in os.environ.items()
            if name != "LANG" and not name.startswith("LC_")
        }
        env.update({"NO_COLOR": "1", "TERM": "xterm-256color"} | environment)
        process = subprocess.Popen(
            ["python3", str(ROOT / "lib/output.py"), "render"],
            stdin=subprocess.PIPE,
            stdout=slave,
            stderr=subprocess.PIPE,
            env=env,
        )
        os.close(slave)
        output = bytearray()
        closed = False

        def read_once(timeout: float) -> bool:
            nonlocal closed
            if not select.select([master], [], [], timeout)[0]:
                return False
            try:
                chunk = os.read(master, 65536)
            except OSError:
                closed = True  # PTYs return EIO when their slave closes.
                return False
            if not chunk:
                closed = True
                return False
            output.extend(chunk)
            return True

        try:
            assert process.stdin is not None
            for event in events:
                if event[0] == "wait":
                    expected = str(event[1]).encode()
                    deadline = time.monotonic() + 3
                    while expected not in output and time.monotonic() < deadline:
                        read_once(0.1)
                    self.assertIn(expected, output)
                    continue
                if event[0] == "interrupt":
                    os.kill(process.pid, signal.SIGINT)
                    continue
                if event[0] == "raw":
                    line = str(event[1])
                else:
                    fields = (
                        str(field)
                        .replace("\t", " ")
                        .replace("\r", " ")
                        .replace("\n", " ")
                        .replace("\x1e", "")
                        for field in event
                    )
                    line = "\x1e" + "\t".join(fields)
                process.stdin.write((line + "\n").encode())
                process.stdin.flush()
            process.stdin.close()
            deadline = time.monotonic() + 10
            while not closed and time.monotonic() < deadline:
                if not read_once(0.1) and process.poll() is not None:
                    read_once(0)
                    break
            try:
                returncode = process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.fail("terminal renderer did not exit: " + output.decode(errors="replace"))
            error = process.stderr.read().decode(errors="replace") if process.stderr else ""
            self.assertEqual(returncode, 0, error)
            return output.decode(errors="replace")
        finally:
            os.close(master)
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=1)
            if process.stderr:
                process.stderr.close()

    def render(self, events: list[tuple], *args: str) -> str:
        lines = []
        for event in events:
            if event[0] == "raw":
                lines.append(event[1])
            else:
                fields = (
                    str(field)
                    .replace("\t", " ")
                    .replace("\r", " ")
                    .replace("\n", " ")
                    .replace("\x1e", "")
                    for field in event
                )
                lines.append("\x1e" + "\t".join(fields))
        result = subprocess.run(
            ["python3", str(ROOT / "lib/output.py"), "render", *args],
            input="\n".join(lines) + "\n",
            env=os.environ | {"NO_COLOR": "1"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_items_stream_and_group_closes_without_result(self):
        events = [
            ("group", "macos", "Apply managed macOS preferences"),
            ("step", "check", "macOS settings"),
            ("item", "ok", "A is false"),
            ("item", "ok", "B is false"),
            ("end", "0"),
        ]
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            out = self.render(events, "--report", directory)
        self.assertEqual(
            out.splitlines(),
            [
                "",
                "› macos  Apply managed macOS preferences",
                "Checking macOS settings...",
                "✓ A is false",
                "✓ B is false",
                "",
                "Ready  Everything is current  0m 00s",
            ],
        )

        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            'jsh::group macos "Apply managed macOS preferences"; '
            'jsh::step check "macOS settings"; '
            'jsh::ok "A is false"; jsh::ok "B is false"; '
            "jsh::event end 0"
        )
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            plain = self.run_output_shell(
                "/bin/bash",
                code,
                JSH_OUTPUT="plain",
                JSH_REPORT=directory,
            ).stdout.decode()
        self.assertEqual(plain.splitlines(), out.splitlines()[:5])

    def test_group_close_prints_no_result_after_failures_and_skips(self):
        out = self.render(
            [
                ("group", "broken", "Failure group"),
                ("item", "fail", "work failed"),
                ("group", "skipped", "Skip group"),
                ("item", "skip", "Skipping unavailable work"),
                ("group", "mixed", "Mixed group"),
                ("item", "ok", "work is current"),
                ("item", "skip", "Skipping optional work"),
                ("end", "0"),
            ]
        )
        self.assertEqual(
            out.splitlines(),
            [
                "",
                "› broken  Failure group",
                "✕ work failed",
                "",
                "› skipped  Skip group",
                "Skipping unavailable work",
                "",
                "› mixed  Mixed group",
                "✓ work is current",
                "Skipping optional work",
            ],
        )
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            'jsh::group broken "Failure group"; jsh::fail "work failed"; '
            'jsh::group skipped "Skip group"; '
            'jsh::skipped "unavailable work"; '
            'jsh::group mixed "Mixed group"; jsh::ok "work is current"; '
            'jsh::skipped "optional work"; jsh::event end 0'
        )
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            plain = self.run_output_shell(
                "/bin/bash",
                code,
                JSH_OUTPUT="plain",
                JSH_REPORT=directory,
            ).stdout.decode()
        self.assertEqual(plain, out)

    def test_plain_groups_show_child_report_events_without_results(self):
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            'jsh::group skipped "Skip group"; '
            'bash -c ". "$JSH_ROOT/lib/shell/output.sh"; jsh::skipped child"; '
            'jsh::group failed "Failure group"; '
            'bash -c ". "$JSH_ROOT/lib/shell/output.sh"; jsh::fail child"; '
            "jsh::event end 0"
        )
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            out = self.run_output_shell(
                "/bin/bash",
                code,
                JSH_OUTPUT="plain",
                JSH_REPORT=directory,
            ).stdout.decode()
        self.assertEqual(
            out.splitlines(),
            [
                "",
                "› skipped  Skip group",
                "Skipping child",
                "",
                "› failed  Failure group",
                "✕ child",
            ],
        )

    def test_terminal_streams_items_above_the_spinner(self):
        display = self.render_terminal(
            [
                ("group", "macos", "Apply managed macOS preferences"),
                ("step", "check", "macOS settings"),
                ("wait", "Checking macOS settings..."),
                ("item", "ok", "A is false"),
                ("wait", "✓ A is false"),
                ("end", "0"),
            ],
            LANG="en_US.UTF-8",
            LC_ALL="en_US.UTF-8",
        )
        self.assertIn("Checking macOS settings...", display)
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        permanent = [line for line in lines if line]
        self.assertEqual(
            permanent,
            [
                "› macos  Apply managed macOS preferences",
                "✓ A is false",
            ],
        )
        self.assertFalse(
            any("Checking macOS settings" in line for line in permanent),
            permanent,
        )
        self.assertNotIn("Checked macOS settings", permanent)

    def test_failed_end_silently_closes_open_step(self):
        events = [
            ("group", "b", "Second"),
            ("step", "check", "thing"),
            ("item", "ok", "thing is current"),
            ("end", "0", "1"),
        ]
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            rendered = self.render(events, "--report", directory)
        expected = [
            "",
            "› b  Second",
            "Checking thing...",
            "✓ thing is current",
        ]
        self.assertEqual(rendered.splitlines()[: len(expected)], expected)
        self.assertNotIn("✓ b  Second", rendered)
        self.assertNotIn("✕ Stopped checking thing", rendered)

        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; jsh::group b Second; '
            'jsh::step check thing; jsh::ok "thing is current"; '
            "jsh::event end 0 1"
        )
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            plain = self.run_output_shell(
                "/bin/bash",
                code,
                JSH_OUTPUT="plain",
                JSH_REPORT=directory,
            ).stdout.decode()
        self.assertEqual(plain.splitlines(), expected)

    def test_cross_process_failed_run_prints_no_group_results_with_parity(self):
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            'jsh::group a First; jsh::fail "a failed (1)"; '
            "jsh::group b Second; "
            'bash -c \'. "$JSH_ROOT/lib/shell/output.sh"; '
            'jsh::step check thing; jsh::ok "thing is current"\'; '
            "jsh::event stepclose; jsh::event end 0 1"
        )
        expected = [
            "",
            "› a  First",
            "✕ a failed (1)",
            "",
            "› b  Second",
            "Checking thing...",
            "✓ thing is current",
        ]
        outputs = {}
        for mode in ("plain", "renderer"):
            with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
                events = self.run_output_shell(
                    "/bin/bash",
                    code,
                    JSH_OUTPUT=mode,
                    JSH_REPORT=directory,
                ).stdout
                if mode == "plain":
                    outputs[mode] = events.decode()
                else:
                    result = subprocess.run(
                        ["python3", str(ROOT / "lib/output.py"), "render", "--report", directory],
                        input=events,
                        env=os.environ | {"NO_COLOR": "1"},
                        capture_output=True,
                        timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    outputs[mode] = result.stdout.decode()
        self.assertEqual(outputs["plain"].splitlines(), expected)
        self.assertEqual(outputs["renderer"].splitlines()[: len(expected)], expected)
        for output in outputs.values():
            self.assertNotIn("✕ a  First", output)
            self.assertNotIn("✓ b  Second", output)

    def test_packages_closes_the_child_step(self):
        code = (
            '. "$JSH_ROOT/scripts/lib/common.sh"; '
            'bash() { jsh::step check thing; jsh::ok "thing is current"; }; '
            "jsh::packages demo"
        )
        events = self.run_output_shell(
            "/bin/bash",
            code,
            JSH_OUTPUT="renderer",
            JSH_DRY_RUN="0",
        ).stdout
        self.assertTrue(events.endswith(b"\x1estepclose\n"), events)

    def test_spinner_omits_empty_dim_suffix(self):
        import importlib.util
        import io

        spec = importlib.util.spec_from_file_location("jsh_output", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        renderer = module.Renderer(
            io.StringIO(),
            tty=False,
            color=True,
            preview=False,
            report=None,
        )
        renderer._step = ("check", "thing")
        renderer._frames = lambda: "|"
        line = renderer._spinner_line(None, "")
        self.assertEqual(line, "\x1b[1m| Checking thing...\x1b[0m")

    def test_interrupted_step_prints_stopped_without_group_result(self):
        with tempfile.TemporaryDirectory(prefix="jsh-report-") as directory:
            out = self.render(
                [
                    ("group", "links", "Dotfiles and commands"),
                    ("step", "check", "links"),
                    ("item", "ok", "one link is current"),
                    ("end", "0", "130"),
                ],
                "--report",
                directory,
            )
        self.assertEqual(
            out.splitlines(),
            [
                "",
                "› links  Dotfiles and commands",
                "Checking links...",
                "✓ one link is current",
                "✕ Stopped checking links",
                "",
                "Finished with errors  Everything is current  0m 00s",
            ],
        )

    def test_renderer_preview_shows_drift_with_planned_action(self):
        out = self.render(
            [
                ("step", "check", "prerequisites"),
                ("item", "added", "jq installed", "jq is not installed"),
                ("end", "0"),
            ],
            "--preview",
        )
        self.assertIn("! jq is not installed  would add", out.splitlines())

    def test_renderer_streams_items_before_stopped_step_at_eof(self):
        out = self.render(
            [
                ("step", "check", "links"),
                ("item", "ok", "$HOME/.zshrc linked"),
            ]
        )
        self.assertEqual(
            out.splitlines(),
            [
                "Checking links...",
                "✓ ~/.zshrc linked",
                "✕ Stopped checking links",
            ],
        )

    def test_renderer_shows_stray_lines_as_output(self):
        out = self.render(
            [
                ("step", "run", "command"),
                ("raw", "boom"),
                ("end", "0"),
            ]
        )
        self.assertEqual(out.splitlines(), ["Running command...", "    boom"])

    def test_renderer_survives_unknown_step_verb_and_item_kind(self):
        with tempfile.TemporaryDirectory(prefix="jsh-output-") as directory:
            out = self.render(
                [
                    ("step", "check", "links"),
                    ("item", "ok", "held item"),
                    ("step", "verify", "thing"),
                    ("item", "mystery", "unknown payload"),
                    ("item", "ok", "after"),
                    ("end", "inf"),
                ],
                "--report",
                directory,
            )
        self.assertEqual(
            out.splitlines(),
            [
                "Checking links...",
                "✓ held item",
                "verify thing...",
                "    unknown payload",
                "✓ after",
                "",
                "Ready  Everything is current  0m 00s",
            ],
        )

    def test_renderer_summary_matches_report(self):
        with tempfile.TemporaryDirectory(prefix="jsh-output-") as directory:
            report = Path(directory)
            (report / "events").write_text("changed\n")
            (report / "failures").write_text("just failed (1)\n")
            (report / "notices").write_text("Restart Ghostty\n")
            out = self.render([("end", "40")], "--report", str(report))
        lines = out.splitlines()
        for line in (
            "Finished with errors  1 changed  1 failed  0m 40s",
            "Failed", "  ✕ just failed (1)", "Action needed", "• Restart Ghostty",
        ):
            self.assertIn(line, lines)

    def test_renderer_summary_with_only_notices_is_not_current(self):
        with tempfile.TemporaryDirectory(prefix="jsh-output-") as directory:
            report = Path(directory)
            (report / "notices").write_text("Restart Ghostty\n")
            out = self.render([("end", "6")], "--report", str(report))
        self.assertIn("Ready  No changes made  0m 06s", out.splitlines())
        self.assertNotIn("Everything is current", out)

    def test_notice_wraps_without_indent_and_keeps_code_whole(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("jsh_output", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        text = "Configuration needs sudo; run `sudo -v` first, then rerun `make configure`"
        self.assertEqual(module.format_notice(text, 41), [
            "• Configuration needs sudo; run `sudo -v`",
            "first, then rerun `make configure`",
        ])
        colored = module.format_notice("run `sudo -v` now", 0, color=True)
        self.assertEqual(colored, [
            "\x1b[1;33m•\x1b[0m run \x1b[36msudo -v\x1b[0m now",
        ])
        common = (ROOT / "scripts/lib/common.sh").read_text()
        function = re.search(r"^jsh::_notice_lines\(\) \{\n.*?^\}\n", common,
                             re.M | re.S)[0]
        code = (f'. "{ROOT}/lib/shell/output.sh"; {function}'
                f'jsh::_notice_lines {shlex.quote(text)} 41')
        result = subprocess.run(["bash", "-c", code], env=os.environ | {"NO_COLOR": "1"},
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.stdout.splitlines(), module.format_notice(text, 41))

    def test_renderer_sanitizes_all_terminal_event_text(self):
        display = self.render_terminal([
            ("step", "check", "links"),
            ("progress", "x\x1b[2Jy"),
            ("wait", "Checking links...  xy"),
            ("item", "ok", "x\x1b[2Jy"),
            ("group", "co\x1b[2Jre", "purpose"),
            ("raw", "\x1b]0;x\x07boom"),
            ("end", "0"),
        ], LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        cleaned = display.replace("\r\x1b[K", "")
        self.assertNotIn("\x1b", cleaned)
        self.assertIn("Checking links...  xy", cleaned)
        self.assertIn("✓ xy", cleaned)
        self.assertIn("› core  purpose", cleaned)
        self.assertIn("    boom", cleaned)

    def test_terminal_spinner_clears_without_a_completion_line(self):
        display = self.render_terminal([
            ("step", "check", "prerequisites"),
            ("progress", "jq"),
            ("wait", "Checking prerequisites...  jq"),
            ("item", "ok", "jq is installed"),
            ("end", "0"),
        ], LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        self.assertIn("Checking prerequisites...  jq", display)
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        self.assertEqual([line for line in lines if line], ["✓ jq is installed"])

    def test_terminal_task_failure_shows_saved_log_tail(self):
        with tempfile.TemporaryDirectory(prefix="jsh-output-") as directory:
            saved = Path(directory) / "saved.log"
            saved.write_text(
                "\n".join(
                    [
                        "drop one",
                        "drop two",
                        "three",
                        "four",
                        "\x1b[31mred\x1b[0m",
                        "a\tb",
                        "seven",
                        "eight",
                        "nine",
                        "ten",
                        "eleven",
                        "twelve",
                    ]
                )
                + "\n"
            )
            display = self.render_terminal(
                [
                    ("step", "install", "package"),
                    ("task", "build", str(Path(directory) / "active.log")),
                    ("taskend", "7", str(saved)),
                    ("end", "0"),
                ],
                LANG="en_US.UTF-8",
                LC_ALL="en_US.UTF-8",
            )
        self.assertNotIn("\x1b[31m", display)
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        self.assertEqual([line for line in lines if line], [
            "✕ build failed (7)", "    three", "    four",
            "    red", "    ab", "    seven", "    eight", "    nine", "    ten",
            "    eleven", "    twelve", f"    Log: {saved}",
        ])

    def test_terminal_selects_frames_from_the_user_locale(self):
        cases = (
            ("LANG=C", {"LANG": "C"}),
            ("LANG=POSIX", {"LANG": "POSIX"}),
            ("LC_CTYPE=C", {"LC_CTYPE": "C"}),
            ("LANG=C LC_ALL=C", {"LANG": "C", "LC_ALL": "C"}),
        )
        for name, environment in cases:
            with self.subTest(name):
                display = self.render_terminal(
                    [
                        ("step", "check", "prerequisites"),
                        ("wait", "Checking prerequisites"),
                        ("end", "0"),
                    ],
                    **environment,
                )
                self.assertIn("| Checking prerequisites", display)
                self.assertNotIn("⠋", display)

        display = self.render_terminal(
            [
                ("step", "check", "prerequisites"),
                ("wait", "Checking prerequisites"),
                ("end", "0"),
            ],
            LANG="en_US.UTF-8",
        )
        self.assertIn("⠋ Checking prerequisites", display)

    def test_terminal_sigint_streams_items_before_stopped_step(self):
        display = self.render_terminal(
            [
                ("step", "check", "links"),
                ("item", "ok", "$HOME/.zshrc linked"),
                ("wait", "Checking links"),
                ("interrupt",),
            ],
            LANG="en_US.UTF-8",
            LC_ALL="en_US.UTF-8",
        )
        lines = [line.split("\r\x1b[K")[-1] for line in display.split("\r\n")]
        self.assertEqual(
            [line for line in lines if line],
            [
                "✓ ~/.zshrc linked",
                "✕ Stopped checking links",
            ],
        )

    def run_output_shell(self, shell, code, *arguments, **environment):
        env = os.environ | {"JSH_ROOT": str(ROOT), "NO_COLOR": "1", "TERM": "dumb"}
        env.update(environment)
        result = subprocess.run(
            [shell, "-c", code, "jsh-output-check", *arguments],
            env=env,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_plain_items_match_the_renderer(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("jsh_output", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cases = [
            (kind, f"{kind} text", "")
            for kind in ("ok", "drift", "fail", "info", "notice", "output")
        ]
        cases.append(("skip", "Skipping skip text", ""))
        cases.extend(
            (kind, f"{kind} text", was)
            for kind in ("added", "changed", "removed")
            for was in ("", f"{kind} before")
        )
        cases.extend(
            [
                ("ok", "$HOME/.zshrc linked", ""),
                ("ok", str(Path.home() / ".zshrc linked"), ""),
                ("added", "$HOME/.config/jsh added", ""),
                ("changed", "$HOME/.config/jsh linked", "$HOME/.config/jsh was elsewhere"),
            ]
        )
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; case $1 in '
            'added|changed|removed) "jsh::$1" "$2" "$3" ;; '
            'skip) jsh::event item skip "$2" ;; '
            '*) "jsh::$1" "$2" ;; esac'
        )
        for shell in SHELLS:
            for preview in (False, True):
                for kind, text, was in cases:
                    with self.subTest(shell=shell, preview=preview, kind=kind, was=was):
                        result = self.run_output_shell(
                            shell,
                            code,
                            kind,
                            text,
                            was,
                            JSH_OUTPUT="plain",
                            JSH_DRY_RUN="1" if preview else "0",
                        )
                        expected = (
                            "\n".join(
                                module.format_item(
                                    kind,
                                    text,
                                    was,
                                    preview=preview,
                                )
                            )
                            + "\n"
                        )
                        self.assertEqual((result.stdout, result.stderr), (expected.encode(), b""))

    def test_events_survive_hostile_text(self):
        payload = "a\tb\nc\x1ed\x1b[31m"
        code = '. "$JSH_ROOT/lib/shell/output.sh"; jsh::ok "$1"'
        event = self.run_output_shell(
            "/bin/bash",
            code,
            payload,
            JSH_OUTPUT="renderer",
        ).stdout
        self.assertEqual(event.count(b"\n"), 1)
        result = subprocess.run(
            ["python3", str(ROOT / "lib/output.py"), "render"],
            input=event,
            env=os.environ | {"NO_COLOR": "1"},
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr), (0, "✓ a b cd\n".encode(), b"")
        )
        self.assertNotIn(b"\x1e", result.stdout)

    def test_plain_output_strips_terminal_controls(self):
        cases = (
            ("controls", "a\tb\nc\x1b[31mred\x1b[0m", "✓ abcred\n"),
            ("CSI uppercase final", "x\x1b[1AHELLO world", "✓ xHELLO world\n"),
            ("CSI erase", "\x1b[2KDownloading", "✓ Downloading\n"),
            ("OSC", "before\x1b]0;title\x07after", "✓ beforeafter\n"),
        )
        code = '. "$JSH_ROOT/lib/shell/output.sh"; jsh::ok "$1"'
        for shell in SHELLS:
            for name, payload, expected in cases:
                with self.subTest(shell=shell, case=name):
                    result = self.run_output_shell(shell, code, payload, JSH_OUTPUT="plain")
                    self.assertEqual((result.stdout, result.stderr), (expected.encode(), b""))

    def test_sessionless_failures_go_to_stderr(self):
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            "jsh::fail x; jsh::drift y; jsh::notice z; jsh::ok current"
        )
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.run_output_shell(shell, code)
                self.assertEqual(result.stdout, "✓ current\n".encode())
                self.assertEqual(result.stderr, "✕ x\n! y\n! z\n".encode())

    def test_report_records_items_skips_changes_failures_and_unique_notices(self):
        code = (
            '. "$JSH_ROOT/lib/shell/output.sh"; '
            "jsh::added a; jsh::changed b; jsh::removed c; "
            'jsh::fail "bad\nthing"; jsh::skipped optional; '
            "jsh::notice restart; jsh::notice restart"
        )
        for mode in ("plain", "renderer"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(
                prefix="jsh-report-"
            ) as directory:
                self.run_output_shell(
                    "/bin/bash",
                    code,
                    JSH_OUTPUT=mode,
                    JSH_REPORT=directory,
                )
                report = Path(directory)
                self.assertEqual(
                    (report / "items").read_text(),
                    "added\nchanged\nremoved\nfail\nskip\nnotice\nnotice\n",
                )
                self.assertEqual((report / "events").read_text(), "added\nchanged\nremoved\n")
                self.assertEqual((report / "failures").read_text(), "bad thing\n")
                self.assertEqual((report / "skips").read_text(), "Skipping optional\n")
                self.assertEqual((report / "notices").read_text(), "restart\n")

    def test_plain_steps_load_and_cache_verbs_with_raw_fallback(self):
        cached = (
            '. "$JSH_ROOT/lib/shell/output.sh"; jsh::step check one; '
            "JSH_ROOT=/missing; jsh::step check two"
        )
        fallback = 'unset JSH_ROOT; . "$1"; jsh::step check things'
        for shell in SHELLS:
            with self.subTest(shell=shell, mode="cached"):
                result = self.run_output_shell(shell, cached, JSH_OUTPUT="plain")
                self.assertEqual(result.stdout, b"Checking one...\nChecking two...\n")
            with self.subTest(shell=shell, mode="fallback"):
                result = self.run_output_shell(
                    shell,
                    fallback,
                    str(ROOT / "lib/shell/output.sh"),
                    JSH_OUTPUT="plain",
                )
                self.assertEqual(result.stdout, b"check things...\n")

    def test_no_legacy_output_helpers_remain(self):
        excluded = {
            ROOT / "bin/git",
            ROOT / "bin/kubectx",
            ROOT / "bin/kubens",
            ROOT / "bin/kubecolor",
            ROOT / "bin/colours",
        }
        paths = [ROOT / "install.sh"]
        paths.extend(
            path
            for path in (ROOT / "scripts").rglob("*")
            if path.is_file() and "__pycache__" not in path.parts
        )
        paths.extend(
            path
            for path in (ROOT / "lib").rglob("*")
            if path.is_file()
            and "__pycache__" not in path.parts
            and ROOT / "lib/git" not in path.parents
        )
        paths.extend(
            path for path in (ROOT / "bin").iterdir() if path.is_file() and path not in excluded
        )
        paths.extend(path for path in (ROOT / "dotfiles").rglob("*") if path.is_file())
        patterns = (
            re.compile(r"jsh::" + r"log_"),
            re.compile(r"jsh::" + r"emit(?=\s)"),
            re.compile(r"jsh::" + r"detail"),
            re.compile(r"jsh::" + r"status_clear"),
            re.compile(r"JSH_" + r"STATUS_TTY"),
        )
        compatibility = "# Compatibility aliases retained only for bin/git and bin/kubectx."
        offenders = []
        for path in paths:
            text = path.read_text(errors="replace")
            if path == ROOT / "lib/shell/output.sh":
                text = text.split(compatibility, 1)[0]
            for pattern in patterns:
                for match in pattern.finditer(text):
                    line = text[: match.start()].count("\n") + 1
                    offenders.append(f"{path.relative_to(ROOT)}:{line}: {match.group()}")
        self.assertEqual(offenders, [])

    def test_compat_info_alias_rechecks_color_after_redirection(self):
        alias = "jsh::" + "log_info"
        code = '. "$JSH_ROOT/lib/shell/output.sh"; ' f"_jsh_color_1=1; {alias} redirected >&2"
        result = self.run_output_shell("/bin/bash", code)
        self.assertEqual((result.stdout, result.stderr), (b"", "› redirected\n".encode()))

    def test_every_step_verb_in_the_repo_is_in_the_table(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("jsh_output", ROOT / "lib/output.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        paths = [ROOT / "install.sh"]
        paths.extend((ROOT / "scripts").rglob("*.sh"))
        paths.extend((ROOT / "lib").rglob("*.sh"))
        paths.extend(path for path in (ROOT / "bin").iterdir() if path.is_file())
        used = {
            match.group(1)
            for path in paths
            for match in re.finditer(r"jsh::step\s+(\w+)", path.read_text(errors="replace"))
        }
        self.assertEqual(used - module.verbs().keys(), set())


class AnsibleChecks(unittest.TestCase):
    """Check the Ansible bootstrap, plugins, and playbook in a temporary HOME."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jsh-ansible-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.tools = self.home / "tools"
        self.tools.mkdir()
        self.env = dict(
            HOME=str(self.home),
            PATH=f"{self.tools}:/usr/bin:/bin:/usr/sbin:/sbin",
            LANG="en_US.UTF-8",
            TMPDIR=str(self.home),
            GIT_CONFIG_NOSYSTEM="1",
        )

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def checkout(self):
        """Copy the parts of the checkout setup scripts read, so tests can change them."""
        root = self.home / "jsh"
        for part in ("scripts/lib", "lib", "ansible", "scripts/ansible.sh"):
            source = ROOT / part
            if source.is_dir():
                shutil.copytree(source, root / part, ignore=shutil.ignore_patterns("__pycache__"))
            else:
                (root / part).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, root / part)
        return root

    def mock_uv(self):
        self.tool(
            "uv",
            r"""printf '%s|%s\n' "${UV_PYTHON_PREFERENCE:-}" "$*" >> "$HOME/uv.log"
case $1 in
  venv)
    for argument; do directory=$argument; done
    mkdir -p "$directory/bin"
    printf '#!/bin/sh\nexit 0\n' > "$directory/bin/python"
    chmod +x "$directory/bin/python" ;;
  pip)
    if [ "${MOCK_PIP_FAIL:-0}" = 1 ]; then echo 'pip failed' >&2; exit 1; fi
    python=
    previous=
    for argument; do
      [ "$previous" = --python ] && python=$argument
      previous=$argument
    done
    bin=${python%/*}
    printf '#!/bin/sh\nexit 0\n' > "$bin/ansible-playbook"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$HOME/galaxy.log"\n' > "$bin/ansible-galaxy"
    chmod +x "$bin/ansible-playbook" "$bin/ansible-galaxy" ;;
esac""",
        )

    def bootstrap(self, root, *arguments, **environment):
        return subprocess.run(
            ["bash", str(root / "scripts/ansible.sh"), *arguments],
            env=self.env
            | {
                "JSH_ANSIBLE_HOME": str(self.home / "ansible"),
                "JSH_UV": str(self.tools / "uv"),
            }
            | environment,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_ansible_bootstrap_installs_then_reports_current(self):
        self.mock_uv()
        root = self.checkout()
        first = self.bootstrap(root)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("+ Ansible installed", first.stdout)
        self.assertTrue((self.home / "ansible/stamp").is_file())
        self.assertFalse((self.home / "galaxy.log").exists())
        (self.home / "uv.log").unlink()
        second = self.bootstrap(root)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("✓ Ansible is current", second.stdout)
        self.assertFalse((self.home / "uv.log").exists())

    def test_ansible_bootstrap_reinstalls_when_requirements_change(self):
        self.mock_uv()
        root = self.checkout()
        self.assertEqual(self.bootstrap(root).returncode, 0)
        requirements = root / "ansible/requirements.txt"
        requirements.write_text(requirements.read_text() + "# changed\n")
        result = self.bootstrap(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("~ Ansible updated", result.stdout)

    def test_ansible_bootstrap_reinstalls_when_interpreter_is_missing(self):
        self.mock_uv()
        root = self.checkout()
        self.assertEqual(self.bootstrap(root).returncode, 0)
        playbook = self.home / "ansible/venv/bin/ansible-playbook"
        playbook.write_text("#!/missing/python\n")
        result = self.bootstrap(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("~ Ansible updated", result.stdout)
        self.assertEqual(subprocess.run([str(playbook)]).returncode, 0)

    def test_ansible_bootstrap_reinstalls_when_environment_moves(self):
        self.mock_uv()
        root = self.checkout()
        self.assertEqual(self.bootstrap(root).returncode, 0)
        moved = self.home / "moved-ansible"
        shutil.copytree(self.home / "ansible", moved)
        result = self.bootstrap(root, JSH_ANSIBLE_HOME=str(moved))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("~ Ansible updated", result.stdout)

    def test_ansible_bootstrap_failure_writes_no_stamp(self):
        self.mock_uv()
        root = self.checkout()
        result = self.bootstrap(root, MOCK_PIP_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((self.home / "ansible/stamp").exists())
        self.assertIn("✕", result.stdout + result.stderr)

    def test_ansible_bootstrap_dry_run_changes_nothing(self):
        self.mock_uv()
        root = self.checkout()
        result = self.bootstrap(root, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("would add", result.stdout)
        self.assertFalse((self.home / "ansible").exists())
        self.assertFalse((self.home / "uv.log").exists())

    def venv(self, name):
        path = ROOT / "local/ansible/venv/bin" / name
        if not path.exists():
            self.fail(f"{path} is missing; run ./scripts/ansible.sh")
        return path

    def ansible_env(self, **environment):
        return (
            self.env
            | {
                "ANSIBLE_CONFIG": str(ROOT / "ansible/ansible.cfg"),
                "ANSIBLE_CACHE_PLUGIN_CONNECTION": str(self.home / "facts"),
                "ANSIBLE_NOCOLOR": "1",
                "JSH_ROOT": str(ROOT),
            }
            | environment
        )

    def playbook(self, playbook, *arguments, limit="localhost", **environment):
        # defaults writes the real user's preferences whatever HOME is, so osx_defaults gets a
        # stub that refuses; a check that needs it passes its own macos_defaults_path later.
        blocked = self.home / "blocked"
        if not blocked.is_dir():
            blocked.mkdir()
            stub = blocked / "defaults"
            stub.write_text(
                "#!/bin/sh\necho 'checks must not write real macOS preferences' >&2\nexit 1\n"
            )
            stub.chmod(0o755)
        guard = json.dumps({"macos_defaults_path": str(blocked)})
        return subprocess.run(
            [
                str(self.venv("ansible-playbook")),
                str(playbook),
                "-e",
                guard,
                *(["--limit", limit] if limit else []),
                *arguments,
            ],
            env=self.ansible_env(**environment),
            cwd=self.home,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=180,
        )

    def test_playbook_uses_the_venv_python(self):
        # Only an explicit inventory host can lose the controller's Python to discovery.
        inventory = subprocess.run(
            [str(self.venv("ansible-inventory")), "--list"],
            env=self.ansible_env(),
            cwd=self.home,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(inventory.returncode, 0, inventory.stdout + inventory.stderr)
        self.assertIn("localhost", json.loads(inventory.stdout)["ungrouped"]["hosts"])
        result = subprocess.run(
            [
                str(self.venv("ansible")),
                "localhost",
                "-m",
                "ansible.builtin.setup",
                "-a",
                "filter=ansible_python",
            ],
            env=self.ansible_env(),
            cwd=self.home,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        facts = json.loads(result.stdout.split("=>", 1)[1])
        executable = facts["ansible_facts"]["ansible_python"]["executable"]
        self.assertTrue(executable.startswith(str(ROOT / "local/ansible/venv/")), executable)

    def test_playbook_detects_platform_desktop_and_host(self):
        site = ROOT / "ansible/site.yml"
        # No role has the facts tag, so only the always-tagged detection tasks run.
        named = self.playbook(
            site,
            "--check",
            "--tags",
            "facts",
            "-e",
            "jsh_debug_facts=true",
            JSH_PLATFORM="rhel",
            JSH_DESKTOP="xfce",
            JSH_HOST="colossus",
        )
        self.assertEqual(named.returncode, 0, named.stdout + named.stderr)
        self.assertIn("rhel xfce colossus", named.stdout)
        detected = self.playbook(site, "--check", "--tags", "facts", "-e", "jsh_debug_facts=true")
        self.assertEqual(detected.returncode, 0, detected.stdout + detected.stderr)
        host = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
        platform = "darwin" if os.uname().sysname == "Darwin" else ""
        if platform:
            self.assertIn(f"darwin darwin {host}", detected.stdout)

    def test_inventory_hosts_match_host_vars(self):
        result = subprocess.run(
            [str(self.venv("ansible-inventory")), "--list"],
            env=self.ansible_env(),
            cwd=self.home,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        inventory = json.loads(result.stdout)
        hosts = set(inventory["_meta"]["hostvars"])
        expected = {"localhost"} | {
            path.stem for path in (ROOT / "ansible/host_vars").glob("*.yml")
        }
        self.assertEqual(hosts, expected)
        self.assertTrue({"archon", "colossus"} <= hosts)
        for name in ("archon.yml", "colossus.yml"):
            self.assertFalse((ROOT / "ansible/group_vars" / name).exists(), name)

    def test_site_refuses_more_than_one_host(self):
        result = self.playbook(ROOT / "ansible/site.yml", "--check", "--tags", "facts", limit=None)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--limit", result.stdout + result.stderr)

    def test_playbook_limits_unknown_host_to_localhost(self):
        checkout = self.installer_fixture()
        (checkout / "ansible/host_vars").mkdir(parents=True)
        (checkout / "ansible/host_vars/colossus.yml").write_text("---\n{}\n")
        self.mock_playbook()
        for host, limit in (
            ("newbox", "localhost"),
            ("colossus", "colossus"),
            ("Colossus", "colossus"),
        ):
            with self.subTest(host=host):
                result = subprocess.run(
                    ["bash", str(checkout / "scripts/configure.sh"), "--dry-run", "desktop"],
                    env=self.env
                    | {
                        "JSH_PLATFORM": "darwin",
                        "JSH_HOST": host,
                        "JSH_ANSIBLE_HOME": str(self.home / "ansible"),
                    },
                    cwd=self.home,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                call = (self.home / "playbook.log").read_text().splitlines()[-1]
                self.assertIn(f"--limit {limit} ", call)

    def test_site_groups_have_matching_role_metadata(self):
        script = (
            "import json, sys, yaml\n"
            "root = sys.argv[1]\n"
            "play = yaml.safe_load(open(root + '/ansible/site.yml'))[0]\n"
            "def includes(tasks):\n"
            "    for task in tasks or []:\n"
            "        if 'ansible.builtin.include_role' in task: yield task\n"
            "        yield from includes(task.get('block'))\n"
            "        yield from includes(task.get('rescue'))\n"
            "        yield from includes(task.get('always'))\n"
            "rows = []\n"
            "for task in includes(play.get('tasks')):\n"
            "    name = task['ansible.builtin.include_role']['name']\n"
            "    meta = yaml.safe_load(open(f'{root}/ansible/roles/{name}/meta/main.yml'))\n"
            "    info = meta['galaxy_info']\n"
            "    names = tuple(platform['name'] for platform in info['platforms'])\n"
            "    platform = {('MacOSX',): 'darwin', "
            "('Debian', 'EL'): 'linux', "
            "('MacOSX', 'Debian', 'EL'): "
            "'all'}[names]\n"
            "    rows.append([name, platform, info['description'], task])\n"
            "print(json.dumps(rows))\n"
        )
        result = subprocess.run(
            [str(self.venv("python")), "-c", script, str(ROOT)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        groups = json.loads(result.stdout)
        self.assertEqual(len({name for name, _, _, _ in groups}), len(groups))
        self.assertTrue({"app", "link"}.isdisjoint(name for name, _, _, _ in groups))
        names = [name for name, _, _, _ in groups]
        owners = list(
            self.yaml_file(ROOT / "ansible/group_vars/all/packages.yml")["packages_roles"]
        )
        self.assertIn("packages", names)
        for owner in owners:
            self.assertIn(owner, names[names.index("packages") + 1 :], owner)
        for name, platform, purpose, task in groups:
            self.assertNotEqual(purpose, "", name)
            tags = ["packages"] + owners if name == "packages" else [name]
            self.assertEqual(task.get("tags"), tags, name)
            self.assertEqual(
                task["ansible.builtin.include_role"].get("apply"), {"tags": tags}, name
            )
            expected = {
                "all": None,
                "darwin": "jsh_platform == 'darwin'",
                "linux": "jsh_platform != 'darwin'",
            }[platform]
            self.assertEqual(task.get("when"), expected, name)

    def test_config_roles_have_no_package_dependency(self):
        roles = ROOT / "ansible/roles"
        for meta in roles.glob("*/meta/main.yml"):
            data = self.yaml_file(meta)
            dependencies = [
                entry.get("role") if isinstance(entry, dict) else entry
                for entry in data.get("dependencies") or []
            ]
            self.assertNotIn("packages", dependencies, meta)
        for defaults in roles.glob("*/defaults/main.yml"):
            keys = self.yaml_file(defaults) or {}
            self.assertEqual([key for key in keys if key.endswith("_packages")], [], defaults)
        for path in roles.rglob("*.yml"):
            self.assertNotIn("app_apply", path.read_text(), path)

    def test_role_file_paths_exist(self):
        script = r"""
import json, re, subprocess, sys, yaml
from pathlib import Path
root = Path(sys.argv[1])
missing = []
tracked = subprocess.run(["git", "-C", str(root), "ls-files", "ansible", "bin", "install.sh",
                          "dotfiles"], capture_output=True, text=True, check=True).stdout.split()
for name in tracked:
    path = root / name
    if not path.is_file() or path.suffix in (".jpg", ".png", ".svg", ".pyc"):
        continue
    text = path.read_text(errors="replace")
    for role, rest in re.findall(r"ansible/roles/([a-z]+)/files/([A-Za-z0-9_./%-]+)", text):
        rest = rest.rstrip(".").replace("%s", "muted")
        if not (root / "ansible/roles" / role / "files" / rest).exists():
            missing.append(f"{name}: ansible/roles/{role}/files/{rest}")
def tasks(items):
    for task in items or []:
        if isinstance(task, dict):
            yield task
            for key in ("block", "rescue", "always"):
                yield from tasks(task.get(key))
for role in sorted((root / "ansible/roles").iterdir()):
    for path in sorted(role.rglob("*.yml")):
        text = path.read_text()
        relative = re.findall(r"role_path\s*[~+]\s*['\"]/files/([^'\"]+)['\"]", text)
        relative += re.findall(r"\{\{ role_path \}\}/files/([A-Za-z0-9_./-]+)", text)
        for rest in relative:
            if not (role / "files" / rest).exists():
                missing.append(f"{path.relative_to(root)}: files/{rest}")
        if path.parent.name not in ("tasks", "handlers") and "tasks" not in path.parts:
            continue
        for task in tasks(yaml.safe_load(text)):
            for module, folder in (("ansible.builtin.copy", "files"),
                                   ("ansible.builtin.template", "templates")):
                args = task.get(module)
                if not isinstance(args, dict) or args.get("remote_src"):
                    continue
                source = str(args.get("src", ""))
                if source and "{{" not in source and not (role / folder / source).exists():
                    missing.append(f"{path.relative_to(root)}: {folder}/{source}")
print(json.dumps(missing))
"""
        result = subprocess.run(
            [str(self.venv("python")), "-c", script, str(ROOT)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_role_includes_target_existing_roles_and_their_variables(self):
        script = r"""
import json, sys, yaml
from pathlib import Path
roles = Path(sys.argv[1]) / "ansible/roles"
problems = []
def tasks(items):
    for task in items or []:
        if isinstance(task, dict):
            yield task
            for key in ("block", "rescue", "always"):
                yield from tasks(task.get(key))
for path in sorted(roles.glob("*/tasks/**/*.yml")):
    for task in tasks(yaml.safe_load(path.read_text())):
        args = task.get("ansible.builtin.include_role") or task.get("ansible.builtin.import_role")
        if not isinstance(args, dict) or "{{" in str(args.get("name")):
            continue
        name, where = args["name"], str(path.relative_to(roles))
        if not (roles / name).is_dir():
            problems.append(f"{where}: role {name} is missing")
            continue
        source = args.get("tasks_from")
        if source and "{{" not in source:
            source = source if source.endswith(".yml") else source + ".yml"
            if not (roles / name / "tasks" / source).is_file():
                problems.append(f"{where}: {name}/tasks/{source} is missing")
        for key in task.get("vars") or {}:
            if not key.startswith(name + "_"):
                problems.append(f"{where}: {key} is not a {name}_ variable")
print(json.dumps(problems))
"""
        result = subprocess.run(
            [str(self.venv("python")), "-c", script, str(ROOT)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_desktop_role_runs_all_areas_in_order(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/desktop/tasks/main.yml")
        includes = [
            (task["ansible.builtin.include_tasks"], task.get("when"))
            for task in tasks
            if "ansible.builtin.include_tasks" in task
        ]
        linux = "jsh_platform != 'darwin'"
        self.assertEqual(
            includes,
            [
                ("fonts/main.yml", None),
                ("appearance/main.yml", linux),
                ("dock/main.yml", linux),
                ("display/main.yml", None),
                ("keybindings/main.yml", None),
                ("audio/main.yml", linux),
                ("wallpaper/main.yml", None),
            ],
        )
        meta = self.yaml_file(ROOT / "ansible/roles/desktop/meta/main.yml")
        self.assertEqual(
            [item["name"] for item in meta["galaxy_info"]["platforms"]], ["MacOSX", "Debian", "EL"]
        )

    def test_patches_role_runs_areas_in_order(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/patches/tasks/main.yml")
        self.assertEqual(
            [(task.get("ansible.builtin.include_tasks"), task.get("when")) for task in tasks],
            [
                ("vscode/main.yml", None),
                ("sublime/main.yml", None),
                ("helium/main.yml", None),
                ("waterfox/main.yml", None),
            ],
        )

    def test_patches_owns_its_four_apps_packages(self):
        data = ROOT / "ansible/group_vars/all/packages.yml"
        result = self.packages_filter(
            f"data = yaml.safe_load(open({str(data)!r}))\n"
            "print(json.dumps(selection('darwin', 'darwin', ['patches'], data['packages_common'],\n"
            "                           data['packages_roles'])))\n"
        )
        self.assertEqual(
            result, {"casks": ["visual-studio-code", "sublime-text", "helium-browser", "waterfox"]}
        )

    def test_merged_roles_never_end_the_role(self):
        for role in ("desktop", "patches", "agentics"):
            folder = ROOT / "ansible/roles" / role / "tasks"
            for path in folder.rglob("*.yml") if folder.is_dir() else []:
                self.assertNotIn("end_role", path.read_text(), path)

    def test_shell_roles_follow_site_and_role_metadata(self):
        root = self.home / "groups"
        (root / "scripts/lib").mkdir(parents=True)
        (root / "ansible/roles/beta/meta").mkdir(parents=True)
        (root / "ansible/roles/alpha/meta").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/lib/common.sh", root / "scripts/lib/common.sh")
        shutil.copytree(ROOT / "lib", root / "lib")
        (root / "ansible/site.yml").write_text(
            "---\n- hosts: localhost\n  tasks:\n"
            "    - name: beta\n      ansible.builtin.include_role:\n        name: beta\n"
            "        apply: {tags: [beta]}\n      tags: [beta]\n"
            "      when: jsh_platform == 'darwin'\n"
            "    - name: alpha\n      ansible.builtin.include_role:\n        name: alpha\n"
            "        apply: {tags: [alpha]}\n      tags: [alpha]\n"
        )
        (root / "ansible/roles/beta/meta/main.yml").write_text(
            "---\ngalaxy_info:\n  description: Beta purpose\n  platforms:\n"
            "    - name: MacOSX\n      versions: [all]\ndependencies: []\n"
        )
        (root / "ansible/roles/alpha/meta/main.yml").write_text(
            "---\ngalaxy_info:\n  description: Alpha purpose\n  platforms:\n"
            "    - name: MacOSX\n      versions: [all]\n"
            "    - name: Debian\n      versions: [all]\n"
            "    - name: EL\n      versions: [all]\ndependencies: []\n"
        )
        expected = {
            ("darwin", ""): "beta\nalpha\n",
            ("darwin", "here"): "beta\nalpha\n",
            ("linux", "here"): "alpha\n",
            ("darwin", "table"): "beta\tBeta purpose\nalpha\tAlpha purpose\n",
        }
        for (platform, view), output in expected.items():
            with self.subTest(platform=platform, view=view):
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        '. "$JSH_ROOT/scripts/lib/common.sh"; jsh::roles "$1"',
                        "test",
                        view,
                    ],
                    env=self.env
                    | {"JSH_ROOT": str(root), "JSH_OUTPUT": "plain", "JSH_PLATFORM": platform},
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, output, ""))

    def run_play(self, tasks, *arguments, roles=None, **environment):
        """Run a playbook with the jsh callback and return (result, events)."""
        play = self.home / "play"
        for name, body in (roles or {}).items():
            (play / "roles" / name / "tasks").mkdir(parents=True, exist_ok=True)
            (play / "roles" / name / "tasks/main.yml").write_text(body)
        play.mkdir(exist_ok=True)
        (play / "site.yml").write_text(
            "- hosts: localhost\n  gather_facts: false\n  tasks:\n" + tasks
        )
        result = self.playbook(
            play / "site.yml",
            *arguments,
            **{
                "ANSIBLE_STDOUT_CALLBACK": "jsh",
                "ANSIBLE_ROLES_PATH": str(play / "roles"),
                "JSH_OUTPUT": "renderer",
                "JSH_PLATFORM": "darwin",
            }
            | environment,
        )
        # str.splitlines() also splits at the \x1e marker itself.
        events = [
            line[1:].split("\t") for line in result.stdout.split("\n") if line.startswith("\x1e")
        ]
        return result, [event for event in events if event[0] != "progress"]

    def purpose(self, group):
        meta = ROOT / f"ansible/roles/{group}/meta/main.yml"
        for line in meta.read_text().splitlines():
            if line.startswith("  description: "):
                return line.removeprefix("  description: ")
        self.fail(group)

    def test_callback_reports_ok_added_changed_removed_and_loop_labels(self):
        for name in ("a", "b"):
            (self.home / name).write_text("same\n")
        target = self.home / "new"
        role = f"""- name: new file exists
  ansible.builtin.copy: {{content: "x\\n", dest: "{target}"}}
- name: new file is current
  ansible.builtin.copy: {{content: "x\\n", dest: "{target}"}}
- name: new file has y
  ansible.builtin.lineinfile: {{path: "{target}", line: "y"}}
- name: new file is gone
  ansible.builtin.file: {{path: "{target}", state: absent}}
- name: copies are current
  ansible.builtin.copy: {{content: "same\\n", dest: "{self.home}/{{{{ item }}}}"}}
  loop: [a, b]
"""
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            "--diff",
            roles={"macos": role},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            events,
            [
                ["group", "macos", self.purpose("macos")],
                ["step", "check", "macos"],
                ["item", "added", "new file exists"],
                ["item", "ok", "new file is current"],
                ["item", "changed", "new file has y"],
                ["item", "removed", "new file is gone"],
                ["item", "ok", "a"],
                ["item", "ok", "b"],
                ["stepclose"],
            ],
        )

    def test_callback_check_mode_reports_drift_and_diff_lines(self):
        target = self.home / "file"
        target.write_text("a\n")
        role = f"""- name: file has b
  ansible.builtin.lineinfile: {{path: "{target}", line: "b"}}
"""
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            "--check",
            "--diff",
            roles={"macos": role},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "changed", "file has b"], events)
        outputs = [event[2] for event in events if event[:2] == ["item", "output"]]
        self.assertTrue(any(line.startswith(("+", "-")) for line in outputs), events)
        self.assertEqual(target.read_text(), "a\n")

    def test_callback_turns_sudo_password_failure_into_notice(self):
        self.tool("sudo", "echo 'sudo: a password is required' >&2\nexit 1")
        role = "- name: root file exists\n  ansible.builtin.command: 'true'\n  become: true\n"
        started = time.monotonic()
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            roles={"macos": role},
        )
        self.assertLess(time.monotonic() - started, 30)
        self.assertNotEqual(result.returncode, 0)
        kinds = [event[1] for event in events if event[0] == "item"]
        self.assertIn("fail", kinds, events)
        self.assertIn(["item", "notice", "run `sudo -v` first, then rerun"], events)

    def test_callback_passes_helper_events_through(self):
        role = r"""- name: helper ran
  ansible.builtin.command: printf '\036item\tadded\tx installed\t\n'
  register: helper
  changed_when: helper.stdout is reported_change
"""
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            roles={"macos": role},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        items = [event for event in events if event[0] == "item"]
        self.assertEqual(items, [["item", "added", "x installed", ""]])

    def test_callback_closes_helper_step_before_later_tasks(self):
        role = r"""- name: helper ran
  ansible.builtin.command: printf '\036step\tcheck\thelper thing\n\036item\tok\tthing\n'
  register: helper
  changed_when: false
- name: later file is current
  ansible.builtin.command: 'true'
"""
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            roles={"macos": role},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            events,
            [
                ["group", "macos", self.purpose("macos")],
                ["step", "check", "helper thing"],
                ["item", "ok", "thing"],
                ["stepclose"],
                ["step", "check", "macos"],
                ["item", "changed", "later file is current"],
                ["stepclose"],
            ],
        )

    def test_callback_handler_start_uses_ansibles_handler_signature(self):
        import ast

        tree = ast.parse((ROOT / "ansible/plugins/callback/jsh.py").read_text())
        callback = next(
            node
            for node in tree.body
            if isinstance(node, ast.ClassDef) and node.name == "CallbackModule"
        )
        handler = next(
            node
            for node in callback.body
            if isinstance(node, ast.FunctionDef)
            and node.name == "v2_playbook_on_handler_task_start"
        )
        self.assertEqual([argument.arg for argument in handler.args.args], ["self", "task"])

    def test_callback_skipped_include_prints_platform_skip(self):
        result, events = self.run_play(
            "    - name: services\n      ansible.builtin.include_role: {name: services}\n"
            "      when: jsh_platform != 'darwin'\n"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "skip", "Skipping services on macOS: Linux only"], events)

    def test_callback_notice_task_adds_notice(self):
        role = (
            "- name: notice\n  ansible.builtin.debug: {msg: quit X}\n"
            '- name: ok\n  ansible.builtin.debug: {msg: "{{ item }}"}\n  loop: [jq, git]\n'
        )
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            roles={"macos": role},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "notice", "quit X"], events)
        self.assertIn(["item", "ok", "jq"], events)
        self.assertIn(["item", "ok", "git"], events)

    def installer_fixture(self):
        checkout = self.home / "checkout"
        for name in ("scripts/lib", "lib/shell", "bin", "dotfiles", "ansible/roles/desktop/tasks"):
            (checkout / name).mkdir(parents=True)
        for name in (
            "scripts/lib/common.sh",
            "lib/shell/output.sh",
            "lib/output.py",
            "lib/verbs.tsv",
            "install.sh",
            "scripts/configure.sh",
        ):
            shutil.copy2(ROOT / name, checkout / name)
        copy_group_sources(checkout)
        (self.home / ".jsh").symlink_to(checkout)
        (checkout / "scripts/packages.sh").write_text("exit 0\n")
        (checkout / "scripts/shell.sh").write_text("exit 0\n")
        (checkout / "scripts/ansible.sh").write_text("exit 0\n")
        (checkout / "scripts/desktop.sh").write_text('touch "$HOME/desktop-script-ran"\n')
        (checkout / "ansible/roles/desktop/tasks/main.yml").write_text("[]\n")
        return checkout

    def mock_playbook(self):
        bin_dir = self.home / "ansible/venv/bin"
        bin_dir.mkdir(parents=True)
        path = bin_dir / "ansible-playbook"
        path.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$HOME/playbook.log"\n')
        path.chmod(0o755)

    def configure(self, checkout, *arguments):
        return subprocess.run(
            ["bash", str(checkout / "scripts/configure.sh"), *arguments],
            env=self.env
            | {"JSH_PLATFORM": "darwin", "JSH_ANSIBLE_HOME": str(self.home / "ansible")},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_configure_runs_ansible_for_ported_groups(self):
        checkout = self.installer_fixture()
        self.mock_playbook()
        result = self.configure(checkout, "--dry-run", "desktop")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = (self.home / "playbook.log").read_text()
        self.assertIn("--tags desktop --check --diff", log)
        self.assertFalse((self.home / "desktop-script-ran").exists())
        (self.home / "playbook.log").unlink()
        result = self.configure(checkout, "--update", "desktop")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = (self.home / "playbook.log").read_text()
        self.assertIn('"jsh_update": true', log)
        self.assertNotIn("--check", log)

    def test_configure_dry_run_without_ansible_skips_groups(self):
        checkout = self.installer_fixture()
        result = self.configure(checkout, "--dry-run", "desktop")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Skipping desktop preview: Ansible is not installed yet", result.stdout)
        self.assertFalse((self.home / "ansible").exists())

    def settings(self, **arguments):
        preview = ["--check", "--diff"] if arguments.pop("_check", False) else []
        result = subprocess.run(
            [
                str(self.venv("ansible")),
                "localhost",
                "-m",
                "settings",
                "-a",
                json.dumps(arguments),
                *preview,
            ],
            env=self.ansible_env(),
            cwd=self.home,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )
        # Ad-hoc output prints any diff first, then "localhost | STATUS => {json}".
        return result, json.loads(result.stdout.rsplit("=>", 1)[1])

    def test_settings_deep_merges_and_keeps_unmanaged_keys(self):
        target = self.home / "settings.json"
        target.write_text('{"a": {"x": 1, "y": 2}, "k": true}\n')
        result, output = self.settings(path=str(target), values={"a": {"y": 3}})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output["changed"])
        self.assertEqual(json.loads(target.read_text()), {"a": {"x": 1, "y": 3}, "k": True})
        result, output = self.settings(path=str(target), values={"a": {"y": 3}})
        self.assertFalse(output["changed"], result.stdout)

    def test_settings_reads_jsonc_target(self):
        target = self.home / "settings.json"
        target.write_text('{\n  // line\n  "url": "http://x", /* block */\n  "a": [1, 2,],\n}\n')
        result, output = self.settings(path=str(target), values={"b": 1})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(target.read_text()), {"url": "http://x", "a": [1, 2], "b": 1})

    def test_settings_invalid_target_fails_without_writing(self):
        target = self.home / "settings.json"
        target.write_bytes(b'{"a":')
        result = subprocess.run(
            [
                str(self.venv("ansible")),
                "localhost",
                "-m",
                "settings",
                "-a",
                json.dumps({"path": str(target), "values": {"b": 1}}),
            ],
            env=self.ansible_env(),
            cwd=self.home,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("left unchanged", result.stdout + result.stderr)
        self.assertEqual(target.read_bytes(), b'{"a":')

    def test_settings_overlays_apply_in_order(self):
        source = self.home / "source.json"
        source.write_text('{"a": 1}\n')
        overlay = self.home / "overlay.json"
        overlay.write_text('{"a": 2}\n')
        target = self.home / "settings.json"
        result, output = self.settings(
            path=str(target),
            source=str(source),
            overlays=[str(overlay), str(self.home / "missing.json")],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(target.read_text()), {"a": 2})

    def test_settings_check_mode_writes_nothing_and_shows_diff(self):
        target = self.home / "settings.json"
        target.write_text('{"a": 1}\n')
        result, output = self.settings(path=str(target), values={"new": 1}, _check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output["changed"])
        self.assertIn('+  "new": 1', result.stdout)
        self.assertEqual(target.read_text(), '{"a": 1}\n')

    def test_settings_shallow_and_replace(self):
        target = self.home / "settings.json"
        target.write_text('{"a": {"x": 1}, "b": 1}\n')
        self.settings(path=str(target), values={"a": {"y": 1}}, merge="shallow")
        self.assertEqual(json.loads(target.read_text()), {"a": {"y": 1}, "b": 1})
        self.settings(path=str(target), values={"c": 1}, merge="replace")
        self.assertEqual(json.loads(target.read_text()), {"c": 1})

    def test_settings_removes_absent_paths(self):
        target = self.home / "settings.json"
        target.write_text('{"mcp": {"notion": {"url": "x"}, "rea": {}}, "a": 1}\n')
        result, output = self.settings(
            path=str(target), values={"a": 1}, absent=[["mcp", "notion"], ["missing", "key"]]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output["changed"])
        self.assertEqual(json.loads(target.read_text()), {"mcp": {"rea": {}}, "a": 1})
        result, output = self.settings(
            path=str(target), values={"a": 1}, absent=[["mcp", "notion"]]
        )
        self.assertFalse(output["changed"], result.stdout)

    def app_play(self, target, *arguments, apply_fails=False, **environment):
        self.tool("pgrep", '[ -e "$HOME/closed" ] && exit 1\necho 123')
        self.tool("osascript", 'touch "$HOME/closed"\nprintf "%s\\n" "$*" >> "$HOME/osascript.log"')
        self.tool("pkill", 'touch "$HOME/closed"')
        self.tool("helium-launch", 'rm -f "$HOME/closed"\ntouch "$HOME/launched"')
        settings = f'  settings: {{path: "{target}", values: {{managed: true}}}}\n'
        main = (
            "- name: Helium settings are pending\n"
            + settings
            + "  check_mode: true\n  register: pending\n"
            "- name: Helium restarts for its settings\n"
            "  ansible.builtin.include_role:\n    name: app\n"
            "  vars:\n    app_label: Helium\n    app_process: Helium\n"
            f'    app_launch: ["{self.tools}/helium-launch"]\n'
            "    app_role: patches\n    app_tasks: apply.yml\n"
            '    app_pending: "{{ pending is changed }}"\n'
        )
        apply = (
            (
                "- name: Helium settings fail\n"
                "  ansible.builtin.command: /usr/bin/false\n"
                "  changed_when: false\n"
            )
            if apply_fails
            else "- name: Helium settings\n" + settings
        )
        play = self.home / "play/roles/patches/tasks"
        play.mkdir(parents=True)
        (play / "apply.yml").write_text(apply)
        return self.run_play(
            "    - name: patches\n      ansible.builtin.include_role: {name: patches}\n",
            *arguments,
            roles={"patches": main},
            ANSIBLE_ROLES_PATH=f"{self.home / 'play/roles'}:{ROOT / 'ansible/roles'}",
            **environment,
        )

    def test_app_role_closes_applies_and_reopens(self):
        target = self.home / "settings.json"
        target.write_text('{"user": 1}\n')
        result, events = self.app_play(target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        items = [event[1:3] for event in events if event[0] == "item"]
        self.assertEqual(
            items,
            [
                ["info", "Closing Helium"],
                ["changed", "Helium settings"],
                ["info", "Reopening Helium"],
                ["changed", "Helium restarted"],
            ],
        )
        self.assertTrue((self.home / "launched").exists())
        self.assertEqual(json.loads(target.read_text()), {"user": 1, "managed": True})

    def test_app_role_keep_apps_skips_with_notice(self):
        target = self.home / "settings.json"
        target.write_text('{"user": 1}\n')
        result, events = self.app_play(target, JSH_KEEP_APPS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            ["item", "notice", "quit Helium, then run `jsh update` to apply its settings"], events
        )
        self.assertEqual(target.read_text(), '{"user": 1}\n')
        self.assertFalse((self.home / "osascript.log").exists())

    def test_app_role_preview_lists_settings_once(self):
        target = self.home / "settings.json"
        target.write_text('{"user": 1}\n')
        result, events = self.app_play(target, "--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        items = [event[1:3] for event in events if event[0] == "item"]
        self.assertEqual(
            items,
            [
                ["notice", "Helium must close and reopen for pending changes"],
                ["changed", "Helium settings"],
            ],
        )
        self.assertEqual(target.read_text(), '{"user": 1}\n')

    def personalization_play(self, group, variables, *arguments, tasks_from=None, **environment):
        variables = {
            "jsh_update": False,
            "jsh_keep_apps": False,
            "jsh_wallpaper": "",
            "jsh_script_env": {
                "JSH_ROOT": str(ROOT),
                "JSH_PLATFORM": environment.get("JSH_PLATFORM", "darwin"),
                "JSH_DESKTOP": environment.get("JSH_DESKTOP", "darwin"),
                "JSH_HOST": "test",
                "JSH_UPDATE": "0",
                "JSH_KEEP_APPS": "0",
                "JSH_DRY_RUN": "1" if "--check" in arguments else "0",
                "JSH_OUTPUT": "renderer",
            },
        } | variables
        target = (
            f"{{name: {group}, tasks_from: {tasks_from}}}" if tasks_from else f"{{name: {group}}}"
        )
        include = f"    - name: {group}\n" f"      ansible.builtin.include_role: {target}\n"
        return self.run_play(
            include,
            *arguments,
            "-e",
            json.dumps(variables),
            ANSIBLE_ROLES_PATH=str(ROOT / "ansible/roles"),
            **environment,
        )

    @unittest.skipUnless(os.uname().sysname == "Darwin", "writes LaunchServices defaults")
    def test_apps_role_replaces_only_stale_markdown_handlers(self):
        import plistlib

        domain = str(self.home / "launch-services")
        plist = self.home / "handlers.plist"
        handlers = [
            {"LSHandlerContentType": "public.text", "LSHandlerRoleAll": "other.app"},
            {
                "LSHandlerContentTag": "mdx",
                "LSHandlerContentTagClass": "public.filename-extension",
                "LSHandlerRoleAll": "other.app",
            },
        ]
        with plist.open("wb") as stream:
            plistlib.dump({"LSHandlers": handlers}, stream)
        subprocess.run(["defaults", "import", domain, str(plist)], check=True)
        macdown = self.home / "MacDown 3000.app"
        macdown.mkdir()
        result, events = self.personalization_play(
            "apps",
            {
                "apps_macdown_application": str(macdown),
                "apps_launchservices_domain": domain,
                "apps_decoder_enabled": False,
                "apps_restart_launchservices": False,
            },
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        exported = subprocess.run(
            ["defaults", "export", domain, "-"], check=True, capture_output=True
        ).stdout
        updated = plistlib.loads(exported)["LSHandlers"]
        self.assertEqual(
            next(item for item in updated if item.get("LSHandlerContentType") == "public.text"),
            handlers[0],
        )
        mdx = [item for item in updated if item.get("LSHandlerContentTag") == "mdx"]
        self.assertEqual(
            mdx,
            [
                {
                    "LSHandlerContentTag": "mdx",
                    "LSHandlerContentTagClass": "public.filename-extension",
                    "LSHandlerPreferredVersions": {"LSHandlerRoleAll": "-"},
                    "LSHandlerRoleAll": "app.macdown.macdown3000",
                }
            ],
        )
        changed = [event[2] for event in events if event[:2] == ["item", "changed"]]
        self.assertEqual(len(changed), 1)
        self.assertIn(".mdx", changed[0])

    @unittest.skipUnless(os.uname().sysname == "Darwin", "reads macOS defaults")
    def test_keybindings_role_applies_integer_and_menu_shortcuts(self):
        domain = str(self.home / "keyboard")
        subprocess.run(["defaults", "write", domain, "KeyRepeat", "-int", "1"], check=True)
        variables = {
            "desktop_keybindings_domain": domain,
            "desktop_keybindings_keyboard": {"KeyRepeat": 2},
            "desktop_keybindings_menu_shortcuts": {"Test Menu": "@x"},
        }
        result, events = self.personalization_play(
            "desktop", variables, tasks_from="keybindings/main.yml"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        items = [event[1:3] for event in events if event[0] == "item"]
        self.assertEqual(
            items, [["changed", "KeyRepeat is 2"], ["changed", "Test Menu shortcut is @x"]]
        )
        result, events = self.personalization_play(
            "desktop", variables, tasks_from="keybindings/main.yml"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            [event[1:3] for event in events if event[0] == "item"],
            [["ok", "KeyRepeat is 2"], ["ok", "Test Menu shortcut is @x"]],
        )

    def test_display_role_reports_resolution_profile(self):
        self.tool("displayplacer", "exit 0")
        self.tool(
            "xcrun",
            'if [ "$1" = --find ]; then exit 0; fi\nprintf "id:1 res:1728x1117 scaling:on\\tBuilt-in display 1\\t300x200 mm\\t1728x1117\\t3456x2234\\ton\\t110.0\\t1728x1117\\t3456x2234\\ton\\t110.0\\n"',
        )
        result, events = self.personalization_play("desktop", {}, tasks_from="display/main.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            ["item", "ok", "Built-in display 1 resolution is 1728x1117 (3456x2234, scaling on)"],
            events,
        )

    def test_wox_disables_clipboard_shortcut_without_changing_other_settings(self):
        database = self.home / "wox.db"
        entries = [
            {"Hotkey": "Cmd+Shift+V", "Query": "cb ", "Disabled": False},
            {"Hotkey": "Cmd+Shift+X", "Query": "other", "Disabled": False},
        ]
        with sqlite3.connect(database) as db:
            db.execute("CREATE TABLE wox_settings (key TEXT PRIMARY KEY, value TEXT)")
            db.executemany(
                "INSERT INTO wox_settings VALUES (?, ?)",
                [
                    ("MainHotkey@darwin", "cmd+space"),
                    ("QueryHotkeys@darwin", json.dumps(entries)),
                ],
            )
        application = self.home / "Wox.app"
        application.mkdir()
        self.tool("pgrep", "echo 123")
        result, _ = self.personalization_play(
            "wox",
            {
                "wox_application": str(application),
                "wox_agent_path": str(self.home / "jsh.wox.plist"),
                "wox_database": str(database),
                "wox_native_shortcuts": False,
                "jsh_keep_apps": True,
            },
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with sqlite3.connect(database) as db:
            value = db.execute(
                "SELECT value FROM wox_settings WHERE key = ?", ("QueryHotkeys@darwin",)
            ).fetchone()[0]
        self.assertEqual(json.loads(value), [entries[0] | {"Disabled": True}, entries[1]])

    def test_wox_dry_run_reports_required_start(self):
        database = self.home / "wox.db"
        with sqlite3.connect(database) as db:
            db.execute("CREATE TABLE wox_settings (key TEXT PRIMARY KEY, value TEXT)")
            db.execute("INSERT INTO wox_settings VALUES (?, ?)", ("MainHotkey@darwin", "cmd+space"))
        application = self.home / "Wox.app"
        application.mkdir()
        self.tool("pgrep", "exit 1")
        result, events = self.personalization_play(
            "wox",
            {
                "wox_application": str(application),
                "wox_agent_path": str(self.home / "jsh.wox.plist"),
                "wox_database": str(database),
                "wox_native_shortcuts": False,
            },
            "--check",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "changed", "Wox started"], events)

    def test_wox_dry_run_reports_hotkey_before_database_is_ready(self):
        application = self.home / "Wox.app"
        application.mkdir()
        self.tool("pgrep", "echo 123")
        result, events = self.personalization_play(
            "wox",
            {
                "wox_application": str(application),
                "wox_agent_path": str(self.home / "jsh.wox.plist"),
                "wox_database": str(self.home / "missing.db"),
                "wox_native_shortcuts": False,
            },
            "--check",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "changed", "Wox hotkey is cmd+space"], events)
        self.assertFalse((self.home / "missing.db").exists())

    def test_wallpaper_role_rejects_a_missing_image(self):
        missing = self.home / "missing.jpg"
        result, events = self.personalization_play(
            "desktop", {"jsh_wallpaper": str(missing)}, tasks_from="wallpaper/main.yml"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(["item", "fail", f"JSH_WALLPAPER is not a file: {missing} failed"], events)

    def browser_play(self, area, variables, **environment):
        variables = {
            "jsh_script_env": {
                "JSH_ROOT": str(ROOT),
                "JSH_PLATFORM": environment.get("JSH_PLATFORM", "darwin"),
                "JSH_DESKTOP": "",
                "JSH_HOST": "test",
                "JSH_UPDATE": "0",
                "JSH_KEEP_APPS": "0",
                "JSH_DRY_RUN": "0",
                "JSH_OUTPUT": "renderer",
            }
        } | variables
        include = (
            "    - name: patches\n"
            f"      ansible.builtin.include_role: {{name: patches, tasks_from: {area}/main.yml}}\n"
        )
        return self.run_play(
            include,
            "-e",
            json.dumps(variables),
            ANSIBLE_ROLES_PATH=str(ROOT / "ansible/roles"),
            **environment,
        )

    def test_helium_policy_reports_restart_and_missing_extension(self):
        import plistlib

        profile_root = self.home / "Helium"
        profile = profile_root / "Default"
        profile.mkdir(parents=True)
        role = ROOT / "ansible/roles/patches/files/helium"
        prefs = json.loads((role / "preferences.json").read_text())
        prefs["extensions"] = {
            "pinned_extensions": [
                "blockjmkbacgjkknlgpkjjiijinjdanf",
                "jplgfhpmjnbigmhklmmbgecoobifkmpa",
                "nngceckbapebfimnlniiiahkandclblb",
            ]
        }
        (profile / "Preferences").write_text(json.dumps(prefs))
        state = json.loads((role / "state.json").read_text())
        state["browser"] = {
            "enabled_labs_experiments": ["enable-experimental-web-platform-features"]
        }
        (profile_root / "Local State").write_text(json.dumps(state))
        (profile / "Secure Preferences").write_text(json.dumps({"extensions": {"settings": {}}}))
        manifest = self.home / "manifest.plist"
        manifest.write_text(
            json.dumps({"pfm_name": "ExtensionForceInstallWithSearchOrNewTabOverridesEnabled"})
        )
        policy = self.home / "policy.plist"
        onepassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        stale_policy = plistlib.dumps({"ExtensionInstallForcelist": [onepassword]})
        policy.write_bytes(stale_policy)
        python = shlex.quote(str(self.venv("python")))
        self.tool(
            "sudo",
            f"{python} -c 'import os; raise SystemExit(os.getsid(0) != {os.getsid(0)})' || exit 1\n"
            '[ -e "$HOME/sudo-authorized" ] || exit 1\n'
            '[ "$1" != -n ] || exit 0\n'
            'while [ "$#" -gt 0 ] && [ "$1" != /bin/sh ]; do shift; done\n'
            '[ "$#" -gt 0 ] || exit 1\n'
            'exec "$@"',
        )
        self.tool("pgrep", '[ -e "$HOME/closed" ] && exit 1\necho 123')
        self.tool("osascript", 'touch "$HOME/closed"')
        self.tool("open", 'rm -f "$HOME/closed"\ntouch "$HOME/launched"')
        self.tool("plutil", 'cat "$5"')
        self.tool("killall", "exit 0")
        variables = {
            "patches_helium_profile_root": str(profile_root),
            "patches_helium_policy_path": str(policy),
            "patches_helium_policy_become": True,
            "patches_helium_manifest_path": str(manifest),
        }

        blocked, _ = self.browser_play("helium", variables)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("Run sudo -v first, then rerun", blocked.stdout)
        self.assertEqual(policy.read_bytes(), stale_policy)
        self.assertFalse((self.home / "launched").exists())

        (self.home / "sudo-authorized").touch()
        result, events = self.browser_play("helium", variables)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        written = plistlib.loads(policy.read_bytes())
        self.assertTrue(written["ExtensionForceInstallWithSearchOrNewTabOverridesEnabled"])
        self.assertIn("fgmjlmbojbkmdpofahffgcpkhkngfpef", written["ExtensionInstallForcelist"])
        self.assertIn("nngceckbapebfimnlniiiahkandclblb", written["ExtensionInstallForcelist"])
        self.assertNotIn(onepassword, written["ExtensionInstallForcelist"])
        self.assertIn(
            [
                "item",
                "notice",
                "Startpage extension is missing or disabled; restart Helium, "
                "enable extension downloads, and check helium://extensions",
            ],
            events,
        )
        self.assertIn(["item", "changed", "Helium restarted"], events)
        self.assertTrue((self.home / "launched").exists())
        self.assertNotIn(["item", "changed", str(profile / "Preferences")], events)

    def test_helium_linux_does_not_check_the_macos_startpage_extension(self):
        profile_root = self.home / "Helium"
        profile = profile_root / "Default"
        profile.mkdir(parents=True)
        (profile / "Preferences").write_text(json.dumps({"extensions": {"pinned_extensions": []}}))
        (profile_root / "Local State").write_text("{}\n")
        (profile / "Secure Preferences").write_text(json.dumps({"extensions": {"settings": {}}}))
        self.tool("helium", "exit 0")
        self.tool("pgrep", "exit 1")
        variables = {
            "patches_helium_profile_root": str(profile_root),
            "patches_helium_policy_path": str(self.home / "policy.json"),
            "patches_helium_policy_become": False,
        }

        result, events = self.browser_play("helium", variables, JSH_PLATFORM="linux")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(
            [
                "item",
                "notice",
                "Startpage extension is missing or disabled; restart Helium, "
                "enable extension downloads, and check helium://extensions",
            ],
            events,
        )

    def test_helium_profile_matches_bash_merge_inputs(self):
        defaults = (ROOT / "ansible/roles/patches/defaults/main.yml").read_text()
        self.assertIn("/Library/Managed Preferences/", defaults)
        self.assertNotIn("/Library/Preferences/net.imput.helium.plist", defaults)

        profile_root = self.home / "Helium"
        profile = profile_root / "Default"
        profile.mkdir(parents=True)
        policy_values = json.loads(
            (ROOT / "ansible/roles/patches/files/helium/policy.json").read_text()
        )
        policy_values["ExtensionForceInstallWithSearchOrNewTabOverridesEnabled"] = True
        policy_values["ExtensionInstallForcelist"].append("fgmjlmbojbkmdpofahffgcpkhkngfpef")
        preferences = json.loads(
            (ROOT / "ansible/roles/patches/files/helium/preferences.json").read_text()
        )
        toolbar_order = list(reversed(policy_values["ExtensionSettings"]))
        preferences["extensions"] = {"pinned_extensions": [*toolbar_order, "personal", "other"]}
        existing = preferences | {
            "extensions": {
                "pinned_extensions": [
                    "personal",
                    "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
                    *reversed(toolbar_order),
                    "other",
                ]
            }
        }
        state = json.loads((ROOT / "ansible/roles/patches/files/helium/state.json").read_text())
        state["browser"] = {
            "enabled_labs_experiments": ["custom", "enable-experimental-web-platform-features"]
        }
        (profile / "Preferences").write_text(json.dumps(existing))
        (profile_root / "Local State").write_text(json.dumps(state))
        (profile / "Secure Preferences").write_text(
            json.dumps(
                {
                    "extensions": {
                        "settings": {"fgmjlmbojbkmdpofahffgcpkhkngfpef": {"disable_reasons": []}}
                    }
                }
            )
        )
        manifest = self.home / "manifest.plist"
        manifest.write_text(
            json.dumps(
                {"policy": {"pfm_name": "ExtensionForceInstallWithSearchOrNewTabOverridesEnabled"}}
            )
        )
        self.tool("pgrep", "exit 1")
        self.tool("plutil", 'cat "$5"')
        self.tool("killall", "exit 0")
        variables = {
            "patches_helium_profile_root": str(profile_root),
            "patches_helium_policy_path": str(self.home / "policy.plist"),
            "patches_helium_policy_become": False,
            "patches_helium_manifest_path": str(manifest),
            "patches_helium_toolbar_order": toolbar_order,
        }

        result, events = self.browser_play("helium", variables)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((profile / "Preferences").read_text()), preferences)
        self.assertNotIn("default_search_provider_data", preferences)
        self.assertEqual(json.loads((profile_root / "Local State").read_text()), state)
        result, events = self.browser_play("helium", variables)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        changed = [event[2] for event in events if event[:2] == ["item", "changed"]]
        self.assertNotIn(str(profile / "Preferences"), changed)
        self.assertNotIn(str(profile_root / "Local State"), changed)

    def test_helium_unpacked_helper_previews_secure_preferences(self):
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq is required")
        (self.tools / "jq").symlink_to(jq)
        self.tool("pgrep", "exit 1")
        extension = self.home / "extension"
        extension.mkdir()
        (extension / "manifest.json").write_text("{}\n")
        config = self.home / "config"
        local = config / "jsh/helium"
        local.mkdir(parents=True)
        (local / "unpacked.json").write_text(json.dumps([str(extension)]))
        profile = self.home / "Helium/Default"
        profile.mkdir(parents=True)
        secure = profile / "Secure Preferences"
        secure.write_text("{}\n")

        result = subprocess.run(
            ["bash", str(ROOT / "ansible/roles/patches/files/helium/unpacked.sh"), str(profile)],
            env=self.env
            | {
                "JSH_ROOT": str(ROOT),
                "JSH_PLATFORM": "darwin",
                "JSH_DRY_RUN": "1",
                "XDG_CONFIG_HOME": str(config),
            },
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Secure Preferences differs", result.stdout)
        self.assertIn("would change", result.stdout)
        self.assertEqual(secure.read_text(), "{}\n")

    def test_waterfox_default_profile_selection_rules(self):
        self.tool("pgrep", "exit 1")

        def run(name, ini, profiles, expected=None, requested="", files=None):
            root = self.home / name
            root.mkdir()
            for relative in profiles:
                (root / relative).mkdir(parents=True)
            for relative, text in (files or {}).items():
                (root / relative).write_text(text)
            (root / "profiles.ini").write_text(ini)
            variables = {
                "patches_waterfox_roots": [str(root)],
                "jsh_waterfox_profile": requested,
                "patches_waterfox_policy_become": False,
            }
            result, events = self.browser_play("waterfox", variables, JSH_PLATFORM="linux")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if expected is None:
                self.assertIn(
                    ["item", "notice", "open Waterfox once to create a profile, then rerun"], events
                )
            else:
                self.assertIn(["item", "ok", f"Waterfox profile is {root / expected}"], events)

        run(
            "single",
            "[Profile0]\nName=single\nIsRelative=1\nPath=Profiles/single\n",
            ["Profiles/single"],
            "Profiles/single",
        )
        multiple = (
            "[Profile0]\nName=first\nIsRelative=1\nPath=Profiles/first\n"
            "[Profile1]\nName=second\nIsRelative=1\nPath=Profiles/second\n"
            "Default=1\n[InstallA]\nDefault=Profiles/first\n"
            "[InstallB]\nDefault=Profiles/second\n"
        )
        run("install-defaults", multiple, ["Profiles/first", "Profiles/second"], "Profiles/second")
        run("override", multiple, ["Profiles/first", "Profiles/second"], "Profiles/first", "first")
        run("missing", "[Profile0]\nName=missing\nPath=Profiles/missing\n", [])
        installs = (
            "[Profile0]\nName=old\nIsRelative=1\nPath=Profiles/old\n"
            "[Profile1]\nName=new\nIsRelative=1\nPath=Profiles/new\n"
            "[Profile2]\nName=stale\nIsRelative=1\nPath=Profiles/stale\n"
            "Default=1\n[InstallA]\nDefault=Profiles/new\n"
            "[InstallB]\nDefault=Profiles/old\n"
        )
        run(
            "newest-build",
            installs,
            ["Profiles/old", "Profiles/new", "Profiles/stale"],
            "Profiles/new",
            files={
                "Profiles/old/compatibility.ini": "[Compatibility]\nLastVersion=153.1.0_20260827164222/20260827164222\n",
                "Profiles/new/compatibility.ini": "[Compatibility]\nLastVersion=153.5.0_20261013130543/20261013130543\n",
            },
        )

    def test_waterfox_keeps_bash_user_js_bytes_and_rewrites_toolbar(self):
        root = self.home / "Waterfox"
        profile = root / "Profiles/default"
        profile.mkdir(parents=True)
        (root / "profiles.ini").write_text(
            "[Profile0]\nName=default\nIsRelative=1\nPath=Profiles/default\n"
        )
        config = self.home / "config"
        overlay_path = config / "jsh/waterfox/user.js"
        overlay_path.parent.mkdir(parents=True)
        overlay = '/* local preferences */\nuser_pref("overlay.pref", true);\n'
        overlay_path.write_text(overlay)
        base = (ROOT / "ansible/roles/patches/files/waterfox/user.js").read_text()
        managed = (base + "\n" + overlay).rstrip()
        expected_user = (
            '/* unmanaged */\nuser_pref("personal.pref", true);\n\n'
            "// BEGIN jsh preferences\n" + managed + "\n// END jsh preferences\n"
        )
        (profile / "user.js").write_bytes(expected_user.encode())
        layout = {
            "placements": {
                "nav-bar": [
                    "back-button",
                    "addon_darkreader_org-browser-action",
                    "unified-extensions-button",
                    "ublock0_raymondhill_net-browser-action",
                ],
                "widget-overflow-fixed-list": ["vpn_proton_ch-browser-action"],
            }
        }
        encoded = json.dumps(json.dumps(layout, separators=(",", ":")), separators=(",", ":"))
        (profile / "prefs.js").write_text(
            'user_pref("browser.uiCustomization.state", ' + encoded + ");\n"
        )
        self.tool("pgrep", "exit 1")
        self.tool(
            "stat",
            """if [ "$1" = -L ] && [ "$2" = -c ] && [ "$3" = %a ]; then
  shift 3
  exec /usr/bin/stat -L -f %Lp "$@"
fi
exec /usr/bin/stat "$@"
""",
        )
        variables = {
            "patches_waterfox_roots": [str(root)],
            "patches_waterfox_policy_become": False,
        }

        result, _ = self.browser_play(
            "waterfox", variables, JSH_PLATFORM="linux", XDG_CONFIG_HOME=str(config)
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((profile / "user.js").read_bytes(), expected_user.encode())
        line = (profile / "prefs.js").read_text().strip()
        value = line.removeprefix('user_pref("browser.uiCustomization.state", ').removesuffix(");")
        rewritten = json.loads(json.loads(value))
        expected_pinned = [
            "ublock0_raymondhill_net-browser-action",
            "vpn_proton_ch-browser-action",
            "_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action",
            "addon_darkreader_org-browser-action",
            "_ce9f4b1f-24b8-4e9a-9051-b9e472b1b2f2_-browser-action",
        ]
        self.assertEqual(
            rewritten["placements"]["nav-bar"],
            ["back-button", *expected_pinned, "unified-extensions-button"],
        )
        self.assertEqual(rewritten["placements"]["widget-overflow-fixed-list"], [])

    def packages_filter(self, script):
        """Run Python with the packages filter loaded as `packages` and role defaults as YAML."""
        prelude = (
            "import importlib.util, json, sys, yaml\n"
            f"spec = importlib.util.spec_from_file_location('f', {str(ROOT / 'ansible/plugins/filter/packages.py')!r})\n"
            "module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)\n"
            "packages = module.FilterModule().filters()['packages']\n"
            "selection = module.FilterModule().filters().get('packages_selection')\n"
        )
        result = subprocess.run(
            [str(self.venv("python")), "-c", prelude + script],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_packages_filter_merges_platform_and_extra(self):
        spec = {
            "all": {"brew": ["a"]},
            "linux": {"flatpak": ["f"]},
            "debian": {"apt": ["p"]},
            "darwin": {"casks": ["c"]},
        }
        result = self.packages_filter(
            f"spec = {spec!r}\n"
            "print(json.dumps([packages(spec, 'debian', {'debian': {'apt': ['q', 'p']}}),\n"
            "                  packages(spec, 'darwin')]))\n"
        )
        self.assertEqual(result[0], {"brew": ["a"], "flatpak": ["f"], "apt": ["p", "q"]})
        self.assertEqual(result[1], {"brew": ["a"], "casks": ["c"]})

    def test_packages_filter_drops_foreign_managers(self):
        spec = {"all": {"apt": ["p"], "dnf": ["d"], "casks": ["c"], "mas": ["1"]}}
        result = self.packages_filter(
            f"spec = {spec!r}\n"
            "print(json.dumps({p: packages(spec, p) for p in ('darwin', 'debian', 'rhel')}))\n"
        )
        self.assertEqual(
            result,
            {
                "darwin": {"casks": ["c"], "mas": ["1"]},
                "debian": {"apt": ["p"]},
                "rhel": {"dnf": ["d"]},
            },
        )

    def test_packages_selection_installs_only_selected_role_packages(self):
        roles = {"patches": {"darwin": {"casks": ["helium-browser"]}}}
        common = {"all": {"brew": ["jq"]}}
        result = self.packages_filter(
            f"roles = {roles!r}\ncommon = {common!r}\n"
            "print(json.dumps({tag: selection('darwin', 'darwin', [tag], common, roles)\n"
            "                  for tag in ('patches', 'desktop', 'packages', 'all')}))\n"
        )
        self.assertEqual(result["patches"], {"casks": ["helium-browser"]})
        self.assertEqual(result["desktop"], {})
        for tag in ("packages", "all"):
            self.assertEqual(result[tag], {"brew": ["jq"], "casks": ["helium-browser"]}, tag)

    def test_packages_selection_uses_desktop_selector(self):
        roles = {
            "desktop": {
                "xfce": {"apt": ["arc-theme"], "dnf": ["arc-theme"]},
                "darwin": {"casks": ["font-jetbrains-mono-nerd-font"]},
            }
        }
        result = self.packages_filter(
            f"roles = {roles!r}\n"
            "cases = [('debian', 'xfce', ['desktop']), ('debian', 'gnome', ['desktop']),\n"
            "         ('rhel', '', ['all']), ('darwin', 'darwin', ['desktop'])]\n"
            "print(json.dumps([selection(p, d, t, {}, roles) for p, d, t in cases]))\n"
        )
        self.assertEqual(
            result, [{"apt": ["arc-theme"]}, {}, {}, {"casks": ["font-jetbrains-mono-nerd-font"]}]
        )

    def test_packages_selection_rejects_unknown_role_and_selector(self):
        result = self.packages_filter(
            "out = []\n"
            "for call in (lambda: selection('darwin', '', ['all'], {}, {'a': {}}, {}, {'nope': {}}),\n"
            "             lambda: selection('darwin', '', ['all'], {'ubuntu': {}}, {})):\n"
            "    try:\n        call(); out.append(None)\n"
            "    except ValueError as error:\n        out.append(str(error))\n"
            "print(json.dumps(out))\n"
        )
        self.assertEqual(result, ["unknown package role: nope", "unknown package selector: ubuntu"])

    def test_uv_update_preview_reports_outdated_managed_tools(self):
        for command in ("current-tool", "outdated-tool", "external-tool"):
            self.tool(command, "exit 0")
        self.tool(
            "uv",
            'if [ "$*" = "tool list --outdated" ]; then\n'
            '  echo "pkg-outdated v1.0.0"\n'
            'elif [ "$*" = "tool list" ]; then\n'
            '  printf "%s\\n" "pkg-current v1.0.0" "pkg-outdated v1.0.0"\n'
            'elif [ "$1 $2" = "tool upgrade" ]; then\n'
            '  touch "$HOME/uv-upgraded"\n'
            "fi",
        )
        variables = json.dumps(
            {
                "jsh_platform": "debian",
                "jsh_update": True,
                "packages_roles": {},
                "packages_common": {
                    "debian": {
                        "uv": [
                            {"command": "current-tool", "package": "pkg-current"},
                            {"command": "outdated-tool", "package": "pkg-outdated"},
                            {"command": "external-tool", "package": "pkg-external"},
                        ]
                    }
                },
                "packages_extra": {},
            }
        )
        roles = {"macos": "- name: Packages\n  ansible.builtin.include_role: {name: packages}\n"}
        include = "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n"
        role_paths = str(self.home / "play/roles") + ":" + str(ROOT / "ansible/roles")

        result, events = self.run_play(
            include, "--check", "-e", variables, roles=roles, **{"ANSIBLE_ROLES_PATH": role_paths}
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "ok", "current-tool"], events)
        self.assertIn(["item", "changed", "outdated-tool"], events)
        self.assertIn(["item", "ok", "external-tool"], events)
        self.assertFalse((self.home / "uv-upgraded").exists())

    def test_flatpak_update_preview_reports_only_outdated_and_missing_apps(self):
        self.tool(
            "flatpak",
            'case " $* " in\n'
            '  *" --version "*) echo "Flatpak 1.16.0" ;;\n'
            '  *" remote-ls "*) echo "com.example.Outdated" ;;\n'
            '  *" list "*) printf "%s\\n" com.example.Current com.example.Outdated ;;\n'
            '  *" remotes "*) echo "flathub" ;;\n'
            '  *" update "*) touch "$HOME/flatpak-updated" ;;\n'
            "esac",
        )
        variables = json.dumps(
            {
                "jsh_platform": "debian",
                "jsh_update": True,
                "packages_roles": {},
                "packages_common": {
                    "debian": {
                        "flatpak": [
                            "com.example.Current",
                            "com.example.Outdated",
                            "com.example.Missing",
                        ]
                    }
                },
                "packages_extra": {},
            }
        )
        roles = {"macos": "- name: Packages\n  ansible.builtin.include_role: {name: packages}\n"}
        include = "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n"
        role_paths = str(self.home / "play/roles") + ":" + str(ROOT / "ansible/roles")

        result, events = self.run_play(
            include, "--check", "-e", variables, roles=roles, **{"ANSIBLE_ROLES_PATH": role_paths}
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "ok", "com.example.Current"], events)
        self.assertIn(["item", "changed", "com.example.Outdated"], events)
        self.assertIn(["item", "changed", "com.example.Missing"], events)
        self.assertFalse((self.home / "flatpak-updated").exists())

    def test_appimage_preview_matches_bash_without_downloading_or_drift(self):
        package = {
            "name": "missing-appimage",
            "release": "https://example.invalid/releases/latest",
            "arm": "arm64",
            "amd": "amd64",
        }
        variables = json.dumps(
            {
                "jsh_platform": "debian",
                "jsh_update": False,
                "packages_roles": {},
                "packages_common": {"debian": {"appimage": [package]}},
                "packages_extra": {},
            }
        )
        roles = {"macos": "- name: Packages\n  ansible.builtin.include_role: {name: packages}\n"}
        include = "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n"
        role_paths = str(self.home / "play/roles") + ":" + str(ROOT / "ansible/roles")

        result, events = self.run_play(
            include, "--check", "-e", variables, roles=roles, **{"ANSIBLE_ROLES_PATH": role_paths}
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "info", "would download verified missing-appimage AppImage"], events)
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse(
            any(
                event[1] in ("added", "changed", "removed")
                for event in events
                if event[0] == "item"
            ),
            events,
        )

    def test_full_package_selection_matches_previous_lists(self):
        tools = (
            "bash gum jq unzip zip zsh age ansible atuin bat btop bun coreutils curl "
            "diffutils direnv eza fd ffmpeg fnm fzf gawk gettext gh git git-lfs gnu-sed gnupg "
            "go go-task grc grep hugo just kew lazygit leaf-markdown-viewer libtiff libxcrypt "
            "make mpv ncdu neovim netcat nmap node parallel pnpm poetry readline ripgrep rsync "
            "rtk sops speedtest-go sshpass stow summarize syncthing tmux tree uv watch "
            "xguot/difi/difi xorriso xz zoxide"
        ).split()
        tools_apt = (
            "jq make ripgrep rsync tmux unzip zip age ansible bat btop direnv fzf gh "
            "git-lfs golang-go grc hugo mpv ncdu netcat-openbsd nmap parallel python3-poetry "
            "sshpass stow syncthing yamllint zoxide build-essential bzip2 cargo cifs-utils "
            "desktop-file-utils dconf-cli dkms earlyoom eza fd-find flatpak gnome-keyring "
            "gnupg libarchive-tools libnotify-bin net-tools nfs-common nodejs ntfs-3g "
            "nvme-cli openssh-client openssh-server pipewire-pulse python3-yaml sqlite3 tar "
            "wireplumber xbindkeys xclip xdg-utils x11-xserver-utils xz-utils yq "
            "systemd-zram-generator"
        ).split()
        tools_dnf = (
            "jq make rsync tmux unzip zip bzip2 cargo cifs-utils desktop-file-utils "
            "dconf dkms earlyoom eza fd-find flatpak gcc gcc-c++ gnome-keyring gnupg2 "
            "libarchive libnotify mpv net-tools nfs-utils nodejs ntfs-3g nvme-cli "
            "openssh-clients openssh-server pipewire-pulseaudio python3-pyyaml readline "
            "ripgrep sqlite syncthing tar wireplumber xbindkeys xclip xdg-utils xrandr xz yq "
            "zram-generator"
        ).split()
        tools_uv = [
            {"command": "just", "package": "rust-just"},
            {"command": "tmail", "package": "tmail-cli"},
        ]
        dev = (
            "actionlint autopep8 bats-core black commitizen commitlint eslint gitleaks hadolint "
            "markdownlint-cli pre-commit prettier pylint shellcheck shfmt yamllint"
        ).split()
        dev_uv = [{"command": "check-yaml", "package": "pre-commit-hooks"}]
        containers = "colima docker docker-buildx docker-compose lima".split()
        ghostty = [
            {
                "name": "ghostty",
                "arm": "aarch64",
                "amd": "x86_64",
                "release": "https://api.github.com/repos/pkgforge-dev/ghostty-appimage/releases/latest",
            }
        ]

        xfce = (
            "fontconfig xfce4-appfinder arc-theme papirus-icon-theme pavucontrol "
            "xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-docklike-plugin "
            "xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-netload-plugin "
            "xfce4-pulseaudio-plugin xfce4-screensaver xfce4-systemload-plugin "
            "xfce4-taskmanager xfce4-terminal"
        ).split()
        graphify = [{"command": "graphify", "package": "graphifyy"}]

        def linux(**managers):
            return {"debian": dict(managers), "rhel": dict(managers)}

        expected = {
            "dev": {p: {"brew": dev, "uv": dev_uv} for p in ("darwin", "debian", "rhel")},
            "kube": {
                p: {"brew": "helm helmfile k9s kubernetes-cli".split()}
                for p in ("darwin", "debian", "rhel")
            },
            "containers": {
                "darwin": {"brew": containers},
                "debian": {"brew": containers, "apt": ["podman"]},
                "rhel": {"brew": containers, "dnf": ["podman"]},
            },
            "password": {
                "darwin": {"casks": ["bitwarden"]},
                **linux(flatpak=["com.bitwarden.desktop"]),
            },
            "fonts": {
                "darwin": {"casks": ["font-jetbrains-mono-nerd-font"]},
                "debian": {},
                "rhel": {},
            },
            "ghostty": {"darwin": {"casks": ["ghostty"]}, **linux(appimage=ghostty)},
            "apps": {
                "darwin": {
                    "brew": ["spicetify-cli"],
                    "casks": "android-platform-tools citrix-workspace foobar2000 macdown-3000 signal spotify tailscale-app todoist-app vorssaint zoom".split(),
                },
                **linux(flatpak=["com.spotify.Client", "com.todoist.Todoist"]),
            },
            "display": {"darwin": {"brew": ["displayplacer"]}, "debian": {}, "rhel": {}},
            "wox": {
                "darwin": {"casks": ["wox"]},
                "debian": {
                    "apt": ["sqlite3"],
                    "appimage": [
                        {
                            "name": "wox",
                            "arm": "arm64",
                            "amd": "amd64",
                            "release": "https://api.github.com/repos/Wox-launcher/Wox/releases/latest",
                        }
                    ],
                },
                "rhel": {
                    "dnf": ["sqlite"],
                    "appimage": [
                        {
                            "name": "wox",
                            "arm": "arm64",
                            "amd": "amd64",
                            "release": "https://api.github.com/repos/Wox-launcher/Wox/releases/latest",
                        }
                    ],
                },
            },
            "helium": {
                "darwin": {"casks": ["helium-browser"]},
                **linux(
                    appimage=[
                        {
                            "name": "helium",
                            "arm": "arm64",
                            "amd": "x86_64",
                            "release": "https://api.github.com/repos/imputnet/helium-linux/releases/latest",
                        }
                    ]
                ),
            },
            "waterfox": {
                "darwin": {"casks": ["waterfox"]},
                **linux(flatpak=["net.waterfox.waterfox"]),
            },
            "desktop": {"darwin": {}, "debian": {"apt": xfce}, "rhel": {"dnf": xfce}},
            "ai": {"darwin": {"brew": ["opencode"], "uv": graphify,
                              "casks": "antigravity-cli chatgpt codex copilot-cli".split()},
                   "debian": {"brew": ["opencode"], "uv": graphify},
                   "rhel": {"brew": ["opencode"], "uv": graphify}},
            "sublime": {"darwin": {"casks": ["sublime-text"]},
                        **linux(flatpak=["com.sublimetext.three"])},
            "vscode": {"darwin": {"casks": ["visual-studio-code"]}, "debian": {}, "rhel": {}},
            "tools": {
                "darwin": {
                    "taps": ["gromgit/fuse", "xguot/difi"],
                    "uv": tools_uv,
                    "brew": "bash-completion duti gromgit/fuse/ntfs-3g-mac imagemagick mas".split()
                    + tools,
                },
                "debian": {"taps": ["xguot/difi"], "brew": tools, "apt": tools_apt, "uv": tools_uv},
                "rhel": {"taps": ["xguot/difi"], "brew": tools, "dnf": tools_dnf, "uv": tools_uv},
            },
        }
        data = ROOT / "ansible/group_vars/all/packages.yml"
        cases = [("darwin", "darwin"), ("debian", "xfce"), ("rhel", "xfce"), ("debian", "gnome")]
        result = self.packages_filter(
            f"data = yaml.safe_load(open({str(data)!r}))\n"
            f"cases = {cases!r}\n"
            "print(json.dumps([selection(p, d, ['all'], data['packages_common'],\n"
            "                            data['packages_roles']) for p, d in cases]))\n"
        )

        def key(value):
            return json.dumps(value, sort_keys=True)

        for (platform, desktop), actual in zip(cases, result):
            wanted = {}
            for role, platforms in expected.items():
                if role == "desktop" and desktop != "xfce":
                    continue
                for manager, names in platforms[platform].items():
                    merged = wanted.setdefault(manager, [])
                    merged += [name for name in names if name not in merged]
            self.assertEqual(sorted(actual), sorted(wanted), f"{platform} {desktop}")
            for manager, names in wanted.items():
                self.assertEqual(
                    sorted(actual[manager], key=key),
                    sorted(names, key=key),
                    f"{platform} {desktop} {manager}",
                )

    def test_archon_adds_only_the_apps_casks(self):
        path = ROOT / "ansible/host_vars/archon.yml"
        data = self.packages_filter(f"print(json.dumps(yaml.safe_load(open({str(path)!r}))))\n")
        self.assertEqual(
            data,
            {
                "packages_extra": {
                    "darwin": {"casks": ["bambu-studio", "elgato-stream-deck", "macfuse", "mounty"]}
                }
            },
        )

    @unittest.skipUnless(os.uname().sysname == "Darwin", "writes a plist with defaults")
    def test_macos_role_reports_each_preference_and_restarts(self):
        domain = str(self.home / "jsh-test")
        subprocess.run(["defaults", "write", domain, "A", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", domain, "B", "-array", "x"], check=True)
        self.tool("killall", 'printf "%s\\n" "$1" >> "$HOME/killall-calls"')
        settings = json.dumps(
            {
                "macos_defaults_path": "/usr/bin",
                "macos_restarts": {domain: "Finder"},
                "macos_preferences": [
                    {"domain": domain, "key": "A", "type": "bool", "value": False},
                    {"domain": domain, "key": "B", "type": "array", "value": []},
                ],
            }
        )
        include = "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n"
        roles = {"ANSIBLE_ROLES_PATH": str(ROOT / "ansible/roles")}

        result, events = self.run_play(include, "-e", settings, **roles)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        items = [event[1:3] for event in events if event[0] == "item"]
        self.assertEqual(
            items,
            [["changed", "A is false"], ["changed", "B is empty"], ["changed", "Finder restarted"]],
        )
        self.assertEqual((self.home / "killall-calls").read_text(), "Finder\n")

        (self.home / "killall-calls").unlink()
        result, events = self.run_play(include, "-e", settings, **roles)
        items = [event[1:3] for event in events if event[0] == "item"]
        self.assertEqual(items, [["ok", "A is false"], ["ok", "B is empty"]])
        self.assertFalse((self.home / "killall-calls").exists())

        subprocess.run(["defaults", "write", domain, "A", "-bool", "true"], check=True)
        result, events = self.run_play(include, "-e", settings, JSH_KEEP_APPS="1", **roles)
        self.assertIn(
            ["item", "notice", "restart Finder to apply its settings: killall Finder"], events
        )
        self.assertFalse((self.home / "killall-calls").exists())

    def test_settings_merges_values_over_source(self):
        source = self.home / "source.json"
        source.write_text('{"a": 1, "b": {"x": 1}}\n')
        target = self.home / "settings.json"
        result, output = self.settings(path=str(target), source=str(source), values={"b": {"y": 2}})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(target.read_text()), {"a": 1, "b": {"x": 1, "y": 2}})

    def test_link_role_backs_up_replaced_files_and_refuses_directories(self):
        source = self.home / "source"
        source.write_text("managed\n")
        target = self.home / "config/file"
        target.parent.mkdir()
        target.write_text("mine\n")
        (self.home / "dir").mkdir()
        items = json.dumps({"link_items": [{"src": str(source), "dest": str(target)}]})
        include = "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n"
        roles = {"ANSIBLE_ROLES_PATH": f"{self.home / 'play/roles'}:{ROOT / 'ansible/roles'}"}
        wrapper = {"macos": "- name: Links\n  ansible.builtin.include_role: {name: link}\n"}
        result, events = self.run_play(include, "-e", items, roles=wrapper, **roles)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "changed", str(target)], [event[:3] for event in events])
        self.assertEqual(target.readlink(), source)
        backups = list((self.home / ".local/state/jsh/backups").rglob("file"))
        self.assertEqual([backup.read_text() for backup in backups], ["mine\n"])
        result, events = self.run_play(include, "-e", items, **roles)
        self.assertIn(["item", "ok", str(target)], [event[:3] for event in events])
        directory = json.dumps(
            {"link_items": [{"src": str(source), "dest": str(self.home / "dir")}]}
        )
        result, events = self.run_play(include, "-e", directory, **roles)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.home / "dir").is_dir())

    def test_agentics_skills_read_the_first_local_skill_list(self):
        source = self.home / "custom skill"
        source.mkdir()
        local = self.home / "skills.tsv"
        local.write_text("custom skill\tlocal-skill\n")
        variables = json.dumps(
            {
                "jsh_root": str(ROOT),
                "agentics_skills_home": str(self.home),
                "agentics_skills_vendor": str(self.home / "vendor"),
                "agentics_skills_repos": [],
                "agentics_skills_links": [],
                "agentics_skills_bundled": [],
                "agentics_skills_local_lists": [str(local)],
            }
        )
        include = (
            "    - name: agentics\n"
            "      ansible.builtin.include_role: {name: agentics, tasks_from: skills/main.yml}\n"
        )
        result, events = self.run_play(
            include, "-e", variables, **{"ANSIBLE_ROLES_PATH": str(ROOT / "ansible/roles")}
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        target = self.home / ".agents/skills/local-skill"
        self.assertEqual(target.readlink(), source)
        self.assertIn(["item", "changed", str(target)], events)

    def test_no_ai_role_references(self):
        tracked = subprocess.run(
            [
                "git",
                "-C",
                str(ROOT),
                "grep",
                "-l",
                "-E",
                r"roles/(ai|skills)(/|\b)",
                "--",
                ".",
                ":!docs",
                ":!tmp",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(tracked.stdout.split(), [])
        self.assertFalse((ROOT / "ansible/roles/ai").exists())
        self.assertFalse((ROOT / "ansible/roles/skills").exists())

    def test_links_filter_builds_link_items(self):
        script = (
            "import importlib.util, json\n"
            f"spec = importlib.util.spec_from_file_location('f', {str(ROOT / 'ansible/plugins/filter/links.py')!r})\n"
            "module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)\n"
            "links = module.FilterModule().filters()['links']\n"
            "print(json.dumps([links([{'source': 'repo/skills/a', 'name': 'a'}, ['b/src', 'b'], 'c'],"
            " '/vendor', '/home/.agents/skills')]))\n"
        )
        result = subprocess.run(
            [str(self.venv("python")), "-c", script], capture_output=True, text=True, timeout=60
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout)[0],
            [
                {"src": "/vendor/repo/skills/a", "dest": "/home/.agents/skills/a"},
                {"src": "/vendor/b/src", "dest": "/home/.agents/skills/b"},
                {"src": "/vendor/c", "dest": "/home/.agents/skills/c"},
            ],
        )

    def test_configure_runs_one_playbook_for_all_groups(self):
        checkout = self.installer_fixture()
        for name in ("macos", "tools", "services"):
            (checkout / "ansible/roles" / name / "tasks").mkdir(parents=True)
            (checkout / "ansible/roles" / name / "tasks/main.yml").write_text("[]\n")
        write_group_sources(
            checkout,
            [
                ("macos", "darwin", "Mac settings"),
                ("fonts", "all", "Fonts"),
                ("tools", "all", "Tools"),
                ("services", "linux", "Services"),
                ("legacy", "linux", "A fixture group without a role directory"),
            ],
        )
        (checkout / "scripts/legacy.sh").write_text('touch "$HOME/legacy-script-ran"\n')
        self.mock_playbook()
        result = subprocess.run(
            [
                "bash",
                str(checkout / "scripts/configure.sh"),
                "--dry-run",
                "macos",
                "fonts",
                "tools",
                "services",
                "legacy",
            ],
            env=self.env
            | {"JSH_PLATFORM": "debian", "JSH_ANSIBLE_HOME": str(self.home / "ansible")},
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.home / "playbook.log").read_text().splitlines()
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("--tags macos,fonts,tools,services,legacy --check --diff", calls[0])
        self.assertFalse((self.home / "legacy-script-ran").exists())

    def yaml_file(self, path):
        script = "import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))"
        result = subprocess.run(
            [str(self.venv("python")), "-c", script, str(path)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def sudo_fixture(self):
        """Copy sudo tasks with system paths and privilege escalation isolated to HOME."""
        role = self.home / "play/roles/sudo_fixture/tasks"
        role.mkdir(parents=True)
        target = self.home / "sudoers"
        tasks = (ROOT / "ansible/roles/linux/tasks/sudo.yml").read_text()
        tasks = tasks.replace('"/etc/sudoers.d/{{ linux_user }}"', f'"{target}"')
        tasks = tasks.replace("  become: true\n", "  become: false\n")
        tasks = tasks.replace("        owner: root\n        group: root\n", "")
        (role / "main.yml").write_text(tasks)
        self.tool("visudo", "exit 0")
        return target

    def run_sudo_fixture(self):
        return self.run_play(
            "    - name: linux\n      ansible.builtin.include_role: {name: sudo_fixture}\n",
            "-e",
            json.dumps(
                {
                    "linux_user": "jay",
                    "linux_state": str(self.home / "state"),
                    "ansible_date_time": {"epoch": "1700000000"},
                }
            ),
        )[0]

    def test_audio_headless_preview_stops_after_the_session_notice(self):
        result, events = self.run_play(
            "    - name: desktop\n"
            "      ansible.builtin.include_role: {name: desktop, tasks_from: audio/main.yml}\n",
            "--check",
            "-e",
            json.dumps({"jsh_desktop": "", "jsh_host": "test", "jsh_audio_policy": ""}),
            ANSIBLE_ROLES_PATH=str(ROOT / "ansible/roles"),
            JSH_PLATFORM="debian",
            JSH_DESKTOP="",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "info", "audio policy: no GNOME or XFCE session"], events)
        self.assertNotIn("has no attribute 'rc'", result.stdout + result.stderr)

    def test_desktop_audio_skip_keeps_later_areas(self):
        result, events = self.personalization_play(
            "desktop",
            {"jsh_wallpaper": "", "jsh_desktop": ""},
            "--check",
            JSH_PLATFORM="debian",
            JSH_DESKTOP="",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        audio = ["item", "info", "audio policy: no GNOME or XFCE session"]
        wallpaper = ["item", "info", "Skipping wallpaper: JSH_WALLPAPER is not set"]
        self.assertIn(audio, events)
        self.assertIn(wallpaper, events)
        self.assertLess(events.index(audio), events.index(wallpaper))

    def test_xfce_screensaver_starts_detached_with_a_display(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/desktop/tasks/appearance/xfce.yml")
        start = next(
            task for task in tasks if task.get("name") == "XFCE screensaver process is running"
        )
        command = start.get("ansible.builtin.shell", "")
        self.assertIn("nohup", command)
        self.assertIn("setsid", command)
        self.assertIn("xfce4-screensaver", command)
        self.assertIn("&", command)
        self.assertEqual(
            start["environment"]["DISPLAY"],
            "{{ lookup('ansible.builtin.env', 'DISPLAY') or ':0' }}",
        )
        self.assertFalse(start["failed_when"])
        self.assertIn("not ansible_check_mode", start["when"])

    def test_handlers_run_when_a_later_group_fails(self):
        roles = self.home / "handler-roles"
        marker = self.home / "handler-ran"
        macos = roles / "macos"
        (macos / "tasks").mkdir(parents=True)
        (macos / "handlers").mkdir()
        (macos / "tasks/main.yml").write_text(
            "- name: handler is notified\n"
            "  ansible.builtin.command:\n"
            "    argv: [/usr/bin/true]\n"
            "  changed_when: true\n"
            "  notify: test handler\n"
        )
        (macos / "handlers/main.yml").write_text(
            "- name: test handler\n" f"  ansible.builtin.copy: {{content: ran, dest: '{marker}'}}\n"
        )
        later = roles / "desktop/tasks"
        later.mkdir(parents=True)
        (later / "main.yml").write_text(
            "- name: later group fails\n" "  ansible.builtin.fail: {msg: expected failure}\n"
        )
        site = self.home / "handler-site.yml"
        shutil.copy2(ROOT / "ansible/site.yml", site)
        result = self.playbook(
            site,
            "--tags",
            "macos,desktop",
            "-e",
            '{"jsh_platform":"darwin","jsh_host":"test"}',
            ANSIBLE_ROLES_PATH=str(roles),
            JSH_PLATFORM="darwin",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(marker.is_file(), result.stdout + result.stderr)
        self.assertEqual(marker.read_text(), "ran")
        config = (ROOT / "ansible/ansible.cfg").read_text()
        self.assertIn("force_handlers = True", config)
        for role in ("apps", "desktop", "linux", "services"):
            tasks = self.yaml_file(ROOT / f"ansible/roles/{role}/tasks/main.yml")
            self.assertEqual(tasks[-1].get("ansible.builtin.meta"), "flush_handlers", role)

    def test_sudoers_exact_rule_is_current_among_other_lines(self):
        target = self.sudo_fixture()
        original = "Defaults:jay !requiretty\njay ALL=(ALL) NOPASSWD:ALL\n"
        target.write_text(original)
        result = self.run_sudo_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(target.read_text(), original)
        self.assertFalse((self.home / "state/jsh/backups").exists())

    def test_sudoers_replacements_create_unique_nonoverwriting_backups(self):
        target = self.sudo_fixture()
        target.write_text("first original\n")
        first = self.run_sudo_fixture()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        target.chmod(0o600)
        target.write_text("second original\n")
        second = self.run_sudo_fixture()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        backups = sorted((self.home / "state/jsh/backups").glob("*/sudoers"))
        self.assertEqual(
            sorted(backup.read_text() for backup in backups),
            ["first original\n", "second original\n"],
        )
        self.assertEqual(len({backup.parent for backup in backups}), 2)

    def test_linux_dry_run_skips_failed_timezone_query(self):
        self.tool("timedatectl", "exit 1")
        tasks = (
            "    - name: linux\n"
            "      ansible.builtin.include_role:\n"
            "        name: linux\n"
            "        tasks_from: timezone\n"
        )
        result, events = self.run_play(
            tasks,
            "--check",
            **{"ANSIBLE_ROLES_PATH": str(ROOT / "ansible/roles"), "JSH_PLATFORM": "linux"},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["item", "info", "timezone: timedatectl failed"], events)

    def test_linux_sysctl_keeps_minimums_but_sets_memory_exactly(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/linux/tasks/sysctl.yml")
        minimum = next(
            task for task in tasks if task.get("name") == "Minimum kernel settings apply"
        )
        exact = next(task for task in tasks if task.get("name") == "Exact kernel settings apply")
        probe = next(task for task in tasks if task.get("name") == "Kernel settings are read")
        self.assertFalse(probe["changed_when"])
        self.assertFalse(probe["check_mode"])
        self.assertEqual(
            minimum["loop_control"]["label"],
            "{{ item.item.key }} is at least {{ item.item.value }}",
        )
        self.assertIn("max", minimum["ansible.posix.sysctl"]["value"])
        self.assertEqual(exact["ansible.posix.sysctl"]["value"], "{{ item.value }}")

    def test_linux_files_notify_only_the_required_reloads_and_restart(self):
        defaults = self.yaml_file(ROOT / "ansible/roles/linux/defaults/main.yml")
        files = {item["dest"]: item["notify"] for item in defaults["linux_system_files"]}
        self.assertEqual(
            files["/etc/default/earlyoom"],
            ["Systemd configuration reloads", "earlyoom.service restarts"],
        )
        self.assertEqual(
            files["/etc/systemd/coredump.conf.d/99-jsh-storage.conf"],
            ["Systemd configuration reloads"],
        )
        self.assertEqual(
            files["/etc/systemd/logind.conf.d/99-jsh-sleep.conf"], ["systemd-logind reloads"]
        )
        self.assertEqual(
            files["/etc/udev/rules.d/90-jsh-usb-wakeup.rules"], ["USB udev rules reload"]
        )

    def test_linux_desktop_roles_keep_package_and_audio_contracts(self):
        common = [
            "fontconfig",
            "xfce4-appfinder",
            "arc-theme",
            "papirus-icon-theme",
            "pavucontrol",
            "xfce4-clipman-plugin",
            "xfce4-cpugraph-plugin",
            "xfce4-docklike-plugin",
            "xfce4-fsguard-plugin",
            "xfce4-genmon-plugin",
            "xfce4-netload-plugin",
            "xfce4-pulseaudio-plugin",
            "xfce4-screensaver",
            "xfce4-systemload-plugin",
            "xfce4-taskmanager",
            "xfce4-terminal",
        ]
        packages = self.yaml_file(ROOT / "ansible/group_vars/all/packages.yml")
        self.assertEqual(packages["packages_roles"]["desktop"]["xfce"]["apt"], common)
        self.assertEqual(packages["packages_roles"]["desktop"]["xfce"]["dnf"], common)
        colossus = self.yaml_file(ROOT / "ansible/host_vars/colossus.yml")
        self.assertEqual(
            colossus["packages_roles_extra"]["desktop"]["xfce"]["apt"],
            [
                "build-essential",
                "pkg-config",
                "patch",
                "gettext",
                "meson",
                "libgtk-3-dev",
                "libpulse-dev",
                "libxfce4panel-2.0-dev",
                "libxfce4ui-2-dev",
                "libxfconf-0-dev",
                "libkeybinder-3.0-dev",
                "libnotify-dev",
                "libwnck-3-dev",
                "libexo-2-dev",
                "libxfce4windowing-0-dev",
            ],
        )
        audio = self.yaml_file(ROOT / "ansible/roles/desktop/tasks/audio/main.yml")
        audio = [task for top in audio for task in (top, *top.get("block", []))]
        wave = next(task for task in audio if task.get("name") == "Wave:3 udev rules are current")
        self.assertEqual(
            wave["ansible.builtin.copy"]["dest"], "/etc/udev/rules.d/70-jsh-wave3.rules"
        )
        self.assertEqual(wave["notify"], "Wave:3 udev rules reload")
        autostart = next(
            task for task in audio if task.get("name") == "Microphone startup mute is configured"
        )
        self.assertEqual(
            autostart["ansible.builtin.template"]["src"], "audio/microphone.desktop.j2"
        )
        policy = next(
            task for task in audio if task.get("name") == "WirePlumber audio policy is current"
        )
        self.assertEqual(policy["notify"], "WirePlumber restarts")

    def test_linux_without_cached_sudo_keeps_the_action_notice(self):
        self.tool("sudo", "exit 1")
        role = self.home / "play/roles/linux/tasks"
        role.mkdir(parents=True)
        marker = self.home / "unsafe-role-task"
        (role / "main.yml").write_text(
            f"- name: unsafe role task\n"
            f"  ansible.builtin.file: {{path: '{marker}', state: touch}}\n"
            "- name: preflight\n"
            "  ansible.builtin.include_tasks: preflight.yml\n"
        )
        shutil.copy2(ROOT / "ansible/roles/linux/tasks/preflight.yml", role / "preflight.yml")
        tasks = (
            "    - name: linux preflight\n"
            "      ansible.builtin.include_role:\n"
            "        name: linux\n"
            "        tasks_from: preflight\n"
        )
        result, events = self.run_play(
            tasks, "-e", json.dumps({"linux_user": "jay"}), JSH_PLATFORM="linux"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(marker.exists(), events)
        self.assertIn(
            [
                "item",
                "notice",
                "Linux system configuration needs sudo; run `sudo -v` first, then rerun",
            ],
            events,
        )

    def test_services_headless_preview_ignores_skipped_legacy_stats(self):
        self.tool("systemctl", '[ "$1" = --version ] && exit 0\nexit 1')
        result, events = self.run_play(
            "    - name: services\n      ansible.builtin.include_role: {name: services}\n",
            "--check",
            ANSIBLE_ROLES_PATH=str(ROOT / "ansible/roles"),
            JSH_PLATFORM="debian",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("has no attribute 'stat'", result.stdout + result.stderr)
        self.assertNotIn("fail", [event[1] for event in events if event[0] == "item"])

    def test_services_restarts_only_when_retiring_legacy_agent_files(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/services/tasks/ssh.yml")
        installed = next(
            task for task in tasks if task.get("name") == "Legacy SSH agent files are installed"
        )
        removed = next(
            task for task in tasks if task.get("name") == "Legacy SSH agent files are absent"
        )
        self.assertEqual(installed["notify"], "User systemd configuration reloads")
        self.assertEqual(
            removed["notify"], ["User systemd configuration reloads", "SSH agent restarts"]
        )

    def test_uv_update_only_upgrades_uv_managed_tools(self):
        self.tool("just", "exit 0")
        self.tool(
            "uv",
            r"""printf '%s\n' "$*" >> "$HOME/uv-tools.log"
case "$*" in
  "tool list") printf 'tmail-cli v1.0.0\n- tmail\n' ;;
  "tool upgrade rust-just") printf 'rust-just is not installed\n' >&2; exit 1 ;;
  "tool upgrade tmail-cli") printf 'Nothing to upgrade\n' ;;
esac""",
        )
        role = """- name: uv packages
  ansible.builtin.include_role:
    name: packages
  vars:
    packages_roles: {}
    packages_common:
      all:
        uv:
          - {command: just, package: rust-just}
          - {command: tmail, package: tmail-cli}
"""
        self.tool("tmail", "exit 0")
        result, _ = self.run_play(
            "    - name: tools\n      ansible.builtin.include_role: {name: tools}\n",
            "-e",
            '{"jsh_platform":"darwin","jsh_update":true}',
            roles={"tools": role},
            ANSIBLE_ROLES_PATH=f"{self.home / 'play/roles'}:{ROOT / 'ansible/roles'}",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.home / "uv-tools.log").read_text().splitlines()
        self.assertEqual(calls.count("tool list"), 1, calls)
        self.assertNotIn("tool upgrade rust-just", calls)
        self.assertIn("tool upgrade tmail-cli", calls)

    def test_site_continues_after_a_role_fails_and_exits_nonzero(self):
        roles = self.home / "site-roles"
        for name, tasks in {
            "macos": "- name: group A breaks\n  ansible.builtin.fail: {msg: expected failure}\n",
            "desktop": "- name: ok\n  ansible.builtin.debug: {msg: group B still runs}\n",
        }.items():
            target = roles / name / "tasks"
            target.mkdir(parents=True)
            (target / "main.yml").write_text(tasks)
        site = self.home / "site.yml"
        shutil.copy2(ROOT / "ansible/site.yml", site)
        result = self.playbook(
            site,
            "--tags",
            "macos,desktop",
            "-e",
            '{"jsh_platform":"darwin","jsh_host":"test"}',
            ANSIBLE_STDOUT_CALLBACK="jsh",
            ANSIBLE_ROLES_PATH=str(roles),
            JSH_OUTPUT="renderer",
            JSH_PLATFORM="darwin",
        )
        events = [
            line[1:].split("\t") for line in result.stdout.split("\n") if line.startswith("\x1e")
        ]
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["group", "desktop", self.purpose("desktop")], events)
        self.assertIn(["item", "ok", "group B still runs"], events)
        b_item = events.index(["item", "ok", "group B still runs"])
        final_failure = events.index(["item", "fail", "Host configuration roles succeeded failed"])
        self.assertEqual(events[b_item + 1], ["stepclose"])
        self.assertGreater(final_failure, b_item + 1)
        self.assertIn("macos", result.stdout + result.stderr)

    def test_browser_policy_tasks_probe_without_sudo_then_write_when_needed(self):
        for role, prefix in (("helium", "Helium"), ("waterfox", "Waterfox")):
            tasks = self.yaml_file(ROOT / f"ansible/roles/patches/tasks/{role}/main.yml")
            flattened = []

            def collect(items):
                for item in items:
                    flattened.append(item)
                    collect(item.get("block", []))
                    collect(item.get("rescue", []))
                    collect(item.get("always", []))

            collect(tasks)
            probe = next(
                item for item in flattened if item.get("name") == f"{prefix} policy is checked"
            )
            self.assertIn("settings", probe)
            self.assertTrue(probe["check_mode"])
            self.assertFalse(probe.get("failed_when", False))
            self.assertNotIn("become", probe)
            preview = next(
                item
                for item in flattened
                if item.get("changed_when") is True and "ansible.builtin.command" in item
            )
            self.assertIn("ansible_check_mode", str(preview["when"]))
            admin = next(
                item
                for item in flattened
                if item.get("name") == f"{prefix} policy admin access is checked"
            )
            self.assertEqual(admin["ansible.builtin.command"]["argv"], ["sudo", "-n", "true"])
            self.assertFalse(admin["failed_when"])
            write = next(
                item
                for item in flattened
                if "settings" in item and item.get("check_mode") is not True
            )
            self.assertEqual(write["become"], f"{{{{ patches_{role}_policy_become | bool }}}}")
            for task in (admin, write):
                self.assertIs(task["vars"]["ansible_worker_session_isolation"], False)
            self.assertIn("not ansible_check_mode", str(write["when"]))
            # Helium stops with a failure; Waterfox skips the write and leaves a notice.
            stop = next(
                (
                    item
                    for item in flattened
                    if "ansible.builtin.fail" in item
                    and "needs sudo" in str(item["ansible.builtin.fail"])
                ),
                None,
            )
            if stop is not None:
                self.assertIn(f"{role}_policy_admin.rc", str(stop["when"]))
                continue
            self.assertIn(f"{role}_policy_admin.rc", str(write["when"]))
            notice = next(
                item
                for item in flattened
                if item.get("name") == "notice"
                and "needs sudo" in str(item.get("ansible.builtin.debug", {}))
            )
            self.assertIn("msg", notice["ansible.builtin.debug"])

    def test_playbook_repairs_ansible_before_every_real_run(self):
        root = self.checkout()
        self.mock_playbook()
        script = root / "scripts/ansible.sh"
        script.write_text('#!/bin/sh\nprintf "called\\n" >> "$HOME/ansible-bootstrap.log"\n')
        script.chmod(0o755)
        result = subprocess.run(
            ["bash", "-c", '. "$JSH_ROOT/scripts/lib/common.sh"; jsh::playbook desktop'],
            env=self.env
            | {
                "JSH_ROOT": str(root),
                "JSH_PLATFORM": "darwin",
                "JSH_ANSIBLE_HOME": str(self.home / "ansible"),
                "JSH_DRY_RUN": "0",
                "JSH_OUTPUT": "plain",
            },
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / "ansible-bootstrap.log").read_text(), "called\n")

    def test_ansible_bootstrap_uses_only_uv_managed_python(self):
        self.mock_uv()
        result = self.bootstrap(self.checkout())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.home / "uv.log").read_text().splitlines()
        self.assertTrue(calls, calls)
        venv = next(line for line in calls if "|venv " in line)
        self.assertTrue(venv.startswith("only-managed|"), calls)

    def test_ansible_bootstrap_on_mirrors_only_hosts_uses_a_system_python(self):
        self.mock_uv()
        stale = self.home / "ansible/collections/ansible_collections"
        stale.mkdir(parents=True)
        result = self.bootstrap(self.checkout(), JSH_MIRRORS_ONLY="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.home / "uv.log").read_text().splitlines()
        venv = next(line for line in calls if "|venv " in line)
        self.assertTrue(venv.startswith("only-system|"), calls)
        self.assertIn("--python >=3.12 ", venv)
        self.assertFalse(stale.parent.exists())

    def test_ansible_bootstrap_on_mirrors_only_hosts_never_downloads_uv(self):
        # A brew on PATH keeps common.sh from adding Homebrew's bin, which may hold a real uv.
        self.tool("brew", "exit 1")
        result = self.bootstrap(
            self.checkout(), JSH_MIRRORS_ONLY="1", JSH_UV="", JSH_PLATFORM="debian"
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("not on an internal mirror", result.stdout + result.stderr)
        self.assertFalse((self.home / ".local/bin/uv").exists())

    def test_settings_back_up_existing_home_files_before_replacing_them(self):
        target = self.home / ".config/example/settings.json"
        target.parent.mkdir(parents=True)
        target.write_text('{"mine": true}\n')
        result, _ = self.settings(path=str(target), values={"managed": True}, merge="replace")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backups = list(
            (self.home / ".local/state/jsh/backups").glob("*/.config/example/settings.json")
        )
        self.assertEqual([backup.read_text() for backup in backups], ['{"mine": true}\n'])

    def test_codex_settings_are_backed_up_in_the_jsh_state_tree(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/agentics/tasks/instructions/main.yml")
        names = {task.get("name"): task for task in tasks}
        backup = names["Existing Codex settings are backed up"]
        command = backup["ansible.builtin.command"]["argv"]
        self.assertIn("{{ agentics_state }}/jsh/backups/", " ".join(command))
        self.assertIn("{{ agentics_home }}/.codex/config.toml", command)
        self.assertFalse(backup["changed_when"])
        current = names["ok"]
        self.assertEqual(
            current["ansible.builtin.debug"]["msg"],
            "{{ item.item.option }} is {{ item.item.value }}",
        )
        self.assertIn("ansible_check_mode", str(current["when"]))

    def test_app_reopens_after_settings_apply_fails(self):
        target = self.home / "settings.json"
        target.write_text('{"user": 1}\n')
        result, events = self.app_play(target, apply_fails=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.home / "launched").exists(), events)
        self.assertIn(["item", "info", "Reopening Helium"], events)
        self.assertIn(["item", "fail", "Helium settings fail failed"], events)

    def test_display_toggle_is_standalone_and_uses_fast_wallpaper_helper(self):
        toggle = ROOT / "ansible/roles/desktop/files/display/toggle.sh"
        source = toggle.read_text()
        self.assertIn("JSH_ROOT=${JSH_ROOT:-", source)
        self.assertNotIn("jsh::playbook", source)
        self.assertIn("ansible/roles/desktop/files/wallpaper/apply.sh", source)
        wallpaper = (ROOT / "ansible/roles/desktop/tasks/wallpaper/main.yml").read_text()
        self.assertIn("ansible/roles/desktop/files/wallpaper/apply.sh", wallpaper)
        self.tool("xrandr", "exit 0")
        self.tool("flock", "exit 0")
        result = subprocess.run(
            ["bash", str(toggle), "--dry-run"],
            env=self.env,
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("would toggle the ultrawide display split", result.stdout)

    def test_flatpak_update_argv_uses_literal_strings(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/packages/tasks/flatpak.yml")
        update = next(
            task for task in tasks[2]["block"] if task.get("name") == "Flatpak apps are updated"
        )
        self.assertEqual(
            update["ansible.builtin.command"]["argv"],
            ["flatpak", "update", "--noninteractive", "-y", "{{ item }}"],
        )

    def test_vscode_linux_download_uses_private_tempdir_and_skips_in_check_mode(self):
        tasks = self.yaml_file(ROOT / "ansible/roles/patches/tasks/vscode/linux.yml")
        package = next(task for task in tasks if task.get("name") == "VS Code package")
        block = package["block"]
        temporary = next(task for task in block if "ansible.builtin.tempfile" in task)
        self.assertEqual(temporary["ansible.builtin.tempfile"]["state"], "directory")
        download = next(task for task in block if "ansible.builtin.get_url" in task)
        self.assertIn("patches_vscode_download.path", download["ansible.builtin.get_url"]["dest"])
        self.assertIn("not ansible_check_mode", str(download["when"]))
        installs = [
            task for task in block if "ansible.builtin.apt" in task or "ansible.builtin.dnf" in task
        ]
        self.assertEqual(len(installs), 2)
        self.assertTrue(all("not ansible_check_mode" in str(task["when"]) for task in installs))
        planned = next(task for task in block if task.get("name") == "VS Code install is planned")
        self.assertIn(
            "ansible_check_mode", str(planned["ansible.builtin.set_fact"]["patches_vscode_planned"])
        )
        preview = next(
            task
            for task in block
            if task.get("ansible.builtin.debug", {}).get("msg")
            == "VS Code update is unchecked in preview"
        )
        self.assertIn("jsh_update", str(preview["when"]))
        self.assertIn("ansible_check_mode", str(preview["when"]))

    @unittest.skipUnless(os.uname().sysname == "Darwin", "reads macOS LaunchServices")
    def test_apps_role_preserves_launchservices_integer_types(self):
        import plistlib

        domain = str(self.home / "typed-launch-services")
        plist = self.home / "typed-handlers.plist"
        handlers = [
            {
                "LSHandlerContentType": "public.text",
                "LSHandlerRoleAll": "other.app",
                "LSHandlerModificationDate": 123456789,
            }
        ]
        with plist.open("wb") as stream:
            plistlib.dump({"LSHandlers": handlers}, stream)
        subprocess.run(["defaults", "import", domain, str(plist)], check=True)
        macdown = self.home / "MacDown 3000.app"
        macdown.mkdir()
        result, _ = self.personalization_play(
            "apps",
            {
                "apps_macdown_application": str(macdown),
                "apps_launchservices_domain": domain,
                "apps_decoder_enabled": False,
                "apps_restart_launchservices": False,
            },
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        exported = subprocess.run(
            ["defaults", "export", domain, "-"], check=True, capture_output=True
        ).stdout
        updated = plistlib.loads(exported)["LSHandlers"]
        unmanaged = next(
            item for item in updated if item.get("LSHandlerContentType") == "public.text"
        )
        self.assertEqual(unmanaged["LSHandlerModificationDate"], 123456789)
        self.assertIs(type(unmanaged["LSHandlerModificationDate"]), int)

    def test_apps_role_stops_when_launchservices_export_fails(self):
        self.tool(
            "defaults",
            r"""printf '%s\n' "$*" >> "$HOME/defaults.log"
[ "$1" != export ] || exit 7
exit 0""",
        )
        macdown = self.home / "MacDown 3000.app"
        macdown.mkdir()
        result, _ = self.personalization_play(
            "apps",
            {
                "apps_macdown_application": str(macdown),
                "apps_launchservices_domain": "broken",
                "apps_decoder_enabled": False,
                "apps_restart_launchservices": False,
            },
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.home / "defaults.log").read_text().splitlines()
        self.assertEqual(calls, ["export broken -"])

    @unittest.skipUnless(os.uname().sysname == "Darwin", "guards the real defaults domain")
    def test_checks_cannot_write_real_macos_preferences(self):
        before = subprocess.run(
            ["defaults", "read", "com.apple.screencapture", "location"],
            capture_output=True,
            text=True,
        ).stdout
        result, events = self.run_play(
            "    - name: macos\n      ansible.builtin.include_role: {name: macos}\n",
            ANSIBLE_ROLES_PATH=str(ROOT / "ansible/roles"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checks must not write real macOS preferences", result.stdout + result.stderr)
        after = subprocess.run(
            ["defaults", "read", "com.apple.screencapture", "location"],
            capture_output=True,
            text=True,
        ).stdout
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
