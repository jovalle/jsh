# Jsh Bash Configuration
# Symlink or copy to ~/.bashrc

# Ensure essential PATH is set before any sourcing
if [[ -z "${PATH:-}" ]] || [[ "${PATH}" != */usr/bin* ]]; then
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
fi

# Homebrew PATH (macOS) - must be early so modern bash/tools are found first
# This is required for jsh which needs bash 4+ (macOS ships with bash 3.2)
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# JSH_DIR - where jsh is installed
export JSH_DIR="${JSH_DIR:-$HOME/.jsh}"

# Source J shell configuration
if [[ -f "${JSH_DIR}/src/init.sh" ]]; then
    source "${JSH_DIR}/src/init.sh"
else
    echo "Jsh not found at ${JSH_DIR}"
    echo "Run: git clone https://github.com/jovalle/jsh ~/.jsh && ~/.jsh/jsh install"
fi

# Local overrides (machine-specific, not tracked)
# shellcheck source=/dev/null
[[ -f ~/.bashrc.local ]] && source ~/.bashrc.local
