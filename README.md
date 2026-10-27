# jsh

A small workstation setup tool for macOS, Debian-family Linux, and RHEL-family Linux.
Plain output, the original jsh banner, and five jobs:

- Install software.
- Link dotfiles.
- Apply OS preferences.
- Customize desktop, dock, audio, display, wallpaper, and keyboard behavior.
- Configure Helium, Waterfox, VS Code, Sublime Text, and AI agent clients.

## Getting started

Clone this repository to `~/.jsh`. Jsh requires Bash, Python 3.9 or later, and
[just](https://just.systems). On macOS, install [Homebrew](https://brew.sh) and
Python first. On Linux, use the system Python package. Install just with
`uv tool install rust-just` or `python3 -m pip install --user rust-just`; the
`tools` group installs it the same way. Add `~/.jsh/bin` and `~/.local/bin` to
your `PATH`.

Run setup from the checkout with just:

```sh
just                        # Show recipes
just list                   # Show available targets
just setup --dry-run        # Preview all five jobs
just install core --dry-run
just install tools
just install runtime
just install apps
just install helium
just set dotfiles
just tweak preferences
just customize keybindings
just customize desktop
just customize display --dry-run
JSH_WALLPAPER="$HOME/Pictures/wallpaper.jpg" just customize wallpaper
just configure waterfox
just configure              # Configure all apps and agent clients
```

The [jsh command](bin/jsh) opens the isolated shell: Zsh with this checkout's
`dotfiles/.zshrc`, keeping history and caches under `local/runtime`. Arguments
pass through to Zsh, for example `jsh -ic 'j status'`. Inside a Jsh shell,
`jsh reload` re-reads `.zshrc`.

Recipes ask before applying changes. Use `--yes` for unattended runs of the
selected recipe. `--dry-run` never writes files, downloads software, invokes
sudo, or restarts applications. Installation checks locally installed packages;
dry runs do not resolve the latest remote versions.

Customization components are `wallpaper`, `keybindings`, `desktop`, `dock`,
`audio`, and `display`. Omitting the component, or selecting `all`, runs all six.

`just setup` runs install, dotfiles, tweak, customize, then configure. On Linux
without root or an authorized `sudo -n` session, it runs only
`install runtime extensions`, dotfiles, customize, and configure. A failed job
does not stop the later ones; rerun the individual recipe after fixing the cause.
Packages that cannot be installed are reported and skipped. Unsupported
desktop sessions and uninitialized or running browser profiles are reported as
skips. Initialize each browser once, close it, then run `just configure` again.

Privileged package and system changes use `sudo -n`. Authorize sudo in your own
terminal before running a job that requires it. Jsh does not change your login
shell, install hooks, pull this repository, or upgrade the system automatically.
Use native package managers for upgrades.

## Software

Edit [conf/packages.json](conf/packages.json). Groups are `core`, `tools`,
`runtime`, `apps`, and `extensions`; omitting the group installs all five. An app
name installs only that app and its required installation channel.

The `extensions` group installs the GNOME Shell extensions under
`gnome.extensions` into the user's extension directory in a GNOME session, using
the pinned extensions.gnome.org build and SHA-256 digest for the running shell
version. New extensions load after the next login.

The `runtime` group shallow-clones the shell plugins and agent skill repositories
listed under `runtime.vendor` into `local/vendor`, installs the fzf release pinned
by the vendored checkout, and links `~/.local/bin/jsh`. Existing clones are not
updated. The `tools` group also installs the shared Homebrew formulae and taps under
`brew` (on Linux too, when Homebrew is on `PATH`), the distro's XFCE packages
under `desktops.xfce` in an XFCE session, the PyPI tools listed under `python`
(using uv when available and `pip install --user` otherwise), and the global npm
packages under `npm`. On macOS, `apps` adds the casks listed for the current host
under `hosts`. Sublime Text installs only with `just install sublime` on macOS, so
an existing manual installation is left alone; on Linux it is a Flatpak in `apps`.

| Platform      | Packages                  | Applications                                                                |
| ------------- | ------------------------- | --------------------------------------------------------------------------- |
| macOS         | Homebrew formulae         | Homebrew casks                                                              |
| Debian family | APT and Homebrew formulae | Helium/Ghostty AppImages, native VS Code, Waterfox/Spotify/Todoist Flatpaks |
| RHEL family   | DNF and Homebrew formulae | Helium/Ghostty AppImages, native VS Code, Waterfox/Spotify/Todoist Flatpaks |

Linux AppImages are installed into `~/.local/bin`; desktop entries go into
`$XDG_DATA_HOME/applications` (normally `~/.local/share/applications`). Downloads
require a matching release SHA-256 digest. Existing installations are left alone.
Linux graphical applications require x86_64 or aarch64 releases from their
respective distributors; an unavailable release fails with an explanation.
Spotify's Flatpak is subject to the architectures published on Flathub.
AppImages require a working AppImage/FUSE runtime on the target workstation.

Sources: [Helium downloads](https://helium.surf/download),
[Ghostty packages](https://ghostty.org/docs/install/binary),
[Ghostty community AppImage](https://github.com/pkgforge-dev/ghostty-appimage),
[VS Code Linux packages](https://code.visualstudio.com/docs/setup/linux), and
[Flathub](https://flathub.org). Ghostty's Linux AppImage is a community build.
Jsh does not enable Fedora COPR repositories on RHEL.

## Configuration

| Location                      | Purpose                                                        |
| ----------------------------- | -------------------------------------------------------------- |
| `dotfiles/`                   | Files and symlinks recursively discovered and linked into HOME |
| `conf/darwin/preferences.tsv` | macOS preferences, dark mode, and Dock                         |
| `conf/linux/`                 | Linux sysctl limits, memory, earlyoom, zram, coredump, power   |
| `conf/fonts.json`             | Verified Linux JetBrains Mono Nerd Font release and files      |
| `conf/audio.conf`             | Host-specific WirePlumber audio policy                         |
| `conf/keybindings.json`       | Keyboard behavior and GNOME/XFCE shortcuts                     |
| `conf/helium/`                | Helium profile preferences and extension/search policy         |
| `conf/gecko/waterfox.js`      | Behavioral preferences applied to the default Waterfox profile |
| `conf/gecko/policies.json`    | Waterfox add-on, search, and Citrix policy (macOS)             |
| `conf/vscode/`                | Settings merged into VS Code's configuration                   |
| `conf/sublime/`               | Settings merged into Sublime Text's user preferences           |

Linux tweaks configure passwordless sudo, SSH/GPG/Podman user services, the
JetBrains Mono Nerd Font, and the timezone from `JSH_TIMEZONE` (default
`America/New_York`). macOS tweaks restart Dock, Finder, or SystemUIServer when
their preferences change. Wallpaper changes require `JSH_WALLPAPER`; no wallpaper
is selected implicitly. Linux customization supports active GNOME and XFCE
sessions and skips headless or other sessions. Its `desktop`, `dock`, `audio`, and
`display` components restore panel monitors, application pins, audio output
cycling, and the X11 ultrawide split shortcut. In GNOME, `desktop` also enables the
Applications menu, the Window List, and Vitals, showing CPU, memory, load, and free
disk space in the top bar. The macOS `display` component uses
displayplacer to select desktop-density resolutions.
On macOS, keybindings configuration sets keyboard repeat and full keyboard
navigation. Add macOS menu shortcuts under `darwin.shortcuts` in
`conf/keybindings.json`, using Cocoa shortcut notation (for example, `@` for
Command and `^` for Control). Ghostty shortcuts belong in
`dotfiles/.config/ghostty/config`.

Dotfiles are linked individually. Conflicts and changed app settings are backed
up under `$XDG_STATE_HOME/jsh/backups` (normally `~/.local/state/jsh/backups`).
Restore a backup manually if needed. Symlinked dotfile parent directories require
manual review. SSH, credentials, and Git identity files are outside the managed
list. Personal shell additions belong in `~/.jshrc`, `~/.local/.jshrc`, or
`local/.jshrc`, loaded in that order.

App settings preserve unrelated values. VS Code JSONC comments are accepted;
modified settings are saved as JSON, with the original backed up. Browsers are
never closed automatically. Browser profiles must already exist.
Browser extensions and search engines come from root-owned enterprise policies,
written with `sudo -n` while the browser may stay open: Helium force-installs and
pins its extensions on macOS and Linux, and Waterfox installs its add-ons on macOS.
Waterfox policies are not managed for the Linux Flatpak. Toolbar layout, binary
patches, and forced themes are not managed.

## Commands

`j` is a Zsh function loaded by `dotfiles/.zshrc`:

- `j` loads the SSH keys named in `conf/git.json`, checks this checkout, dotfile
  links, and core tools, checks the current stack, then runs executables in
  `local/init.d`.
- `j status [STACK]` summarizes the Git repositories in a stack, or in
  `~/Projects` outside a stack.
- `j QUERY` jumps to a directory by frecency; `j pick` chooses one; `j --help`
  lists the rest.

A stack is a directory in `~/Stacks` whose children are repositories. An optional
`repos.list` holds one `NAME URL` per line; `j` clones missing entries.

These commands are on `PATH` through `bin/`:

| Command                    | Purpose                                               |
| -------------------------- | ----------------------------------------------------- |
| [cafe](bin/cafe)           | Keep the computer awake until interrupted             |
| [colours](bin/colours)     | Print the terminal's 256-color palette                |
| [jssh](bin/jssh)           | Open an ephemeral Jsh Zsh session on a Linux SSH host |
| [kubecolor](bin/kubecolor) | Colorize interactive `kubectl` output                 |
| [kubectx](bin/kubectx)     | Switch between kubectl contexts                       |
| [kubens](bin/kubens)       | Switch between Kubernetes namespaces                  |
| [nukem](bin/nukem)         | Remove finalizers from a namespace stuck terminating  |
| [proxy](bin/proxy)         | Run a command with proxy environment variables set    |

## Development

```sh
just check          # Syntax, headers, README coverage, linters, and tests
just check syntax   # Or one of: syntax, headers, readme, hooks
just lint           # Or one of: shell, python, yaml, markdown
just test
```

Runtime uses only Bash and the Python standard library. Development checks also
require Zsh, ShellCheck, Pylint, yamllint, and markdownlint. Tests use temporary
home directories and mocked commands. No setup command is run by the checks.

The former profiles, reconciliation journal, styled UI, Windows/Arch setup, and
application patching were retired.
