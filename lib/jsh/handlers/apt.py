"""Debian packages: `apt: [name, ...]`. Installs missing packages without upgrading others."""

from jsh.handlers import _native

BATCH = True
PRIORITY = 10
PLATFORMS = ("debian",)
check = _native.check
units = _native.units


def install(ctx, steps):
    _native.install(ctx, steps, _native.Apt())


def update(ctx, steps):
    _native.update(ctx, steps, _native.Apt())
