import importlib.machinery
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("jventoy", str(ROOT / "bin/jventoy"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
JVENTOY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = JVENTOY
LOADER.exec_module(JVENTOY)


class VentoyUiTests(unittest.TestCase):
    def test_confirmation_maps_shared_ui_status(self):
        with patch.object(JVENTOY.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertTrue(JVENTOY.ui_confirm("Download?", "yes"))
            run.assert_called_once_with(
                [str(JVENTOY.JSH_UI), "confirm", "--default", "yes", "--", "Download?"],
                check=False,
            )

            run.reset_mock()
            run.return_value.returncode = 1
            self.assertFalse(JVENTOY.ui_confirm("Download?"))

            run.return_value.returncode = 2
            with self.assertRaisesRegex(RuntimeError, "status 2"):
                JVENTOY.ui_confirm("Download?")


if __name__ == "__main__":
    unittest.main()
