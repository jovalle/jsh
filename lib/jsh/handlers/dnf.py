"""RHEL-family packages: `dnf: [name, ...]`. Installs missing packages without upgrading others."""

from jsh.handlers import _native

BATCH = True
PRIORITY = 10
PLATFORMS = ("rhel",)
check = _native.check
units = _native.units


def install(ctx, steps):
    _native.install(ctx, steps, _native.Dnf())


def update(ctx, steps):
    _native.update(ctx, steps, _native.Dnf())
