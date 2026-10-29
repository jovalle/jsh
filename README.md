# jsh

A small workstation setup tool for macOS, Debian-family Linux, and RHEL-family Linux.
Everything it sets up lives in a module: one folder under [modules/](modules) with a
`module.json` that says what to install, which files to link, and what to configure.
Add a folder to add a module; delete it to remove one.

```text
jsh setup 1d5a32f (darwin)

+ ripgrep
+ ~/.config/ghostty/config
~ com.apple.dock autohide

2 installed, 1 linked, 1 configured [41.20s]
```

## Getting started

Clone this repository to `~/.jsh`. Jsh needs Bash and Python 3.9 or later. When no such
Python is on the machine, `j.sh`
installs one first: with Homebrew on macOS (install [Homebrew](https://brew.sh) first),
or with apt or dnf on Linux (run `sudo -v` first). Then:

```sh
~/.jsh/j.sh setup --dry-run   # Show what would change
~/.jsh/j.sh setup             # Install, link, and configure every module
```

`setup` links `~/.local/bin/jsh`, so later runs are just `jsh COMMAND`:

| Command                     | Does                                                            |
| --------------------------- | --------------------------------------------------------------- |
| `jsh setup [MODULE...]`     | `install`, then `link`, then `configure`                        |
| `jsh install [MODULE...]`   | Install missing software; never upgrades                        |
| `jsh link [MODULE...]`      | Link each module's `home/` files into your home directory       |
| `jsh configure [MODULE...]` | Apply settings: OS preferences, desktop, apps                   |
| `jsh update [MODULE...]`    | Upgrade declared software that has a newer version              |
| `jsh status [MODULE...]`    | Show checkout state, missing software, and unlinked files       |
| `jsh list`                  | List modules and their commands                                 |
| `jsh MODULE COMMAND`        | Run a module command, for example `jsh audio cycle`             |
| `jsh`                       | Open the isolated jsh Zsh shell (history under `local/runtime`) |

With no module names a command covers every module that applies to this machine.
`--dry-run` reports what would change without changing anything. A failed step is
reported with the end of its log and the log path under `local/logs/`; later steps
still run. Root changes use `sudo -n`, so authorize sudo first (`sudo -v`); jsh never
prompts for a password and never asks for confirmation. Zsh completes `jsh` commands,
module names, and module commands.

## Modules

A module is `modules/NAME/` (one lowercase word) containing:

- `module.json`: the manifest (below).
- `home/`: files linked into `$HOME` at the same relative path, one link per file.
- Scripts and data files that its steps refer to.

A `link` entry links its `from` path (relative to the module) to `to` as one link,
so a directory is linked whole.

```json
{
  "description": "Example app with its settings and a shortcut command",
  "when": { "platform": ["darwin", "linux"] },
  "install": [
    { "brew": { "casks": ["example"] } },
    {
      "appimage": {
        "name": "example",
        "release": "https://api.github.com/repos/example/example/releases/latest"
      }
    }
  ],
  "configure": [{ "script": "configure.py" }],
  "link": [{ "from": "settings.json", "to": "~/.config/example/settings.json" }],
  "commands": { "sync": { "run": "sync.sh", "about": "Sync example data now" } }
}
```

Each `install`, `configure`, or `update` step names one handler and may add
`when` (same keys as the module; optional: `platform`, `desktop`, `host`),
`"root": true` (skip with a notice when sudo is not authorized), or `"optional": true`
(run only when the module is named, as in `jsh install sublime`). `platform` matches
`darwin`, `debian`, `rhel`, or `linux`; `desktop` matches `darwin`, `gnome`, or `xfce`;
`host` matches the short host name. Malformed manifests are rejected with the file and
the problem.

| Handler    | Arguments                              | `install`                            | `update`                      |
| ---------- | -------------------------------------- | ------------------------------------ | ----------------------------- |
| `brew`     | `taps`, `formulae`, `casks` lists      | Missing ones (casks on macOS only)   | Declared, outdated ones       |
| `apt`      | package list (Debian family)           | Missing ones, `--no-upgrade`         | Declared, upgradable ones     |
| `dnf`      | package list (RHEL family)             | Missing ones                         | Declared, upgradable ones     |
| `flatpak`  | app ID list (Linux, Flathub, per user) | Missing ones                         | Apps with updates             |
| `appimage` | `name`, `release` URL, `architectures` | Into `~/.local/bin`, SHA-256 checked | When the release digest moves |
| `uv`       | `command: package` pairs               | Missing commands                     | `uv tool upgrade`             |
| `git`      | `path: url` pairs under `local/vendor` | Shallow clones                       | Reset to the remote `HEAD`    |
| `script`   | `NAME [ARGS]`, a file in the module    | Runs in whichever phase lists it     | Only from `update:`           |

Batched handlers (`brew`, `apt`, `dnf`, `flatpak`, `uv`, `git`) collect every module's
steps into one call per run. Python scripts define `install(ctx)`, `configure(ctx)`,
or `update(ctx)` and report through `ctx.added`, `ctx.changed`, `ctx.current`,
`ctx.notice`, and `ctx.run`; [lib/jsh/](lib/jsh) has shared helpers for settings
files, policies, downloads, and desktop settings. Bash scripts source
`lib/core.sh` and report with `jsh::added`, `jsh::changed`, `jsh::current`, and
`jsh::notice`. A new handler is a file in [lib/jsh/handlers/](lib/jsh/handlers).

## What the modules cover

| Module                                                 | Covers                                                                       |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `core`                                                 | Bash, curl, Git, Python, Zsh                                                 |
| `shell`                                                | `.zshrc` and friends, Zsh plugins in `local/vendor`, fzf, the `jsh` launcher |
| `tools`                                                | Everyday CLI tools and their settings (Homebrew on Linux when installed)     |
| `dev`, `kube`, `containers`, `ai`                      | Linters, Kubernetes, container, and AI CLIs                                  |
| `git`                                                  | `.gitconfig`                                                                 |
| `fonts`                                                | JetBrains Mono Nerd Font                                                     |
| `apps`                                                 | Apps without managed settings; extra casks on the `archon` host              |
| `helium`, `waterfox`, `vscode`, `sublime`, `ghostty`   | The app plus its managed settings                                            |
| `macos`                                                | `defaults` preferences, restarting Dock, Finder, or SystemUIServer           |
| `linux`                                                | Kernel limits, memory, earlyoom, zram, coredump, sleep, timezone, sudo       |
| `services`                                             | SSH agent, GPG agent, and Podman user services                               |
| `desktop`                                              | GNOME/XFCE appearance, panel, screensaver, and GNOME extensions              |
| `dock`, `keybindings`, `wallpaper`, `audio`, `display` | Desktop behavior and shortcuts                                               |

Notes:

- Linux AppImages need x86_64 or aarch64 and a working FUSE runtime. Ghostty's Linux
  AppImage is a [community build](https://github.com/pkgforge-dev/ghostty-appimage).
- Sublime Text's cask is optional, so a manual macOS install is left alone.
- `JSH_TIMEZONE` (default `America/New_York`), `JSH_WALLPAPER` (no default), and
  `JSH_AUDIO_POLICY` adjust the `linux`, `wallpaper`, and `audio` modules.
- Browsers are never closed for you; open each once to create a profile, close it,
  then run `jsh configure helium waterfox`. Policies are root-owned and replaced
  wholesale; app settings files are merged, keeping unrelated settings.
- Replaced files go to `$XDG_STATE_HOME/jsh/backups` (normally
  `~/.local/state/jsh/backups`); a stale link into this checkout is replaced without
  one. Targets under a symlinked directory are left for you to review.
- Personal shell additions belong in `~/.jshrc`, `~/.local/.jshrc`, or `local/.jshrc`.
  Git identities live in `conf/git.json` (see [conf/git.example.json](conf/git.example.json)).

## Commands

`j` is a Zsh function loaded by `.zshrc`:

- `j` loads the SSH keys named in `conf/git.json`, checks this checkout, links, and
  core tools, then runs executables in `local/init.d`.
- `j status` summarizes the Git repositories in `J_PATHS`.
- `j QUERY` jumps to a directory by frecency; `j pick` chooses one; `j --help` lists
  the rest.

Integrations can show a directory relative to a project root in the prompt by setting
`_JSH_PROMPT_DIR_ROOT` and a prompt-formatted `_JSH_PROMPT_DIR_LABEL` from a `precmd`
hook.

These commands are on `PATH` through `bin/`:

| Command                    | Purpose                                                        |
| -------------------------- | -------------------------------------------------------------- |
| [cafe](bin/cafe)           | Keep the computer awake until interrupted                      |
| [colours](bin/colours)     | Print the terminal's 256-color palette                         |
| [git](bin/git)             | Git plus `save`, `load`, `refresh`, `profile`, and `commit -t` |
| [jsh](bin/jsh)             | Open the jsh Zsh shell, or run `jsh COMMAND` from anywhere     |
| [jssh](bin/jssh)           | Open an ephemeral jsh Zsh session on a Linux SSH host          |
| [kubecolor](bin/kubecolor) | Colorize interactive `kubectl` output                          |
| [kubectx](bin/kubectx)     | Switch between kubectl contexts                                |
| [kubens](bin/kubens)       | Switch between Kubernetes namespaces                           |
| [nukem](bin/nukem)         | Remove finalizers from a namespace stuck terminating           |
| [proxy](bin/proxy)         | Run a command with proxy environment variables set             |

## Development

```sh
make check   # syntax, headers, readme, modules, lint, and test
make help    # each check on its own
```

Runtime uses only Bash and the Python 3.9+ standard library. Checks also need Zsh,
ShellCheck, Pylint, yamllint, and markdownlint. Tests use temporary home directories
and mocked commands; no check changes the machine.
