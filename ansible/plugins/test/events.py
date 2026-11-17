"""Tests for output from helper scripts that emit jsh events."""

from __future__ import annotations

import re

CHANGE = re.compile("\x1eitem\t(?:added|changed|removed)\t")


def reported_change(value: object) -> bool:
    """True when helper output contains an added, changed, or removed item event."""
    return bool(CHANGE.search(str(value or "")))


class TestModule:
    def tests(self):
        return {"reported_change": reported_change}
