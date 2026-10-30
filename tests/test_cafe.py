"""XFCE cafe status uses theme-aware icons when they are installed."""

import contextlib
import importlib.machinery
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("cafe", str(ROOT / "bin/cafe"))
spec = importlib.util.spec_from_loader(loader.name, loader)
cafe = importlib.util.module_from_spec(spec)
loader.exec_module(cafe)


class CafeStatusTest(unittest.TestCase):
    def test_symbolic_icon_for_each_state_and_fallback(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory:
            home = Path(directory)
            icons = home / ".local/share/icons/hicolor/scalable/status"
            icons.mkdir(parents=True)
            with mock.patch.object(Path, "home", return_value=home):
                for state, pid in (("off", None), ("on", 123)):
                    with self.subTest(state=state):
                        with mock.patch.object(cafe, "running_pid", return_value=pid):
                            output = io.StringIO()
                            with contextlib.redirect_stdout(output):
                                cafe.show_xfce_status()
                            self.assertIn(
                                f"<img>{ROOT}/assets/icons/cafe-{state}.svg</img>",
                                output.getvalue(),
                            )
                            (icons / f"cafe-{state}-symbolic.svg").touch()
                            output = io.StringIO()
                            with contextlib.redirect_stdout(output):
                                cafe.show_xfce_status()
                            self.assertIn(f"<icon>cafe-{state}-symbolic</icon>", output.getvalue())
                            self.assertIn(
                                f"<iconclick>{ROOT}/bin/cafe --xfce-toggle</iconclick>",
                                output.getvalue(),
                            )


if __name__ == "__main__":
    unittest.main()
