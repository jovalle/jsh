# Jsh Bash Configuration
# Symlink or copy to ~/.bashrc

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
