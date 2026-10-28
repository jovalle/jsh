"""Discover modules: each modules/<name>/module.toml describes one subject jsh sets up."""

import re
import tomllib
from pathlib import Path

from jsh.system import ROOT

PHASES = ("install", "configure", "update")
TOP_KEYS = {"description", "when", "commands", *PHASES, "link"}
STEP_KEYS = {"when", "root", "optional"}
WHEN_KEYS = {"platform", "desktop", "host"}
NAME = re.compile(r"^[a-z][a-z0-9]*$")


class ManifestError(ValueError):
    pass


class Step:
    """One handler invocation declared by a module."""

    def __init__(  # pylint: disable=too-many-positional-arguments
        self, module, phase, handler, args, when=None, root=False, optional=False
    ):
        self.module = module
        self.phase = phase
        self.handler = handler
        self.args = args
        self.when = when or {}
        self.root = root
        self.optional = optional

    def __repr__(self):
        return f"Step({self.module.name}.{self.phase}.{self.handler})"


class Module:
    def __init__(self, name, path, data):
        self.name = name
        self.path = path
        self.description = data["description"]
        self.when = data.get("when") or {}
        self.commands = data.get("commands") or {}
        self.steps = {phase: [] for phase in (*PHASES, "link")}
        home = path / "home"
        self.home = home if home.is_dir() else None

    def __repr__(self):
        return f"Module({self.name})"


def discover(root=None):
    """Return every module under modules/, sorted by name; malformed manifests raise."""
    base = Path(root or ROOT).resolve() / "modules"
    found = []
    for path in sorted(base.glob("*/module.toml")):
        found.append(load(path.parent))
    return found


def load(path):
    path = Path(path)
    name = path.name
    source = path / "module.toml"
    if not NAME.match(name):
        raise ManifestError(f"{source}: module names are one lowercase word")
    try:
        with open(source, "rb") as stream:
            data = tomllib.load(stream)
    except tomllib.TOMLDecodeError as error:
        raise ManifestError(f"{source}: {error}") from error
    unknown = set(data) - TOP_KEYS
    if unknown:
        raise ManifestError(f"{source}: unknown keys {', '.join(sorted(unknown))}")
    if not isinstance(data.get("description"), str):
        raise ManifestError(f"{source}: description is required")
    check_when(data.get("when"), source)
    module = Module(name, path, data)
    for phase in (*PHASES, "link"):
        entries = data.get(phase) or []
        if not isinstance(entries, list):
            raise ManifestError(f"{source}: use [[{phase}]] tables for {phase} steps")
        for entry in entries:
            module.steps[phase].append(step(module, phase, entry, source))
    for command, spec in module.commands.items():
        if not isinstance(spec, dict) or not isinstance(spec.get("run"), str):
            raise ManifestError(f"{source}: [commands.{command}] needs run")
    return module


def step(module, phase, entry, source):
    if phase == "link":
        if not {"from", "to"} <= set(entry):
            raise ManifestError(f"{source}: [[link]] entries need from and to")
        when = entry.get("when")
        check_when(when, source)
        args = {key: value for key, value in entry.items() if key != "when"}
        return Step(module, "link", "link", args, when)
    handlers = [key for key in entry if key not in STEP_KEYS]
    if len(handlers) != 1:
        raise ManifestError(f"{source}: each [[{phase}]] step names exactly one handler")
    check_when(entry.get("when"), source)
    handler = handlers[0]
    return Step(
        module,
        phase,
        handler,
        entry[handler],
        entry.get("when"),
        bool(entry.get("root")),
        bool(entry.get("optional")),
    )


def check_when(when, source):
    if when is None:
        return
    if not isinstance(when, dict) or set(when) - WHEN_KEYS:
        raise ManifestError(f"{source}: when accepts {', '.join(sorted(WHEN_KEYS))}")


def select(modules, names):
    """Pick modules by name, preserving discovery order; unknown names raise."""
    if not names:
        return list(modules)
    known = {module.name: module for module in modules}
    missing = [name for name in names if name not in known]
    if missing:
        raise ValueError(f"Unknown module: {', '.join(missing)} (see: jsh list)")
    return [module for module in modules if module.name in names]
