"""Run a module's own script for work no declarative handler covers.

`script: NAME [ARGS]` runs modules/<module>/NAME. Bash scripts report through the lib/core.sh
helpers (jsh::added, jsh::changed, jsh::current, jsh::notice, jsh::progress); Python scripts
are imported and their install, configure, or update function receives the task context.
"""

import importlib.util
import os
import select
import shlex
import subprocess
import threading

# Install steps are not rerun by `jsh update`; declare update: steps explicitly.
EXPLICIT = True


def check(args):
    if not isinstance(args, str) or not args.strip():
        raise ValueError("script: needs a file name")


def install(ctx, steps):
    for step in steps:
        run(ctx, step)


configure = update = install


def environment(ctx, step):
    return {
        "JSH_ROOT": str(ctx.root),
        "JSH_MODULE": str(step.module.path),
        "JSH_PHASE": ctx.phase,
        "JSH_PLATFORM": ctx.facts.platform,
        "JSH_DESKTOP": ctx.facts.desktop,
        "JSH_HOST": ctx.facts.host,
        "JSH_DRY_RUN": "1" if ctx.dry_run else "0",
    }


def resolve(step):
    name, *arguments = shlex.split(step.args)
    path = (step.module.path / name).resolve()
    if step.module.path.resolve() not in path.parents or not path.is_file():
        raise ValueError(f"script {name} is not a file in {step.module.name}")
    return path, arguments


def run(ctx, step):
    path, arguments = resolve(step)
    if path.suffix == ".py":
        spec = importlib.util.spec_from_file_location(f"jsh_{step.module.name}_{path.stem}", path)
        script = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(script)
        getattr(script, ctx.phase)(ctx, *arguments)
        return
    reader, writer = os.pipe()
    env = {**os.environ, **environment(ctx, step), "JSH_EVENTS": str(writer)}
    with open(ctx.log, "a", encoding="utf-8") as log:
        log.write(f"$ bash {shlex.join([path.name, *arguments])}\n")
        log.flush()
        process = subprocess.Popen(  # pylint: disable=consider-using-with
            ["bash", str(path), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=step.module.path,
            pass_fds=(writer,),
        )
    os.close(writer)
    finished = threading.Event()
    listener = threading.Thread(target=listen, args=(ctx, reader, finished))
    listener.start()
    code = process.wait()
    finished.set()
    listener.join()
    if code:
        raise RuntimeError(f"{path.name} exited with {code}")


def listen(ctx, reader, finished):
    """Relay events until the script exits; background children may keep the pipe open."""
    actions = {
        "added": ctx.added,
        "changed": ctx.changed,
        "removed": ctx.removed,
        "progress": ctx.progress,
        "notice": ctx.notice,
    }
    buffer = b""
    try:
        while True:
            ready, _, _ = select.select([reader], [], [], 0.1)
            if not ready:
                if finished.is_set():
                    return
                continue
            chunk = os.read(reader, 65536)
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                event, _, text = line.decode(errors="replace").partition(" ")
                if event == "current":
                    ctx.current(int(text) if text.isdigit() else 1)
                elif event in actions:
                    actions[event](text)
    finally:
        os.close(reader)
