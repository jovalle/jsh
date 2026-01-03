# profiles.sh - Git profile management helpers
#
# Provides helper functions for managing git user profiles.
# Profiles are defined in config/profiles.json and can be applied
# to git repositories to set user.name and user.email.
#
# Profile detection works by matching the repo's user.email against
# configured profiles.

# shellcheck disable=SC2034

# =============================================================================
# Configuration
# =============================================================================

_PROFILES_CONFIG="${JSH_DIR:-${HOME}/.jsh}/local/profiles.json"

# =============================================================================
# Helper Functions
# =============================================================================

# Get profile data by name
# Arguments:
#   $1 - Profile name
# Output: JSON object with name, email, username
_profiles_get() {
  local name="$1"

  [[ -f "$_PROFILES_CONFIG" ]] || return 1
  command -v jq &>/dev/null || return 1

  jq -r --arg name "$name" '.profiles[$name] // empty' "$_PROFILES_CONFIG" 2>/dev/null
}

# List all profile names
# Output: Profile names, one per line
_profiles_list() {
  [[ -f "$_PROFILES_CONFIG" ]] || return 0
  command -v jq &>/dev/null || return 0

  jq -r '.profiles | keys[]' "$_PROFILES_CONFIG" 2>/dev/null
}

# Check if profile exists
# Arguments:
#   $1 - Profile name
# Returns: 0 if exists, 1 otherwise
_profiles_exists() {
  local name="$1"
  local result

  result="$(_profiles_get "$name")"
  [[ -n "$result" ]]
}

