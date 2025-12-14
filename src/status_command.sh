root_dir="$(get_root_dir)"

header "System Status"

check_brew || exit 1

# Homebrew formulae
echo -e "${BOLD}${MAGENTA}Homebrew Formulae:${RESET}"
if cmd_exists brew; then
  formulae_count=$(brew list --formula 2> /dev/null | wc -l | tr -d ' ')
  echo -e "  Installed: ${GREEN}${formulae_count}${RESET} formulae"

  outdated=$(brew outdated --formula 2> /dev/null | wc -l | tr -d ' ')
  if [[ "$outdated" -gt 0 ]]; then
    echo -e "  Outdated:  ${YELLOW}${outdated}${RESET} formulae"
  else
    echo -e "  Outdated:  ${GREEN}0${RESET} (all up to date)"
  fi
fi
echo

# Homebrew casks (macOS only)
if is_macos; then
  echo -e "${BOLD}${MAGENTA}Homebrew Casks:${RESET}"
  casks_count=$(brew list --cask 2> /dev/null | wc -l | tr -d ' ')
  echo -e "  Installed: ${GREEN}${casks_count}${RESET} casks"

  outdated_casks=$(brew outdated --cask 2> /dev/null | wc -l | tr -d ' ')
  if [[ "$outdated_casks" -gt 0 ]]; then
    echo -e "  Outdated:  ${YELLOW}${outdated_casks}${RESET} casks"
  else
    echo -e "  Outdated:  ${GREEN}0${RESET} (all up to date)"
  fi
  echo
fi

# Homebrew services
echo -e "${BOLD}${MAGENTA}Homebrew Services:${RESET}"
if cmd_exists brew; then
  while IFS= read -r line; do
    service=$(echo "$line" | awk '{print $1}')
    svc_status=$(echo "$line" | awk '{print $2}')

    if [[ "$svc_status" == "started" ]]; then
      echo -e "  ${GREEN}●${RESET} ${service} (${GREEN}running${RESET})"
    elif [[ "$svc_status" == "stopped" ]]; then
      echo -e "  ${RED}●${RESET} ${service} (${RED}stopped${RESET})"
    else
      echo -e "  ${YELLOW}●${RESET} ${service} (${YELLOW}${svc_status}${RESET})"
    fi
  done < <(brew services list 2> /dev/null | tail -n +2)
fi
echo

# Symlinks
echo -e "${BOLD}${MAGENTA}Dotfile Symlinks:${RESET}"
symlink_count=0
broken_count=0

for link in "$HOME"/.* "$HOME"/*; do
  [[ ! -L "$link" ]] && continue
  target=$(readlink "$link" 2>/dev/null || true)
  [[ -z "$target" ]] && continue

  case "$target" in
    "$root_dir"*) ;;
    *) continue ;;
  esac

  ((++symlink_count))
  if [[ ! -e "$link" ]]; then
    ((++broken_count))
  fi
done

echo -e "  Total:  ${GREEN}${symlink_count}${RESET} symlinks"
if [[ "$broken_count" -gt 0 ]]; then
  echo -e "  Broken: ${RED}${broken_count}${RESET} symlinks"
else
  echo -e "  Broken: ${GREEN}0${RESET} (all valid)"
fi
echo

# Git status
echo -e "${BOLD}${MAGENTA}Git Repository:${RESET}"
if [[ -d "${root_dir}/.git" ]]; then
  pushd "${root_dir}" > /dev/null
  branch=$(git branch --show-current 2> /dev/null || echo "unknown")
  echo -e "  Branch:  ${CYAN}${branch}${RESET}"

  git_status=$(git status --porcelain 2> /dev/null | wc -l | tr -d ' ')
  if [[ "$git_status" -gt 0 ]]; then
    echo -e "  Changes: ${YELLOW}${git_status}${RESET} uncommitted changes"
  else
    echo -e "  Changes: ${GREEN}clean${RESET}"
  fi
  popd > /dev/null
fi
echo

# System info
echo -e "${BOLD}${MAGENTA}System Information:${RESET}"
echo -e "  OS:     $(uname -s) $(uname -r)"
echo -e "  Shell:  ${SHELL} (${ZSH_VERSION:-bash})"
echo -e "  Arch:   $(uname -m)"
echo
