"""Load handlers by name: lib/jsh/handlers/<name>.py.

A handler module may define:
  BATCH     True to receive every matching step of a phase in one call (default False)
  PRIORITY  ordering among batch handlers within a phase, lower first (default 50)
  PLATFORMS platforms or families the handler applies to; steps elsewhere are dropped
  EXPLICIT  True when install steps must not be reused by `jsh update`
  units(step)          progress units one step contributes (default 1)
  check(args)          raise ValueError for malformed arguments
  install(ctx, steps)  / update(ctx, steps) / configure(ctx, steps) / link(ctx, steps)
Each phase function receives a list of steps; non-batch handlers get one step at a time.
"""

import importlib
import re
from functools import lru_cache
from pathlib import Path

NAME = re.compile(r"^[a-z]+$")


@lru_cache(maxsize=None)
def get(name):
    if not isinstance(name, str) or not NAME.match(name):
        raise ValueError(f"Unknown handler: {name!r}")
    if not (Path(__file__).parent / f"{name}.py").is_file():
        raise ValueError(f"Unknown handler: {name}")
    return importlib.import_module(f"jsh.handlers.{name}")


def batch(handler):
    return getattr(handler, "BATCH", False)


def priority(handler):
    return getattr(handler, "PRIORITY", 50)


def units(handler, step):
    counter = getattr(handler, "units", None)
    return counter(step) if counter else 1


def supports(handler, phase):
    return callable(getattr(handler, phase, None))


def applies(handler, facts):
    platforms = getattr(handler, "PLATFORMS", None)
    return platforms is None or facts.platform in platforms or facts.family in platforms