# Apply a profile to a git repository
# Arguments:
#   $1 - Profile name
#   $2 - Directory (optional, defaults to PWD)
# Returns: 0 on success, 1 on failure
_profiles_apply() {
  local profile_name="$1"
  local dir="${2:-.}"
  local profile_data name email username host

  profile_data="$(_profiles_get "$profile_name")"
  if [[ -z "$profile_data" ]]; then
    printf '%s\n' "Profile not found: $profile_name" >&2
    return 1
  fi

  # Check if directory is a git repo
  if ! git -C "$dir" rev-parse --git-dir &>/dev/null; then
    printf '%s\n' "Not a git repository: $dir" >&2
    return 1
  fi

  name=$(printf '%s' "$profile_data" | jq -r '.name // empty')
  email=$(printf '%s' "$profile_data" | jq -r '.email // empty')
  username=$(printf '%s' "$profile_data" | jq -r '.user // empty')
  host=$(printf '%s' "$profile_data" | jq -r '.host // empty')

  if [[ -n "$name" ]]; then
    git -C "$dir" config user.name "$name"
  fi

  if [[ -n "$email" ]]; then
    git -C "$dir" config user.email "$email"
  fi

  if [[ -n "$username" ]]; then
    git -C "$dir" config github.user "$username"
  fi

  # Update origin remote to point to user's fork
  if [[ -n "$username" ]]; then
    local origin_url repo_name new_origin_url
    local url_host url_protocol
    origin_url=$(git -C "$dir" remote get-url origin 2>/dev/null)

    if [[ -n "$origin_url" ]]; then
      # Extract repo name (last path component without .git)
      repo_name="${origin_url##*/}"
      repo_name="${repo_name%.git}"

      # Detect protocol and extract host from existing URL
      if [[ "$origin_url" == https://* ]]; then
        # HTTPS: https://host/owner/repo.git
        url_protocol="https"
        url_host="${origin_url#https://}"
        url_host="${url_host%%/*}"
      elif [[ "$origin_url" == git@* ]]; then
        # SSH: git@host:owner/repo.git
        url_protocol="ssh"
        url_host="${origin_url#git@}"
        url_host="${url_host%%:*}"
      elif [[ "$origin_url" == ssh://* ]]; then
        # SSH alternate: ssh://git@host/owner/repo.git
        url_protocol="ssh-alt"
        url_host="${origin_url#ssh://git@}"
        url_host="${url_host%%/*}"
      else
        # Unknown format, skip origin update
        return 0
      fi

      # Use profile host if specified, otherwise keep existing host
      [[ -z "$host" ]] && host="$url_host"

      if [[ -n "$repo_name" ]]; then
        # Build new URL preserving the original protocol
        case "$url_protocol" in
          https)
            new_origin_url="https://${host}/${username}/${repo_name}.git"
            ;;
          ssh)
            new_origin_url="git@${host}:${username}/${repo_name}.git"
            ;;
          ssh-alt)
            new_origin_url="ssh://git@${host}/${username}/${repo_name}.git"
            ;;
        esac

        git -C "$dir" remote set-url origin "$new_origin_url"
      fi
    fi
  fi

  return 0
}

# Get current git config for a directory
# Arguments:
#   $1 - Directory (optional, defaults to PWD)
# Output: "name|email" or empty if not a git repo
_profiles_get_current() {
  local dir="${1:-.}"
  local name email

  git -C "$dir" rev-parse --git-dir &>/dev/null || return 1

  name=$(git -C "$dir" config user.name 2>/dev/null)
  email=$(git -C "$dir" config user.email 2>/dev/null)

  printf '%s|%s\n' "$name" "$email"
}

# Detect which profile matches a git repo's config
# Matches by email address
# Arguments:
#   $1 - Directory (optional, defaults to PWD)
# Output: Profile name or empty if no match
_profiles_detect() {
  local dir="${1:-.}"
  local current_config current_email profile_name profile_data p_email

  current_config="$(_profiles_get_current "$dir")"
  [[ -z "$current_config" ]] && return 1

  current_email="${current_config#*|}"
  [[ -z "$current_email" ]] && return 1

  while IFS= read -r profile_name; do
    [[ -z "$profile_name" ]] && continue
    profile_data="$(_profiles_get "$profile_name")"
    p_email=$(printf '%s' "$profile_data" | jq -r '.email // empty')

    if [[ "$p_email" == "$current_email" ]]; then
      printf '%s\n' "$profile_name"
      return 0
    fi
  done < <(_profiles_list)

  return 1
}

# =============================================================================
# Profile Subcommand Handlers
# =============================================================================

# Show current profile status
_profile_cmd_status() {
  local current_config detected_profile origin_url
  local C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'

  if ! git rev-parse --git-dir &>/dev/null; then
    printf '%s\n' "Not in a git repository" >&2
    return 1
  fi

  current_config="$(_profiles_get_current)"
  detected_profile="$(_profiles_detect)"
  origin_url=$(git remote get-url origin 2>/dev/null)
  github_user=$(git config github.user 2>/dev/null)

  local current_name="${current_config%|*}"
  local current_email="${current_config#*|}"

  printf '%s\n' "Current git user:"
  if [[ -n "$current_name" ]]; then
    printf '  Name:   %s\n' "$current_name"
  else
    printf '  Name:   %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi
  if [[ -n "$current_email" ]]; then
    printf '  Email:  %s\n' "$current_email"
  else
    printf '  Email:  %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi
  if [[ -n "$origin_url" ]]; then
    printf '  Origin: %b%s%b\n' "$C_CYAN" "$origin_url" "$C_RESET"
  else
    printf '  Origin: %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi
  if [[ -n "$github_user" ]]; then
    printf '  GitHub: %b%s%b\n' "$C_CYAN" "$github_user" "$C_RESET"
  else
    printf '  GitHub: %b(not set)%b\n' "$C_DIM" "$C_RESET"
  fi

  printf '%s\n' ""
  if [[ -n "$detected_profile" ]]; then
    printf 'Profile: %b%s%b\n' "$C_GREEN" "$detected_profile" "$C_RESET"
  else
    printf 'Profile: %b(none)%b\n' "$C_DIM" "$C_RESET"
  fi
}

# List all profiles
_profile_cmd_list() {
  local C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
  local profile_name profile_data name email current_profile

  if [[ ! -f "$_PROFILES_CONFIG" ]]; then
    printf '%s\n' "No profiles configured."
    printf '%s\n' "Create config at: $_PROFILES_CONFIG"
    return 0
  fi

  current_profile="$(_profiles_detect 2>/dev/null)"

  printf '%b%-15s %-30s %s%b\n' "$C_DIM" "PROFILE" "EMAIL" "NAME" "$C_RESET"
  printf '%s\n' "$(printf '%60s' '' | tr ' ' '-')"

  while IFS= read -r profile_name; do
    [[ -z "$profile_name" ]] && continue
    profile_data="$(_profiles_get "$profile_name")"
    name=$(printf '%s' "$profile_data" | jq -r '.name // empty')
    email=$(printf '%s' "$profile_data" | jq -r '.email // empty')

    local marker=""
    if [[ "$profile_name" == "$current_profile" ]]; then
      marker="${C_GREEN}* ${C_RESET}"
    else
      marker="  "
    fi

    printf '%s%b%-15s%b %-30s %s\n' "$marker" "$C_CYAN" "$profile_name" "$C_RESET" "$email" "$name"
  done < <(_profiles_list)
}

# Apply a profile to the current repo
_profile_cmd_apply() {
  local profile_name="$1"
  local C_GREEN=$'\033[32m' C_CYAN=$'\033[36m' C_RESET=$'\033[0m'

  if [[ -z "$profile_name" ]]; then
    printf '%s\n' "Usage: project profile <name>" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "Available profiles:" >&2
    _profiles_list | while read -r p; do
      printf '%s\n' "  $p" >&2
    done
    return 1
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    printf '%s\n' "Not in a git repository" >&2
    return 1
  fi

  if _profiles_apply "$profile_name"; then
    printf '%b\n' "${C_GREEN}Applied profile:${C_RESET} ${C_CYAN}${profile_name}${C_RESET}"
    printf '%s\n' ""
    _profile_cmd_status
  fi
}

# Check all projects for their profile status
_profile_cmd_check() {
  local dir display_name detected_profile
  local C_CYAN=$'\033[36m' C_GREEN=$'\033[32m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'

  printf '%b%-40s %s%b\n' "$C_DIM" "PROJECT" "PROFILE" "$C_RESET"
  printf '%s\n' "$(printf '%55s' '' | tr ' ' '-')"

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ ! -d "$dir/.git" ]] && continue

    display_name="$(_projects_display_name "$dir")"
    detected_profile="$(_profiles_detect "$dir")"

    if [[ -n "$detected_profile" ]]; then
      printf '%-40s %b%s%b\n' "$display_name" "$C_GREEN" "$detected_profile" "$C_RESET"
    else
      printf '%-40s %b-%b\n' "$display_name" "$C_DIM" "$C_RESET"
    fi
  done < <(_projects_get_all)
}

