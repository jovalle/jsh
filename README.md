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
  `go-task` (`task`), `jq`, `just`, and `zsh`. It installs `fzf` from the pinned
  `vendor/fzf` submodule without changing shell configuration files; jsh loads
  the integration itself. Contributor tooling is installed separately with
  `just prepare`.

For a noninteractive install, choose the mode explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/j.sh | JSH_MODE=lite sh -s -- --yes
# or, from an existing checkout:
JSH_MODE=full jsh install --yes
```
