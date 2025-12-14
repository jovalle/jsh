root_dir="$(get_root_dir)"

header "Running jsh diagnostics"

issues=0

# Check for required commands
echo -e "${BOLD}Checking required commands...${RESET}"
required_cmds=(brew git curl jq vim)
for cmd in "${required_cmds[@]}"; do
  if cmd_exists "$cmd"; then
    echo -e "  ${GREEN}✓${RESET} ${cmd}"
  else
    echo -e "  ${RED}✗${RESET} ${cmd} (missing)"
    ((issues++))
  fi
done
echo

# Check for broken symlinks
echo -e "${BOLD}Checking for broken symlinks...${RESET}"
broken_links=()
while IFS= read -r link; do
  broken_links+=("$link")
done < <(find "$HOME" -maxdepth 1 -type l ! -exec test -e {} \; -print 2> /dev/null)

if [[ ${#broken_links[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}✓${RESET} No broken symlinks found"
else
  echo -e "  ${YELLOW}⚠${RESET} Found ${#broken_links[@]} broken symlink(s):"
  for link in "${broken_links[@]}"; do
    echo -e "    ${RED}→${RESET} $link"
    ((issues++))
  done
fi
echo

# Check Git repository status
echo -e "${BOLD}Checking Git repository...${RESET}"
if [[ -d "${root_dir}/.git" ]]; then
  pushd "${root_dir}" > /dev/null
  if git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${RESET} Git repository is valid"
  else
    echo -e "  ${RED}✗${RESET} Git repository is corrupted"
    ((issues++))
  fi

  if [[ -f "${root_dir}/.gitmodules" ]]; then
    if git submodule status | grep -q '^-'; then
      echo -e "  ${YELLOW}⚠${RESET} Some submodules are not initialized"
      ((issues++))
    else
      echo -e "  ${GREEN}✓${RESET} All submodules initialized"
    fi
  fi
  popd > /dev/null
else
  echo -e "  ${RED}✗${RESET} Not a Git repository"
  ((issues++))
fi
echo

# Check Homebrew health
if cmd_exists brew; then
  echo -e "${BOLD}Checking Homebrew...${RESET}"
  if brew doctor > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${RESET} Homebrew is healthy"
  else
    echo -e "  ${YELLOW}⚠${RESET} Homebrew has warnings (run 'brew doctor' for details)"
  fi
fi
echo

# Summary
if [[ $issues -eq 0 ]]; then
  success "All checks passed! No issues found."
else
  warn "Found ${issues} issue(s). Please review the output above."
  exit 1
fi