# Show SSH config documentation
_profile_cmd_docs() {
  cat << 'EOF'
# SSH Config for Git Profiles
# ===========================
#
# To use different SSH keys per profile, configure ~/.ssh/config:
#
# Example for work profile (GitHub Enterprise):
#
#   Host github-work
#       HostName github.company.com
#       User git
#       IdentityFile ~/.ssh/id_work
#       IdentitiesOnly yes
#
# Example for personal profile (GitHub.com):
#
#   Host github-personal
#       HostName github.com
#       User git
#       IdentityFile ~/.ssh/id_personal
#       IdentitiesOnly yes
#
# Then clone using the host alias:
#   git clone github-work:org/repo.git      # Uses work key
#   git clone github-personal:user/repo.git # Uses personal key
#
# For existing repos, update the remote:
#   git remote set-url origin github-work:org/repo.git
#
# Profile config location: ~/.jsh/config/profiles.json
EOF
}

# Show help for profile subcommand
_profile_cmd_help() {
  cat << EOF
Usage: project profile [command] [args]

Commands:
  (none)        Show current profile for this repo
  list          List all configured profiles
  <name>        Apply profile to current repo
  check         Check all projects and show profiles
  docs          Show SSH config documentation

Examples:
  project profile                # Show current profile
  project profile list           # List all profiles
  project profile work           # Apply work profile
  project profile check          # Check all projects

Config: $_PROFILES_CONFIG
EOF
}
