#!/usr/bin/env python3
"""Install declared software without upgrading existing installations."""

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRY_RUN = os.environ.get("JSH_DRY_RUN") == "1"
# JSH_INSTALL=0 only reports missing tools, for hosts where software cannot be installed.
INSTALL = os.environ.get("JSH_INSTALL", "1") != "0"
sys.path.insert(0, str(ROOT / "lib"))
import output  # pylint: disable=import-error,wrong-import-position


def run(arguments, root=False, capture=False):
    if root and os.geteuid() != 0:
        arguments = ["sudo", "-n", "--", *arguments]
    if capture:
        return subprocess.run(arguments, check=True, text=True, capture_output=True).stdout.strip()
    if DRY_RUN:
        output.note(f"would run {shlex.join(arguments)}")
    else:
        output.run(arguments)
    return ""


def admin():
    if os.geteuid() == 0:
        return True
    if not installed("sudo"):
        return False
    result = subprocess.run(
        ["sudo", "-n", "true"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    return result.returncode == 0


def report(names):
    output.count("to install" if DRY_RUN else "installed", len(names))
    for name in names:
        output.item(name)


def installed(command):
    return shutil.which(command) is not None


def native_installed(manager, name):
    if manager == "apt":
        command = ["dpkg-query", "-W", "-f=${db:Status-Status}", name]
    else:
        command = ["rpm", "-q", name]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    return result.returncode == 0 and (manager != "apt" or result.stdout == "installed")


def native_packages(manager, names):
    missing = [name for name in names if not native_installed(manager, name)]
    for name in names:
        if name not in missing:
            output.current(name)
    if not missing:
        return
    output.attention("missing: " + ", ".join(missing))
    if not INSTALL:
        output.note("installs disabled by JSH_INSTALL=0")
        return
    if not DRY_RUN:
        if not admin():
            output.problem("sudo needs a password; install these packages manually")
            return
        if not output.confirm("Install the missing packages?"):
            output.note("skipped installing missing packages")
            return
    output.progress("installing " + ", ".join(missing))
    if manager == "apt":
        run(["apt-get", "update"], root=True)
        run(["apt-get", "install", "--no-upgrade", "-y", "--", *missing], root=True)
    else:
        run(["dnf", "install", "-y", "--", *missing], root=True)
    report(missing)


def brew_missing(kind, names):
    flag = "--formula" if kind == "formulae" else "--cask"
    current = set(run(["brew", "list", flag, "-1"], capture=True).splitlines())
    missing = [name for name in names if name not in current]
    if not missing:
        return []
    # brew list omits aliases and renames, such as python for python@3.15.
    try:
        info = json.loads(run(["brew", "info", "--json=v2", flag, *missing], capture=True))
    except subprocess.CalledProcessError:
        # Formulae from taps that a dry run has not added yet are unknown to brew.
        return missing
    for entry in info[kind]:
        if entry.get("installed"):
            current.update(entry.get("aliases", []) + entry.get("oldnames", []))
            current.update(entry.get("old_tokens", []))
            current.update(entry[key] for key in ("full_name", "full_token") if key in entry)
    return [name for name in missing if name not in current]


def brew_packages(spec):
    if not installed("brew"):
        raise RuntimeError("Install Homebrew first: https://brew.sh")
    os.environ.update(
        HOMEBREW_NO_AUTO_UPDATE="1",
        HOMEBREW_NO_INSTALL_CLEANUP="1",
        HOMEBREW_NO_INSTALL_UPGRADE="1",
        # Fail instead of hiding a password prompt behind the spinner.
        SUDO_ASKPASS="/usr/bin/false",
    )
    taps = spec.get("taps", [])
    current = set(run(["brew", "tap"], capture=True).splitlines()) if taps else set()
    for tap in taps:
        if tap in current:
            output.current(tap)
        else:
            run(["brew", "tap", tap])
            report([tap])
    for kind in ("formulae", "casks"):
        names = spec.get(kind, [])
        missing = brew_missing(kind, names)
        for name in names:
            if name not in missing:
                output.current(name)
        if missing:
            output.progress("installing " + ", ".join(missing))
            run(["brew", "install", "--formula" if kind == "formulae" else "--cask", *missing])
            report(missing)


def download(url, target, digest):
    if not url.startswith("https://"):
        raise ValueError("Downloads require HTTPS")
    if not digest or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError("A SHA-256 digest is required for downloaded applications")
    request = urllib.request.Request(url, headers={"User-Agent": "jsh"})
    checksum = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as stream:
        while block := response.read(1024 * 1024):
            checksum.update(block)
            stream.write(block)
    if checksum.hexdigest() != digest:
        raise ValueError("Application download checksum mismatch")


def metadata(url):
    request = urllib.request.Request(url, headers={"User-Agent": "jsh"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def appimage_asset(release, architecture):
    assets = [
        asset
        for asset in release["assets"]
        if asset["name"].lower().endswith(f"-{architecture}.appimage")
    ]
    if len(assets) != 1:
        raise RuntimeError(f"Expected one matching {architecture} AppImage")
    return assets[0]


def appimage(name, spec):
    if installed(name):
        output.current(name)
        return
    arch = {"AMD64": "x86_64", "arm64": "aarch64"}.get(platform.machine(), platform.machine())
    if arch not in ("x86_64", "aarch64"):
        raise RuntimeError(f"{name}: no declared AppImage for {arch}")
    if DRY_RUN:
        output.note(f"would install {name} ({arch}) from {spec['release']} into ~/.local/bin")
        report([name])
        return
    output.progress(f"downloading {name}")
    release = metadata(spec["release"])
    release_arch = spec.get("architectures", {}).get(arch, arch)
    asset = appimage_asset(release, release_arch)
    digest = (asset.get("digest") or "").removeprefix("sha256:")
    destination = Path.home() / ".local/bin" / name
    if destination.exists() or destination.is_symlink():
        raise RuntimeError(f"Refusing to replace existing launcher: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jsh-", dir=ROOT / "tmp") as directory:
        temporary = Path(directory) / name
        download(asset["browser_download_url"], temporary, digest)
        temporary.chmod(0o755)
        # Copy beside the destination before atomically publishing it.
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
            staged = Path(stream.name)
        try:
            shutil.copy2(temporary, staged)
            staged.replace(destination)
        finally:
            staged.unlink(missing_ok=True)
    desktop = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    desktop = desktop / "applications" / f"jsh-{name}.desktop"
    desktop.parent.mkdir(parents=True, exist_ok=True)
    executable = str(destination).replace("\\", "\\\\").replace('"', '\\"')
    executable = executable.replace("`", "\\`").replace("$", "\\$").replace("%", "%%")
    desktop.write_text(
        f"[Desktop Entry]\nType=Application\nName={name.title()}\n"
        f'Exec="{executable}" %U\nTerminal=false\n'
    )
    report([name])


def flatpak(spec, manager, dependencies):
    if not installed("flatpak"):
        native_packages(manager, dependencies)
        if not DRY_RUN and not installed("flatpak"):
            output.problem(f"flatpak is missing; skipped {spec['id']}")
            return
    if DRY_RUN:
        output.note(f"would ensure user Flathub remote and install {spec['id']} if missing")
        return
    result = subprocess.run(
        ["flatpak", "info", "--user", spec["id"]],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    system = subprocess.run(
        ["flatpak", "info", "--system", spec["id"]],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0 or system.returncode == 0:
        output.current(spec["id"])
        return
    output.progress(f"installing {spec['id']}")
    run(["flatpak", "remote-add", "--user", "--if-not-exists", "flathub", spec["remote"]])
    run(["flatpak", "install", "--user", "--noninteractive", "-y", "flathub", spec["id"]])
    report([spec["id"]])


def vscode(spec, manager):
    if installed("code") or native_installed(manager, spec["package"]):
        output.current("vscode")
        return
    arch = {"x86_64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    if not arch:
        raise RuntimeError("VS Code requires x86_64 or aarch64")
    channel = "deb" if manager == "apt" else "rpm"
    url = spec["metadata"].format(channel=channel, arch=arch)
    if DRY_RUN:
        output.note(f"would download the official VS Code {channel} package from {url}")
        report(["vscode"])
        return
    if not admin():
        output.problem("sudo needs a password; install vscode manually")
        return
    output.progress("downloading vscode")
    release = metadata(url)
    with tempfile.TemporaryDirectory(prefix="vscode-", dir=ROOT / "tmp") as directory:
        package = Path(directory) / f"vscode.{channel}"
        download(release["url"], package, release["sha256hash"])
        output.progress("installing vscode")
        if manager == "apt":
            run(["apt-get", "install", "--no-upgrade", "-y", str(package)], root=True)
        else:
            run(["dnf", "install", "-y", str(package)], root=True)
    report(["vscode"])


def python_tools(tools):
    """Install command-line tools published on PyPI, preferring uv over pip."""
    for command, package in tools.items():
        if installed(command):
            output.current(command)
            continue
        output.progress(f"installing {package}")
        try:
            if installed("uv"):
                run(["uv", "tool", "install", package])
            else:
                run([sys.executable, "-m", "pip", "install", "--user", package])
        except subprocess.CalledProcessError:
            output.problem(f"could not install {package}")
            continue
        report([command])


def npm_packages(packages):
    if packages and not installed("npm"):
        output.skip("npm is not installed; skipping npm packages")
        return
    for name, version in packages.items():
        specification = f"{name}@{version}"
        result = subprocess.run(
            ["npm", "list", "--global", "--depth=0", specification],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            output.current(name)
            continue
        output.progress(f"installing {specification}")
        try:
            run(["npm", "install", "--global", specification])
        except subprocess.CalledProcessError:
            output.problem(f"could not install {specification}")
            continue
        report([name])


def combine(*specs):
    merged = {}
    for spec in specs:
        for key, names in spec.items():
            target = merged.setdefault(key, [])
            target.extend(name for name in names if name not in target)
    return merged


def host():
    return os.environ.get("JSH_HOST") or platform.node().split(".")[0].lower()


def session_desktop():
    session = os.environ.get("JSH_DESKTOP") or (
        os.environ.get("XDG_CURRENT_DESKTOP", "") + ":" + os.environ.get("DESKTOP_SESSION", "")
    )
    return next((name for name in ("xfce", "gnome") if name in session.lower()), "")


def vendor(repositories):
    for path, url in repositories.items():
        target = ROOT / "local/vendor" / path
        if (target / ".git").exists():
            output.current(path)
            continue
        output.progress(f"cloning {path}")
        run(["git", "clone", "--quiet", "--depth", "1", "--", url, str(target)])
        report([path])


def fzf_binary():
    """Install the fzf release that matches the vendored checkout's pinned version."""
    directory = ROOT / "local/vendor/fzf"
    script = directory / "install"
    if not script.exists():
        return
    pinned = re.search(r"^version=(\S+)", script.read_text(), re.MULTILINE)
    binary = directory / "bin/fzf"
    current = run([str(binary), "--version"], capture=True) if binary.exists() else ""
    if pinned and current.split(" ")[0] == pinned.group(1):
        output.current("fzf binary")
        return
    output.progress("installing fzf")
    run([str(script), "--bin"])
    report(["fzf binary"])


def launcher():
    link = Path.home() / ".local/bin/jsh"
    target = ROOT / "bin/jsh"
    if link.is_symlink() or link.exists():
        if link.resolve() != target.resolve():
            raise RuntimeError(f"Refusing to replace existing launcher: {output.tilde(link)}")
        output.current("jsh launcher")
        return
    if DRY_RUN:
        output.note(f"would link {output.tilde(link)} to {output.tilde(target)}")
    else:
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
    report(["jsh launcher"])


def main(group):
    config = json.loads((ROOT / "conf/packages.json").read_text())
    selected = os.environ["JSH_PLATFORM"]
    spec = config["platforms"][selected]
    groups = ["core", "tools", "runtime", "apps"] if group == "all" else [group]
    if not DRY_RUN:
        (ROOT / "tmp").mkdir(exist_ok=True)
    for item in groups:
        with output.Step(item):
            install_group(config, spec, selected, item)


def darwin_group(config, spec, item):
    if item == "tools":
        brew_packages(combine(config["brew"], spec["tools"]))
    elif item == "apps":
        brew_packages(combine(spec["apps"], spec.get("hosts", {}).get(host(), {})))
    elif item in spec:
        brew_packages(spec[item])
    else:
        brew_packages({"casks": [config["apps"][item]["cask"]]})


def install_group(config, spec, selected, item):
    if not INSTALL and (selected == "darwin" or item not in ("core", "tools")):
        output.skip("installs disabled by JSH_INSTALL=0")
    elif item == "runtime":
        vendor(config["runtime"]["vendor"])
        fzf_binary()
        launcher()
    elif selected == "darwin":
        darwin_group(config, spec, item)
    elif item == "core":
        native_packages(spec["manager"], spec[item])
    elif item == "tools":
        native_packages(
            spec["manager"], spec[item] + spec.get("desktops", {}).get(session_desktop(), [])
        )
        if not INSTALL:
            return
        if installed("brew"):
            brew_packages(config["brew"])
        else:
            output.skip("install Homebrew from https://brew.sh to add the shared tools")
    else:
        names = list(config["apps"]) if item == "apps" else [item]
        for name in names:
            app = config["apps"][name]["linux"]
            if app["type"] == "appimage":
                appimage(name, app)
            elif app["type"] == "flatpak":
                flatpak(app, spec["manager"], spec["flatpak"])
            elif app["type"] == "vscode":
                vscode(app, spec["manager"])
    if item == "tools" and INSTALL:
        python_tools(config["python"])
        npm_packages(config.get("npm", {}))


if __name__ == "__main__":
    try:
        main(sys.argv[1] if len(sys.argv) > 1 else "all")
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        output.error(str(error))
        sys.exit(1)
