"""Interactive first-run selection and machine-local module preferences."""

import json
import io
import os
import shlex
import sys
from contextlib import redirect_stdout
from pathlib import Path

from jsh import handlers, menu, runner, system

GROUPS = {
    "Essentials": ("core", "shell", "tools", "fonts"),
    "Desktop": ("desktop", "dock", "keybindings", "wallpaper", "audio", "display"),
    "Applications": ("apps", "ghostty", "helium", "sublime", "vscode", "waterfox"),
    "Development": ("ai", "containers", "dev", "git", "kube", "skills"),
    "System": ("linux", "macos", "services"),
}


def path():
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return state / "jsh" / "selection.json"


def load():
    file = path()
    if not file.exists():
        return None
    try:
        data = json.loads(file.read_text(encoding="utf-8"))
        modules = data["modules"]
        optional = data["optional"]
        if (
            not isinstance(modules, list)
            or not modules
            or not all(isinstance(name, str) for name in modules)
            or not isinstance(optional, list)
            or not all(name in modules for name in optional)
        ):
            raise ValueError("invalid module selection")
        return data
    except (ValueError, KeyError, TypeError) as error:
        message = f"Invalid selection in {file}: {error}; run ./j.sh to choose again"
        raise ValueError(message) from error


def choose(prompt, choices, default):
    """Choose by name or number, with all, none and a default."""
    names = [item.name for item in choices]
    while True:
        answer = input(prompt).strip().lower()
        if not answer:
            return list(default)
        if answer in ("all", "none"):
            return names if answer == "all" else []
        selected = []
        for part in answer.replace(",", " ").split():
            if part.isdigit() and 1 <= int(part) <= len(names):
                part = names[int(part) - 1]
            if part not in names:
                print(f"Unknown choice: {part}")
                break
            if part not in selected:
                selected.append(part)
        else:
            return selected


def optional_steps(module, facts):
    return [
        step
        for phase in ("install", "configure", "update")
        for step in module.steps[phase]
        if step.optional
        and facts.matches(step.when)
        and handlers.applies(handlers.get(step.handler), facts)
    ]


def banner():
    source = (system.ROOT / "lib/output.sh").read_text(encoding="utf-8")
    return source.split("<<'BANNER'\n", 1)[1].split("\nBANNER", 1)[0]


def details(selected, facts, optional):  # pylint: disable=too-many-locals
    """Describe planned steps without claiming scripts have a complete preview."""
    tasks = runner.plan(selected, ("install", "link", "configure"), facts, optional)
    result = []
    for task in tasks:
        for step in task.steps:
            deferred = step.root or step.handler in ("apt", "dnf")
            prefix = "Skipped in wizard; run with jsh: " if deferred else ""
            if step.handler == "link":
                from jsh.handlers import link  # pylint: disable=import-outside-toplevel

                for source, target in link.pairs(step):
                    state = (
                        "Existing target will be reviewed or backed up"
                        if (target.exists() or target.is_symlink())
                        else "New link"
                    )
                    description = f"Source: {source}\nDestination: {target}\n{state}"
                    result.append((step.module.name, f"{prefix}link {target}", description))
            elif step.handler == "script":
                script = (step.module.path / shlex.split(step.args)[0]).resolve()
                description = "Individual changes are not fully available in preview."
                if step.module.path.resolve() in script.parents and script.is_file():
                    description += f"\n\nSource: {script}\n\n" + script.read_text(encoding="utf-8")
                for name in (
                    "preferences.json",
                    "policy.json",
                    "policies.json",
                    "state.json",
                    "keybindings.json",
                    "user.js",
                ):
                    data = step.module.path / name
                    if data.is_file():
                        description += f"\n\nManaged data: {data}\n\n" + data.read_text(
                            encoding="utf-8"
                        )
                result.append((step.module.name, f"{prefix}{step.phase}: {step.args}", description))
            else:
                result.append(
                    (step.module.name, f"{prefix}{step.phase} {step.handler}", str(step.args))
                )
    return result


def apply(command, modules, optional):
    """Apply the approved plan and enter the runtime after a successful setup."""
    from jsh import cli  # pylint: disable=import-outside-toplevel,cyclic-import

    status = cli.run(command, modules, optional, False, user_only=True)
    if status == 0 and command == "setup":
        cli.enter_runtime()
    return status


