<p align="center">
  <img src="assets/terminal.png" alt="jsh" width="500">
</p>

<p align="center">Life in the shell automated</p>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jovalle/jsh/main/install.sh | bash
```

This clones into `~/.jsh` (or `JSH_HOME`), installs Git, Zsh, and the shell plugins, links
`dotfiles/` into your home, and opens the `jsh` shell. From a checkout:

```sh
./install.sh --dry-run        # preview
./install.sh helium waterfox  # also set up named groups
./install.sh --update tools   # update the group and installed Homebrew packages
```

The `tools` group installs [just](https://github.com/casey/just), which runs shortcuts from
a checkout:

```sh
just update       # update software and settings
just status       # preview what setup would change
just list groups  # list setup groups
```

Homebrew updates include installed dependencies and other outdated packages, and remove
installed packages Homebrew marks deprecated or disabled when nothing depends on them.
On macOS, updates include outdated App Store apps such as Xcode through `mas`, which
needs an Apple Account signed in to the App Store and cached sudo credentials (`sudo -v`).

## Enhancements

### Commands

| Command                         | Enhancement                                                                       |
| ------------------------------- | --------------------------------------------------------------------------------- |
| `git status`                    | Adds identity and branch notes and condenses file lists; `--raw` for plain output |
| `git status -R [DIR]`           | Outside a repository, summarizes every repository below `DIR` (or `~/Projects`)   |
| `git save`, `git load`          | Backs up and restores uncommitted changes through a secret gist                   |
| `git refresh`                   | Fetches origin and rebases onto the default branch                                |
| `git create`, `git get`         | Creates or clones a project under `$GIT_BASE`                                     |
| `git profile [NAME]`            | Switches identity, SSH key, and remotes from `local/git.json`                     |
| `git profiles`                  | Lists Git profiles and marks the current identity                                 |
| `git commits`                   | Browses formatted commit history                                                  |
| `git commit`                    | Rejects `Co-authored-by` trailers in every repository, then runs its own hooks    |
| `git handoff`                   | Carries unpushed commits to another workstation through Syncthing                 |
| `j [QUERY]`                     | Jumps to the best frecency match; `j` alone picks a project, `j -c` opens VS Code |
| `projects`                      | Summarizes the Git state of every tracked project and stack                       |
| `ls`, `l`, `la`, `lt`, `tree`   | Uses `eza` with Git status and icons, falling back to `exa` or `ls`               |
| `grep`                          | Colors matches and skips VCS, dependency, cache, and build directories            |
| `kubectl`                       | Colorized through `kubecolor`; `kubectx` and `kubens` switch context/namespace    |
| `nukem`                         | Clears finalizers from a namespace stuck terminating                              |
| `jsh`                           | Opens this checkout's shell without installing anything                           |
| `jsh init [-n] [-y]`            | Sources `local/init/*.zsh` in this shell; `-n` previews, `-y` never prompts       |
| `jsh update [GROUP ...]`        | Runs `install.sh --update` without closing open apps, then lists apps to restart  |
| `jssh HOST`                     | Opens SSH with the jsh runtime shipped to a temporary directory on the host       |
| `proxy`                         | Runs a command with HTTP/HTTPS proxy variables set                                |
| `cafe`                          | Keeps the screen awake until stopped                                              |
| `microphone`                    | Mutes the Elgato Wave:3 when it first appears in a desktop session                |
| `colours`                       | Prints the 256-color palette                                                      |
| `awk`, `sed`, `tar` (macOS)     | Use the GNU versions when installed                                               |
| `cp`, `mv`, `rm`, `ln`, `mkdir` | Verbose and interactive; `mkdir` creates parents                                  |

### Apps

| Helium                               | Waterfox                                 |
| ------------------------------------ | ---------------------------------------- |
| ![Helium browser](assets/helium.png) | ![Waterfox browser](assets/waterfox.png) |

Browser policies, preferences, and extensions are managed alongside VS Code, Sublime Text,
and Ghostty settings. Open each browser once before configuring it.
[Wox](https://github.com/Wox-launcher/Wox) starts at login and takes Command+Space from
Spotlight on macOS and Super+Space from the desktop on Linux; Spotlight and the desktop's app
launcher move to Control+Space. Open Wox once before configuring it.
Helium enables experimental web-platform features on Linux and macOS so [Kingpin](https://github.com/jovalle/kingpin) can use Web Bluetooth where needed. This also enables other experimental web features; existing browser flags are preserved.

## Layout

```sh
install.sh          # bootstrap
justfile            # shortcuts and checks
scripts/            # setup groups, shared code in scripts/lib/, smoke checks in check.py
scripts/groups.tsv  # every setup group with its platforms and purpose, in run order
scripts/packages.sh # package declarations; package-manager code is in scripts/lib/packages.sh
dotfiles/           # linked into $HOME
lib/                # shell runtime (lib/shell/), bin/git helpers and global Git hooks (lib/git/)
bin/                # everyday commands
```

`just check` runs syntax checks, ShellCheck, and the shell smoke checks in temporary homes.

`dotfiles/.gitconfig` points `core.hooksPath` at `lib/git/hooks/` in every repository that does
not set its own: those hooks reject `Co-authored-by` trailers, then run the repository's own
hooks. A repository's tracked `.githooks/` run once it opts in with `git config jsh.hooks true`,
followed by anything installed in `.git/hooks`. pre-commit refuses to install while
`core.hooksPath` is set, so install the commit checks with
`GIT_CONFIG_GLOBAL=/dev/null pre-commit install` after installing `pre-commit` and Go.
Gitleaks scans staged changes, including `archive/`. If it reports a credential, remove it
from the staged changes and rotate it if it was exposed. `just check hooks` runs the checks
manually; Gitleaks still scans only staged changes.

The Secrets CI check scans incoming Git history, including merged commits, using the
Gitleaks version pinned in `.pre-commit-config.yaml`. Local hooks can be bypassed;
configure GitHub push protection and require the CI check on the default branch.
Renovate proposes dependency updates and automerges passing non-major updates.
