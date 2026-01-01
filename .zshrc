# Jsh Zsh Configuration
# Symlink or copy to ~/.zshrc
# shellcheck shell=bash disable=SC2296

# Enable p10k instant prompt (must be at very top)
# shellcheck source=/dev/null
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
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
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
