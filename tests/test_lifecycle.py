"""Application restarts are conditional, bounded and never affect real processes in tests."""

import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
from jsh import apps  # pylint: disable=wrong-import-position


class LifecycleTests(unittest.TestCase):
    def context(self, dry_run=False):
        return mock.Mock(dry_run=dry_run)

    def test_stopped_app_needs_no_restart(self):
        with (
            mock.patch.object(apps, "running", return_value=False),
            mock.patch.object(apps.subprocess, "Popen") as launch,
        ):
            with apps.closed_for_changes(
                self.context(), "Browser", ("browser",), ["browser"]
            ) as ok:
                self.assertTrue(ok)
        launch.assert_not_called()

    def test_dry_run_never_closes_an_app(self):
        ctx = self.context(True)
        with (
            mock.patch.object(apps, "running", return_value=True),
            mock.patch.object(apps.os, "kill") as kill,
            mock.patch.object(apps.subprocess, "Popen") as launch,
        ):
            with apps.closed_for_changes(ctx, "Browser", ("browser",), ["browser"]) as ok:
                self.assertTrue(ok)
        kill.assert_not_called()
        launch.assert_not_called()
        ctx.notice.assert_called_once()

    def test_running_app_is_closed_and_reopened_even_if_write_fails(self):
        with (
            mock.patch.object(apps, "MACOS", False),
            mock.patch.object(apps, "running", side_effect=[True, False, False]),
            mock.patch.object(apps.shutil, "which", return_value="/bin/browser"),
            mock.patch.object(apps.system, "query", return_value="123"),
            mock.patch.object(apps.os, "kill") as kill,
            mock.patch.object(apps.subprocess, "Popen") as launch,
        ):
            with self.assertRaisesRegex(ValueError, "write failed"):
                with apps.closed_for_changes(self.context(), "Browser", ("browser",), ["browser"]):
                    raise ValueError("write failed")
        kill.assert_called_once_with(123, apps.signal.SIGTERM)
        launch.assert_called_once()

    def test_refuses_to_close_when_it_cannot_reopen(self):
        ctx = self.context()
        with (
            mock.patch.object(apps, "running", return_value=True),
            mock.patch.object(apps.shutil, "which", return_value=None),
            mock.patch.object(apps.os, "kill") as kill,
        ):
            with apps.closed_for_changes(ctx, "Browser", ("browser",), ["missing"]) as ok:
                self.assertFalse(ok)
        kill.assert_not_called()
        ctx.notice.assert_called_once()

    def test_app_that_remains_open_blocks_writes(self):
        ctx = self.context()
        with (
            mock.patch.object(apps, "MACOS", False),
            mock.patch.object(apps, "running", return_value=True),
            mock.patch.object(apps.shutil, "which", return_value="/bin/browser"),
            mock.patch.object(apps.system, "query", return_value="123"),
            mock.patch.object(apps.os, "kill"),
            mock.patch.object(apps.time, "monotonic", side_effect=[0, 11]),
            mock.patch.object(apps.subprocess, "Popen") as launch,
        ):
            with apps.closed_for_changes(ctx, "Browser", ("browser",), ["browser"]) as ok:
                self.assertFalse(ok)
        launch.assert_not_called()
        ctx.notice.assert_called_once()

    def test_mac_app_that_refuses_quit_event_is_terminated(self):
        refused = mock.Mock(returncode=1)
        with (
            mock.patch.object(apps, "MACOS", True),
            mock.patch.object(apps, "running", side_effect=[True, False, False]),
            mock.patch.object(apps.shutil, "which", return_value="/usr/bin/open"),
            mock.patch.object(apps.subprocess, "run", return_value=refused),
            mock.patch.object(apps.system, "query", return_value="123"),
            mock.patch.object(apps.os, "kill") as kill,
            mock.patch.object(apps.subprocess, "Popen") as launch,
        ):
            with apps.closed_for_changes(
                self.context(), "Browser", ("browser",), ["open", "-a", "Browser"]
            ) as ok:
                self.assertTrue(ok)
        kill.assert_called_once_with(123, apps.signal.SIGTERM)
        launch.assert_called_once()


if __name__ == "__main__":
    unittest.main()
