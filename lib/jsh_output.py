#!/usr/bin/env python3
"""Emit messages through the shared Jsh shell output contract."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def emit(kind, message=""):
    subprocess.run(
        [
            "sh",
            "-c",
            '. "$1"; shift; "$@"',
            "jsh-output",
            str(ROOT / "lib/output.sh"),
            "jsh_" + kind,
            message,
        ],
        check=True,
    )
