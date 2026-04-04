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

- **Lite** (default): runs `jsh` without changing dotfiles
- **Full**: additionally links the managed dotfiles into `HOME`, the XDG config
  directory, and the platform-specific VS Code user directory.

For a noninteractive install, choose the mode explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | JSH_MODE=lite sh -s -- --yes
```
