# jsh

## Prerequisites

- bash
- curl
- git
- zsh (for full experience)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | sh
```

## Modes

- **Lite** (default): checks the host and checkout, then installs only the
  launcher; it does not initialize submodules, install Homebrew/core packages,
  or change dotfiles.
- **Full**: additionally links the managed dotfiles into `HOME`, the XDG config
  directory, and the platform-specific VS Code user directory. Full setup also
  initializes vendored submodules and, when needed, offers Homebrew (Linuxbrew
  on Linux) and the core packages from `config/homebrew/Brewfile.core`:
  `fzf`, `go-task` (`task`), `jq`, `just`, and `zsh`. Contributor tooling is
  installed separately with `just prepare`.

The installer first prints a component matrix. Each component is checked in
dependency order and shows whether it is current, needs a change, is blocked,
or has an error. Only components that need changes receive a prompt; `--yes`
approves every applicable action. Declining a prerequisite skips its dependent
actions. A dirty checkout prevents an upstream checkout update, but setup can
still reconcile against the current files and report package, submodule,
vendored-asset, or link state. Existing files are backed up by the reversible
managed-link state used by `jsh`.

`j.sh` is the curl-friendly bootstrap: it acquires the checkout when needed
and then delegates to the installed `jsh install` command. From an existing
checkout, `jsh install` is the canonical reconciliation entrypoint and accepts
the same mode, confirmation, and dry-run options.

When a clean checkout differs from its upstream branch, the checkout row asks
whether to fast-forward it. Declining that update keeps the current checkout
and allows the remaining setup components to continue using it.

Use `--dry-run` to print the same resolved plan without cloning, installing,
initializing, or linking anything:

```text
Setup plan (full)
[ok]   Host prerequisites       bash, git, curl, platform, permissions, and network are ready
[ok]   Git checkout             main is current
[plan] Core dependencies        missing: fzf, just; install core packages from Brewfile.core
[plan] Launcher                 ~/.local/bin/jsh is not linked; link ~/.local/bin/jsh
```

For a noninteractive install, choose the mode explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | JSH_MODE=lite sh -s -- --yes
# or, from an existing checkout:
JSH_MODE=full jsh install --yes
```

Later runs re-evaluate the same matrix and leave current components alone, so
rerunning the installer is safe and idempotent. Use `jsh doctor` or the
component plan to investigate anything that remains unavailable.

On macOS, `task configure` starts with a terminal privacy preflight so TCC
prompts appear before the rest of the configuration. It checks `Terminal.app`
by default; use `task configure:permissions APP=iTerm.app` for another
terminal. macOS still requires the user to approve protected-data access.

Contributors can install the core and contributor check/hook tooling from a
checkout with:

```sh
just prepare
```
