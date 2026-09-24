<div align="center">
  <img src=".github/assets/terminal.webp" alt="Jsh terminal prompt" />
</div>

Jsh provides a portable shell runtime and two opt-in levels of workstation management. It supports macOS, Linux, and
Windows Subsystem for Linux (WSL).

![Jsh runtime architecture](assets/runtime.svg)

## Contents

- [Quick Start](#quick-start)
- [Choose an Experience](#choose-an-experience)
- [Update Jsh](#update-jsh)
- [Included Commands](#included-commands)

## Quick Start

On a new machine, run the bootstrap from an interactive terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash
```

This opens the **bare** experience: it clones or updates `~/.jsh`, initializes the runtime submodules, and starts an
isolated shell. It does not install a launcher, edit PATH or shell startup files, deploy managed dotfiles, install the
broader package set, change the login shell, or configure the system. If Git and either Zsh or Bash 5.1+ are unavailable,
the bootstrap asks before installing the missing runtime prerequisites.

Leave the runtime with `exit`. From outside Jsh, `~/.jsh/bin/jsh` and `~/.jsh/bin/jsh runtime` both open it again. Inside
an active Jsh runtime or a shell configured by install or setup, `jsh` and `jsh runtime` show command help instead of
nesting another shell.

## Choose an Experience

Jsh has three explicit installation boundaries:

| Experience | Command       | Includes                                                                                  |
| ---------- | ------------- | ----------------------------------------------------------------------------------------- |
| Bare       | `jsh runtime` | Repository, runtime submodules, and an isolated shell                                     |
| Slim       | `jsh install` | Bare, persistent launcher and PATH, core tools, managed dotfiles, and default-shell offer |
| Full       | `jsh setup`   | Slim, all matching package and application layers, and detected platform configuration    |

Each command is its own consent boundary. Runtime remains ephemeral, install applies only the slim shell environment,
and setup applies the full workstation. Each phase is shown before it runs.

To select a persistent experience directly from a new machine, pass its command to the bootstrap:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash -s -- install
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash -s -- setup
```

Without `-y` or `--yes`, prerequisite installation, repository synchronization, PATH changes, shell changes, and
configuration steps remain interactive. `--yes` accepts prompts only for the selected command; it never widens runtime
to install or install to setup.

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash -s -- --yes setup
# From an active runtime:
jsh --yes setup
```

Package selection is declared in [`conf/packages.json`](conf/packages.json). Its additive layers match the current
operating system, Linux distribution, desktop, hostname, and architecture, then feed the native package manager,
Homebrew, Flatpak, Cargo, uv, and npm installers. Applications with custom release or configuration requirements are
owned by their component scripts. Installers inspect current state before changing it and verify convergence afterward.

## Update Jsh

Run `jsh update` to update the repository and reconcile the installed experience. Bare updates only the runtime; install
reconciles core packages and dotfiles; setup also updates all selected packages, applications, and managed configuration,
then reapplies platform patches.
The persistent scope is stored at `${XDG_STATE_HOME:-$HOME/.local/state}/jsh/install-profile`. When no state exists, Jsh
defaults to bare unless deployed Jsh dotfiles identify a legacy full installation.

## Included Commands

The [`bin/`](bin/) directory is added to `PATH` inside Jsh.

| Command                      | Description                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------------- |
| [`cafe`](bin/cafe)           | Keeps the system awake for a command or a specified duration.                         |
| [`colours`](bin/colours)     | Prints the terminal's 256-color palette.                                              |
| [`helium`](bin/helium)       | Applies, verifies, and launches a hardened Helium browser profile.                    |
| [`httpstat`](bin/httpstat)   | HTTP(S) request visualizer.                                                           |
| [`jadopt`](bin/jadopt)       | Moves selected home paths into the shared dotfiles package.                           |
| [`jbrew`](bin/jbrew)         | J-augmented {home,linux}brew command. Better cross-platform search and easy adoption. |
| [`jfetch`](bin/jfetch)       | J-augmented fastfetch-inspired command.                                               |
| [`jgit`](bin/jgit)           | Git identity, history, update, backup, and broken-ref workflows.                      |
| [`jgraphify`](bin/jgraphify) | Creates or incrementally updates Graphify data for a project.                         |
| [`jmount`](bin/jmount)       | Mounts SMB and NFS shares from URLs or local profiles.                                |
| [`jsh`](bin/jsh)             | Opens the isolated shell and dispatches setup, repair, and adoption commands.         |
| [`jssh`](bin/jssh)           | Opens an ephemeral Jsh shell on a Linux host over SSH.                                |
| [`jstow`](bin/jstow)         | Provides a Bash implementation of GNU Stow for deploying and removing dotfile links.  |
| [`jventoy`](bin/jventoy)     | Initializes and updates bootable ISO images on Ventoy drives.                         |
| [`jvim`](bin/jvim)           | Runs Neovim with Jsh-local data and cache directories, with Vim or Vi as fallbacks.   |
| [`kubecolor`](bin/kubecolor) | Colorizes interactive `kubectl` output while preserving machine-readable formats.     |
| [`kubectx`](bin/kubectx)     | Lists, switches, renames, and removes Kubernetes contexts.                            |
| [`kubens`](bin/kubens)       | Lists and switches Kubernetes namespaces for the current context.                     |
| [`nukem`](bin/nukem)         | Helps handle those pesky Kubernetes finalizers.                                       |
| [`proxy`](bin/proxy)         | Forces commands through proxy.                                                        |
| [`spotifix`](bin/spotifix)   | Plays random Spotify library selections with optional shuffle modes.                  |
| [`sublime`](bin/sublime)     | Opens files or directories in Sublime Text.                                           |
| [`waterfix`](bin/waterfix)   | Controls Waterfox, manages add-ons, organizes bookmarks, and restores favicons.       |
