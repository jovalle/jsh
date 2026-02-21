# Jsh Bash Profile
# Symlink or copy to ~/.bash_profile
# This file is sourced for LOGIN shells (VS Code, Terminal.app, SSH)

# Source .bashrc for interactive shells
# This ensures consistent configuration between login and non-login shells
if [[ -f ~/.bashrc ]]; then
    source ~/.bashrc
fi
