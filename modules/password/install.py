"""Install 1Password from its configured Linux package repository."""

import shutil

from jsh import apps, system


def install(ctx):
    if shutil.which("1password"):
        ctx.current()
        return
    debian = ctx.facts.platform == "debian"
    query = (
        ["dpkg-query", "-W", "-f=${db:Status-Status}", "1password"]
        if debian
        else ["rpm", "-q", "1password"]
    )
    installed = system.query(query)
    if (debian and installed == "installed") or (not debian and bool(installed)):
        ctx.current()
        return
    if apps.defer(ctx):
        return
    available = (
        ["apt-cache", "show", "1password"]
        if debian
        else ["dnf", "repoquery", "--available", "1password"]
    )
    if not system.query(available):
        ctx.notice(
            "add the 1Password Linux package repository: "
            "https://support.1password.com/install-linux/"
        )
        return
    if ctx.dry_run:
        ctx.added("1password")
        return
    if not ctx.admin():
        ctx.notice("needs sudo to install 1Password; run sudo -v first, then rerun")
        return
    command = (
        ["apt-get", "install", "--no-upgrade", "-y", "1password"]
        if debian
        else ["dnf", "install", "-y", "1password"]
    )
    ctx.run(command, root=True)
    ctx.added("1password")
