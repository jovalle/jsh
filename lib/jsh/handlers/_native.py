"""Shared logic for the apt and dnf handlers."""

import subprocess

from jsh import system


def check(args):
    if not isinstance(args, list) or not all(isinstance(name, str) for name in args):
        raise ValueError("expected a list of package names")


def units(step):
    return len(step.args)


def mapping(steps):
    """Merge `name: value` step arguments; later steps win."""
    merged = {}
    for step in steps:
        merged.update(step.args)
    return merged


def names(steps):
    merged = []
    for step in steps:
        merged += [name for name in step.args if name not in merged]
    return merged


def install(ctx, steps, manager):
    wanted = names(steps)
    absent = [name for name in wanted if not manager.installed(name)]
    ctx.current(len(wanted) - len(absent))
    if not absent:
        return
    if not ctx.dry_run and not ctx.admin():
        ctx.notice(f"missing {', '.join(absent)}; run sudo -v first, then rerun")
        return
    ctx.progress(", ".join(absent))
    manager.add(ctx, absent)
    for name in absent:
        ctx.added(name)


def update(ctx, steps, manager):
    wanted = names(steps)
    if not ctx.dry_run and not ctx.admin():
        ctx.notice("needs sudo; run sudo -v first, then rerun")
        return
    ctx.progress("checking for updates")
    stale = {name: text for name, text in manager.upgradable(ctx).items() if name in wanted}
    ctx.current(len(wanted) - len(stale))
    if stale:
        ctx.progress(", ".join(stale))
        manager.upgrade(ctx, list(stale))
        for text in stale.values():
            ctx.changed(text)


class Apt:
    environment = {"DEBIAN_FRONTEND": "noninteractive"}

    @staticmethod
    def installed(name):
        status = system.query(["dpkg-query", "-W", "-f=${db:Status-Status}", name])
        return status == "installed"

    def add(self, ctx, names_):
        ctx.run(["apt-get", "update"], root=True, env=self.environment)
        command = ["apt-get", "install", "--no-upgrade", "-y", "--", *names_]
        ctx.run(command, root=True, env=self.environment)

    def upgradable(self, ctx):
        ctx.run(["apt-get", "update"], root=True, env=self.environment)
        found = {}
        for line in system.query(["apt", "list", "--upgradable"]).splitlines():
            if "/" not in line or "upgradable from" not in line:
                continue
            name = line.split("/", 1)[0]
            fields = line.split()
            old = line.rsplit("upgradable from: ", 1)[-1].rstrip("]")
            found[name] = f"{name} {old} → {fields[1]}"
        return found

    def upgrade(self, ctx, names_):
        command = ["apt-get", "install", "--only-upgrade", "-y", "--", *names_]
        ctx.run(command, root=True, env=self.environment)


class Dnf:
    @staticmethod
    def installed(name):
        return bool(system.query(["rpm", "-q", name]))

    @staticmethod
    def add(ctx, names_):
        ctx.run(["dnf", "install", "-y", "--", *names_], root=True)

    @staticmethod
    def upgradable(ctx):
        del ctx
        found = {}
        # check-update exits 100 when updates exist, so read stdout regardless of status.
        result = subprocess.run(
            ["dnf", "check-update", "-q"], check=False, text=True, capture_output=True
        )
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) == 3 and "." in fields[0]:
                name = fields[0].rsplit(".", 1)[0]
                found[name] = f"{name} → {fields[1]}"
        return found

    @staticmethod
    def upgrade(ctx, names_):
        ctx.run(["dnf", "upgrade", "-y", "--", *names_], root=True)
