# Contributing to jsh

Thank you for considering contributing to jsh! This guide will help you get started with making contributions to this project.

## Getting Started

1. Fork and clone the repository
2. Install dependencies using `task install`
3. Make your changes
4. Test your changes
5. Submit a pull request

## Development Workflow

### Prerequisites

- `task` (Task runner) - Install via `./setup.sh`
- `commitizen` - Installed automatically via `task install`
- `pre-commit` - Installed automatically via `task install`

### Making Changes

1. Create a new branch for your feature or fix:

   ```bash
   git checkout -b feat/your-feature-name
   ```

2. Make your changes to the codebase

3. Test your changes:

   ```bash
   task install  # Test installation
   task configure  # Test configuration
   ```

## Commit Convention

This project follows [Conventional Commits](https://www.conventionalcommits.org/) specification. All commits must follow this format to maintain a clean and readable git history.

**Commit message validation is enforced automatically via pre-commit hooks.** If your commit message doesn't follow the conventional format, the commit will be rejected with a helpful error message.

### Using Commitizen

We use `commitizen` to ensure all commits follow the conventional commit format.

#### Installation

Commitizen is automatically installed when you run:

```bash
task install
```

If you need to install it manually:

- **Linux/WSL**: `pipx install commitizen && pipx install pre-commit`
- **macOS**: `brew install commitizen && brew install pre-commit`

After installation, set up the git hooks:

```bash
task git-hooks
```

#### Making Commits

Instead of using `git commit`, use the interactive commitizen tool:

```bash
task commit
# or
task cz
```

This will guide you through an interactive prompt:

1. **Select commit type**:
   - `feat`: A new feature
   - `fix`: A bug fix
   - `docs`: Documentation changes
   - `style`: Code style changes (formatting, etc.)
   - `refactor`: Code refactoring
   - `perf`: Performance improvements
   - `test`: Adding or updating tests
   - `build`: Build system or dependency changes
   - `ci`: CI/CD changes
   - `chore`: Other changes that don't modify src/test files
   - `revert`: Revert a previous commit

2. **Add scope** (optional): e.g., `taskfile`, `zsh`, `readme`

3. **Breaking change?**: Indicate if this introduces breaking changes

4. **Description**: Short summary of the change

5. **Body** (optional): Longer description of the change

### Commit Examples

```yaml
feat(taskfile): add interactive conventional commit helper
fix(zsh): resolve path issues in WSL
docs(readme): update installation instructions
chore(deps): upgrade fzf to latest version
```

### Breaking Changes

If your change introduces breaking changes, make sure to:

1. Select "yes" when prompted about breaking changes
2. Provide a clear description of what breaks and how to migrate
3. Update relevant documentation

Example:

```yaml
feat(taskfile)!: restructure OS-specific task organization

BREAKING CHANGE: OS-specific tasks are now under `os:` namespace.
Update your scripts from `task linux:install` to `task os:install`.
```

## Pull Request Process

1. Ensure your code follows the project's style and conventions
2. Update documentation if you're adding new features
3. Use commitizen for all commits
4. Push your branch and create a pull request
5. Wait for review and address any feedback

## Questions or Issues?

If you have questions or run into issues:

- Open an issue on GitHub
- Check existing issues for similar problems
- Review the README.md for setup instructions

Thank you for contributing!