def interactive(
    found, facts, saved
):  # pylint: disable=too-many-locals,too-many-branches,too-many-statements
    from jsh import cli  # pylint: disable=import-outside-toplevel,cyclic-import

    available = [module for module in found if facts.matches(module.when)]
    names = {module.name for module in available}
    saved_names = [name for name in (saved["modules"] if saved else []) if name in names]
    minimal = [name for name in ("core", "shell") if name in names]
    workstation = [
        name
        for name in (
            "core",
            "shell",
            "tools",
            "fonts",
            "desktop",
            "dock",
            "keybindings",
            "wallpaper",
            "audio",
            "display",
        )
        if name in names
    ]
    choices = [
        ("minimal", "Minimal", "Core tools and shell"),
        ("workstation", "Workstation", "Shell, tools and desktop"),
        ("custom", "Custom", "Choose modules yourself"),
    ]
    if saved_names:
        choices.append(("previous", "Previous", "Use saved choices"))
    preset = menu.choose("\n" + banner(), choices, title_color="36")
    if preset is None:
        return 0
    selected = {
        "minimal": minimal,
        "workstation": workstation,
        "custom": [],
        "previous": saved_names,
    }[preset]
    categories = {name: group for group, members in GROUPS.items() for name in members}
    order = {name: index for index, name in enumerate(GROUPS)}
    items = [
        (module.name, f"{categories.get(module.name, 'Other')} / {module.name}", module.description)
        for module in sorted(
            available,
            key=lambda item: (order.get(categories.get(item.name), len(order)), item.name),
        )
    ]
    while True:
        chosen = menu.choose("Setup · Choose modules", items, selected, multiple=True)
        if chosen is None:
            preset = menu.choose("\n" + banner(), choices, title_color="36")
            if preset is None:
                return 0
            selected = {
                "minimal": minimal,
                "workstation": workstation,
                "custom": [],
                "previous": saved_names,
            }[preset]
            continue
        selected = chosen
        if not selected:
            return 0
        modules = [module for module in available if module.name in selected]
        extras = [module for module in modules if optional_steps(module, facts)]
        optional = (
            [name for name in (saved["optional"] if saved else []) if name in selected]
            if preset == "previous"
            else []
        )
        if extras:
            items_extra = [
                (
                    module.name,
                    module.name,
                    "; ".join(
                        f"{step.phase} {step.handler}: {step.args}"
                        for step in optional_steps(module, facts)
                    ),
                )
                for module in extras
            ]
            optional = menu.choose(
                "Setup · Choose optional steps", items_extra, optional, multiple=True
            )
            if optional is None:
                continue
        print("Checking the selected changes…", flush=True)
        preview = io.StringIO()
        with redirect_stdout(preview):
            preview_status = cli.run("setup", modules, optional, True, user_only=True)
        preview_text = preview.getvalue()
        while True:
            decision = menu.view(
                "Setup · Preview and approve",
                preview_text + "\nExisting files may be backed up; apps may close and reopen.\n",
                actions=True,
            )
            if decision is None:
                return 0
            if decision == "change":
                break
            if decision == "details":
                entries = details(modules, facts, optional)
                while entries:
                    options = [
                        (str(index), f"{module}: {label}", description.splitlines()[0])
                        for index, (module, label, description) in enumerate(entries)
                    ]
                    picked = menu.choose("Setup · Plan details", options)
                    if picked is None:
                        break
                    module, label, description = entries[int(picked)]
                    menu.view(f"{module}: {label}", description)
            elif decision == "apply":
                if preview_status:
                    menu.view("Preview failed", "Fix the reported errors before applying.")
                    continue
                file = path()
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(
                    json.dumps({"modules": selected, "optional": optional}, indent=2) + "\n",
                    encoding="utf-8",
                )
                return apply("setup", modules, optional)


def start(found):  # pylint: disable=too-many-locals,too-many-branches
    if not sys.stdin.isatty():
        raise ValueError("The setup wizard needs an interactive terminal; run ./j.sh in a terminal")
    from jsh import cli  # pylint: disable=import-outside-toplevel,cyclic-import

    facts = system.Facts()
    available = [module for module in found if facts.matches(module.when)]
    try:
        saved = load()
    except ValueError as error:
        print(f"{error}; choosing a new selection")
        saved = None
    if menu.available():
        return interactive(found, facts, saved)
    print(banner())
    print(f"\nSet up jsh on {facts.platform}" + (f" ({facts.desktop})" if facts.desktop else ""))
    print("Choose modules by number or name, separated by spaces or commas.")
    for index, module in enumerate(available, 1):
        print(f"  {index:2}. {module.name:12} {module.description}")
    defaults = [
        name
        for name in (saved["modules"] if saved else [])
        if name in {module.name for module in available}
    ]
    if not defaults:
        defaults = [module.name for module in available if module.name in ("core", "shell")]
    print(f"Default: {', '.join(defaults)}. Enter 'all' for everything.")
    names = choose("Modules: ", available, defaults)
    if not names:
        print("No modules selected; nothing changed.")
        return 0
    selected = [module for module in available if module.name in names]
    optional_modules = [module for module in selected if optional_steps(module, facts)]
    optional = []
    if optional_modules:
        print("\nOptional steps (these are excluded unless chosen):")
        for index, module in enumerate(optional_modules, 1):
            for step in optional_steps(module, facts):
                print(f"  {index}. {module.name}: {step.phase} {step.handler} {step.args}")
        prior = saved["optional"] if saved else []
        defaults = [name for name in prior if name in names]
        print(f"Default: {', '.join(defaults) or 'none'}.")
        optional = choose("Enable optional steps for modules: ", optional_modules, defaults)
    print("\nChoose a phase: setup (install, link, configure), install, link, or configure.")
    while True:
        command = input("Phase [setup]: ").strip().lower() or "setup"
        if command in ("setup", "install", "link", "configure"):
            break
        print("Choose setup, install, link, or configure.")
    print("\nPreview (some scripts can only describe their changes):")
    if cli.run(command, selected, optional, True, user_only=True):
        print("Preview failed; nothing was applied.")
        return 1
    print("Existing files may be backed up; apps may close and reopen for required changes.")
    if input("Save this selection and apply the plan? [y/N] ").strip().lower() not in ("y", "yes"):
        print("Cancelled; selection was not saved.")
        return 0
    file = path()
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(
        json.dumps({"modules": names, "optional": optional}, indent=2) + "\n", encoding="utf-8"
    )
    return apply(command, selected, optional)
