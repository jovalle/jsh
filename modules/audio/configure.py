"""Install the host's WirePlumber device policy and bind Ctrl+Alt+Super+A to cycle outputs."""

import os
import shutil
from pathlib import Path

from jsh import desktop, files, system

HERE = Path(__file__).resolve().parent
POLICY = ".config/wireplumber/wireplumber.conf.d/51-jsh-audio-policy.conf"


def configure(ctx):
    source = os.environ.get("JSH_AUDIO_POLICY")
    if not source and ctx.facts.host == "colossus":
        source = str(HERE / "colossus.conf")
    changed = False
    if source and Path(source).is_file():
        changed = files.write(ctx, Path.home() / POLICY, Path(source).read_bytes(), 0o644)
    if shutil.which("pactl"):
        command = f"bash {system.ROOT}/modules/audio/cycle.sh cycle"
        keys = ("<Control><Alt><Super>a", "<Primary><Alt><Super>a")
        desktop.shortcut(ctx, "Jsh audio output", *keys, command)
    if changed and not ctx.dry_run and shutil.which("systemctl"):
        ctx.run(["systemctl", "--user", "restart", "wireplumber.service"])
