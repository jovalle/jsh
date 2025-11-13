#!/usr/bin/env bash
# shellcheck shell=bash
#
# brew-update-checker.sh - Lightweight Homebrew update checker with smart caching
#
# Checks for outdated Homebrew packages once per day and displays a notification.
# Runs in the background to minimize shell startup delay.
#

# Only run if brew is available
if ! command -v brew &>/dev/null; then
  return 0 2>/dev/null || exit 0
fi

# Configuration
BREW_CACHE_DIR="${HOME}/.cache/brew"
BREW_UPDATE_STAMP="${BREW_CACHE_DIR}/last_update_check"
BREW_OUTDATED_COUNT="${BREW_CACHE_DIR}/outdated_count"
UPDATE_INTERVAL=86400  # 24 hours in seconds

# Ensure cache directory exists
[[ -d "${BREW_CACHE_DIR}" ]] || mkdir -p "${BREW_CACHE_DIR}" 2>/dev/null

# Check if we should update (>24 hours since last check)
should_update=0
if [[ ! -f "${BREW_UPDATE_STAMP}" ]]; then
  should_update=1
else
  last_update=$(cat "${BREW_UPDATE_STAMP}" 2>/dev/null || echo 0)
  now=$(date +%s)
  time_diff=$((now - last_update))

  if [[ ${time_diff} -ge ${UPDATE_INTERVAL} ]]; then
    should_update=1
  fi
fi

# Run background update if needed
if [[ ${should_update} -eq 1 ]]; then
  {
    brew update &>/dev/null
    date +%s > "${BREW_UPDATE_STAMP}"
    brew outdated --quiet 2>/dev/null | wc -l | tr -d ' ' > "${BREW_OUTDATED_COUNT}"
  } &
fi

# Display outdated package count if available (instant)
if [[ -f "${BREW_OUTDATED_COUNT}" ]]; then
  count=$(cat "${BREW_OUTDATED_COUNT}" 2>/dev/null || echo 0)
  if [[ ${count} -gt 0 ]]; then
    # Use warn function if available, otherwise use fallback
    if command -v warn &>/dev/null; then
      warn "📦 ${count} Homebrew package(s) can be upgraded (run 'brew upgrade' or 'task update')"
    else
      echo -e "\033[33m📦 ${count} Homebrew package(s) can be upgraded (run 'brew upgrade' or 'task update')\033[0m"
    fi
  fi
fi
