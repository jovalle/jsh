import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]


class PreferencesTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("mpv"), "mpv is not installed")
    def test_real_mpv_playback_does_not_write_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            audio = directory / "silence.wav"
            with wave.Wave_write(str(audio)) as output:
                output.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
                output.writeframes(bytes(16000))
            script = directory / "assert.lua"
            script.write_text("""
local mp = require 'mp'
mp.register_event('file-loaded', function()
    mp.add_timeout(0.01, function()
        assert(mp.get_property_native('options/save-position-on-quit') == false)
        assert(mp.get_property_native('options/resume-playback') == false)
        assert(mp.get_property('options/watch-later-directory') == '/dev/null')
        local history = mp.get_property_native('options/save-watch-history')
        assert(history == nil or history == false)
        mp.msg.info('JSH_PRIVACY_PASSED')
    end)
end)
""")
            result = subprocess.run(
                [
                    "mpv",
                    "--config-dir=" + str(ROOT / "dotfiles/.config/mpv"),
                    "--vo=null",
                    "--ao=null",
                    "--script=" + str(script),
                    str(audio),
                ],
                env={**os.environ, "XDG_STATE_HOME": str(directory / "state")},
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("JSH_PRIVACY_PASSED", result.stdout)
            self.assertEqual(list(directory.glob("state/mpv/watch*")), [])

    def test_setup_installs_preferences_and_dry_run_does_not_write(self):
        for dry_run in (True, False):
            with self.subTest(dry_run=dry_run), tempfile.TemporaryDirectory() as temporary:
                config = Path(temporary) / "mpv"
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        'mpv() { :; }; source "$1"',
                        "_",
                        str(ROOT / "scripts/unix/configure/mpv.sh"),
                    ],
                    env={
                        **os.environ,
                        "HOME": temporary,
                        "MPV_HOME": str(config),
                        "JSH_CONFIGURE_DRY_RUN": str(int(dry_run)),
                    },
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((config / "mpv.conf").exists(), not dry_run)
                self.assertEqual((config / "scripts/privacy.lua").exists(), not dry_run)

    @unittest.skipUnless(shutil.which("lua"), "Lua is not installed")
    def test_privacy_script_sets_options_on_old_and_new_mpv(self):
        script = ROOT / "dotfiles/.config/mpv/scripts/privacy.lua"
        result = subprocess.run(
            ["lua", "-", str(script)],
            input="""
for _, supported in ipairs({true, false}) do
    local calls = {}
    package.loaded.mp = {
        set_property_native = function(name, value)
            calls[name] = value
            return supported or nil, 'option not found'
        end,
        set_property = function(name, value)
            calls[name] = value
            return supported or nil, 'option not found'
        end,
    }
    dofile(arg[1])
    assert(calls['options/save-watch-history'] == false)
    assert(calls['options/watch-history-path'] == '/dev/null')
end
""",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
