<div align="center">
  <img src="jsh.jpeg" width="200px" height="200px" />

  # jsh

  <p>
    A collection of files to improve life in the shell
  </p>
</div>

## 📖 Overview

A feature-rich and consistent life in the shell. This is a mono repository for my local environments in both macOS and Linux (+WSL). I sync this project/directory across my devices using [Syncthing](https://syncthing.net/).

## 📚 Core Elements

My shell of choice is `zsh` with [oh-my-zsh](https://github.com/ohmyzsh/ohmyzsh) as the shell framework. Bootstrapping with [`task`](https://github.com/go-task/task) and [`stow`](https://www.gnu.org/software/stow/).

### 🔌 Shell Plugins

- `fzf`: Fuzzy finder enabled in shell reverse search and in `vim`
- `powerlevel10k`: Stunning yet functional shell prompt
- `zinit`: Shell framework that enables themes and plugins
- `zsh-autosuggestions`: Pseudo auto-completion like in `fish` shell
- `zsh-highlighting`: Emphasizes, as you write, if a command/file/directory is missing (usually due to a typo)

### 🍟 Binaries

Scripts at `./bin/` are imported into `PATH`:

- `colours`: Unlocks full 8-bit colors in the shell
- `httpstat`: Quick and easy HTTP requests with light benchmarking
- `kubectx`: Must-have script for managing local Kubernetes configuration contexts
- `kubens`: Similar to `kubectx` but for cluster namespaces
- `nukem`: Quick and dirty script for eliminating pesky finalizers in Kubernetes
- `sshrc`: Copies shell customizations to SSH targets for duration of sessions

### 📝 Configurations

Project includes custom configs for `iTerm2` and `vscode`.

### 🖍️ Customization

#### 🎨 Theme

[Night Owl](https://marketplace.visualstudio.com/items?itemName=sdras.night-owl) is the default theme. If only it was as widely supported as [Dracula](https://draculatheme.com/)... 🤷🏽‍♂️

## 🐣 Prerequisites

Taskfile is a needed! Install via `./setup.sh`.

### Font

Using [JetBrainsMono](https://www.jetbrains.com/lp/mono/) with [FiraCode](https://github.com/tonsky/FiraCode) and [Meslo](https://github.com/andreberg/Meslo-Font) as backups.

Installation should procure the fonts automatically but you may need to restart your app(s).

## 📲 Install

```sh
task install
```

### 🗑️ Uninstall

```sh
task uninstall
```
