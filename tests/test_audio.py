"""Tests for the Wave:3 startup mute watcher."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("microphone", ROOT / "modules/audio/microphone.py")
microphone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(microphone)
sys.path.insert(0, str(ROOT / "lib"))
spec = importlib.util.spec_from_file_location(
    "audio_configure", ROOT / "modules/audio/configure.py"
)
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


class MicrophoneTests(unittest.TestCase):
    def test_usb_rule_install_and_idempotence(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as temporary:
            target = Path(temporary) / "wave3.rules"
            ctx = mock.Mock(dry_run=False, user_only=False)
            ctx.admin.return_value = True
            with (
                mock.patch.object(configure, "USB_RULE", target),
                mock.patch.object(configure.apps, "install_root") as install,
            ):
                configure.configure_usb(ctx)
                install.assert_called_once()
                self.assertEqual(ctx.run.call_count, 3)
                target.write_bytes((configure.HERE / "70-jsh-wave3.rules").read_bytes())
                ctx.reset_mock()
                configure.configure_usb(ctx)
                ctx.current.assert_called_once()
                ctx.run.assert_not_called()

    def test_usb_rule_dry_run_does_not_install(self):
        ctx = mock.Mock(dry_run=True, user_only=False)
        with (
            tempfile.TemporaryDirectory(dir=ROOT / "tmp") as temporary,
            mock.patch.object(configure, "USB_RULE", Path(temporary) / "wave3.rules"),
            mock.patch.object(configure.apps, "install_root") as install,
        ):
            configure.configure_usb(ctx)
            install.assert_not_called()
            ctx.run.assert_not_called()
            ctx.added.assert_called_once()

    def test_sources_selects_only_the_wave_input(self):
        listing = (
            "61\talsa_input.usb-Elgato_Systems_Elgato_Wave_3_serial-00.mono-fallback\tPipeWire\n"
            "62\talsa_input.other\tPipeWire\n"
        )
        with mock.patch.object(microphone.subprocess, "run") as run:
            run.return_value.stdout = listing
            self.assertEqual(microphone.sources(), {"61"})

    def test_panel_state_tracks_mute_and_handles_unavailable_sources(self):
        with (
            mock.patch.object(microphone, "sources", return_value={"61"}),
            mock.patch.object(microphone, "hardware_mute", return_value=False),
            mock.patch.object(microphone.subprocess, "run") as run,
        ):
            for reported, expected in (
                ("Mute: yes\n", "muted"),
                ("Mute: no\n", "live"),
                ("unexpected", "unavailable"),
            ):
                run.return_value.stdout = reported
                self.assertEqual(microphone.status(), expected)
        with (
            mock.patch.object(microphone, "sources", return_value={"61"}),
            mock.patch.object(microphone, "hardware_mute", return_value=True),
            mock.patch.object(microphone.subprocess, "run") as run,
        ):
            run.return_value.stdout = "Mute: no\n"
            self.assertEqual(microphone.status(), "muted")
        with (
            mock.patch.object(microphone, "sources", return_value={"61"}),
            mock.patch.object(microphone, "hardware_mute", side_effect=PermissionError),
            mock.patch.object(microphone.subprocess, "run") as run,
        ):
            run.return_value.stdout = "Mute: no\n"
            self.assertEqual(microphone.status(), "unavailable")
        with mock.patch.object(microphone, "sources", return_value=set()):
            self.assertEqual(microphone.status(), "unavailable")
        with mock.patch.object(microphone, "sources", side_effect=OSError):
            self.assertEqual(microphone.status(), "unavailable")

    def test_menu_unmute_clears_software_mute_before_hardware_unmute(self):
        with (
            mock.patch.object(microphone, "sources", return_value={"61"}),
            mock.patch.object(microphone.subprocess, "run") as run,
            mock.patch.object(microphone, "set_hardware_mute") as hardware,
        ):
            run.return_value.stdout = "Mute: yes\n"
            microphone.set_mute(False)
            self.assertEqual(run.call_args_list[1].args[0], ["pactl", "set-source-mute", "61", "0"])
            hardware.assert_called_once_with(False)

    def test_menu_mute_controls_hardware_without_software_toggle(self):
        with (
            mock.patch.object(microphone.subprocess, "run") as run,
            mock.patch.object(microphone, "set_hardware_mute") as hardware,
        ):
            microphone.set_mute(True)
            run.assert_not_called()
            hardware.assert_called_once_with(True)

    def test_menu_unmute_refuses_ambiguous_source(self):
        with (
            mock.patch.object(microphone, "sources", return_value=set()),
            mock.patch.object(microphone, "set_hardware_mute") as hardware,
        ):
            with self.assertRaises(OSError):
                microphone.set_mute(False)
            hardware.assert_not_called()

    def test_mutes_once_and_again_after_reconnect(self):
        seen = set()
        with (
            mock.patch.object(microphone, "sources", side_effect=[{"61"}, {"61"}, set(), {"62"}]),
            mock.patch.object(microphone, "mute_hardware") as mute,
        ):
            for _ in range(4):
                microphone.update(seen)
        self.assertEqual(mute.call_count, 2)

    def test_failed_mute_is_retried(self):
        seen = set()
        with (
            mock.patch.object(microphone, "sources", return_value={"61"}),
            mock.patch.object(microphone, "mute_hardware", side_effect=[OSError, None]),
        ):
            with self.assertRaises(OSError):
                microphone.update(seen)
            self.assertEqual(seen, set())
            microphone.update(seen)
            self.assertEqual(seen, {"61"})


if __name__ == "__main__":
    unittest.main()
