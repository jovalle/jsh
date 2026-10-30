"""Exercise the display toggle with a simulated X11 ultrawide monitor."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DisplayToggleTests(unittest.TestCase):
    def test_split_and_refresh_xfce_layout(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as scratch:
            root = Path(scratch)
            module = root / "modules/display"
            module.mkdir(parents=True)
            (root / "lib").mkdir()
            shutil.copy(ROOT / "modules/display/toggle.sh", module / "toggle.sh")
            shutil.copy(ROOT / "lib/core.sh", root / "lib/core.sh")
            shutil.copy(ROOT / "lib/output.sh", root / "lib/output.sh")
            bindir = root / "bin"
            bindir.mkdir()
            commands = {
                "xrandr": """#!/bin/sh
case "$1" in
  --query) printf 'Screen 0: minimum 320 x 200, current 5120 x 1440, maximum 16384 x 16384\\nDisplayPort-0 connected 5120x1440+0+0 (normal) 1190mm x 340mm\\n' ;;
  --listmonitors)
    if [ -f "$TEST_ROOT/split" ]; then
      printf 'Monitors: 2\\n 0: +jsh-left 2560/595x1440/340+0+0 DisplayPort-0\\n 1: +jsh-right 2560/595x1440/340+2560+0 DisplayPort-0\\n'
    else
      printf 'Monitors: 1\\n 0: +DisplayPort-0 5120/1190x1440/340+0+0 DisplayPort-0\\n'
    fi ;;
  --setmonitor) printf '%s\\n' "$*" >> "$TEST_ROOT/calls"; touch "$TEST_ROOT/split" ;;
  --fb) : ;;
esac
""",
                "xwininfo": """#!/bin/sh
printf '%s\\n' '  0x1 "desktop" ("xfdesktop" "Xfdesktop"): 2560x1440+0+0  +0+0' '  0x2 "desktop" ("xfdesktop" "Xfdesktop"): 2560x1440+2560+0  +2560+0'
""",
                "xfconf-query": """#!/bin/sh
case "$*" in
  *" -l") printf '%s\\n' /backdrop/screen0/monitorjsh-left/workspace0/image-style /backdrop/screen0/monitorjsh-right/workspace0/image-style /backdrop/screen0/monitorDisplayPort-0/workspace0/image-style ;;
  *" -s 6") printf '%s\\n' "$*" >> "$TEST_ROOT/styles" ;;
  *) printf '5\\n' ;;
esac
""",
                "xfdesktop": "#!/bin/sh\nexit 0\n",
                "flock": "#!/bin/sh\nexit 0\n",
                "notify-send": "#!/bin/sh\nexit 0\n",
                "sleep": "#!/bin/sh\nexit 0\n",
            }
            for name, contents in commands.items():
                path = bindir / name
                path.write_text(contents)
                path.chmod(0o755)
            (root / "j.sh").write_text("#!/bin/sh\nexit 0\n")
            (root / "j.sh").chmod(0o755)
            env = {
                **os.environ,
                "HOME": scratch,
                "XDG_CONFIG_HOME": scratch,
                "XDG_STATE_HOME": scratch,
                "XDG_RUNTIME_DIR": scratch,
                "TEST_ROOT": scratch,
                "XDG_CURRENT_DESKTOP": "XFCE",
                "DISPLAY": ":99",
                "PATH": f"{bindir}:{os.environ['PATH']}",
            }
            result = subprocess.run(
                ["bash", str(module / "toggle.sh"), "toggle"],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            style = (
                "-c xfce4-desktop -p /backdrop/screen0/monitorjsh-{}/workspace0/image-style -s 6"
            )
            self.assertEqual(
                (root / "styles").read_text().splitlines(),
                [
                    style.format("left"),
                    style.format("right"),
                ],
            )
            self.assertEqual(
                (root / "calls").read_text().splitlines(),
                [
                    "--setmonitor *jsh-left 2560/595x1440/340+0+0 DisplayPort-0",
                    "--setmonitor jsh-right 2560/595x1440/340+2560+0 DisplayPort-0",
                ],
            )


if __name__ == "__main__":
    unittest.main()
