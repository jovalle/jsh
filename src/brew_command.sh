subcmd="${args[subcommand]:-help}"

# Parse extra args from catch_all
# Bashly stores catch_all args in other_args array
extra_args=("${other_args[@]}")

# Build flags to pass through
flags=()
[[ -n "${args[--quiet]}" ]] && flags+=("--quiet")
[[ -n "${args[--force]}" ]] && flags+=("--force")

case "${subcmd}" in
  setup)
    brew_setup
    ;;
  check)
    brew_check "${flags[@]}" "${extra_args[@]}"
    ;;
  help|--help|-h)
    echo -e "${BOLD}${CYAN}jsh brew${RESET} - Homebrew wrapper"
    echo ""
    echo "Subcommands:"
    echo "  setup                 Install or update Homebrew"
    echo "  check [package]       Verify package or run comprehensive checks"
    echo "  <brew command>        Pass through to brew (e.g., install, list, update)"
    echo ""
    echo "Check Options:"
    echo "  --quiet, -q          Silent mode (for check command)"
    echo "  --force, -f          Force check even if run recently"
    echo "  --linux              Force check as if on Linux platform"
    echo "  --darwin, --macos    Force check as if on Darwin/macOS platform"
    ;;
  *)
    if ! check_brew; then
      exit 1
    fi
    run_brew "${subcmd}" "${extra_args[@]}"
    ;;
esac
