"""Desktop extension configuration preserves unrelated GNOME extensions."""

import ast
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
spec = importlib.util.spec_from_file_location(
    "desktop_extensions", ROOT / "modules/desktop/extensions.py"
)
extensions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extensions)


class DesktopTests(unittest.TestCase):
    def test_unchanged_xfconf_setting_succeeds_under_errexit(self):
        source = (ROOT / "modules/desktop/desktop.sh").read_text()
        function = source.split("xfconf_set() {", 1)[1].split("\nwrite_if_changed()", 1)[0]
        script = "set -e\nxfconf-query() { printf '%s\\n' 0; }\nxfconf_set() {" + function
        script += "\nxfconf_set channel /property int 0\nprintf 'continued\\n'\n"
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, "continued\n")

    def test_desktop_icon_extensions_are_disabled_and_other_extensions_preserved(self):
        ctx = mock.Mock()
        lists = {
            "enabled-extensions": ["other@example", "ding@rastersoft.com"],
            "disabled-extensions": ["disabled@example"],
        }

        def read_list(_schema, key):
            return lists[key].copy()

        def set_value(_ctx, _schema, key, value, *_args):
            if key in lists:
                lists[key] = ast.literal_eval(value)

        missing = ROOT / "missing"
        with mock.patch.object(extensions, "data", return_value={"enable": []}), mock.patch.object(
            extensions.desktop, "gnome_list", side_effect=read_list
        ), mock.patch.object(
            extensions.desktop, "gsetting", side_effect=set_value
        ) as setting, mock.patch.object(
            extensions, "roots", return_value=(missing, missing)
        ):
            extensions.configure(ctx)
            self.assertEqual(lists["enabled-extensions"], ["other@example"])
            self.assertEqual(
                lists["disabled-extensions"], ["disabled@example", *extensions.DESKTOP_ICONS]
            )
            setting.reset_mock()
            extensions.configure(ctx)
            self.assertEqual(
                [call.args[2] for call in setting.call_args_list], ["disable-user-extensions"]
            )


if __name__ == "__main__":
    unittest.main()
