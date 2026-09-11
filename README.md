<div align="center">
  <img src=".github/assets/terminal.webp" alt="Jsh terminal prompt" />
</div>

Jsh provides an isolated shell you can try without replacing your dotfiles, plus an installer for adopting the
environment across a machine. It supports macOS, Linux, and Windows Subsystem for Linux (WSL).

## Contents

- [Run Jsh](#run-jsh)
- [Install the Jsh Command](#install-the-jsh-command)
- [Install Jsh](#install-jsh)
- [Included Commands](#included-commands)

## Run Jsh

Run the bootstrap script from an interactive terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash
```

This clones or updates Jsh in `~/.jsh`, initializes its submodules, and opens an isolated Zsh session. It does not link
dotfiles into your home directory or run the system configuration scripts. If Git or Zsh is missing, the bootstrap asks
before installing it with pacman on Arch-based Linux or Homebrew elsewhere.

Leave the runtime with `exit`.

## Install the Jsh Command

To keep Jsh available as a command without deploying managed dotfiles or configuring the system, run:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash -s -- runtime
```

This installs `jsh` at `~/.local/bin/jsh` and offers to add that directory to your Bash and Zsh startup files. You can
also run `jsh runtime` from an existing checkout. Afterward, `jsh` opens the isolated shell and `jsh install` starts the
full installation.

## Install Jsh

Run the same bootstrap with the `install` command:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | bash -s -- install
```

The installer checks its prerequisites, clones or updates `~/.jsh`, deploys the managed dotfiles, installs packages, and
offers the configuration and patching steps for the detected platform. It describes each phase and prompts before it
runs. Some platform scripts make privileged or destructive changes; review their prompts before accepting them. Add
`--yes` to accept the setup workflow prompts. After installation, run `jsh update` to update the repository,
dependencies, packages, and managed configuration.

## Included Commands

The [`bin/`](bin/) directory is added to `PATH` inside Jsh.

| Command                      | Description                                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| [`cafe`](bin/cafe)           | Keeps the system awake for a command or a specified duration.                          |
| [`colours`](bin/colours)     | Prints the terminal's 256-color palette.                                               |
| [`httpstat`](bin/httpstat)   | HTTP(S) request visualizer.                                                            |
| [`jbrew`](bin/jbrew)         | J-augmented {home,linux}brew command. Better cross-platform search and easy adoption.  |
| [`jfetch`](bin/jfetch)       | J-augmented fastfetch-inspired command.                                                |
| [`jgit`](bin/jgit)           | J-augmented git command.                                                               |
| [`jsh`](bin/jsh)             | Opens the isolated shell and dispatches runtime, install, update, and reload commands. |
| [`jssh`](bin/jssh)           | Opens an ephemeral Jsh shell on a Linux host over SSH.                                 |
| [`jstow`](bin/jstow)         | Provides a Bash implementation of GNU Stow for deploying and removing dotfile links.   |
| [`jventoy`](bin/jventoy)     | Initializes and updates bootable ISO images on Ventoy drives.                          |
| [`jvim`](bin/jvim)           | Runs Neovim with Jsh-local data and cache directories, with Vim or Vi as fallbacks.    |
| [`kubecolor`](bin/kubecolor) | Colorizes interactive `kubectl` output while preserving machine-readable formats.      |
| [`kubectx`](bin/kubectx)     | Lists, switches, renames, and removes Kubernetes contexts.                             |
| [`kubens`](bin/kubens)       | Lists and switches Kubernetes namespaces for the current context.                      |
| [`nukem`](bin/nukem)         | Helps handle those pesky Kubernetes finalizers.                                        |
| [`proxy`](bin/proxy)         | Forces commands through proxy.                                                         |
