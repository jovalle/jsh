"""Install the host's WirePlumber device policy and bind Ctrl+Alt+Super+A to cycle outputs."""

import os
import shutil
from pathlib import Path

from jsh import apps, desktop, files, system

HERE = Path(__file__).resolve().parent
POLICY = ".config/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf"
USB_RULE = Path("/etc/udev/rules.d/70-jsh-wave3.rules")


def configure_usb(ctx):
    target = USB_RULE
    desired = (HERE / "70-jsh-wave3.rules").read_bytes()
    if target.is_file() and target.read_bytes() == desired:
        ctx.current()
        return
    if apps.defer(ctx):
        return
    existed = target.exists()
    if not ctx.dry_run:
        if not ctx.admin():
            ctx.notice("Wave:3 USB access needs sudo; run sudo -v first, then rerun")
            return
        apps.install_root(target, desired)
        ctx.run(["udevadm", "control", "--reload"], root=True)
        ctx.run(
            [
                "udevadm",
                "trigger",
                "--action=change",
                "--subsystem-match=usb",
                "--attr-match=idVendor=0fd9",
                "--attr-match=idProduct=0070",
            ],
            root=True,
        )
        ctx.run(["udevadm", "settle"], root=True)
    (ctx.changed if existed else ctx.added)(str(target))


def configure(ctx):
    source = os.environ.get("JSH_AUDIO_POLICY")
    if not source and ctx.facts.host == "colossus":
        source = str(HERE / "colossus.conf")
    if ctx.facts.host == "colossus" and shutil.which("pactl"):
        configure_usb(ctx)
        autostart = Path.home() / ".config/autostart/jsh-microphone.desktop"
        files.write(
            ctx,
            autostart,
            "[Desktop Entry]\nType=Application\nName=Jsh microphone startup mute\n"
            f"Exec=python3 {system.ROOT}/modules/audio/microphone.py\n"
            "OnlyShowIn=XFCE;GNOME;\n",
            0o644,
        )
    changed = False
    if source and Path(source).is_file():
        changed = files.write(ctx, Path.home() / POLICY, Path(source).read_bytes(), 0o644)
    if shutil.which("pactl"):
        command = f"bash {system.ROOT}/modules/audio/cycle.sh cycle"
        keys = ("<Control><Alt><Super>a", "<Primary><Alt><Super>a")
        desktop.shortcut(ctx, "Jsh audio output", *keys, command)
    if changed and not ctx.dry_run and shutil.which("systemctl"):
        ctx.run(["systemctl", "--user", "restart", "wireplumber.service"])
