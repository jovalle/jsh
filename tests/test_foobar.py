"""The foobar2000 DSD component is installed safely and only once."""

import importlib.util
import io
import os
import tempfile
import unittest
import zipfile
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

from jsh import system

ROOT = Path(__file__).resolve().parents[1]


def package():
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, "w") as bundle:
        bundle.writestr("mac/foo_input_udsd.component/Contents/Info.plist", "plist")
        bundle.writestr("mac/foo_input_udsd.component/Contents/MacOS/foo_input_udsd", "binary")
    outer = io.BytesIO()
    with zipfile.ZipFile(outer, "w") as archive:
        archive.writestr("foo_input_udsd.fb2k-component", inner.getvalue())
    return outer.getvalue()


class FoobarTests(unittest.TestCase):
    def test_install_and_preserve_existing_component(self):
        spec = importlib.util.spec_from_file_location("foobar", ROOT / "modules/apps/foobar.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        (ROOT / "tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as scratch:
            home = Path(scratch)
            ctx = mock.Mock(dry_run=False)
            target = home / "Library/foobar2000-v2/user-components/foo_input_udsd.component"
            lifecycle = []

            @contextmanager
            def closed(*_args):
                self.assertFalse(target.exists())
                lifecycle.append("close")
                yield True
                self.assertTrue(target.exists())
                lifecycle.append("reopen")

            with (
                mock.patch.dict(os.environ, {"HOME": str(home)}),
                mock.patch.object(system, "ROOT", home),
                mock.patch.object(module.apps, "closed_for_changes", side_effect=closed),
                mock.patch.object(
                    module.web, "download", side_effect=lambda _u, p, _d: p.write_bytes(package())
                ) as download,
            ):
                module.configure(ctx)
                binary = (
                    home
                    / "Library/foobar2000-v2/user-components"
                    / "foo_input_udsd.component/Contents/MacOS/foo_input_udsd"
                )
                self.assertEqual(binary.read_bytes(), b"binary")
                self.assertTrue(binary.stat().st_mode & 0o111)
                module.configure(ctx)
                download.assert_called_once()
                ctx.current.assert_called_once()
                self.assertEqual(lifecycle, ["close", "reopen"])


if __name__ == "__main__":
    unittest.main()
