<div align="center">
  <img src=".github/assets/jsh.jpeg" width="200px" height="200px" alt="jsh logo" />

# jsh

  <p>
    A collection of files to improve life in the shell
  </p>
</div>

## 📖 Overview

A feature-rich and consistent life in the shell, powered by the `jsh` CLI. This is a mono repository for my local environments in both macOS and Linux (+WSL). I sync this project/directory across my devices using [Syncthing](https://syncthing.net/).

## 🚀 Capabilities

The core of this repository is the `jsh` utility, a comprehensive command-line interface that manages the entire environment.

### 🛠️ Core Features

- **Cross-Platform Support**: Seamlessly works across **macOS**, **Linux**, and **Windows** (via **WSL**).
- **Automated Setup**: Single-command initialization (`jsh init --full`) to go from a fresh OS to a fully configured environment.
- **Dotfile Management**: Deploys configurations for `zsh`, `vim`, `git`, `tmux`, and more using symlinks (inspired by GNU Stow).
- **Package Management**: Unified interface (`jsh install`) that abstracts `brew`, `apt`, `dnf`, `pacman`, `apk`, and `zypper`.
- **Application Configuration**: Automates settings for **VS Code** (settings/keybindings) and macOS system defaults.
- **Diagnostics & Maintenance**: Built-in health checks (`jsh doctor`), cleanup scripts (`jsh clean`), and backup/restore functionality.

### 🍟 Binaries

Custom tools and wrappers located in `./bin/` are automatically added to `PATH`:

| Binary     | Description                                                                           |
| :--------- | :------------------------------------------------------------------------------------ |
| `gitx`     | Bulk git command runner. Update or run commands across multiple repositories at once. |
| `httpstat` | Visual curl statistics tool for debugging HTTP requests.                              |
| `kubectx`  | Fast way to switch between Kubernetes contexts.                                       |
| `kubens`   | Fast way to switch between Kubernetes namespaces.                                     |
| `colours`  | Simple script to test terminal color capabilities.                                    |

## 📚 Core Elements

My shell of choice is `zsh` with [zinit](https://github.com/zdharma-continuum/zinit) as the zippy plugin manager.

### 🔌 Shell Plugins

| Plugin                                       | Description                        |
| -------------------------------------------- | ---------------------------------- |
| `romkatv/powerlevel10k`                      | Fast, customizable prompt theme    |
| `Aloxaf/fzf-tab`                             | FZF-powered tab completion         |
| `zsh-users/zsh-completions`                  | Additional completion definitions  |
| `zsh-users/zsh-autosuggestions`              | Fish-like autosuggestions          |
| `zdharma-continuum/fast-syntax-highlighting` | Syntax highlighting                |
| `akarzim/zsh-docker-aliases`                 | Docker command aliases             |
| `MichaelAquilina/zsh-you-should-use`         | Reminds you of aliases             |
| `wfxr/forgit`                                | Git commands with fzf              |
| `lukechilds/zsh-nvm`                         | Lazy-load nvm                      |
| `mafredri/zsh-async`                         | Async library                      |
| `supercrabtree/k`                            | Directory listings with git status |

## ⚡ Quick Start

1. **Clone the repository:**

   ```bash
   git clone https://github.com/jovalle/.jsh.git ~/.jsh
   ```

2. **Initialize the environment:**

   ```bash
   ~/.jsh/jsh init --setup
   ```

   This will:

   - Install Homebrew (on macOS/Linux)
   - Configure your shell (zsh or bash)
   - Set up shell plugins and themes
   - Install packages defined in configs/
   - Link dotfiles to your home directory
   - Apply system settings

3. **Or run step-by-step:**

   ```bash
   jsh init              # Set up shell environment only
   jsh install           # Install packages from configs/
   jsh configure         # Apply dotfiles and system settings
   ```

## 📦 Installation & Usage

The `jsh` CLI is your main entry point. Once initialized, it is available in your PATH.

```bash
jsh --help            # Show all commands
jsh init              # Set up shell environment (one-time)
jsh install           # Install packages defined in configs/
jsh install           # Install specific package(s) and add to config
jsh uninstall <pkg>   # Uninstall package and remove from config
jsh upgrade           # Upgrade all packages (brew, zinit, system)
jsh configure         # Apply system settings and link dotfiles
jsh dotfiles          # Manage dotfile symlinks
jsh status            # Show packages, services, symlinks, git status
jsh doctor            # Check for missing tools, broken symlinks
jsh clean             # Remove caches, temp files, old brew versions
jsh deinit            # Remove jsh symlinks and restore backups
jsh brew <args>       # Homebrew wrapper (handles root delegation)
jsh completions       # Generate shell completion script
```

### 🎯 Init Command Options

The `init` command supports several flags for customization:

```bash
jsh init --setup              # Initialize + install packages + configure
jsh init --non-interactive    # Use defaults (zsh + full setup)
jsh init --shell zsh          # Pre-select shell (zsh, bash, or skip)
jsh init --minimal            # Lightweight setup without plugins
jsh init --full               # Full setup with themes, plugins, completions
jsh init --no-install         # Skip package installation
jsh init --skip-brew          # Skip Homebrew installation
jsh init --dry-run            # Preview changes without applying
```

### 📦 Install Command Options

Install packages via specific package managers:

```bash
jsh install <package> --brew     # Install via Homebrew
jsh install <package> --npm      # Install via npm
jsh install <package> --pip      # Install via pip
jsh install <package> --cargo    # Install via cargo (Rust)
jsh install <package> --gem      # Install via Ruby gem
jsh install <package> --apt      # Install via apt (Debian/Ubuntu)
jsh install <package> --dnf      # Install via dnf (Fedora/RHEL)
jsh install <package> --pacman   # Install via pacman (Arch)
jsh install <package> --yum      # Install via yum (CentOS/RHEL)
jsh install <package> --zypper   # Install via zypper (openSUSE)
```

## 📂 Project Structure

```text
.jsh/
├── bin/                            # Custom CLI tools and utilities
│   ├── colours                     # Terminal color test script
│   ├── gitx                        # Bulk git command runner
│   ├── httpstat                    # Visual curl statistics
│   ├── kubectx                     # Kubernetes context switcher
│   └── kubens                      # Kubernetes namespace switcher
├── configs/                        # Package manifests and app configs
│   ├── git/                        # Git profiles and configurations
│   │   └── profiles.json.example   # Example git profiles
│   ├── linux/                      # Linux distro configs
│   │   ├── apk.json                # Alpine packages
│   │   ├── apt.json                # Debian/Ubuntu packages
│   │   ├── dnf.json                # Fedora packages
│   │   ├── formulae.json           # Homebrew formulae (Linux)
│   │   ├── pacman.json             # Arch packages
│   │   ├── services.json           # Linux services
│   │   ├── yum.json                # CentOS/RHEL packages
│   │   └── zypper.json             # openSUSE packages
│   ├── macos/                      # macOS-specific configs
│   │   ├── casks.json              # Homebrew casks
│   │   ├── formulae.json           # Homebrew formulae
│   │   └── services.json           # macOS services
│   ├── vscode/                     # VS Code settings and keybindings
│   │   ├── keybindings.json        # Keyboard shortcuts
│   │   └── settings.json           # Editor settings
│   └── windows/                    # Windows/WSL configs
│       ├── fonts.json              # Windows fonts
│       └── winget.json             # Windows package manager
├── dotfiles/                       # Configuration files (symlinked to ~/)
│   ├── .bashrc                     # Bash configuration
│   ├── .commitlintrc.json          # Commit message linting
│   ├── .config/                    # XDG config directory
│   ├── .czrc                       # Commitizen configuration
│   ├── .editorconfig               # Editor configuration
│   ├── .eslintrc.json              # ESLint configuration
│   ├── .gitconfig                  # Git global configuration
│   ├── .inputrc                    # Readline configuration
│   ├── .jsh_local                  # Local overrides (not tracked)
│   ├── .jshrc                      # Shell agnostic configuration
│   ├── .markdownlint.json          # Markdown linting rules
│   ├── .p10k.zsh                   # Powerlevel10k theme config
│   ├── .pre-commit-config.yaml     # Pre-commit hooks
│   ├── .prettierrc.json            # Prettier configuration
│   ├── .pylintrc                   # Python linting
│   ├── .shellcheckrc               # ShellCheck configuration
│   ├── .tmux.conf                  # Tmux configuration
│   ├── .vim/                       # Vim plugins and config
│   ├── .vimrc                      # Vim configuration
│   ├── .yamllint                   # YAML linting
│   ├── .zsh/                       # Zsh plugins and functions
│   └── .zshrc                      # Zsh configuration
├── scripts/                        # Setup and maintenance scripts
│   ├── linux/                      # Linux system configuration
│   ├── macos/                      # macOS system configuration
│   ├── unix/                       # Cross-platform scripts
│   └── windows/                    # Windows/WSL configuration
└── src/                            # jsh CLI source code (bashly)
    ├── bashly.yml                  # CLI command definitions
    └── lib/                        # Shared shell functions
```

## 🔧 Development

The `jsh` CLI is built using [bashly](https://bashly.dannyb.co/), a bash CLI framework. To modify commands:

1. **Edit the command definitions:** Modify `src/bashly.yml` or individual command files in `src/`
2. **Regenerate the CLI:** Run `make build` or `bashly generate`
3. **Test changes:** The updated `jsh` script is ready to use

### Available Make Targets

```bash
make help              # Show all available targets
make install-tools     # Install development tools (shfmt, shellcheck, etc.)
make fmt               # Format all code (shell, Python, YAML, JSON, Markdown)
make lint              # Lint all code
make build             # Regenerate jsh from bashly sources
```
