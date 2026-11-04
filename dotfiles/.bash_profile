# shellcheck shell=bash
# Keep interactive login shells consistent with ordinary Bash terminals.
[[ ! -r ${HOME}/.bashrc ]] || . "${HOME}/.bashrc"
