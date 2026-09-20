import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from lib.ui import progress as UI  # pylint: disable=wrong-import-position,import-error


class SharedProgressTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {
            "UI_COLOR_MODE": "truecolor", "TERM": "xterm-256color", "JSH_PLAIN_OUTPUT": "0",
        })
        environment.start()
        self.addCleanup(environment.stop)
        UI.progress_theme.cache_clear()
        self.addCleanup(UI.progress_theme.cache_clear)

    def test_verdicts_stay_above_spinner_and_original_colored_bar(self):
        progress = UI.Progress("Checking", 5)
        progress.started_at = 0
        progress.completed = 2
        progress.failed = 1
        progress.report("https://example.test/page HTTPS...")
        output = io.StringIO()
        with (
            patch.object(output, "isatty", return_value=True),
            patch.object(progress.stopped, "wait", side_effect=[False, True]),
            patch.object(UI.time, "monotonic", return_value=10),
            patch.object(
                UI.shutil, "get_terminal_size",
                return_value=UI.os.terminal_size((140, 24)),
            ),
            redirect_stdout(output),
        ):
            progress.animate()
            first_frame = output.getvalue()
            self.assertTrue(first_frame.startswith(
                "⠋ Checking https://example.test/page HTTPS...\nProgress "
            ))
            self.assertIn("\033[38;2;0;153;170m" + "━" * 12 + "\033[38;2;167;169;172m" + "─" * 18, first_frame)
            self.assertIn(" 40.0%  2/5  \033[38;2;0;147;60m✓ 1\033[0m  \033[38;2;238;53;46m✗ 1", first_frame)
            self.assertIn("3 left  ETA 15s", first_frame)

            progress.clear()
            UI.print_status("Dead", "https://dead.test/ (HTTP 404)", "error")
            progress.report("next.test favicon...")
            progress.render()
            verdict_frame = output.getvalue()[len(first_frame):]
            self.assertTrue(verdict_frame.startswith("\r\033[K\033[1A\r\033[K"))
            self.assertIn("Dead: https://dead.test/ (HTTP 404)\033[0m\n⠙ Checking next.test favicon...\nProgress ",
                          verdict_frame)

            progress.completed = 5
            offset = len(output.getvalue())
            progress.__exit__(None, None, None)
            final_frame = output.getvalue()[offset:]
            self.assertIn("100.0%  5/5  \033[38;2;0;147;60m✓ 4\033[0m  \033[38;2;238;53;46m✗ 1", final_frame)
            self.assertIn("0 left  ETA 0s", final_frame)
            self.assertNotIn("Checking", final_frame)
            self.assertTrue(final_frame.endswith("\n"))

    def test_shell_cli_streams_only_verdicts_when_output_is_redirected(self):
        result = subprocess.run(
            [str(ROOT / "lib/ui/cli.sh"), "progress", "Checking", "2"],
            input='{"completed":1,"endpoint":"one.test HTTPS...","message":"Alive: one.test"}\n'
                  '{"completed":2,"failed":1,"message":"Dead: two.test"}\n',
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Alive: one.test\nDead: two.test\n")
        self.assertEqual(result.stderr, "")

    def test_shell_function_works_from_another_directory_in_bash_and_zsh(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell):
                result = subprocess.run(
                    [shell, "-c", '. "$1/lib/ui.sh"; cd /; jsh::progress Checking 1', "_", str(ROOT)],
                    input='{"completed":1,"message":"Done"}\n',
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "Done\n")
                self.assertEqual(result.stderr, "")

    def test_stream_rejects_invalid_counts_without_a_traceback(self):
        result = subprocess.run(
            [str(ROOT / "lib/ui/cli.sh"), "progress", "Checking", "2"],
            input='{"completed":3}\n', text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Progress: invalid progress counts or text\n")

    def test_plain_mode_suppresses_animation_even_on_a_terminal(self):
        output = io.StringIO()
        with (patch.dict(os.environ, {"JSH_PLAIN_OUTPUT": "1"}),
              patch.object(output, "isatty", return_value=True), redirect_stdout(output)):
            with UI.Progress("Checking", 1) as progress:
                progress.render()
                UI.print_status("Alive", "one.test", "success")
                self.assertFalse(progress.thread.is_alive())
        self.assertEqual(output.getvalue(), "Alive: one.test\n")


if __name__ == "__main__":
    unittest.main()
