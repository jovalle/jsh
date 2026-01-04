# Jsh Zsh Configuration
# Symlink or copy to ~/.zshrc
# shellcheck shell=bash disable=SC2296

# =============================================================================
# PATH Bootstrap (must be first - required for basic commands like uname)
# =============================================================================
# Ensure minimal system PATH exists before any commands run
# This handles cases where PATH is empty or missing system directories
if [[ -z "${PATH:-}" ]] || [[ ":${PATH}:" != *":/usr/bin:"* ]]; then
    export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
fi

# Ensure UTF-8 locale is set early (required for Unicode prompt icons)
# VS Code terminals may not inherit LANG from the parent environment
# Customize via JSH_LANG (e.g., de_DE.UTF-8, ja_JP.UTF-8, pt_BR.UTF-8)
export LANG="${JSH_LANG:-en_US.UTF-8}"
export LC_ALL="${JSH_LANG:-en_US.UTF-8}"

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
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
